import json
import pika


class MQClient:
    def __init__(self, url: str):
        params = pika.URLParameters(url)
        params.heartbeat = 600
        params.blocked_connection_timeout = 300
        self.connection = pika.BlockingConnection(params)
        self.channel = self.connection.channel()

    def declare_queue(self, queue):
        self.channel.queue_declare(queue=queue, durable=True)

    def publish(self, queue, payload):
        self.channel.basic_publish(
            exchange="",
            routing_key=queue,
            body=json.dumps(payload).encode(),
            properties=pika.BasicProperties(
                delivery_mode=2,
                content_type="application/json"
            )
        )
