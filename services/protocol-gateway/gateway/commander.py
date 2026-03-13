# =============================================================================
# commander.py  (Command Consumer — RabbitMQ → BACnet WriteProperty)
# =============================================================================
#
# COMMAND MESSAGE FORMAT (JSON):
# {
#   "device_id":  "bacnet:1",
#   "point_name": "ZN-SP",
#   "value":      "74.0",
#   "priority":   8
# }
#
# Publish to exchange: daws.bas.commands
# Routing key:         command.bacnet.<point_name>
#
# Uses a DURABLE named queue "gateway.commands" so the HTTP management API
# and other producers can reliably deliver messages even between restarts.
#
# =============================================================================

import json
import logging
import os
import pika
import asyncio
from threading import Thread

logger = logging.getLogger(__name__)

COMMAND_QUEUE = "gateway.commands"


class Commander:
    """
    Subscribes to the commands exchange via a durable named queue and
    forwards write requests to the BACnet handler via an asyncio.Queue.
    """

    def __init__(self, command_queue: asyncio.Queue):
        self.host          = os.environ.get("RABBITMQ_HOST",     "localhost")
        self.user          = os.environ.get("RABBITMQ_USER",     "daws")
        self.password      = os.environ.get("RABBITMQ_PASS",     "changeme")
        self.vhost         = os.environ.get("RABBITMQ_VHOST",    "bas")
        self.cmd_exchange  = "daws.bas.commands"
        self.command_queue = command_queue
        self.loop          = None
        self.connection    = None
        self.channel       = None

    def _connect(self):
        credentials = pika.PlainCredentials(self.user, self.password)
        params = pika.ConnectionParameters(
            host=self.host, virtual_host=self.vhost,
            credentials=credentials, heartbeat=60
        )
        self.connection = pika.BlockingConnection(params)
        self.channel    = self.connection.channel()

        # Durable topic exchange for commands
        self.channel.exchange_declare(
            exchange=self.cmd_exchange,
            exchange_type="topic",
            durable=True
        )

        # Durable named queue — survives restarts, receivable via HTTP API
        self.channel.queue_declare(
            queue=COMMAND_QUEUE,
            durable=True
        )

        # Bind to all command routing keys
        self.channel.queue_bind(
            exchange=self.cmd_exchange,
            queue=COMMAND_QUEUE,
            routing_key="command.#"
        )

        logger.info(f"Commander bound queue '{COMMAND_QUEUE}' to {self.cmd_exchange} (command.#)")
        return COMMAND_QUEUE

    def _on_message(self, ch, method, properties, body):
        try:
            cmd = json.loads(body.decode())
            logger.info(f"Command received: {cmd}")
            self.loop.call_soon_threadsafe(self.command_queue.put_nowait, cmd)
            ch.basic_ack(delivery_tag=method.delivery_tag)
        except Exception as e:
            logger.error(f"Failed to parse command: {e} | body: {body}")
            ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)

    def _run(self):
        try:
            queue_name = self._connect()
            self.channel.basic_qos(prefetch_count=1)
            self.channel.basic_consume(
                queue=queue_name,
                on_message_callback=self._on_message,
                auto_ack=False   # Manual ack — safer for write commands
            )
            logger.info("Commander consuming commands...")
            self.channel.start_consuming()
        except Exception as e:
            logger.error(f"Commander error: {e}", exc_info=True)

    def start(self, loop: asyncio.AbstractEventLoop):
        self.loop = loop
        t = Thread(target=self._run, daemon=True, name="commander")
        t.start()
        logger.info("Commander thread started")
