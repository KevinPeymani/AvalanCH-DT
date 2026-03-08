import os, json, uuid
import pika

BROKER_URL = os.getenv("BROKER_URL", "amqp://admin:simulation_secure@localhost:5672/%2F")
QUEUE_NAME = os.getenv("QUEUE_NAME", "simulation_queue")

job_id = "test_" + uuid.uuid4().hex[:8]

payload = {
    "job_id": job_id,
    "job": "simulation",
    "input_dir": "/data/avaParabola",   # must exist inside containers
    "params": {
        "auto_init": True,
        "clean": False,
        "run_ab": False
    }
}

conn = pika.BlockingConnection(pika.URLParameters(BROKER_URL))
ch = conn.channel()
ch.queue_declare(queue=QUEUE_NAME, durable=True)

ch.basic_publish(
    exchange="",
    routing_key=QUEUE_NAME,
    body=json.dumps(payload).encode("utf-8"),
    properties=pika.BasicProperties(delivery_mode=2),
)

print("sent job_id:", job_id)
conn.close()
