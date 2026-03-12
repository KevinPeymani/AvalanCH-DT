from __future__ import annotations

import configparser
import shutil
from pathlib import Path
from typing import Dict, Any

from avaframe.in3Utils import initializeProject
from avaframe.in3Utils import logUtils


def _is_remote(uri: str) -> bool:
    return uri.startswith("http://") or uri.startswith("https://") or uri.startswith("s3://")


def _copy_local_file(src: str | Path, dst: Path) -> Path:
    src = Path(src)
    if not src.exists():
        raise FileNotFoundError(f"Input file not found: {src}")
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy(src, dst)
    return dst


def _find_base_cfg_file() -> Path:
    """
    Locate a base com1DFA cfg file from avaParabola example.

    Adjust these candidate paths if your repo layout differs.
    """
    candidates = [
        Path("/examples/avaParabola/Inputs/CFGs/com1DFACfg.ini"),
        Path("/app/examples/avaParabola/Inputs/CFGs/com1DFACfg.ini"),
    ]

    for path in candidates:
        if path.exists():
            return path

    raise FileNotFoundError(
        "Could not find base AvaFrame CFG file from avaParabola example. "
        "Checked: " + ", ".join(str(p) for p in candidates)
    )


def _patch_cfg_file(
    cfg_path: Path,
    snow_density_kg_m3: float | None = None,
    snow_density_entrained_kg_m3: float | None = None,
    release_thickness_m: float | None = None,
    config_overrides: Dict[str, Any] | None = None,
) -> None:
    """
    Patch cfg file in place.

    Notes:
    - config_overrides should ideally be:
      {
        "SECTION": {
          "key": value
        }
      }
    - The direct keys below are written only if the target section/key names
      match your config conventions.
    """
    parser = configparser.ConfigParser()
    parser.optionxform = str
    parser.read(cfg_path)

    # Minimal defaults: adapt section/key names to your actual ini if needed.
    # These are placeholders commonly customized by users.
    default_section = "GENERAL"
    if not parser.has_section(default_section):
        parser.add_section(default_section)

    if snow_density_kg_m3 is not None:
        parser.set(default_section, "rho", str(snow_density_kg_m3))

    if snow_density_entrained_kg_m3 is not None:
        parser.set(default_section, "rhoEnt", str(snow_density_entrained_kg_m3))

    if release_thickness_m is not None:
        parser.set(default_section, "relTh", str(release_thickness_m))

    if config_overrides:
        for section, values in config_overrides.items():
            if not isinstance(values, dict):
                continue
            if not parser.has_section(section):
                parser.add_section(section)
            for key, value in values.items():
                parser.set(section, str(key), str(value))

    with open(cfg_path, "w", encoding="utf-8") as f:
        parser.write(f)


def run(
    avalanche_dir: str | Path,
    dem_uri: str,
    rel_uri: str,
    snow_density_kg_m3: float | None = None,
    snow_density_entrained_kg_m3: float | None = None,
    release_thickness_m: float | None = None,
    config_overrides: Dict[str, Any] | None = None,
) -> Dict[str, Any]:
    """
    Initialize a full AvaFrame case inside avalanche_dir.

    Creates folder structure, copies DEM/REL, copies and patches config file.
    """
    avalanche_dir = Path(avalanche_dir)
    avalanche_dir.mkdir(parents=True, exist_ok=True)

    log = logUtils.initiateLogger(str(avalanche_dir), "initializeProject")
    log.info("JOB init_project start")
    log.info("Initializing project: %s", avalanche_dir)

    initializeProject.initializeFolderStruct(str(avalanche_dir))

    inputs_dir = avalanche_dir / "Inputs"
    dem_dir = inputs_dir
    rel_dir = inputs_dir / "REL"
    cfg_dir = inputs_dir / "CFGs"

    dem_dir.mkdir(parents=True, exist_ok=True)
    rel_dir.mkdir(parents=True, exist_ok=True)
    cfg_dir.mkdir(parents=True, exist_ok=True)

    if _is_remote(dem_uri):
        raise ValueError("remote DEM not supported yet")
    if _is_remote(rel_uri):
        raise ValueError("remote REL not supported yet")

    dem_dest = _copy_local_file(dem_uri, dem_dir / Path(dem_uri).name)
    rel_dest = _copy_local_file(rel_uri, rel_dir / Path(rel_uri).name)

    base_cfg = _find_base_cfg_file()
    local_cfg = cfg_dir / "local_com1DFACfg.ini"
    shutil.copy(base_cfg, local_cfg)

    _patch_cfg_file(
        local_cfg,
        snow_density_kg_m3=snow_density_kg_m3,
        snow_density_entrained_kg_m3=snow_density_entrained_kg_m3,
        release_thickness_m=release_thickness_m,
        config_overrides=config_overrides,
    )

    log.info("Project initialized.")
    log.info("DEM copied to: %s", dem_dest)
    log.info("REL copied to: %s", rel_dest)
    log.info("CFG prepared at: %s", local_cfg)

    return {
        "status": "initialized",
        "avalancheDir": str(avalanche_dir),
        "inputsDir": str(inputs_dir),
        "dem_path": str(dem_dest),
        "rel_path": str(rel_dest),
        "cfg_path": str(local_cfg),
    }
