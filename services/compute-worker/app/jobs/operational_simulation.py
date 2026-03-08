from __future__ import annotations

import time
from pathlib import Path
from typing import Any, Dict, Optional

from avaframe.in3Utils import cfgUtils
from avaframe.in3Utils import logUtils
from avaframe.in3Utils import initializeProject as initProj
from avaframe.in3Utils import fileHandlerUtils as fU
from avaframe.log2Report import generateReport as gR

from avaframe.com1DFA import com1DFA
from avaframe.com2AB import com2AB
from avaframe.out3Plot import outAB

# ---- simple mappings (à ajuster selon ton modèle)
FRICT_MODEL_MAP = {
    "dry": "samosATAuto",
    "wet": "wetSnow",
    "powder": "voellmy",
    "custom": None,  # l'utilisateur doit passer un override frictModel
}

# Presets qualité (exemples: tu ajusteras selon tes besoins/ini)
QUALITY_PRESETS: dict[str, dict[str, dict[str, Any]]] = {
    "fast": {
        "GENERAL": {
            # exemple: moins de steps / moins de sorties
            # "tSteps": 80,
        }
    },
    "default": {},
    "high": {
        "GENERAL": {
            # exemple: plus de steps
            # "tSteps": 300,
        }
    },
}


def _deep_update(dst: Dict[str, Any], src: Dict[str, Any]) -> Dict[str, Any]:
    for k, v in src.items():
        if isinstance(v, dict) and isinstance(dst.get(k), dict):
            _deep_update(dst[k], v)  # type: ignore[index]
        else:
            dst[k] = v
    return dst


def _apply_overrides_cfg(cfg, overrides: Dict[str, Dict[str, Any]]) -> None:
    """
    Apply overrides to a ConfigParser-like object.
    overrides format: { "SECTION": {"key": value, ...}, ... }
    """
    for section, kv in overrides.items():
        if not cfg.has_section(section):
            cfg.add_section(section)
        for key, value in kv.items():
            cfg.set(section, key, str(value))


