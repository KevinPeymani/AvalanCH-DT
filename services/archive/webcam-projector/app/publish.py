import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pika
import yaml

from .config import load_settings


def load_camera_yaml(path: Path) -> dict:
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    if "camera" not in data:
        raise ValueError("camera YAML must contain a top-level 'camera' key")
    return data["camera"]


def build_message(camera: dict) -> dict:
    now = datetime.now(timezone.utc)
    width = camera.get("image", {}).get("resolution", {}).get("width", 14309)
    height = camera.get("image", {}).get("resolution", {}).get("height", 2048)

    return {
        "job_id": str(uuid.uuid4()),
        "message_type": "detector_result_ready",
        "camera": camera,
        "capture": {
            "captured_at_utc": now.isoformat(),
            "captured_at_local": now.isoformat(),
            "date": now.strftime("%Y-%m-%d"),
            "time": now.strftime("%H:%M:%S"),
        },
        "source": {
            "raw_image_width": width,
            "raw_image_height": height,
            "raw_path": "/tmp/example.jpg",
            "cloud_url": "local",
        },
        "tile": {
            "index": 0,
            "path": "/tmp/tile_000.jpg",
            "x0": 0,
            "y0": 0,
            "x1": width,
            "y1": height,
            "width": width,
            "height": height,
            "overlap_px": 160,
        },
        "detections": [
            {
                "id": "det-1",
                "class_name": "avalanche",
                "confidence": 0.91,
                "bbox": [6200, 1100, 6700, 1450],
            },
            {
                "id": "det-2",
                "class_name": "snow_smoke",
                "confidence": 0.42,
                "bbox": [2500, 850, 2900, 1150],
            },
        ],
    }


def main():
    config_path = "config/dev.yaml"
    settings = load_settings(config_path)

    if len(sys.argv) < 2:
        print("usage: python -m app.publish <camera_yaml>")
        sys.exit(1)

    camera_yaml = Path(sys.argv[1]).resolve()
    camera = load_camera_yaml(camera_yaml)
    message = build_message(camera)

    params = pika.URLParameters(settings.rabbitmq.url)
    params.heartbeat = 600
    params.blocked_connection_timeout = 300

    conn = pika.BlockingConnection(params)
    ch = conn.channel()

    ch.queue_declare(queue=settings.rabbitmq.input_queue, durable=True)
    ch.queue_declare(queue=settings.rabbitmq.output_queue, durable=True)

    ch.basic_publish(
        exchange="",
        routing_key=settings.rabbitmq.input_queue,
        body=json.dumps(message, ensure_ascii=False).encode("utf-8"),
        properties=pika.BasicProperties(
            delivery_mode=2,
            content_type="application/json",
        ),
    )

    print(f"published job_id={message['job_id']} to {settings.rabbitmq.input_queue}")
    print("waiting for projector output...\n")

    while True:
        method, properties, body = ch.basic_get(queue=settings.rabbitmq.output_queue, auto_ack=False)
        if method is None:
            continue

        payload = json.loads(body.decode("utf-8"))
        if payload.get("job_id") == message["job_id"]:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
            ch.basic_ack(delivery_tag=method.delivery_tag)
            break

        ch.basic_ack(delivery_tag=method.delivery_tag)

    conn.close()


if __name__ == "__main__":
    main()
