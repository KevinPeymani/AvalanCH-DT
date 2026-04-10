from __future__ import annotations

import json
import math
import os
from pathlib import Path
from typing import Any, Dict

import aio_pika
import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_origin
from rasterio.windows import from_bounds

from . import storage
from .jobs import init_project

SIM_QUEUE = os.getenv("SIM_QUEUE", "simulation_queue")

DEFAULT_CRS = "EPSG:2056"
DEFAULT_CROP_RADIUS_M = 1000.0
DEFAULT_TARGET_RESOLUTION_M = 5.0
DEFAULT_RELEASE_RADIUS_M = 25.0
DEFAULT_RELEASE_THICKNESS_M = 0.8


# =========================
# Helpers
# =========================

def _get_inputs(payload: Dict[str, Any]) -> Dict[str, Any]:
    inputs = payload.get("inputs") or {}
    dem_uri = inputs.get("dem_uri") or payload.get("dem_uri")
    rel_uri = inputs.get("rel_uri") or payload.get("rel_uri")

    if not dem_uri or not rel_uri:
        raise ValueError("inputs.dem_uri and inputs.rel_uri are required")

    return {"dem_uri": dem_uri, "rel_uri": rel_uri}


def _get_coord(payload: Dict[str, Any]) -> Dict[str, Any] | None:
    coord = payload.get("coord")
    if coord is None:
        return None
    if not isinstance(coord, dict):
        raise ValueError("coord must be an object")
    return coord


def _generated_dir(job_id: str) -> Path:
    path = storage.job_root(job_id) / "generated"
    path.mkdir(parents=True, exist_ok=True)
    return path


def _validate_coord(coord: Dict[str, Any]) -> Dict[str, Any]:
    dem_uri = coord.get("dem_uri")
    x = coord.get("x")
    y = coord.get("y")
    crs = coord.get("crs", DEFAULT_CRS)

    if not dem_uri:
        raise ValueError("coord.dem_uri is required")
    if x is None or y is None:
        raise ValueError("coord.x and coord.y are required")
    if str(crs).upper() != DEFAULT_CRS:
        raise ValueError(f"coord.crs must be {DEFAULT_CRS}")

    crop_radius_m = float(coord.get("crop_radius_m", DEFAULT_CROP_RADIUS_M))
    target_resolution_m = float(coord.get("target_resolution_m", DEFAULT_TARGET_RESOLUTION_M))
    release_radius_m = float(coord.get("release_radius_m", DEFAULT_RELEASE_RADIUS_M))
    release_thickness_m = float(coord.get("release_thickness_m", DEFAULT_RELEASE_THICKNESS_M))

    if release_radius_m >= crop_radius_m:
        raise ValueError("release_radius_m must be smaller than crop_radius_m")

    return {
        "dem_uri": str(dem_uri),
        "x": float(x),
        "y": float(y),
        "crop_radius_m": crop_radius_m,
        "target_resolution_m": target_resolution_m,
        "release_radius_m": release_radius_m,
        "release_thickness_m": release_thickness_m,
    }


# =========================
# Core logic
# =========================