def run(
    ava_dir,
    avalanche_type: str,
    quality: str,
    snow_density_kg_m3: float,
    snow_density_entrained_kg_m3: float | None = None,
    release_thickness_m: float | None = None,
    config_overrides: dict | None = None,
    **kwargs,
):
    """
    Operational simulation: com1DFA + optional com2AB.
    Returns JSON-friendly output paths and peak files list.
    """
    # flags (safe defaults)
    clean: bool = bool(kwargs.get("clean", False))
    run_ab: bool = bool(kwargs.get("run_ab", False))
    serialize_peak_df: bool = bool(kwargs.get("serialize_peak_df", True))

    start_time = time.time()
    avalanche_dir = Path(ava_dir)

    if not avalanche_dir.exists():
        raise FileNotFoundError(f"avalanche_dir not found: {avalanche_dir}")

    cfgMain = cfgUtils.getGeneralConfig()
    cfgMain["MAIN"]["avalancheDir"] = str(avalanche_dir)

    log = logUtils.initiateLogger(str(avalanche_dir), "operationalSimulation")
    log.info("JOB operational_simulation start")
    log.info("Current avalanche: %s", avalanche_dir)

    if clean:
        initProj.cleanSingleAvaDir(str(avalanche_dir), deleteOutput=False)

    # --- com1DFA config (override if Inputs/CFGs/com1DFACfg.ini exists)
    cfg_override = avalanche_dir / "Inputs" / "CFGs" / "local_com1DFACfg.ini"

    if cfg_override.exists():
        cfgCom1DFA = cfgUtils.getModuleConfig(com1DFA, fileOverride=str(cfg_override))
    else:
        cfgCom1DFA = cfgUtils.getModuleConfig(com1DFA)

    # -----------------------------
    # Build overrides from API fields
    # -----------------------------
    overrides: Dict[str, Dict[str, Any]] = {"GENERAL": {}}

    # avalanche_type -> frictModel
    frict_model = FRICT_MODEL_MAP.get(avalanche_type)
    if avalanche_type not in FRICT_MODEL_MAP:
        raise ValueError(f"Unknown avalanche_type '{avalanche_type}'. Allowed: {sorted(FRICT_MODEL_MAP.keys())}")

    if frict_model is not None:
        overrides["GENERAL"]["frictModel"] = frict_model
    else:
        # custom: require user to set frictModel in config_overrides
        log.info("avalanche_type=custom: expecting frictModel via config_overrides")

    # density
    overrides["GENERAL"]["rho"] = snow_density_kg_m3
    if snow_density_entrained_kg_m3 is not None:
        overrides["GENERAL"]["rhoEnt"] = snow_density_entrained_kg_m3

    # release thickness: if provided, use ini thickness instead of REL
    if release_thickness_m is not None:
        overrides["GENERAL"]["relThFromFile"] = False
        if "INPUT" not in overrides:
            overrides["INPUT"] = {}
        overrides["INPUT"]["thFromIni"] = release_thickness_m

    # quality preset
    preset = QUALITY_PRESETS.get(quality)
    if preset is None:
        raise ValueError(f"Unknown quality '{quality}'. Allowed: {sorted(QUALITY_PRESETS.keys())}")
    merged_overrides: Dict[str, Dict[str, Any]] = {}
    _deep_update(merged_overrides, preset)  # preset first
    _deep_update(merged_overrides, overrides)  # explicit params override preset

    # config_overrides (from payload)
    # expected format: {"modules": {"com1DFA": {"GENERAL": {"mu": 0.22}}}}
    if config_overrides:
        modules = config_overrides.get("modules", {})
        com1dfa_over = modules.get("com1DFA", {})
        if isinstance(com1dfa_over, dict):
            # merge on top
            _deep_update(merged_overrides, com1dfa_over)

    # Apply to cfg object
    _apply_overrides_cfg(cfgCom1DFA, merged_overrides)

    log.info("Applied com1DFA overrides: %s", merged_overrides)

    # -----------------------------
    # Run com1DFA
    # -----------------------------
    _, plotDict, reportDictList, _ = com1DFA.com1DFAMain(cfgMain, cfgInfo=cfgCom1DFA)

    peak_dir = avalanche_dir / "Outputs" / "com1DFA" / "peakFiles"
    peakFilesDF = fU.makeSimDF(peak_dir, avaDir=avalanche_dir)

    # --- com2AB optional
    abShpFile: Optional[str] = None
    if run_ab:
        try:
            com2AB.readABinputs(str(avalanche_dir))
            cfgAB = cfgUtils.getModuleConfig(com2AB, str(avalanche_dir))
            pathDict, dem, splitPoint, eqParams, resAB = com2AB.com2ABMain(cfgAB, str(avalanche_dir))
            abShpFile = str(outAB.writeABtoSHP(pathDict, resAB))
            reportDictList, _, _ = outAB.writeABpostOut(
                pathDict, dem, splitPoint, eqParams, resAB, cfgMain, reportDictList
            )
        except AssertionError as e:
            log.info("No Alpha Beta info, skipping: %s", e)

    # --- report
    report_dir = avalanche_dir / "Outputs" / "reports"
    fU.makeADir(report_dir)
    gR.writeReport(
        report_dir,
        reportDictList,
        cfgMain["FLAGS"].getboolean("reportOneFile"),
        plotDict=plotDict,
        standaloneReport=True,
    )

    runtime_s = time.time() - start_time
    log.info("Finished in %.1f s", runtime_s)

    payload: Dict[str, Any] = {
        "status": "done",
        "avalancheDir": str(avalanche_dir),
        "peakDir": str(peak_dir),
        "reportDir": str(report_dir),
        "abShpFile": abShpFile,
        "runtimeSeconds": runtime_s,
        "appliedOverrides": merged_overrides,  # super utile pour debug/reproductibilité
    }

    if serialize_peak_df:
        payload["peakFiles"] = peakFilesDF.to_dict(orient="records")
    else:
        payload["peakFilesDF"] = peakFilesDF  # internal use only

    return payload
