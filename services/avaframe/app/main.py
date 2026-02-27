import os
import json
import uuid
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
import aio_pika

from .models import AvalancheJobRequest, AvalancheJob  # tes modèles
from . import storage

RABBITMQ_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
QUEUE_NAME = os.getenv("QUEUE_NAME", "simulation_queue")

app = FastAPI(title="Avalanche Service API")

mq_connection = None
mq_channel = None


@app.on_event("startup")
async def startup():
    global mq_connection, mq_channel
    mq_connection = await aio_pika.connect_robust(RABBITMQ_URL)
    mq_channel = await mq_connection.channel()
    await mq_channel.declare_queue(QUEUE_NAME, durable=True)


@app.on_event("shutdown")
async def shutdown():
    global mq_connection
    if mq_connection:
        await mq_connection.close()


@app.get("/health")
async def health():
    return {"status": "ok"}


@app.post("/simulate/avalanche", response_model=AvalancheJob)
async def simulate_avalanche(req: AvalancheJobRequest):
    """
    User calls ONLY this endpoint.
    We create a job, persist job.json, publish to RabbitMQ.
    """
    if mq_channel is None or mq_channel.is_closed:
        raise HTTPException(status_code=503, detail="Broker not available")

    job_id = uuid.uuid4().hex

    # worker payload
    payload = {
        "job_id": job_id,
        "job": "simulation",  # uses JOB_REGISTRY alias -> operational_simulation
        "dem_uri": req.dem_uri,
        "rel_uri": req.rel_uri,
        "avalanche_type": req.avalanche_type,
        "quality": req.quality,
        "params": req.params,
    }

    storage.init_job(job_id, payload)

    await mq_channel.default_exchange.publish(
        aio_pika.Message(
            body=json.dumps(payload).encode("utf-8"),
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
            content_type="application/json",
        ),
        routing_key=QUEUE_NAME,
    )

    meta = storage.get_job(job_id)
    return AvalancheJob(
        job_id=meta["job_id"],
        status=meta["status"],
        created_at=meta["created_at"],
        started_at=meta["started_at"],
        finished_at=meta["finished_at"],
        error=meta["error"],
        outputs_dir=meta["outputs_dir"],
    )


@app.get("/jobs/{job_id}", response_model=AvalancheJob)
async def get_job(job_id: str):
    try:
        meta = storage.get_job(job_id)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="job not found")

    return AvalancheJob(
        job_id=meta["job_id"],
        status=meta["status"],
        created_at=meta["created_at"],
        started_at=meta.get("started_at"),
        finished_at=meta.get("finished_at"),
        error=meta.get("error"),
        outputs_dir=meta.get("outputs_dir", ""),
    )


@app.get("/jobs/{job_id}/artifacts")
async def get_artifacts(job_id: str):
    try:
        storage.get_job(job_id)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="job not found")
    return {"job_id": job_id, "files": storage.list_artifacts(job_id)}


@app.get("/jobs/{job_id}/artifacts/{relpath:path}")
async def download_artifact(job_id: str, relpath: str):
    try:
        storage.get_job(job_id)
        path = storage.resolve_artifact_path(job_id, relpath)
    except FileNotFoundError:
        raise HTTPException(status_code=404, detail="job not found")
    except ValueError:
        raise HTTPException(status_code=400, detail="invalid path")

    if not path.exists():
        raise HTTPException(status_code=404, detail="file not found")

    return FileResponse(str(path))
