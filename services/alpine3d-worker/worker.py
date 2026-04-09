import json
import os
import subprocess
import sys
import traceback

import pika

BROKER_URL = os.environ.get("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
ALPINE_QUEUE = os.environ.get("ALPINE_QUEUE", "alpine3d_queue")
WORKSPACE_DIR = os.environ.get("WORKSPACE_DIR", "/workspace")
PYTHON_BIN = os.environ.get("PYTHON_BIN", "python")
ALPINE3D_BIN = os.environ.get("ALPINE3D_BIN", "/opt/alpine3d/bin/alpine3d")


def build_pipeline_command(payload: dict) -> list[str]:
    cmd = [
        PYTHON_BIN,
        "Alpine3D/run_alpine3d_pipeline.py",
        "--station",
        str(payload.get("station", "ZER2")),
        "--days",
        str(payload.get("days", 2)),
        "--np",
        str(payload.get("np", 2)),
        "--image",
        str(payload.get("image", "alpine3d:local")),
        "--binary",
        str(payload.get("binary", ALPINE3D_BIN)),
    ]
    return cmd


def build_predict_command(payload: dict) -> list[str]:
    cmd = [
        PYTHON_BIN,
        "Alpine3D/predict_grid.py",
        "--station",
        str(payload.get("station", "ZER2")),
        "--days",
        str(payload.get("predict_days", payload.get("days", 7))),
    ]
    if bool(payload.get("no_png", False)):
        cmd.append("--no-png")
    return cmd


def run_command(cmd: list[str], env: dict) -> None:
    print("[alpine3d-worker] Running:", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=WORKSPACE_DIR, env=env, check=True)


def on_message(channel, method, properties, body):
    try:
        payload = json.loads(body.decode("utf-8")) if body else {}
        job_id = str(payload.get("job_id", "unknown"))
        print(f"[alpine3d-worker] Received job_id={job_id} payload={payload}", flush=True)
        env = os.environ.copy()

        run_command(build_pipeline_command(payload), env)
        run_command(build_predict_command(payload), env)

        channel.basic_ack(delivery_tag=method.delivery_tag)
        print(f"[alpine3d-worker] Job completed job_id={job_id}", flush=True)
    except Exception:
        try:
            payload = json.loads(body.decode("utf-8")) if body else {}
            job_id = str(payload.get("job_id", "unknown"))
        except Exception:
            job_id = "unknown"
        print(f"[alpine3d-worker] Job failed job_id={job_id}", flush=True)
        traceback.print_exc()
        try:
            channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
        except Exception:
            traceback.print_exc()


if __name__ == "__main__":
    try:
        params = pika.URLParameters(BROKER_URL)
        # Jobs can run for tens of minutes, so disable heartbeat timeouts while
        # the callback is blocked in subprocess execution.
        params.heartbeat = 0
        params.blocked_connection_timeout = 3600
        connection = pika.BlockingConnection(params)
        channel = connection.channel()
        channel.queue_declare(queue=ALPINE_QUEUE, durable=True)
        channel.basic_qos(prefetch_count=1)
        channel.basic_consume(queue=ALPINE_QUEUE, on_message_callback=on_message)
        print(f"[alpine3d-worker] Listening on queue: {ALPINE_QUEUE}", flush=True)
        channel.start_consuming()
    except KeyboardInterrupt:
        sys.exit(0)
