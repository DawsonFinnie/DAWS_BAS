# =============================================================================
# publisher.py
# =============================================================================
#
# WHAT IS THIS FILE?
# This file handles the connection to RabbitMQ and sends (publishes)
# normalized point data messages to it.
#
# WHAT IS RABBITMQ?
# RabbitMQ is a "message broker" — think of it like a post office.
# Instead of one service talking directly to another, services send
# messages to RabbitMQ (the post office), and other services pick up
# their messages from there.
#
# This means:
#   - The protocol gateway doesn't need to know who is consuming the data
#   - New consumers (InfluxDB, Neo4j, Web UI) can be added without
#     changing the gateway code at all
#   - If a consumer is offline, messages queue up and get delivered later
#
# KEY RABBITMQ CONCEPTS USED HERE:
#
#   Exchange:
#     The routing engine inside RabbitMQ. We use a "topic" exchange,
#     which routes messages based on a routing key pattern.
#     Our exchange is named "daws.bas".
#
#   Routing Key:
#     A dot-separated string that describes what a message is about.
#     Format: "point.<protocol>.<point_name>"
#     Examples:
#       "point.bacnet.red_light"     → BACnet point named red_light
#       "point.modbus.supply_temp"   → Modbus point named supply_temp
#       "point.mqtt.zone_co2"        → MQTT point named zone_co2
#
#   Binding Key (used by consumers):
#     A pattern that consumers use to say "I want these messages".
#     The # wildcard means "anything here".
#     Examples:
#       "point.bacnet.#"  → give me all BACnet points
#       "point.#"         → give me everything from all protocols
#
#   Queue:
#     Each consumer has its own queue. RabbitMQ delivers matching
#     messages to each subscribed queue. Telegraf has one queue,
#     Neo4j has another - they each get their own copy of every message.
#
# HOW IT FITS IN THE SYSTEM:
#
#   Protocol handler reads a device point
#       normalize() creates a standard dict
#           publisher.publish() converts dict to JSON
#               JSON string sent to RabbitMQ exchange with routing key
#                   RabbitMQ delivers to all matching consumer queues
#
# =============================================================================

import json     # Python built-in library for converting dicts to/from JSON strings
import pika     # Third-party library for connecting to RabbitMQ (AMQP protocol)
import os       # Python built-in for reading environment variables
import logging  # Python built-in for writing log messages

# Get a logger for this module. Log messages will show "publisher" as the source.
logger = logging.getLogger(__name__)


class Publisher:
    """
    Manages the connection to RabbitMQ and publishes messages.

    A class is used here (instead of plain functions) because we need to
    maintain state - specifically the connection and channel objects that
    stay open across multiple publish() calls.
    """

    def __init__(self):
        # __init__ is called automatically when you create a Publisher()
        # It reads configuration from environment variables set in .env / docker-compose

        # RabbitMQ server address - where to connect
        # Defaults to "localhost" if not set (useful for local testing)
        self.host = os.environ.get("RABBITMQ_HOST", "localhost")

        # Username for RabbitMQ authentication
        self.user = os.environ.get("RABBITMQ_USER", "daws")

        # Password for RabbitMQ authentication
        self.password = os.environ.get("RABBITMQ_PASS", "changeme")

        # Virtual host - RabbitMQ supports multiple isolated environments
        # on one server. We use "bas" to keep DAWS_BAS separate from anything else.
        self.vhost = os.environ.get("RABBITMQ_VHOST", "bas")

        # The exchange name - this is the routing hub all messages go through
        self.exchange = os.environ.get("RABBITMQ_EXCHANGE", "daws.bas")

        # These will hold the actual connection objects once connect() is called
        # They start as None because we haven't connected yet
        self.connection = None  # The TCP connection to RabbitMQ
        self.channel    = None  # A channel within that connection (like a lane)


    def connect(self):
        """
        Opens a connection to RabbitMQ and sets up the exchange.

        This must be called once before any publish() calls.
        Called from gateway/main.py at startup.
        """

        # PlainCredentials packages the username and password together
        credentials = pika.PlainCredentials(self.user, self.password)

        # ConnectionParameters describes how to reach the RabbitMQ server
        parameters = pika.ConnectionParameters(
            host         = self.host,       # IP or hostname of the RabbitMQ server
            virtual_host = self.vhost,      # Which virtual host to connect to
            credentials  = credentials,     # Username + password
            heartbeat    = 60               # Send a "still alive" ping every 60 seconds
                                            # This keeps the connection from timing out
        )

        # Open the actual TCP connection to RabbitMQ
        # BlockingConnection means we wait for the connection to be established
        # before moving on (as opposed to async connections)
        self.connection = pika.BlockingConnection(parameters)

        # A channel is a virtual connection within the TCP connection.
        # RabbitMQ uses channels to multiplex multiple operations over one TCP socket.
        # You can think of it like multiple lanes on one highway.
        self.channel = self.connection.channel()

        # Declare the exchange if it doesn't already exist.
        # exchange_type="topic" means routing is based on dot-separated routing key patterns.
        # durable=True means the exchange survives a RabbitMQ server restart.
        self.channel.exchange_declare(
            exchange      = self.exchange,
            exchange_type = "topic",
            durable       = True        # Persist across RabbitMQ restarts
        )

        logger.info(f"Connected to RabbitMQ at {self.host}, exchange: {self.exchange}")


    def publish(self, message: dict, protocol: str, point_name: str):
        """
        Publishes one normalized point update message to RabbitMQ.

        Parameters:
            message    - The normalized dict from normalizer.normalize()
            protocol   - Protocol string e.g. "bacnet", "modbus", "mqtt"
            point_name - Point name string e.g. "red_light", "supply_temp"

        The routing key is built from protocol and point_name:
            "point.bacnet.red_light"
            "point.modbus.supply_temp"

        Consumers use wildcard patterns to subscribe:
            "point.#"         → receive everything
            "point.bacnet.#"  → receive only BACnet points
        """

        # Build the routing key from protocol and point name
        # This is what RabbitMQ uses to decide which queues get this message
        routing_key = f"point.{protocol}.{point_name}"

        # json.dumps() converts a Python dict to a JSON string
        # e.g. {"value": "active"} → '{"value": "active"}'
        # RabbitMQ messages are byte strings, so we need to convert the dict first
        body = json.dumps(message)

        # Send the message to the exchange with the routing key
        self.channel.basic_publish(
            exchange    = self.exchange,    # Which exchange to send to
            routing_key = routing_key,      # How to route it to the right queues
            body        = body,             # The message content (JSON string)
            properties  = pika.BasicProperties(
                delivery_mode = 2,              # 2 = persistent message
                                                # This means the message is saved to disk
                                                # and survives a RabbitMQ restart
                                                # 1 = transient (lost on restart)
                content_type  = "application/json"  # Tell consumers what format this is
            )
        )

        # Log at DEBUG level (only visible if debug logging is enabled)
        # DEBUG is used here because this fires hundreds of times per minute
        # and would flood the logs if set to INFO
        logger.debug(f"Published [{routing_key}]: {body}")


    def disconnect(self):
        """
        Cleanly closes the RabbitMQ connection.
        Called during shutdown to avoid leaving open connections on the server.
        """

        # Check that a connection exists and is not already closed before closing
        if self.connection and not self.connection.is_closed:
            self.connection.close()
            logger.info("Disconnected from RabbitMQ")
