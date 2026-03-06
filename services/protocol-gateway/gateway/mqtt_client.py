# =============================================================================
# mqtt_client.py  (MQTT Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file connects to an MQTT broker, subscribes to device topics,
# and forwards received messages to RabbitMQ via the Publisher.
#
# WHAT IS MQTT?
# MQTT (Message Queuing Telemetry Transport) is a lightweight publish/subscribe
# protocol originally designed for IoT devices on unreliable networks.
# It is extremely popular in:
#   - Smart thermostats and sensors
#   - Energy monitors
#   - Custom Arduino/Raspberry Pi sensor nodes
#   - Modern IoT HVAC equipment
#
# MQTT VS BACNET/MODBUS:
# BACnet and Modbus are "pull" protocols — the gateway asks the device for data.
# MQTT is a "push" protocol — devices send data to a broker when they have it.
# This makes MQTT great for battery-powered or wireless sensors that wake up,
# send a reading, and go back to sleep.
#
# KEY MQTT CONCEPTS:
#
#   Broker:
#     A central server that receives and distributes messages.
#     Mosquitto is the most common open-source MQTT broker.
#     Think of it like a post office for sensor data.
#
#   Topic:
#     A string that describes what a message is about, using / as a separator.
#     Examples: "building/floor2/ahu-01/supply_temp"
#               "sensors/room301/co2"
#               "energy/panel-a/phase1/watts"
#     Consumers subscribe to topics using wildcards:
#       +  matches one level:  "building/+/ahu-01/supply_temp"
#       #  matches all levels: "building/#"
#
#   Publisher (device side):
#     The sensor/device that sends data to the broker on a topic.
#
#   Subscriber (our side):
#     We subscribe to topic patterns and receive all matching messages.
#
# HOW THIS FILE WORKS:
#   1. Connect to an MQTT broker (e.g. Mosquitto on your network)
#   2. Subscribe to a topic pattern (e.g. "building/#" = all building topics)
#   3. When a message arrives on any matching topic, on_message() is called
#   4. We parse the topic to extract device_id and point_name
#   5. We normalize the data and publish to RabbitMQ
#
# TOPIC PARSING CONVENTION:
# We expect topics in the format: <anything>/<device_id>/<point_name>
# The last segment = point_name, the second-to-last = device_id
# Example: "building/ahu-01/supply_temp"
#           → device_id  = "ahu-01"
#           → point_name = "supply_temp"
#
# THREADING NOTE:
# paho-mqtt is NOT an async library. It uses its own internal thread
# to receive messages. This means we cannot use async/await here.
# In main.py, this function is started in a separate Python thread
# using Thread(target=run_mqtt_gateway, ...).start()
#
# CONFIGURATION:
# Set these environment variables in your .env file:
#   MQTT_BROKER  = IP of your MQTT broker, e.g. "192.168.30.50"
#   MQTT_PORT    = Port (default 1883)
#   MQTT_TOPIC   = Topic pattern to subscribe to (default "building/#")
#   MQTT_USER    = Username if broker requires auth (optional)
#   MQTT_PASS    = Password if broker requires auth (optional)
#
# =============================================================================

import logging          # For writing log messages
import os               # For reading environment variables
import json             # For parsing JSON payloads from MQTT messages
import paho.mqtt.client as mqtt     # The MQTT client library

from gateway.normalizer import normalize    # Standard message format converter
from gateway.publisher  import Publisher    # RabbitMQ message sender

logger = logging.getLogger(__name__)