def _materialize_coord_inputs(job_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    coord_raw = _get_coord(payload)
    if coord_raw is None:
        return payload

    coord = _validate_coord(coord_raw)

    src_dem = Path(coord["dem_uri"])
    if not src_dem.exists():
        raise FileNotFoundError(f"DEM not found: {src_dem}")

    out_dir = _generated_dir(job_id)
    dem_out = out_dir / "dem.tif"
    rel_out = out_dir / "rel.tif"

    x, y = coord["x"], coord["y"]
    crop_radius = coord["crop_radius_m"]
    res = coord["target_resolution_m"]
    release_radius = coord["release_radius_m"]
    thickness = coord["release_thickness_m"]

    xmin, xmax = x - crop_radius, x + crop_radius
    ymin, ymax = y - crop_radius, y + crop_radius

    with rasterio.open(src_dem) as ds:

        if str(ds.crs).upper() != DEFAULT_CRS:
            raise ValueError(f"DEM CRS must be {DEFAULT_CRS}")

        bounds = ds.bounds

        xmin = max(xmin, bounds.left)
        xmax = min(xmax, bounds.right)
        ymin = max(ymin, bounds.bottom)
        ymax = min(ymax, bounds.top)

        window = from_bounds(xmin, ymin, xmax, ymax, ds.transform)

        width = int(math.ceil((xmax - xmin) / res))
        height = int(math.ceil((ymax - ymin) / res))

        dem = ds.read(
            1,
            window=window,
            out_shape=(height, width),
            resampling=Resampling.bilinear,
        ).astype(np.float32)

        transform = from_origin(xmin, ymax, res, res)

        profile = {
            "driver": "GTiff",
            "height": height,
            "width": width,
            "count": 1,
            "dtype": "float32",
            "crs": ds.crs,
            "transform": transform,
            "compress": "deflate",
        }

        if ds.nodata is not None:
            profile["nodata"] = float(ds.nodata)

        with rasterio.open(dem_out, "w", **profile) as dst:
            dst.write(dem, 1)

        # =========================
        # REL (no nodata, 0 everywhere)
        # =========================
        print("new version")
        rel_profile = profile.copy()
        rel_profile.pop("nodata", None)

        rows, cols = np.indices((height, width), dtype=np.float32)

        xs = transform.c + (cols + 0.5) * transform.a
        ys = transform.f + (rows + 0.5) * transform.e

        dist = np.sqrt((xs - x) ** 2 + (ys - y) ** 2)

        rel = np.zeros((height, width), dtype=np.float32)
        mask = dist <= release_radius

        rel[mask] = thickness

        if not np.any(mask):
            raise ValueError("REL is empty (resolution too coarse or radius too small)")

        with rasterio.open(rel_out, "w", **rel_profile) as dst:
            dst.write(rel, 1)

    payload = dict(payload)
    payload["inputs"] = {
        "dem_uri": str(dem_out),
        "rel_uri": str(rel_out),
    }

    sim = dict(payload.get("simulation") or {})
    sim.pop("release_thickness_m", None)
    payload["simulation"] = sim

    payload["generated_inputs"] = {
        "mode": "coord",
        "x": x,
        "y": y,
        "crop_radius_m": crop_radius,
        "resolution_m": res,
        "release_radius_m": release_radius,
        "release_thickness_m": thickness,
    }

    return payload


# =========================
# Pipeline
# =========================

def prepare_inputs(job_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    ava_dir = storage.avalanche_dir(job_id)

    inp = _get_inputs(payload)
    sim = payload.get("simulation") or {}

    return {
        "prepared": True,
        **init_project(
            avalanche_dir=ava_dir,
            dem_uri=inp["dem_uri"],
            rel_uri=inp["rel_uri"],
            snow_density_kg_m3=sim.get("snow_density_kg_m3"),
            snow_density_entrained_kg_m3=sim.get("snow_density_entrained_kg_m3"),
            config_overrides=payload.get("config_overrides"),
        ),
    }


async def publish_to_queue(channel: aio_pika.Channel, queue: str, payload: Dict[str, Any]) -> None:
    await channel.declare_queue(queue, durable=True)
    await channel.default_exchange.publish(
        aio_pika.Message(
            body=json.dumps(payload).encode(),
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        ),
        routing_key=queue,
    )


async def run_ingestion(payload: Dict[str, Any], channel: aio_pika.Channel, sim_queue: str) -> Dict[str, Any]:
    job_id = payload["job_id"]

    if not storage.job_meta_path(job_id).exists():
        storage.init_job(job_id, payload)

    storage.update_job(job_id, status="ingesting", started_at=storage.now_iso())

    payload = _materialize_coord_inputs(job_id, payload)

    prep = prepare_inputs(job_id, payload)

    next_payload = dict(payload, prepared=True, prep=prep)

    await publish_to_queue(channel, sim_queue, next_payload)

    result = {
        "stage": "ingestion",
        "forwarded_to": sim_queue,
        "generated_inputs": payload.get("generated_inputs"),
    }

    storage.update_job(
        job_id,
        status="queued_for_simulation",
        result=result,
        error=None,
    )

    return result