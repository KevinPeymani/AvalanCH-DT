from __future__ import annotations

import asyncio
import json
import os
import traceback
from typing import Any, Dict

import aio_pika

from . import storage
from .digest_service import run_digest
from .ingest_service import run_ingestion
from .simulation_service import run_simulation

RABBITMQ_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
WORKER_TYPE = os.getenv("WORKER_TYPE", "simulation").strip().lower()

INGEST_QUEUE = os.getenv("INGEST_QUEUE", "ingestion_queue")
SIM_QUEUE = os.getenv("SIM_QUEUE", "simulation_queue")
DIGEST_QUEUE = os.getenv("DIGEST_QUEUE", "digestion_queue")

RECONNECT_DELAY_SECONDS = int(os.getenv("RECONNECT_DELAY_SECONDS", "5"))
PREFETCH_COUNT = int(os.getenv("PREFETCH_COUNT", "1"))


def queue_name_for_worker() -> str:
    if WORKER_TYPE == "ingestion":
        return INGEST_QUEUE
    if WORKER_TYPE == "simulation":
        return SIM_QUEUE
    if WORKER_TYPE == "digestion":
        return DIGEST_QUEUE
    raise ValueError(f"Unsupported WORKER_TYPE='{WORKER_TYPE}'")


async def publish_to_queue(channel: aio_pika.Channel, queue_name: str, payload: Dict[str, Any]) -> None:
    await channel.declare_queue(queue_name, durable=True)
    await channel.default_exchange.publish(
        aio_pika.Message(
            body=json.dumps(storage.to_jsonable(payload)).encode("utf-8"),
            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
        ),
        routing_key=queue_name,
    )


async def process_message(payload: Dict[str, Any], channel: aio_pika.Channel) -> Dict[str, Any]:
    if "job_id" not in payload:
        raise ValueError("payload.job_id is required")

    if WORKER_TYPE == "ingestion":
        return await run_ingestion(payload, channel, SIM_QUEUE)

    if WORKER_TYPE == "simulation":
        sim_result = await asyncio.to_thread(run_simulation, payload)
        digest_payload = dict(payload)
        digest_payload["simulation_result"] = sim_result
        await publish_to_queue(channel, DIGEST_QUEUE, digest_payload)
        return sim_result

    if WORKER_TYPE == "digestion":
        return await run_digest(payload, channel)

    raise ValueError(f"Unsupported WORKER_TYPE='{WORKER_TYPE}'")


async def handle_message(message: aio_pika.IncomingMessage, channel: aio_pika.Channel) -> None:
    payload: Dict[str, Any] | None = None
    job_id: str | None = None

    try:
        payload = json.loads(message.body.decode("utf-8"))
        job_id = payload.get("job_id")

        await process_message(payload, channel)

        await message.ack()
        print(f"[worker:{WORKER_TYPE}] job '{job_id}' done")

    except Exception as exc:
        print(f"[worker:{WORKER_TYPE}] job failed: {exc}")
        print(traceback.format_exc())

        if job_id:
            try:
                storage.update_job(
                    job_id,
                    status="failed",
                    finished_at=storage.now_iso(),
                    error={
                        "message": f"{type(exc).__name__}: {exc}",
                        "traceback": traceback.format_exc(),
                        "worker_type": WORKER_TYPE,
                    },
                )
            except Exception as storage_error:
                print(f"[worker:{WORKER_TYPE}] failed to update job status: {storage_error}")
                print(traceback.format_exc())

        try:
            await message.reject(requeue=False)
        except Exception as ack_error:
            print(f"[worker:{WORKER_TYPE}] failed to reject message: {ack_error}")
            print(traceback.format_exc())


async def consume_forever() -> None:
    queue_name = queue_name_for_worker()

    while True:
        conn = None
        try:
            print(f"[worker:{WORKER_TYPE}] connecting to broker: {RABBITMQ_URL}")
            conn = await aio_pika.connect_robust(RABBITMQ_URL, heartbeat=600)

            channel = await conn.channel()
            await channel.set_qos(prefetch_count=PREFETCH_COUNT)

            queue = await channel.declare_queue(queue_name, durable=True)

            print(f"[worker:{WORKER_TYPE}] consuming '{queue_name}'")

            async with queue.iterator() as queue_iter:
                async for message in queue_iter:
                    await handle_message(message, channel)

        except asyncio.CancelledError:
            print(f"[worker:{WORKER_TYPE}] cancellation received, shutting down")
            raise

        except Exception as exc:
            print(f"[worker:{WORKER_TYPE}] consumer loop crashed: {exc}")
            print(traceback.format_exc())
            print(f"[worker:{WORKER_TYPE}] reconnecting in {RECONNECT_DELAY_SECONDS}s...")
            await asyncio.sleep(RECONNECT_DELAY_SECONDS)

        finally:
            if conn is not None:
                try:
                    await conn.close()
                except Exception:
                    pass


async def main() -> None:
    print(f"[worker:{WORKER_TYPE}] starting")
    await consume_forever()


if __name__ == "__main__":
    asyncio.run(main())