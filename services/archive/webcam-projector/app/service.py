from __future__ import annotations

import json
import logging
from datetime import datetime, timezone
from typing import Any

import pika

from .config import ServiceSettings
from .messages import coalesce, extract_detections, get_nested
from .projector import CameraGeometry, SwissProjector

logger = logging.getLogger("webcam-projector")


class WebcamProjectorService:
    def __init__(self, settings: ServiceSettings):
        self.settings = settings
        self.projector = SwissProjector(
            swiss_epsg=settings.projection.swiss_epsg,
            min_range_m=settings.projection.min_range_m,
            max_range_m=settings.projection.max_range_m,
            earth_radius_m=settings.projection.earth_radius_m,
        )

    def build_camera_geometry(self, message: dict[str, Any]) -> CameraGeometry:
        raw_w = int(
            coalesce(
                get_nested(message, "source", "raw_image_width"),
                get_nested(message, "image", "raw_width"),
                get_nested(message, "camera", "image_width"),
                0,
            )
        )
        raw_h = int(
            coalesce(
                get_nested(message, "source", "raw_image_height"),
                get_nested(message, "image", "raw_height"),
                get_nested(message, "camera", "image_height"),
                0,
            )
        )

        if raw_w <= 0 or raw_h <= 0:
            tile = message.get("tile", {})
            if tile:
                raw_w = max(raw_w, int(tile.get("x1", 0)))
                raw_h = max(raw_h, int(tile.get("y1", 0)))

        lat = coalesce(
            get_nested(message, "camera", "location", "latitude"),
            get_nested(message, "camera", "latitude"),
        )
        lon = coalesce(
            get_nested(message, "camera", "location", "longitude"),
            get_nested(message, "camera", "longitude"),
        )
        elev = coalesce(
            get_nested(message, "camera", "location", "elevation_m"),
            get_nested(message, "camera", "elevation_m"),
            0.0,
        )
        north = coalesce(
            get_nested(message, "camera", "location", "north_deg"),
            get_nested(message, "angles", "reference_north_deg"),
            0.0,
        )
        fov = coalesce(
            get_nested(message, "camera", "location", "fov_deg"),
            get_nested(message, "angles", "fov_deg"),
            360.0,
        )
        is_panorama = bool(
            coalesce(
                get_nested(message, "camera", "is_panorama"),
                get_nested(message, "camera", "image", "is_panorama"),
                True,
            )
        )

        if lat is None or lon is None:
            raise ValueError("Camera latitude/longitude are required in the message")

        return CameraGeometry(
            latitude=float(lat),
            longitude=float(lon),
            elevation_m=float(elev),
            north_deg=float(north),
            fov_deg=float(fov),
            raw_width=int(raw_w),
            raw_height=int(raw_h),
            is_panorama=is_panorama,
        )

    def project_message(self, message: dict[str, Any]) -> dict[str, Any]:
        camera = self.build_camera_geometry(message)
        detections = extract_detections(
            message,
            fallback_class=self.settings.projection.default_detection_class,
        )
        valid_detections = [
            d for d in detections if d["confidence"] >= self.settings.projection.confidence_floor
        ]

        projected = [
            self.projector.project_detection(detection=d, camera=camera)
            for d in valid_detections
        ]

        now_utc = datetime.now(timezone.utc).isoformat()

        return {
            "job_id": message.get("job_id"),
            "message_type": "projected_detection_ready",
            "service": {
                "name": self.settings.rabbitmq.service_name,
                "projected_at_utc": now_utc,
            },
            "camera": message.get("camera", {}),
            "capture": message.get("capture", {}),
            "source": message.get("source", {}),
            "tile": message.get("tile", {}),
            "input_message_type": message.get("message_type"),
            "projector": {
                "swiss_epsg": self.settings.projection.swiss_epsg,
                "range_model": {
                    "type": "linear_y_to_range",
                    "min_range_m": self.settings.projection.min_range_m,
                    "max_range_m": self.settings.projection.max_range_m,
                },
            },
            "projected_detections": projected,
            "counts": {
                "input_detections": len(detections),
                "projected_detections": len(projected),
            },
        }

    def publish(self, channel, payload: dict[str, Any]) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        channel.basic_publish(
            exchange="",
            routing_key=self.settings.rabbitmq.output_queue,
            body=body,
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json",
            ),
        )

    def run(self) -> None:
        params = pika.URLParameters(self.settings.rabbitmq.url)
        params.heartbeat = 600
        params.blocked_connection_timeout = 300

        conn = pika.BlockingConnection(params)
        channel = conn.channel()

        channel.queue_declare(queue=self.settings.rabbitmq.input_queue, durable=True)
        channel.queue_declare(queue=self.settings.rabbitmq.output_queue, durable=True)
        channel.basic_qos(prefetch_count=1)

        logger.info("service=%s", self.settings.rabbitmq.service_name)
        logger.info("input_queue=%s", self.settings.rabbitmq.input_queue)
        logger.info("output_queue=%s", self.settings.rabbitmq.output_queue)

        def on_message(ch, method, properties, body):
            try:
                message = json.loads(body.decode("utf-8"))
                projected = self.project_message(message)

                if self.settings.runtime.debug:
                    print(json.dumps(projected, indent=2, ensure_ascii=False))
                else:
                    self.publish(ch, projected)

                ch.basic_ack(delivery_tag=method.delivery_tag)
            except Exception:
                logger.exception("failed to process message")
                ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)

        channel.basic_consume(
            queue=self.settings.rabbitmq.input_queue,
            on_message_callback=on_message,
            auto_ack=False,
        )

        logger.info("waiting for messages")
        try:
            channel.start_consuming()
        finally:
            if conn.is_open:
                conn.close()
