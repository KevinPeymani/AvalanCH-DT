import os
import json
import traceback
import shutil
import urllib.parse
from pathlib import Path
from typing import Dict, Any

import aio_pika

from . import storage
from .jobs import JOB_REGISTRY
from .jobs import init_project

RABBITMQ_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
WORKER_TYPE = os.getenv("WORKER_TYPE", "simulation").strip().lower()

INGEST_QUEUE = os.getenv("INGEST_QUEUE", "ingestion_queue")
SIM_QUEUE = os.getenv("SIM_QUEUE", "simulation_queue")


def is_remote(uri: str) -> bool:
    parsed = urllib.parse.urlparse(uri)
    return parsed.scheme in ("http", "https", "s3")


def queue_name_for_worker() -> str:
    if WORKER_TYPE == "ingestion":
        return INGEST_QUEUE
    if WORKER_TYPE == "simulation":
        return SIM_QUEUE
    raise ValueError(f"Unsupported WORKER_TYPE='{WORKER_TYPE}'")


def _get_inputs(payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Preferred format:
      payload["inputs"] = {"dem_uri": "...", "rel_uri": "..."}
    Backward compatibility:
      payload["dem_uri"], payload["rel_uri"]
    """
    inputs = payload.get("inputs") or {}
    dem_uri = inputs.get("dem_uri") or payload.get("dem_uri")
    rel_uri = inputs.get("rel_uri") or payload.get("rel_uri")

    if not dem_uri or not rel_uri:
        raise ValueError("inputs.dem_uri and inputs.rel_uri are required")

    return {"dem_uri": dem_uri, "rel_uri": rel_uri}


def prepare_inputs(job_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare a full AvaFrame case under storage.avalanche_dir(job_id):
      - initialize AvaFrame folder structure
      - copy DEM / REL
      - copy base CFG from avaParabola example
      - apply request overrides
    """
    ava_dir = storage.avalanche_dir(job_id)

    inp = _get_inputs(payload)
    sim = payload.get("simulation") or {}

    prep = init_project(
        avalanche_dir=ava_dir,
        dem_uri=inp["dem_uri"],
        rel_uri=inp["rel_uri"],
        snow_density_kg_m3=sim.get("snow_density_kg_m3"),
        snow_density_entrained_kg_m3=sim.get("snow_density_entrained_kg_m3"),
        release_thickness_m=sim.get("release_thickness_m"),
        config_overrides=payload.get("config_overrides"),
    )

    return {
        "prepared": True,
        **prep,
    }


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


async def publish_to_queue(channel: aio_pika.Channel, queue_name: str, payload: Dict[str, Any]) -> None:
    await channel.declare_queue(queue_name, durable=True)
    await channel.default_exchange.publish(
        aio_pika.Message(
            body=json.dumps(payload).encode("utf-8"),
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        ),
        routing_key=queue_name,
    )


async def run_ingestion(payload: Dict[str, Any], channel: aio_pika.Channel) -> Dict[str, Any]:
    job_id = payload["job_id"]

    if not storage.job_meta_path(job_id).exists():
        storage.init_job(job_id, payload)

    storage.update_job(job_id, status="ingesting", started_at=storage.now_iso())

    prep = prepare_inputs(job_id, payload)

    next_payload = dict(payload)
    next_payload["prepared"] = True
    next_payload["prep"] = prep

    await publish_to_queue(channel, SIM_QUEUE, next_payload)

    result = {
        "stage": "ingestion",
        "forwarded_to": SIM_QUEUE,
        "prep": prep,
    }

    storage.update_job(
        job_id,
        status="queued_for_simulation",
        result=result,
        error=None,
    )

    return result


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


async def process_message(payload: Dict[str, Any], channel: aio_pika.Channel) -> Dict[str, Any]:
    if "job_id" not in payload:
        raise ValueError("payload.job_id is required")

    if WORKER_TYPE == "ingestion":
        return await run_ingestion(payload, channel)

    if WORKER_TYPE == "simulation":
        return run_simulation(payload)

    raise ValueError(f"Unsupported WORKER_TYPE='{WORKER_TYPE}'")


async def main() -> None:
    queue_name = queue_name_for_worker()

    conn = await aio_pika.connect_robust(RABBITMQ_URL, heartbeat=600)
    channel = await conn.channel()
    await channel.set_qos(prefetch_count=1)

    queue = await channel.declare_queue(queue_name, durable=True)

    print(f"[worker:{WORKER_TYPE}] consuming '{queue_name}'")

    async with queue.iterator() as it:
        async for message in it:
            async with message.process(requeue=False):
                payload = json.loads(message.body.decode("utf-8"))

                try:
                    await process_message(payload, channel)
                except Exception as e:
                    job_id = payload.get("job_id")
                    if job_id:
                        storage.update_job(
                            job_id,
                            status="failed",
                            finished_at=storage.now_iso(),
                            error={
                                "message": f"{type(e).__name__}: {e}",
                                "traceback": traceback.format_exc(),
                                "worker_type": WORKER_TYPE,
                            },
                        )
                    raise

    await conn.close()


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
