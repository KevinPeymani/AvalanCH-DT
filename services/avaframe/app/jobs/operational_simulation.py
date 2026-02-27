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


def run(
    avalanche_dir: str | Path,
    *,
    clean: bool = False,
    run_ab: bool = True,
    serialize_peak_df: bool = True,
) -> Dict[str, Any]:
    """
    Operational simulation: com1DFA + optional com2AB.
    Returns JSON-friendly output paths and peak files list.
    """
    start_time = time.time()
    avalanche_dir = Path(avalanche_dir)

    if not avalanche_dir.exists():
        raise FileNotFoundError(f"avalanche_dir not found: {avalanche_dir}")

    cfgMain = cfgUtils.getGeneralConfig()
    cfgMain["MAIN"]["avalancheDir"] = str(avalanche_dir)

    log = logUtils.initiateLogger(str(avalanche_dir), "operationalSimulation")
    log.info("JOB operational_simulation start")
    log.info("Current avalanche: %s", avalanche_dir)

    if clean:
        initProj.cleanSingleAvaDir(str(avalanche_dir), deleteOutput=False)

    # --- com1DFA (override if Inputs/CFGs/com1DFACfg.ini exists)
    cfgCom1DFAPath = avalanche_dir / "Inputs" / "CFGs" / "com1DFACfg.ini"
    if cfgCom1DFAPath.exists():
        cfgCom1DFA = cfgUtils.getModuleConfig(com1DFA, fileOverride=str(cfgCom1DFAPath))
        log.info("Using override config: %s", cfgCom1DFAPath)
    else:
        cfgCom1DFA = cfgUtils.getModuleConfig(com1DFA, str(avalanche_dir))
        log.info("Using default project com1DFA config")

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
    }

    if serialize_peak_df:
        payload["peakFiles"] = peakFilesDF.to_dict(orient="records")
    else:
        payload["peakFilesDF"] = peakFilesDF  # internal use only

    return payload
