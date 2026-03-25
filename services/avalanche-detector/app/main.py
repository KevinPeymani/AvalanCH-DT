import json
import logging
from pathlib import Path

import pika

from .config import load_settings
from .detector import AvalancheDetector
from .mq import MQClient
from .schemas import DownloadTileMessage, DetectionResultMessage

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("detector")


def main():
    settings = load_settings("./config/dev.yaml")

    detector = AvalancheDetector(settings)
    publisher = MQClient(settings.rabbitmq.url)
    publisher.declare_queue(settings.rabbitmq.output_queue)

    params = pika.URLParameters(settings.rabbitmq.url)
    connection = pika.BlockingConnection(params)
    channel = connection.channel()

    channel.queue_declare(queue=settings.rabbitmq.input_queue, durable=True)
    channel.basic_qos(prefetch_count=settings.rabbitmq.prefetch_count)

    def callback(ch, method, properties, body):
        try:
            payload = json.loads(body)
            msg = DownloadTileMessage(**payload)

            tile_path = Path(msg.tile.path)
            if not tile_path.exists():
                raise FileNotFoundError(tile_path)

            result = detector.predict(str(tile_path))

            detections = detector.extract_detections(
                result,
                x0=msg.tile.x0,
                y0=msg.tile.y0,
            )

            detections = detector.apply_postprocess(
                detections,
                msg.tile.width,
                msg.tile.height
            )

            out = DetectionResultMessage(
                job_id=msg.job_id,
                source=msg.source,
                capture=msg.capture,
                image=msg.image,
                tile=msg.tile,
                geometry=msg.geometry,
                detections=detections,
                has_detection=len(detections) > 0,
            )

            publisher.publish(settings.rabbitmq.output_queue, out.model_dump())

            logger.info(
                "[%s:%s tile=%d] det=%d",
                msg.source.source_type,
                msg.source.source_id,
                msg.tile.index,
                len(detections),
            )

            ch.basic_ack(method.delivery_tag)

        except Exception:
            logger.exception("error")
            ch.basic_nack(method.delivery_tag, requeue=False)

    channel.basic_consume(
        queue=settings.rabbitmq.input_queue,
        on_message_callback=callback
    )

    logger.info("Listening...")
    channel.start_consuming()


if __name__ == "__main__":
    main()
