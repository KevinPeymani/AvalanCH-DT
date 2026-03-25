from pathlib import Path
import os
from typing import Dict, Optional

import yaml
from pydantic import BaseModel, Field


class RabbitMQSettings(BaseModel):
    url: str
    input_queue: str
    output_queue: str
    prefetch_count: int = 1


class ModelSettings(BaseModel):
    weights_path: str
    repo_path: str
    device: str = "cpu"


class InferenceSettings(BaseModel):
    conf_threshold: float = 0.25
    iou_threshold: float = 0.45
    imgsz: int = 896
    max_det: int = 50


class SizeFilter(BaseModel):
    max_width_ratio: Optional[float] = None
    max_height_ratio: Optional[float] = None


class PostProcessSettings(BaseModel):
    class_thresholds: Dict[str, float] = Field(default_factory=dict)
    size_filters: Dict[str, SizeFilter] = Field(default_factory=dict)


class Settings(BaseModel):
    rabbitmq: RabbitMQSettings
    model: ModelSettings
    inference: InferenceSettings
    postprocess: PostProcessSettings = Field(default_factory=PostProcessSettings)


def _resolve_path(value: str, base_dir: Path) -> str:
    path = Path(os.path.expandvars(value))
    if not path.is_absolute():
        path = (base_dir / path).resolve()
    return str(path)


def load_settings(config_path: str | Path) -> Settings:
    config_path = Path(config_path).resolve()

    with open(config_path, "r") as f:
        data = yaml.safe_load(f)

    data["rabbitmq"]["url"] = os.environ["BROKER_URL"]

    settings = Settings(**data)

    base_dir = config_path.parent
    settings.model.weights_path = _resolve_path(settings.model.weights_path, base_dir)
    settings.model.repo_path = _resolve_path(settings.model.repo_path, base_dir)

    return settings
