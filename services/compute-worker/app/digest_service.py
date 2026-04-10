from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path
from typing import Any, Dict, List, Optional

import aio_pika
import rasterio

from . import storage

DIGEST_DIR = Path(os.getenv("DIGEST_DIR", "/data/digest"))
DIGEST_EVENTS_QUEUE = os.getenv("DIGEST_EVENTS_QUEUE", "digest_events")

DEFAULT_RES_TYPES = ["FT"]
NON_IMAGE_RES_TYPES = {"timeInfo"}


def _job_digest_dir(job_id: str) -> Path:
    path = DIGEST_DIR / job_id
    path.mkdir(parents=True, exist_ok=True)
    return path


def _find_time_steps_dir(job_id: str) -> Path:
    return storage.avalanche_dir(job_id) / "Outputs" / "com1DFA" / "peakFiles" / "timeSteps"


def _get_simulation_result(payload: Dict[str, Any]) -> Dict[str, Any]:
    sim = payload.get("simulation_result")
    if not isinstance(sim, dict):
        raise ValueError("payload.simulation_result is required")
    return sim


def _parse_res_type_string(value: str) -> List[str]:
    return [item.strip() for item in value.split("|") if item.strip()]


def _get_res_types(payload: Dict[str, Any]) -> List[str]:
    sim = _get_simulation_result(payload)
    job = sim.get("job") or {}
    applied_overrides = job.get("appliedOverrides") or {}
    general = applied_overrides.get("GENERAL") or {}

    candidates = [
        general.get("resType"),
        ((payload.get("simulation") or {}).get("extra_params") or {}).get("resType"),
        ((payload.get("digest") or {}).get("resType")),
    ]

    for value in candidates:
        if isinstance(value, str) and value.strip():
            return _parse_res_type_string(value)
        if isinstance(value, list):
            items = [str(item).strip() for item in value if str(item).strip()]
            if items:
                return items

    return DEFAULT_RES_TYPES.copy()


def _get_image_res_types(payload: Dict[str, Any]) -> List[str]:
    return [item for item in _get_res_types(payload) if item not in NON_IMAGE_RES_TYPES]


def _build_timestep_pattern(res_types: List[str]) -> re.Pattern[str]:
    escaped = [re.escape(item) for item in res_types]
    kinds = "|".join(escaped)
    return re.compile(rf"_(?P<kind>{kinds})_t(?P<time>\d+(?:\.\d+)?)\.tif$")


def _parse_timestep_info(path: Path, pattern: re.Pattern[str]) -> Optional[Dict[str, Any]]:
    match = pattern.search(path.name)
    if not match:
        return None

    return {
        "kind": match.group("kind"),
        "time": float(match.group("time")),
    }


def _frames_dir_for_kind(digest_dir: Path, kind: str) -> Path:
    path = digest_dir / kind
    path.mkdir(parents=True, exist_ok=True)
    return path


def _build_frame_name(kind: str, frame_num: int) -> str:
    return f"frame{kind}_{frame_num:04d}.exr"


def _convert_tif_to_exr(src: Path, dst: Path) -> None:
    dst.parent.mkdir(parents=True, exist_ok=True)

    try:
        subprocess.run(
            [
                "oiiotool",
                str(src),
                "-ch",
                "R",
                "-d",
                "float",
                "-o",
                str(dst),
            ],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"oiiotool failed on {src}:\n{e.stderr}") from e


def _copy_generated_dem(payload: Dict[str, Any], digest_dir: Path) -> Optional[Path]:
    sim = payload.get("simulation_result") or {}
    sim_prep = sim.get("prep") or {}
    prep = payload.get("prep") or {}
    inputs = payload.get("inputs") or {}

    candidates = [
        sim_prep.get("dem_path"),
        prep.get("dem_path"),
        inputs.get("dem_uri"),
    ]

    for candidate in candidates:
        if not candidate:
            continue
        src = Path(candidate)
        if src.exists():
            dst = digest_dir / "dem.tif"
            shutil.copy2(src, dst)
            return dst

    return None