def run_mqtt_gateway(publisher: Publisher):
    """
    Connects to an MQTT broker, subscribes to configured topics,
    and forwards all received messages to RabbitMQ.

    This function blocks forever (loop_forever() never returns).
    It is designed to run in its own thread, started from main.py.
    """

    # Read configuration from environment variables
    broker   = os.environ.get("MQTT_BROKER",  "localhost")
    port     = int(os.environ.get("MQTT_PORT", "1883"))
    topic    = os.environ.get("MQTT_TOPIC",    "building/#")  # Subscribe to all building topics
    username = os.environ.get("MQTT_USER",     "")            # Empty = no auth required
    password = os.environ.get("MQTT_PASS",     "")

    # Safety check - if no broker is configured, don't try to connect
    if not broker or broker == "localhost":
        logger.info("No MQTT broker configured. Set MQTT_BROKER environment variable to enable.")
        return


    # -------------------------------------------------------------------------
    # CALLBACK FUNCTIONS
    # paho-mqtt works by defining callback functions that get called automatically
    # when certain events happen (connected, message received, disconnected, etc.)
    # We define them here and attach them to the client below.
    # -------------------------------------------------------------------------

    def on_connect(client, userdata, flags, rc):
        """
        Called automatically by paho-mqtt when a connection attempt completes.

        Parameters:
            client   - The MQTT client object
            userdata - Custom data we passed in (not used here)
            flags    - Connection flags from broker (not used here)
            rc       - Result code: 0 = success, anything else = error
        """
        if rc == 0:
            # Connection successful - now subscribe to our topic pattern
            logger.info(f"Connected to MQTT broker at {broker}:{port}")
            client.subscribe(topic)
            logger.info(f"Subscribed to MQTT topic pattern: '{topic}'")
        else:
            # Connection failed - rc codes:
            #   1 = wrong protocol version
            #   2 = invalid client ID
            #   3 = broker unavailable
            #   4 = bad username or password
            #   5 = not authorised
            logger.error(f"MQTT connection failed. Result code: {rc}")


    def on_message(client, userdata, msg):
        """
        Called automatically by paho-mqtt when a message arrives on a subscribed topic.

        Parameters:
            client   - The MQTT client object
            userdata - Custom data we passed in (not used here)
            msg      - The message object, with .topic and .payload attributes
        """
        try:
            # --- Parse the topic to get device_id and point_name ---
            # Topic format expected: <prefix>/<device_id>/<point_name>
            # We split on "/" and take the last two segments
            # e.g. "building/floor2/ahu-01/supply_temp".split("/")
            #       = ["building", "floor2", "ahu-01", "supply_temp"]
            #       parts[-1] = "supply_temp"   (last item)
            #       parts[-2] = "ahu-01"         (second to last)
            parts      = msg.topic.split("/")
            point_name = parts[-1] if len(parts) >= 1 else "unknown"
            device_id  = parts[-2] if len(parts) >= 2 else "unknown"

            # --- Parse the payload (message body) ---
            # MQTT payloads are raw bytes. We decode to a string first,
            # then try to parse as JSON (many IoT devices send JSON).
            # If it's not valid JSON, we treat the whole payload as a plain string value.
            try:
                # msg.payload is bytes — .decode() converts to a string
                # json.loads() converts the JSON string to a Python dict
                payload = json.loads(msg.payload.decode())

                # If the JSON has a "value" key, use that as the value
                # Otherwise use the whole parsed JSON object as the value
                # This handles both:
                #   {"value": 21.5, "unit": "degC"}  → value = 21.5, unit = "degC"
                #   {"temp": 21.5}                   → value = {"temp": 21.5}
                value = payload.get("value", payload)
                unit  = payload.get("unit", "")

            except (json.JSONDecodeError, UnicodeDecodeError):
                # Not valid JSON - treat the whole payload as a plain string
                # e.g. payload = b"21.5" → value = "21.5"
                value = msg.payload.decode()
                unit  = ""

            # --- Normalize and publish to RabbitMQ ---
            message = normalize(
                protocol   = "mqtt",
                device_id  = f"mqtt:{device_id}",
                point_name = point_name,
                value      = value,
                unit       = unit,
                metadata   = {
                    "topic": msg.topic,     # Full original MQTT topic for reference
                    "qos":   msg.qos        # Quality of service level (0, 1, or 2)
                                            # 0 = fire and forget
                                            # 1 = at least once delivery
                                            # 2 = exactly once delivery
                }
            )
            publisher.publish(message, "mqtt", point_name)

        except Exception as e:
            # Log the error but don't crash - we want to keep receiving messages
            logger.warning(f"Failed to process MQTT message on topic '{msg.topic}': {e}")


    # -------------------------------------------------------------------------
    # CREATE AND CONFIGURE THE MQTT CLIENT
    # -------------------------------------------------------------------------

    # Create a new MQTT client instance
    # mqtt.Client() is the main paho-mqtt class
    client = mqtt.Client()

    # Set authentication credentials if provided
    if username:
        client.username_pw_set(username, password)

    # Attach our callback functions to the client
    # These will be called automatically when the corresponding events occur
    client.on_connect = on_connect      # Called when connection completes
    client.on_message = on_message      # Called when a message arrives

    # Connect to the MQTT broker
    # keepalive=60 means send a ping every 60 seconds to keep the connection alive
    client.connect(broker, port, keepalive=60)

    # Start the blocking network loop
    # loop_forever() runs until the connection is broken or client.disconnect() is called
    # It handles reconnection automatically if the connection drops
    # Since this blocks, it must run in its own thread (handled in main.py)
    logger.info("MQTT client starting loop...")
    client.loop_forever()
