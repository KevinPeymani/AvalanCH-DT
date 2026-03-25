#!/usr/bin/env python3

import os
import io
import json
import time
import uuid
import logging
from dataclasses import dataclass
from datetime import datetime, time as dt_time
from pathlib import Path
from typing import Any, Dict, Optional, List

import requests
import yaml
from PIL import Image
from zoneinfo import ZoneInfo

from app.config import load_config

CFG = load_config()

CAMERA_DIR = CFG.camera_dir
DOWNLOAD_DIR = CFG.download_dir
TILES_DIR = CFG.tiles_dir
OUTBOX_DIR = CFG.outbox_dir
STATE_DIR = CFG.state_dir
POLL_INTERVAL = CFG.poll_interval
DEBUG_LOCAL_OUTBOX = CFG.debug_local_outbox
USE_BROKER = CFG.use_broker

POLL_INTERVAL = int(os.getenv("POLL_INTERVAL", "60"))

TILE_WIDTH = 1280
TILE_OVERLAP = 160

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("camera-fetcher")

SESSION = requests.Session()
SESSION.headers["User-Agent"] = "Mozilla/5.0"


# ================= CAMERA =================

@dataclass
class CameraConfig:
    path: Path
    raw: Dict[str, Any]

    @property
    def c(self):
        return self.raw["camera"]

    @property
    def name(self):
        return self.c["name"]

    @property
    def timezone(self):
        return self.c["provider"]["timezone"]

    @property
    def inactive(self):
        return self.c["capabilities"].get("cam_inactive", False)

    @property
    def nightvision(self):
        return self.c["capabilities"].get("nightvision", False)

    @property
    def schedule(self):
        return self.c["temporal"]["schedule"]

    @property
    def base_url(self):
        return self.c["data_access"]["base_url"]

    @property
    def cam_id(self):
        return self.c["data_access"]["storage_camera_id"]

    @property
    def north(self):
        return self.c["location"].get("north_deg", 0)

    @property
    def fov(self):
        return self.c["location"].get("fov_deg", 360)


# ================= TIME =================

def parse_time(t):
    h, m = map(int, t.split(":"))
    return dt_time(h, m)


def in_range(now, start, end):
    return start <= now <= end if start <= end else (now >= start or now <= end)


def get_slot(cam, now):
    for s in cam.schedule:
        if in_range(now.time(), parse_time(s["start"]), parse_time(s["end"])):
            return s
    return None


def snap(now, start, step):
    mins = now.hour * 60 + now.minute
    base = start.hour * 60 + start.minute
    if mins < base:
        mins += 1440
    snapped = base + ((mins - base) // step) * step
    snapped %= 1440
    return dt_time(snapped // 60, snapped % 60)


# ================= STATE =================

def load_last_processed(cam):
    f = STATE_DIR / f"{cam.path.stem}.txt"
    if not f.exists():
        return None
    return f.read_text().strip()


def save_last_processed(cam, key):
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    (STATE_DIR / f"{cam.path.stem}.txt").write_text(key)


# ================= DOWNLOAD =================

def download(url):
    try:
        r = SESSION.get(url, timeout=10)
        logger.info("GET %s -> %s", url, r.status_code)
        return r.content if r.status_code == 200 else None
    except Exception as e:
        logger.warning("download error %s", e)
        return None


# ================= TILING =================

def tiles(w):
    step = TILE_WIDTH - TILE_OVERLAP
    xs = []
    x = 0
    while x + TILE_WIDTH < w:
        xs.append(x)
        x += step
    xs.append(max(0, w - TILE_WIDTH))
    return xs


def angle(x, w, north, fov):
    return (north + (x / w) * fov) % 360


# ================= PROCESS =================

def process(cam):
    tz = ZoneInfo(cam.timezone)
    now = datetime.now(tz)

    if cam.inactive:
        return 0

    slot = get_slot(cam, now)
    if not slot:
        return 0

    if slot.get("type") == "night" and not cam.nightvision:
        return 0

    dt = now.replace(
        hour=snap(now, parse_time(slot["start"]), slot["step_minutes"]).hour,
        minute=snap(now, parse_time(slot["start"]), slot["step_minutes"]).minute,
        second=0,
    )

    key = f"{cam.path.stem}|{dt.strftime('%Y-%m-%dT%H:%M:%S')}"
    if load_last_processed(cam) == key:
        logger.info("[%s] skip already processed", cam.name)
        return 0

    url = f"{cam.base_url}/{cam.cam_id}/{dt.strftime('%Y-%m-%d')}/{dt.strftime('%H-%M-%S')}/{dt.strftime('%Y-%m-%d-%H-%M-%S')}_half.jpg"

    logger.info("[%s] try %s", cam.name, url)

    img_bytes = download(url)
    if not img_bytes:
        return 0

    img = Image.open(io.BytesIO(img_bytes))
    w, h = img.size

    raw_dir = DOWNLOAD_DIR / cam.path.stem
    raw_dir.mkdir(parents=True, exist_ok=True)

    raw_path = raw_dir / f"{dt.strftime('%H%M%S')}.jpg"
    raw_path.write_bytes(img_bytes)

    count = 0
    for i, x in enumerate(tiles(w)):
        tile = img.crop((x, 0, x + TILE_WIDTH, h))

        tile_dir = TILES_DIR / cam.path.stem
        tile_dir.mkdir(parents=True, exist_ok=True)

        tile_path = tile_dir / f"{raw_path.stem}_{i}.jpg"
        tile.save(tile_path)

        msg = {
            "job_id": str(uuid.uuid4()),
            "camera": cam.name,
            "tile": str(tile_path),
            "angle_start": angle(x, w, cam.north, cam.fov),
            "angle_end": angle(x + TILE_WIDTH, w, cam.north, cam.fov),
        }

        out = OUTBOX_DIR / f"{uuid.uuid4()}.json"
        OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
        out.write_text(json.dumps(msg, indent=2))

        count += 1

    save_last_processed(cam, key)
    logger.info("[%s] done %d tiles", cam.name, count)
    return count


# ================= MAIN =================

def main():
    DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
    TILES_DIR.mkdir(parents=True, exist_ok=True)
    OUTBOX_DIR.mkdir(parents=True, exist_ok=True)
    STATE_DIR.mkdir(parents=True, exist_ok=True)

    cams = []
    for f in CAMERA_DIR.glob("*.yaml"):
        cams.append(CameraConfig(f, yaml.safe_load(open(f))))

    while True:
        total = 0
        for cam in cams:
            total += process(cam)

        logger.info("cycle done: %d messages", total)
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    if USE_BROKER:
        logger.info("using RabbitMQ")
    else:
        logger.info("using local outbox=%s", OUTBOX_DIR)
    main()