def _dataset_info(path: Path) -> Dict[str, Any]:
    with rasterio.open(path) as ds:
        return {
            "path": str(path),
            "crs": str(ds.crs) if ds.crs else None,
            "width": ds.width,
            "height": ds.height,
            "bounds": {
                "left": ds.bounds.left,
                "bottom": ds.bounds.bottom,
                "right": ds.bounds.right,
                "top": ds.bounds.top,
            },
            "res": [ds.res[0], ds.res[1]],
            "dtype": ds.dtypes[0] if ds.count else None,
        }


def _process_frames(job_id: str, digest_dir: Path, payload: Dict[str, Any]) -> Dict[str, Any]:
    time_steps_dir = _find_time_steps_dir(job_id)
    res_types = _get_image_res_types(payload)

    if not time_steps_dir.exists():
        return {
            "time_steps_dir": str(time_steps_dir),
            "res_types": res_types,
            "types": {},
        }

    if not res_types:
        return {
            "time_steps_dir": str(time_steps_dir),
            "res_types": [],
            "types": {},
        }

    pattern = _build_timestep_pattern(res_types)
    discovered_by_kind: Dict[str, List[tuple[float, Path]]] = {kind: [] for kind in res_types}

    for tif in time_steps_dir.glob("*.tif"):
        info = _parse_timestep_info(tif, pattern)
        if info is None:
            continue

        kind = info["kind"]
        t = info["time"]
        discovered_by_kind.setdefault(kind, []).append((t, tif))

    result_types: Dict[str, Any] = {}

    for kind in res_types:
        items = discovered_by_kind.get(kind, [])
        items.sort(key=lambda item: item[0])

        frames_dir = _frames_dir_for_kind(digest_dir, kind)
        converted: List[Dict[str, Any]] = []
        skipped: List[Dict[str, Any]] = []

        frame_num: Optional[int] = None
        first_valid_time: Optional[float] = None

        for t, tif in items:
            if tif.stat().st_size == 0:
                skipped.append(
                    {
                        "file": str(tif),
                        "time": t,
                        "reason": "empty_file",
                    }
                )
                continue

            if frame_num is None:
                frame_num = int(t)
                first_valid_time = t

            dst = frames_dir / _build_frame_name(kind, frame_num)

            try:
                _convert_tif_to_exr(tif, dst)
                converted.append(
                    {
                        "src": str(tif),
                        "dst": str(dst),
                        "time": t,
                        "frame": frame_num,
                        "kind": kind,
                    }
                )
                frame_num += 1
            except Exception as exc:
                skipped.append(
                    {
                        "file": str(tif),
                        "time": t,
                        "frame": frame_num,
                        "reason": f"convert_failed: {type(exc).__name__}: {exc}",
                    }
                )
                frame_num += 1

        result_types[kind] = {
            "frames_dir": str(frames_dir),
            "discovered": len(items),
            "converted": converted,
            "skipped": skipped,
            "first_valid_time": first_valid_time,
        }

    return {
        "time_steps_dir": str(time_steps_dir),
        "res_types": res_types,
        "types": result_types,
    }


