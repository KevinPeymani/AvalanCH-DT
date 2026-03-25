from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict

import yaml


@dataclass
class AppConfig:
    camera_dir: Path
    download_dir: Path
    tiles_dir: Path
    outbox_dir: Path
    state_dir: Path
    poll_interval: int
    debug_local_outbox: bool

    @property
    def use_broker(self) -> bool:
        return not self.debug_local_outbox


def _require(data: Dict[str, Any], key: str) -> Any:
    if key not in data:
        raise ValueError(f"Missing required config key: {key}")
    return data[key]


def load_config(config_path: str | Path = "config/config.yaml") -> AppConfig:
    config_path = Path(config_path)

    with config_path.open("r", encoding="utf-8") as f:
        raw = yaml.safe_load(f) or {}

    paths = _require(raw, "paths")
    runtime = _require(raw, "runtime")

    cfg = AppConfig(
        camera_dir=Path(_require(paths, "camera_dir")),
        download_dir=Path(_require(paths, "download_dir")),
        tiles_dir=Path(_require(paths, "tiles_dir")),
        outbox_dir=Path(_require(paths, "outbox_dir")),
        state_dir=Path(_require(paths, "state_dir")),
        poll_interval=int(_require(runtime, "poll_interval")),
        debug_local_outbox=bool(_require(runtime, "debug_local_outbox")),
    )

    return cfg
