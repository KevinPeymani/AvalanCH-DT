import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml


def _env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.getenv(name, default)
    if required and not value:
        raise RuntimeError(f"Missing required environment variable: {name}")
    if value is None:
        raise RuntimeError(f"Missing environment variable: {name}")
    return value


@dataclass(frozen=True)
class RabbitMQSettings:
    url: str
    input_queue: str
    output_queue: str
    service_name: str


@dataclass(frozen=True)
class RuntimeSettings:
    debug: bool
    log_level: str
    consume_timeout_seconds: float


@dataclass(frozen=True)
class DemSettings:
    path: str
    expected_resolution_m: float
    nodata_fallback: float | None
    enable_ground_sampling: bool


@dataclass(frozen=True)
class ProjectionSettings:
    swiss_epsg: int
    earth_radius_m: float
    min_range_m: float
    max_range_m: float
    confidence_floor: float
    default_detection_class: str
    default_tile_overlap_px: int
    dem: DemSettings


@dataclass(frozen=True)
class ServiceSettings:
    runtime: RuntimeSettings
    rabbitmq: RabbitMQSettings
    projection: ProjectionSettings


def load_yaml(path: str | Path) -> dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if not isinstance(data, dict):
        raise ValueError("YAML root must be a mapping")
    return data


def _resolve_config_path(config_path: str | Path, value: str | None) -> str:
    if not value:
        return ""
    p = Path(value)
    if p.is_absolute():
        return str(p)
    return str((Path(config_path).resolve().parent / p).resolve())



def load_settings(config_path: str | Path) -> ServiceSettings:
    data = load_yaml(config_path)

    runtime = data.get("runtime", {})
    projection = data.get("projection", {})
    dem = projection.get("dem", {})

    return ServiceSettings(
        runtime=RuntimeSettings(
            debug=bool(runtime.get("debug", False)),
            log_level=str(runtime.get("log_level", "INFO")),
            consume_timeout_seconds=float(runtime.get("consume_timeout_seconds", 1.0)),
        ),
        rabbitmq=RabbitMQSettings(
            url=_env("RABBITMQ_URL", required=True),
            input_queue=_env("RABBITMQ_INPUT_QUEUE", required=True),
            output_queue=_env("RABBITMQ_OUTPUT_QUEUE", required=True),
            service_name=_env("SERVICE_NAME", "webcam-projector"),
        ),
        projection=ProjectionSettings(
            swiss_epsg=int(projection.get("swiss_epsg", 2056)),
            earth_radius_m=float(projection.get("earth_radius_m", 6371000.0)),
            min_range_m=float(projection.get("min_range_m", 350.0)),
            max_range_m=float(projection.get("max_range_m", 2800.0)),
            confidence_floor=float(projection.get("confidence_floor", 0.20)),
            default_detection_class=str(projection.get("default_detection_class", "avalanche")),
            default_tile_overlap_px=int(projection.get("default_tile_overlap_px", 160)),
            dem=DemSettings(
                path=_resolve_config_path(config_path, str(dem.get("path", ""))),
                expected_resolution_m=float(dem.get("expected_resolution_m", 5.0)),
                nodata_fallback=(
                    float(dem["nodata_fallback"])
                    if dem.get("nodata_fallback") is not None
                    else None
                ),
                enable_ground_sampling=bool(dem.get("enable_ground_sampling", True)),
            ),
        ),
    )
