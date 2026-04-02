import json
import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path

import pika
from PIL import Image

from .config import load_settings


def compute_tiles(w, h, tile_width=896, overlap=160):
    tile_w = min(tile_width, w)
    stride = tile_w - overlap

    xs = []
    x = 0
    while x + tile_w < w:
        xs.append(x)
        x += stride
    xs.append(max(0, w - tile_w))

    tiles = []
    for i, x0 in enumerate(xs):
        tiles.append((i, x0, 0, x0 + tile_w, h))

    return tiles


def make_tiles(image_path: Path, tile_dir: Path):
    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    tile_dir.mkdir(parents=True, exist_ok=True)

    tiles = []
    boxes = compute_tiles(w, h)

    for i, x0, y0, x1, y1 in boxes:
        tile = img.crop((x0, y0, x1, y1))

        if tile.width < 896:
            padded = Image.new("RGB", (896, tile.height), (114, 114, 114))
            padded.paste(tile, (0, 0))
            tile = padded

        path = tile_dir / f"tile_{i:03d}.jpg"
        tile.save(path, quality=90)

        tiles.append({
            "index": i,
            "count": len(boxes),
            "path": str(path.resolve()),
            "x0": x0,
            "y0": y0,
            "x1": x1,
            "y1": y1,
            "width": x1 - x0,
            "height": y1 - y0,
            "raw_w": w,
            "raw_h": h
        })

    return tiles


def build_message(image_path: Path, tile, source_id="testcam"):
    now = datetime.now(timezone.utc)

    image_id = f"webcam:{source_id}|{now.isoformat()}"

    return {
        "job_id": str(uuid.uuid4()),
        "message_type": "image_tile_ready",

        "source": {
            "source_type": "webcam",
            "source_id": source_id,
            "source_name": source_id
        },

        "capture": {
            "captured_at": now.isoformat(),
            "captured_at_utc": now.isoformat()
        },

        "image": {
            "image_id": image_id,
            "raw_path": str(image_path.resolve()),
            "raw_image_width": tile["raw_w"],
            "raw_image_height": tile["raw_h"],
            "cloud_url": "local"
        },

        "tile": {
            "index": tile["index"],
            "count": tile["count"],
            "path": tile["path"],
            "x0": tile["x0"],
            "y0": tile["y0"],
            "x1": tile["x1"],
            "y1": tile["y1"],
            "width": tile["width"],
            "height": tile["height"],
            "overlap_px": 160
        },

        "geometry": {
            "angle_center": None
        },

        "metadata": {}
    }


def main():
    if len(sys.argv) < 2:
        print("usage: python -m app.publish <image_path>")
        sys.exit(1)

    settings = load_settings("./config/dev.yaml")

    image_path = Path(sys.argv[1]).resolve()
    if not image_path.exists():
        raise FileNotFoundError(image_path)

    tile_dir = Path("./test/tiles")
    tiles = make_tiles(image_path, tile_dir)

    params = pika.URLParameters(settings.rabbitmq.url)
    connection = pika.BlockingConnection(params)
    ch = connection.channel()

    ch.queue_declare(queue=settings.rabbitmq.input_queue, durable=True)
    ch.queue_declare(queue=settings.rabbitmq.output_queue, durable=True)

    print(f"Sending {len(tiles)} tiles...\n")

    job_ids = set()

    for tile in tiles:
        msg = build_message(image_path, tile)
        job_ids.add(msg["job_id"])

        ch.basic_publish(
            exchange="",
            routing_key=settings.rabbitmq.input_queue,
            body=json.dumps(msg).encode(),
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json"
            )
        )

    print("Waiting results...\n")

    received = 0
    while received < len(tiles):
        method, props, body = ch.basic_get(
            queue=settings.rabbitmq.output_queue,
            auto_ack=False
        )

        if method is None:
            continue

        payload = json.loads(body)

        print(json.dumps(payload, indent=2))
        print("-" * 80)

        received += 1
        ch.basic_ack(method.delivery_tag)

    print(f"Received {received}/{len(tiles)}")

    connection.close()


if __name__ == "__main__":
    main()
