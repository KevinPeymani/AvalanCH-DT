from __future__ import annotations

from pathlib import Path
from typing import Any, Dict, Optional

from avaframe.com1DFA import com1DFA
from avaframe.ana4Stats import probAna
from avaframe.out3Plot import statsPlots as sP
from avaframe.out3Plot import outQuickPlot as oP
from avaframe.in3Utils import initializeProject as initProj
from avaframe.in3Utils import cfgUtils, logUtils
import avaframe.in3Utils.fileHandlerUtils as fU


def run(
    avalanche_dir: str | Path,
    *,
    probana_cfg_path: Optional[str | Path] = None,
    clean: bool = True,
    make_contour_plots: bool = True,
    make_prob_map: bool = True,
    module: str = "com1DFA",
) -> Dict[str, Any]:
    """
    Analysis job:
    - generate param-variation configs for com1DFA (from probAna cfg)
    - run com1DFA simulations
    - run probability analysis (ana4Stats)
    - optional plots (contours + probability maps)
    """
    avalanche_dir = Path(avalanche_dir)
    if not avalanche_dir.exists():
        raise FileNotFoundError(f"avalanche_dir not found: {avalanche_dir}")

    log = logUtils.initiateLogger(str(avalanche_dir), "analysis")
    log.info("JOB analysis start")
    log.info("avalanche_dir=%s probana_cfg_path=%s", avalanche_dir, probana_cfg_path)

    cfgMain = cfgUtils.getGeneralConfig()
    cfgMain["MAIN"]["avalancheDir"] = str(avalanche_dir)

    if clean:
        initProj.cleanSingleAvaDir(str(avalanche_dir))

    # Load probabilistic config (override optional)
    if probana_cfg_path is not None:
        cfgProb = cfgUtils.getModuleConfig(probAna, str(avalanche_dir), fileOverride=str(Path(probana_cfg_path)))
        log.info("Using probAna override config: %s", probana_cfg_path)
    else:
        cfgProb = cfgUtils.getModuleConfig(probAna, str(avalanche_dir))
        log.info("Using default probAna config from project")

    # Create config files for parameter variations
    cfgFiles, cfgPath = probAna.createComModConfig(cfgProb, str(avalanche_dir), com1DFA)

    # Run com1DFA simulations for all generated configs
    dem, plotDict, reportDictList, simDF = com1DFA.com1DFAMain(cfgMain, cfgInfo=cfgPath)

    # Determine prob configurations to evaluate
    probabilityConfigurations = probAna.fetchProbConfigs(cfgProb["PROBRUN"])

    input_dir = avalanche_dir / "Outputs" / "ana4Stats"
    processed = []
    warnings = []

    for probConf in probabilityConfigurations:
        cfgProb["FILTER"] = probabilityConfigurations[probConf]
        log.info("Perform probability analysis for configuration: %s", probConf)

        parametersDict = fU.getFilterDict(cfgProb, "FILTER")

        anaPerformed, contourDict = probAna.probAnalysis(
            str(avalanche_dir),
            cfgProb,
            module,
            parametersDict=parametersDict,
            probConf=probConf,
        )

        if not anaPerformed:
            msg = f"No files found for configuration: {probConf}"
            log.warning(msg)
            warnings.append(msg)
            processed.append({"probConf": probConf, "anaPerformed": False})
            continue

        out_name = f"{avalanche_dir.stem}_prob_{probConf}_{cfgProb['GENERAL']['peakVar']}_lim{cfgProb['GENERAL']['peakLim']}"

        if make_contour_plots:
            pathDict = {
                "pathResult": str(input_dir / "plots"),
                "avaDir": str(avalanche_dir),
                "plotScenario": out_name,
            }
            oP.plotContours(
                contourDict,
                cfgProb["GENERAL"]["peakVar"],
                cfgProb["GENERAL"]["peakLim"],
                pathDict,
                layer=cfgProb["GENERAL"].get("layer", ""),
            )

        processed.append(
            {
                "probConf": probConf,
                "anaPerformed": True,
                "plotScenario": out_name,
                "plotsDir": str(input_dir / "plots"),
            }
        )

    if make_prob_map:
        sP.plotProbMap(str(avalanche_dir), str(input_dir), cfgProb, demPlot=True)

    return {
        "status": "done",
        "avalancheDir": str(avalanche_dir),
        "probAnaCfg": str(probana_cfg_path) if probana_cfg_path else None,
        "generatedCfgPath": str(cfgPath),
        "ana4StatsDir": str(input_dir),
        "processedProbConfigs": processed,
        "warnings": warnings,
    }
