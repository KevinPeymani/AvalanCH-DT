from __future__ import annotations

from typing import Any, Dict

from . import storage
from .jobs import JOB_REGISTRY
from .ingest_service import prepare_inputs


def build_params_from_payload(payload: Dict[str, Any]) -> Dict[str, Any]:
    sim = payload.get("simulation") or {}
    extra = sim.get("extra_params") or {}

    params: Dict[str, Any] = {}

    if "avalanche_type" in sim:
        params["avalanche_type"] = sim["avalanche_type"]
    if "quality" in sim:
        params["quality"] = sim["quality"]

    if "snow_density_kg_m3" in sim:
        params["snow_density_kg_m3"] = sim["snow_density_kg_m3"]
    if "snow_density_entrained_kg_m3" in sim and sim["snow_density_entrained_kg_m3"] is not None:
        params["snow_density_entrained_kg_m3"] = sim["snow_density_entrained_kg_m3"]
    if "release_thickness_m" in sim and sim["release_thickness_m"] is not None:
        params["release_thickness_m"] = sim["release_thickness_m"]

    cfg_overrides = payload.get("config_overrides") or None
    if cfg_overrides:
        params["config_overrides"] = cfg_overrides

    if isinstance(extra, dict):
        params.update(extra)

    return params



def run_simulation(payload: Dict[str, Any]) -> Dict[str, Any]:
    job_id = payload["job_id"]
    job = payload.get("job", "simulation")

    if not storage.job_meta_path(job_id).exists():
        storage.init_job(job_id, payload)

    storage.update_job(job_id, status="running", started_at=storage.now_iso())

    ava_dir = storage.avalanche_dir(job_id)

    if job not in JOB_REGISTRY:
        raise ValueError(f"Unknown job '{job}'")

    prep = payload.get("prep")
    if not prep:
        prep = prepare_inputs(job_id, payload)

    sim = payload.get("simulation") or {}
    auto_init = bool(sim.get("auto_init", True))

    if auto_init and job in ("simulation", "operational_simulation", "analysis"):
        if not (ava_dir / "Inputs").exists() and "init" in JOB_REGISTRY:
            JOB_REGISTRY["init"](ava_dir)

    params = build_params_from_payload(payload)
    result = JOB_REGISTRY[job](ava_dir, **params)

    final_result = {"prep": prep, "job": result}

    storage.update_job(
        job_id,
        status="done",
        finished_at=storage.now_iso(),
        result=final_result,
        error=None,
    )

    return final_result
