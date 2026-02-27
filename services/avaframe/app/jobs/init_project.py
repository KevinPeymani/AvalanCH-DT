from __future__ import annotations

from pathlib import Path
from typing import Dict, Any

from avaframe.in3Utils import initializeProject
from avaframe.in3Utils import logUtils


def run(avalanche_dir: str | Path) -> Dict[str, Any]:
    """
    Initialize AvaFrame folder structure inside avalanche_dir.
    """
    avalanche_dir = Path(avalanche_dir)
    avalanche_dir.mkdir(parents=True, exist_ok=True)

    log = logUtils.initiateLogger(str(avalanche_dir), "initializeProject")
    log.info("JOB init_project start")
    log.info("Initializing project: %s", avalanche_dir)

    initializeProject.initializeFolderStruct(str(avalanche_dir))

    log.info("Project initialized.")
    return {
        "status": "initialized",
        "avalancheDir": str(avalanche_dir),
    }
