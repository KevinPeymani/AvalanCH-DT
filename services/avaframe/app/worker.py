import os
import json
import asyncio
import traceback
from pathlib import Path
from typing import Dict, Any
import aio_pika

from . import storage
from .jobs import JOB_REGISTRY

RABBITMQ_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
QUEUE_NAME = os.getenv("QUEUE_NAME", "simulation_queue")
MAX_CONCURRENT_JOBS = int(os.getenv("MAX_CONCURRENT_JOBS", "1"))


async def prepare_inputs(job_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare avalanche_dir/Inputs from dem_uri + rel_uri + avalanche_type + quality.
    This is the missing glue between REST and AvaFrame.

    For now: creates Inputs/ folders only (stub).
    Replace with:
      - copy/download DEM -> Inputs/DEM/
      - copy/download REL -> Inputs/REL/
      - write Inputs/CFGs/com1DFACfg.ini based on avalanche_type/quality/params
    """
    ava_dir = storage.avalanche_dir(job_id)
    (ava_dir / "Inputs").mkdir(parents=True, exist_ok=True)
    (ava_dir / "Inputs" / "DEM").mkdir(parents=True, exist_ok=True)
    (ava_dir / "Inputs" / "REL").mkdir(parents=True, exist_ok=True)
    (ava_dir / "Inputs" / "CFGs").mkdir(parents=True, exist_ok=True)

    return {
        "prepared": True,
        "inputsDir": str(ava_dir / "Inputs"),
        "dem_uri": payload.get("dem_uri"),
        "rel_uri": payload.get("rel_uri"),
        "quality": payload.get("quality"),
        "avalanche_type": payload.get("avalanche_type"),
    }


async def run_one(payload: Dict[str, Any]) -> None:
    job_id = payload["job_id"]
    job = payload.get("job", "simulation")
    params = payload.get("params", {}) or {}

    # ensure job.json exists
    if not storage.job_meta_path(job_id).exists():
        storage.init_job(job_id, payload)

    storage.update_job(job_id, status="running", started_at=storage.now_iso())

    ava_dir = storage.avalanche_dir(job_id)

    # auto-init (default true)
    auto_init = bool(params.get("auto_init", True))
    if auto_init and job in ("simulation", "operational_simulation", "analysis"):
        if not (ava_dir / "Inputs").exists():
            await asyncio.to_thread(JOB_REGISTRY["init"], ava_dir)

    # prepare inputs (DEM/REL/CFG)
    prep = await prepare_inputs(job_id, payload)

    if job not in JOB_REGISTRY:
        raise ValueError(f"Unknown job '{job}'. Available: {sorted(JOB_REGISTRY.keys())}")

    # run job (threaded)
    result = await asyncio.to_thread(JOB_REGISTRY[job], ava_dir, **params)

    storage.update_job(
        job_id,
        status="done",
        finished_at=storage.now_iso(),
        result={"prep": prep, "job": result},
        error=None,
    )


async def main():
    conn = await aio_pika.connect_robust(RABBITMQ_URL)
    channel = await conn.channel()
    await channel.set_qos(prefetch_count=MAX_CONCURRENT_JOBS)
    queue = await channel.declare_queue(QUEUE_NAME, durable=True)

    sem = asyncio.Semaphore(MAX_CONCURRENT_JOBS)

    async with queue.iterator() as it:
        print(f"[worker] consuming {QUEUE_NAME} concurrency={MAX_CONCURRENT_JOBS}")
        async for message in it:
            async with sem:
                async with message.process(requeue=False):
                    payload = json.loads(message.body.decode("utf-8"))
                    job_id = payload.get("job_id")
                    if not job_id:
                        raise ValueError("missing job_id")

                    try:
                        await run_one(payload)
                    except Exception as e:
                        storage.update_job(
                            job_id,
                            status="failed",
                            finished_at=storage.now_iso(),
                            error={
                                "message": f"{type(e).__name__}: {e}",
                                "traceback": traceback.format_exc(),
                            },
                        )
                        raise

    await conn.close()


if __name__ == "__main__":
    asyncio.run(main())