def _write_summary(
    digest_dir: Path,
    payload: Dict[str, Any],
    dem_copy: Optional[Path],
    frame_info: Dict[str, Any],
) -> Path:
    coord = payload.get("coord") or {}
    generated = payload.get("generated_inputs") or {}
    sim = payload.get("simulation_result") or {}
    sim_job = sim.get("job") or {}
    sim_prep = sim.get("prep") or {}

    lines: List[str] = []
    lines.append(f"job_id: {payload.get('job_id')}")
    lines.append("")

    lines.append("coord:")
    lines.append(f"  x: {coord.get('x', generated.get('x'))}")
    lines.append(f"  y: {coord.get('y', generated.get('y'))}")
    lines.append(f"  crs: {coord.get('crs', generated.get('crs', 'EPSG:2056'))}")
    lines.append("")

    lines.append("generated_inputs:")
    lines.append(f"  mode: {generated.get('mode')}")
    lines.append(f"  crop_radius_m: {generated.get('crop_radius_m')}")
    lines.append(f"  resolution_m: {generated.get('resolution_m')}")
    lines.append(f"  release_radius_m: {generated.get('release_radius_m')}")
    lines.append(f"  release_thickness_m: {generated.get('release_thickness_m')}")
    lines.append("")

    lines.append("simulation:")
    lines.append(f"  avalancheDir: {sim_prep.get('avalancheDir')}")
    lines.append(f"  peakDir: {sim_job.get('peakDir')}")
    lines.append(f"  reportDir: {sim_job.get('reportDir')}")
    lines.append(f"  runtimeSeconds: {sim_job.get('runtimeSeconds')}")
    lines.append("")

    lines.append("res_types:")
    for item in frame_info.get("res_types", []):
        lines.append(f"  - {item}")
    lines.append("")

    lines.append("frames:")
    for kind, info in frame_info["types"].items():
        lines.append(f"  {kind}:")
        lines.append(f"    frames_dir: {info['frames_dir']}")
        lines.append(f"    discovered: {info['discovered']}")
        lines.append(f"    converted: {len(info['converted'])}")
        lines.append(f"    skipped: {len(info['skipped'])}")
        lines.append(f"    first_valid_time: {info['first_valid_time']}")
    lines.append("")

    if dem_copy and dem_copy.exists():
        info = _dataset_info(dem_copy)
        lines.append("dem:")
        lines.append(f"  path: {info['path']}")
        lines.append(f"  crs: {info['crs']}")
        lines.append(f"  width: {info['width']}")
        lines.append(f"  height: {info['height']}")
        lines.append(f"  dtype: {info['dtype']}")
        lines.append(f"  res: {info['res']}")
        lines.append(
            "  bounds: "
            f"left={info['bounds']['left']}, "
            f"bottom={info['bounds']['bottom']}, "
            f"right={info['bounds']['right']}, "
            f"top={info['bounds']['top']}"
        )
        lines.append("")

    for kind, info in frame_info["types"].items():
        if info["skipped"]:
            lines.append(f"skipped_frames_{kind}:")
            for item in info["skipped"]:
                lines.append(
                    f"  - time={item.get('time')} frame={item.get('frame')} "
                    f"reason={item.get('reason')} file={item.get('file')}"
                )
            lines.append("")

    summary_path = digest_dir / "summary.txt"
    summary_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return summary_path


async def publish_digest_event(channel: aio_pika.Channel, payload: Dict[str, Any]) -> None:
    await channel.declare_queue(DIGEST_EVENTS_QUEUE, durable=True)
    await channel.default_exchange.publish(
        aio_pika.Message(
            body=json.dumps(storage._jsonable(payload)).encode("utf-8"),
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        ),
        routing_key=DIGEST_EVENTS_QUEUE,
    )


async def run_digest(payload: Dict[str, Any], channel: aio_pika.Channel) -> Dict[str, Any]:
    job_id = payload["job_id"]

    digest_dir = _job_digest_dir(job_id)
    dem_copy = _copy_generated_dem(payload, digest_dir)
    frame_info = _process_frames(job_id, digest_dir, payload)
    summary_path = _write_summary(digest_dir, payload, dem_copy, frame_info)

    total_converted = sum(len(info["converted"]) for info in frame_info["types"].values())
    total_skipped = sum(len(info["skipped"]) for info in frame_info["types"].values())

    result = {
        "stage": "digest",
        "job_id": job_id,
        "digest_dir": str(digest_dir),
        "dem_path": str(dem_copy) if dem_copy else None,
        "summary_path": str(summary_path),
        "frame_count": total_converted,
        "skipped_count": total_skipped,
        "res_types": frame_info["res_types"],
        "types": frame_info["types"],
    }

    (digest_dir / "digest.json").write_text(
        json.dumps(storage._jsonable(result), indent=2, ensure_ascii=False),
        encoding="utf-8",
    )

    await publish_digest_event(channel, result)

    current = storage.get_job(job_id)
    current_result = current.get("result") or {}
    current_result["digest"] = result

    storage.update_job(
        job_id,
        status="digested",
        result=current_result,
        error=None,
    )

    return result