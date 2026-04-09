import json
from pathlib import Path

import pika

BROKER_URL = "amqp://admin:simulation_secure@localhost:5672/"
QUEUE = "alpine3d_queue"


def main() -> None:
    payload_path = Path(__file__).with_name("job_example.json")
    payload = json.loads(payload_path.read_text(encoding="utf-8"))

    conn = pika.BlockingConnection(pika.URLParameters(BROKER_URL))
    ch = conn.channel()
    ch.queue_declare(queue=QUEUE, durable=True)
    ch.basic_publish(
        exchange="",
        routing_key=QUEUE,
        body=json.dumps(payload).encode("utf-8"),
        properties=pika.BasicProperties(delivery_mode=2),
    )
    conn.close()
    print(f"Queued job on {QUEUE}")


if __name__ == "__main__":
    main()
