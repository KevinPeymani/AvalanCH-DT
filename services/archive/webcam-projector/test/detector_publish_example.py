import json
import sys
import uuid
from datetime import datetime
from pathlib import Path

import pika
from PIL import Image

from .config import load_settings


def compute_tiles(w: int, h: int, tile_width: int, tile_overlap: int):
    """
    Même logique que le fetcher :
    - bandes verticales
    - largeur cible = tile_width
    - hauteur = toute la hauteur
    """
    tile_w = min(tile_width, w)
    tile_h = h

    if tile_w <= 0 or tile_h <= 0:
        return []

    if w <= tile_w:
        return [(0, 0, w, h)]

    stride_x = tile_w - tile_overlap
    if stride_x <= 0:
        raise ValueError("tile_overlap must be smaller than tile_width")

    xs = []
    x = 0
    while x + tile_w < w:
        xs.append(x)
        x += stride_x

    last_x = max(0, w - tile_w)
    if not xs or xs[-1] != last_x:
        xs.append(last_x)

    tiles = []
    seen = set()
    for x0 in xs:
        x1 = x0 + tile_w
        box = (x0, 0, x1, tile_h)
        if box not in seen:
            seen.add(box)
            tiles.append(box)

    return tiles


def px_to_angle(x: float, w: int, north: float = 0.0, fov: float = 360.0) -> float:
    return (north + (x / w) * fov) % 360.0


def make_test_tiles(image_path: Path, tile_dir: Path, tile_width: int, tile_overlap: int):
    img = Image.open(image_path).convert("RGB")
    w, h = img.size

    tile_dir.mkdir(parents=True, exist_ok=True)

    tiles = []
    for i, (x0, y0, x1, y1) in enumerate(compute_tiles(w, h, tile_width, tile_overlap)):
        tile = img.crop((x0, y0, x1, y1))

        if tile.width < tile_width:
            padded = Image.new("RGB", (tile_width, tile.height), (114, 114, 114))
            padded.paste(tile, (0, 0))
            tile = padded

        tile_path = tile_dir / f"tile_{i:03d}.jpg"
        tile.save(tile_path, quality=90)

        tiles.append(
            {
                "idx": i,
                "path": str(tile_path.resolve()),
                "x0": x0,
                "y0": y0,
                "x1": x1,
                "y1": y1,
                "width": x1 - x0,
                "height": y1 - y0,
                "raw_w": w,
                "raw_h": h,
            }
        )

    return tiles


def build_message(image_path: Path, tile: dict):
    now = datetime.now().astimezone()
    return {
        "job_id": str(uuid.uuid4()),
        "message_type": "image_tile_ready",
        "camera": {
            "name": "testcam",
            "slug": "testcam",
            "yaml_file": None,
            "timezone": str(now.tzinfo),
            "storage_camera_id": "testcam",
            "is_panorama": True,
        },
        "capture": {
            "captured_at_local": now.isoformat(),
            "captured_at_utc": now.astimezone().astimezone().isoformat(),
            "date": now.strftime("%Y-%m-%d"),
            "time": now.strftime("%H:%M:%S"),
        },
        "source": {
            "cloud_url": "local",
            "raw_path": str(image_path.resolve()),
            "raw_image_width": tile["raw_w"],
            "raw_image_height": tile["raw_h"],
        },
        "tile": {
            "index": tile["idx"],
            "path": tile["path"],
            "x0": tile["x0"],
            "y0": tile["y0"],
            "x1": tile["x1"],
            "y1": tile["y1"],
            "width": tile["width"],
            "height": tile["height"],
            "overlap_px": 160,
        },
        "angles": {
            "reference_north_deg": 0.0,
            "fov_deg": 360.0,
            "start": px_to_angle(tile["x0"], tile["raw_w"]),
            "end": px_to_angle(tile["x1"], tile["raw_w"]),
            "center": px_to_angle((tile["x0"] + tile["x1"]) / 2.0, tile["raw_w"]),
        },
    }


def main():
    if len(sys.argv) < 2:
        print("usage: python -m app.publish <image_path>")
        sys.exit(1)

    settings = load_settings("./config/dev.yaml")

    image_path = Path(sys.argv[1]).resolve()
    if not image_path.exists():
        raise FileNotFoundError(f"Image not found: {image_path}")

    tile_dir = Path("./test/tiles").resolve()
    tiles = make_test_tiles(
        image_path=image_path,
        tile_dir=tile_dir,
        tile_width=896,
        tile_overlap=160,
    )

    if not tiles:
        print("No tiles generated")
        sys.exit(1)

    params = pika.URLParameters(settings.rabbitmq.url)
    params.heartbeat = 600
    params.blocked_connection_timeout = 300

    conn = pika.BlockingConnection(params)
    ch = conn.channel()

    ch.queue_declare(queue=settings.rabbitmq.input_queue, durable=True)
    ch.queue_declare(queue=settings.rabbitmq.output_queue, durable=True)

    print(f"Publishing {len(tiles)} tiles to {settings.rabbitmq.input_queue}")

    expected_job_ids = set()

    for tile in tiles:
        msg = build_message(image_path, tile)
        expected_job_ids.add(msg["job_id"])

        ch.basic_publish(
            exchange="",
            routing_key=settings.rabbitmq.input_queue,
            body=json.dumps(msg).encode("utf-8"),
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json",
            ),
        )

    print("Waiting for detector outputs...\n")

    received = 0
    while received < len(tiles):
        method, properties, body = ch.basic_get(queue=settings.rabbitmq.output_queue, auto_ack=False)

        if method is None:
            continue

        payload = json.loads(body.decode("utf-8"))

        if payload.get("job_id") in expected_job_ids:
            print(json.dumps(payload, indent=2, ensure_ascii=False))
            print("-" * 80)
            received += 1

        ch.basic_ack(delivery_tag=method.delivery_tag)

    print(f"Received {received}/{len(tiles)} outputs")
    conn.close()


if __name__ == "__main__":
    main()
