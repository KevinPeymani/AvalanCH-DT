import json
import os
import subprocess
import sys
import traceback

import pika

BROKER_URL = os.environ.get("BROKER_URL", "amqp://admin:simulation_secure@rabbitmq:5672/")
GRID_QUEUE = os.environ.get("GRID_QUEUE", "grid_queue")


def build_command(payload: dict) -> list[str]:
    required = ["dem", "smet_template", "sno_template", "ini_template", "output_root"]
    for key in required:
        if key not in payload:
            raise ValueError(f"Missing required payload key: {key}")

    cmd = [
        "/usr/local/bin/grid_snowpack_service",
        "--dem",
        payload["dem"],
        "--smet-template",
        payload["smet_template"],
        "--sno-template",
        payload["sno_template"],
        "--ini-template",
        payload["ini_template"],
        "--output-root",
        payload["output_root"],
    ]

    if "threads" in payload:
        cmd += ["--threads", str(payload["threads"])]
    if "stride" in payload:
        cmd += ["--stride", str(payload["stride"])]
    if "feature_columns" in payload:
        cmd += ["--feature-columns", payload["feature_columns"]]
    if "features_csv" in payload:
        cmd += ["--features-csv", payload["features_csv"]]
    if "end_time" in payload:
        cmd += ["--end-time", payload["end_time"]]
    if "cell_size" in payload:
        cmd += ["--cell-size", str(payload["cell_size"])]
    if "max_cells" in payload:
        cmd += ["--max-cells", str(payload["max_cells"])]
    if "snowpack_bin" in payload:
        cmd += ["--snowpack-bin", payload["snowpack_bin"]]

    return cmd


def on_message(channel, method, properties, body):
    try:
        payload = json.loads(body.decode("utf-8"))
        cmd = build_command(payload)
        proc = subprocess.run(cmd, cwd="/workspace", check=False)
        if proc.returncode == 0:
            channel.basic_ack(delivery_tag=method.delivery_tag)
            return
        print(f"Job failed with return code {proc.returncode}", file=sys.stderr)
        channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)
    except Exception:
        traceback.print_exc()
        channel.basic_nack(delivery_tag=method.delivery_tag, requeue=False)


if __name__ == "__main__":
    params = pika.URLParameters(BROKER_URL)
    connection = pika.BlockingConnection(params)
    channel = connection.channel()
    channel.queue_declare(queue=GRID_QUEUE, durable=True)
    channel.basic_qos(prefetch_count=1)
    channel.basic_consume(queue=GRID_QUEUE, on_message_callback=on_message)
    print(f"[grid-worker] Listening on queue: {GRID_QUEUE}")
    channel.start_consuming()
