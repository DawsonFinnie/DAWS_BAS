# =============================================================================
# commander.py  (Command Consumer — RabbitMQ → BACnet WriteProperty)
# =============================================================================
#
# WHAT IS THIS FILE?
# This module listens on the RabbitMQ "daws.bas.commands" exchange for write
# commands, then forwards them into an asyncio queue that the BACnet handler
# drains and executes as WriteProperty requests.
#
# WHY TWO LAYERS (thread + asyncio queue)?
# pika (RabbitMQ client) is blocking/synchronous. BAC0 is async. They cannot
# directly call each other. The solution:
#   1. Commander runs in a separate OS thread (blocking pika consumer loop)
#   2. When a command arrives, it puts it into a thread-safe asyncio.Queue
#   3. The BACnet coroutine periodically checks that queue and issues writes
#
# COMMAND MESSAGE FORMAT (JSON, published to daws.bas.commands exchange):
# {
#   "device_id":  "bacnet:1",          # matches device_id in point_update messages
#   "point_name": "ZN-SP",             # BACnet object name as discovered
#   "value":      "74.0",              # new value as string (will be cast by BAC0)
#   "priority":   8                    # BACnet write priority (1=highest, 16=lowest)
#                                      # 8 = "Manual Operator", 16 = "Default"
# }
#
# ROUTING KEY FORMAT:
#   command.bacnet.<point_name>
#   e.g. command.bacnet.ZN-SP
#
# CONFIRMATION:
# After the write, the gateway publishes a confirmation back to daws.bas with
# routing key:  command.confirm.<device_id>.<point_name>
# Body: {"status": "ok"|"error", "device_id": ..., "point_name": ..., "value": ...,
#        "message": "..."}
#
# =============================================================================

import json
import logging
import os
import pika
import asyncio
from threading import Thread

logger = logging.getLogger(__name__)


class Commander:
    """
    Subscribes to the commands exchange and forwards write requests to
    the BACnet handler via an asyncio.Queue.
    """

    def __init__(self, command_queue: asyncio.Queue):
        self.host          = os.environ.get("RABBITMQ_HOST",     "localhost")
        self.user          = os.environ.get("RABBITMQ_USER",     "daws")
        self.password      = os.environ.get("RABBITMQ_PASS",     "changeme")
        self.vhost         = os.environ.get("RABBITMQ_VHOST",    "bas")
        self.exchange      = os.environ.get("RABBITMQ_EXCHANGE", "daws.bas")
        self.cmd_exchange  = "daws.bas.commands"
        self.command_queue = command_queue   # asyncio.Queue shared with bacnet.py
        self.loop          = None            # set by start()
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

        # Commands exchange — topic, durable
        self.channel.exchange_declare(
            exchange=self.cmd_exchange, exchange_type="topic", durable=True
        )

        # Exclusive queue — auto-deleted when this consumer disconnects
        result = self.channel.queue_declare(queue="", exclusive=True)
        queue_name = result.method.queue

        # Bind to all command routing keys: command.#
        self.channel.queue_bind(
            exchange=self.cmd_exchange,
            queue=queue_name,
            routing_key="command.#"
        )

        logger.info(f"Commander subscribed to {self.cmd_exchange} (command.#)")
        return queue_name

    def _on_message(self, ch, method, properties, body):
        """Called by pika when a command message arrives."""
        try:
            cmd = json.loads(body.decode())
            logger.info(f"Command received: {cmd}")
            # Thread-safe: schedule putting the command onto the asyncio queue
            # asyncio.Queue is NOT thread-safe by default — use call_soon_threadsafe
            self.loop.call_soon_threadsafe(self.command_queue.put_nowait, cmd)
        except Exception as e:
            logger.error(f"Failed to parse command: {e} | body: {body}")

    def _run(self):
        """Blocking consume loop — runs in its own thread."""
        try:
            queue_name = self._connect()
            self.channel.basic_consume(
                queue=queue_name,
                on_message_callback=self._on_message,
                auto_ack=True
            )
            logger.info("Commander consuming commands...")
            self.channel.start_consuming()
        except Exception as e:
            logger.error(f"Commander error: {e}", exc_info=True)

    def start(self, loop: asyncio.AbstractEventLoop):
        """Start the consumer in a daemon thread."""
        self.loop = loop
        t = Thread(target=self._run, daemon=True, name="commander")
        t.start()
        logger.info("Commander thread started")
