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


from pathlib import Path
import shutil
from typing import Dict, Any
import urllib.parse

def is_remote(uri: str) -> bool:
    parsed = urllib.parse.urlparse(uri)
    return parsed.scheme in ("http", "https", "s3")

async def prepare_inputs(job_id: str, payload: Dict[str, Any]) -> Dict[str, Any]:
    """
    Prepare avalanche_dir/Inputs from dem_uri + rel_uri.

    Supports:
      - local paths (for dev)
      - http/https/s3 (future prod)
    """

    ava_dir = storage.avalanche_dir(job_id)
    inputs_dir = ava_dir / "Inputs"
    dem_dir = inputs_dir / "DEM"
    rel_dir = inputs_dir / "REL"
    cfg_dir = inputs_dir / "CFGs"

    dem_dir.mkdir(parents=True, exist_ok=True)
    rel_dir.mkdir(parents=True, exist_ok=True)
    cfg_dir.mkdir(parents=True, exist_ok=True)

    dem_uri = payload.get("dem_uri")
    rel_uri = payload.get("rel_uri")

    if not dem_uri or not rel_uri:
        raise ValueError("dem_uri and rel_uri are required")

    # ---- DEM handling ----
    dem_dest = dem_dir / Path(dem_uri).name
    if is_remote(dem_uri):
        #await download_file(dem_uri, dem_dest)   # implement later
        raise ValueError("remote DEM not supported yet")
    else:
        shutil.copy(Path(dem_uri), dem_dest)

    # ---- REL handling ----
    rel_dest = rel_dir / Path(rel_uri).name
    if is_remote(rel_uri):
        #await download_file(rel_uri, rel_dest)
        raise ValueError("remote REL not supported yet")
    else:
        shutil.copy(Path(rel_uri), rel_dest)

    return {
        "prepared": True,
        "inputsDir": str(inputs_dir),
        "dem_path": str(dem_dest),
        "rel_path": str(rel_dest),
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
