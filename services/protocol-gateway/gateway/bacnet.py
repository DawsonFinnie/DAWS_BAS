# =============================================================================
# bacnet.py  (BACnet Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file discovers BACnet devices on your network, reads their points,
# and publishes the values to RabbitMQ via the Publisher.
#
# WHAT IS BACNET?
# BACnet (Building Automation and Control Networks) is the standard protocol
# used in building automation. HVAC controllers, lighting systems, energy
# meters, and sensors all commonly speak BACnet.
#
# Your traffic light simulator is a BACnet device. This gateway would
# discover it automatically and start publishing its four binary values
# (red_light, yellow_light, green_light, running) to RabbitMQ.
#
# HOW BACNET DISCOVERY WORKS:
#   1. The gateway broadcasts a "WhoIs" packet to the network
#      (like shouting "Is anyone there?" to the whole building network)
#   2. Every BACnet device on the network responds with an "IAm" packet
#      (like each device saying "Yes, I'm here, my ID is 3001")
#   3. For each device found, we connect and read its object list
#      (a list of all its data points)
#   4. For each object/point, we read the presentValue (the current reading)
#   5. We normalize and publish each value to RabbitMQ
#   6. We wait POLL_INTERVAL seconds, then do it all again
#
# NOTE: This is a polling approach (we ask devices for their values).
# The traffic light simulator also supports COV (Change of Value) which
# is a push approach (devices tell us when values change). Adding COV
# subscription support to this gateway would be a future improvement.
#
# HOW IT FITS IN THE SYSTEM:
#   main.py calls run_bacnet_gateway(publisher)
#       BAC0 sends WhoIs broadcast → devices respond with IAm
#           For each device → read all points → normalize() → publish()
#               RabbitMQ receives messages with routing key "point.bacnet.<name>"
#                   Telegraf picks them up → writes to InfluxDB
#
# =============================================================================

import asyncio      # For async/await - BAC0 requires an asyncio event loop
import logging      # For writing log messages
import os           # For reading environment variables
import BAC0         # The BACnet library that handles all BACnet communication

# Import our helper functions from other files in this package
from gateway.normalizer import normalize    # Converts raw data to standard format
from gateway.publisher  import Publisher    # Sends messages to RabbitMQ

# Get a logger for this module
logger = logging.getLogger(__name__)

# How many seconds to wait between full network scans.
# 30 seconds means every device gets polled every 30 seconds.
# Read from environment variable so it can be changed without editing code.
# Defaults to 30 if not set.
POLL_INTERVAL = int(os.environ.get("GATEWAY_POLL_INTERVAL", 30))


async def run_bacnet_gateway(publisher: Publisher):
    """
    Main BACnet gateway loop. Runs forever.

    1. Initializes a BAC0 BACnet client on the network
    2. Sends WhoIs to discover all devices
    3. Reads all points from each device
    4. Publishes each value to RabbitMQ
    5. Waits POLL_INTERVAL seconds
    6. Repeats from step 2
    """

    # Read network configuration from environment variables
    # BACNET_NETWORK tells BAC0 which network interface to use for broadcasts
    # e.g. "192.168.30.0/24" means use the interface on the 192.168.30.x subnet
    network   = os.environ.get("BACNET_NETWORK", "192.168.30.0/24")

    # BACNET_DEVICE_ID is the BACnet device ID for THIS gateway itself
    # Every BACnet device on a network needs a unique ID
    # We use 9001 to avoid conflicting with the traffic light (3001)
    device_id = int(os.environ.get("BACNET_DEVICE_ID", 9001))

    logger.info(f"Starting BACnet gateway | Network: {network} | Device ID: {device_id}")

    # Initialize BAC0 as a "lite" client
    # BAC0.lite() creates a minimal BACnet device that can send/receive on the network
    # Unlike the traffic light which uses BAC0 as a SERVER (serving data),
    # here we use it as a CLIENT (reading data from other devices)
    bacnet = BAC0.lite(deviceId=device_id)

    # Wait 2 seconds for BAC0 to fully initialize before we start using it
    # This is the same delay we use in the traffic light simulator
    # Without this, BAC0 may not be ready to send WhoIs broadcasts yet
    await asyncio.sleep(2)

    logger.info("BAC0 initialized. Beginning network scan loop.")

    # Main loop - runs forever, scanning and publishing
    while True:
        try:
            logger.info("Scanning BACnet network for devices...")

            # Send a WhoIs broadcast to the entire network
            # All BACnet devices should respond with an IAm packet
            # BAC0 automatically collects the responses
            bacnet.whois()

            # Wait 3 seconds for all devices to respond to the WhoIs
            # Devices on slow networks or far away may take a moment to reply
            await asyncio.sleep(3)

            # bacnet.devices is a list of tuples: [(address, device_id), ...]
            # Each entry represents one BACnet device that responded to WhoIs
            if not bacnet.devices:
                logger.warning("No BACnet devices found on network. Is the network correct?")
            else:
                logger.info(f"Found {len(bacnet.devices)} BACnet device(s)")

            # Loop through each discovered device
            for device_address, device_id_found in bacnet.devices:
                try:
                    logger.info(f"Reading device {device_id_found} at {device_address}")

                    # Connect to the device and load its object/point list
                    # BAC0.device() reads the device's object list and creates
                    # Python objects for each BACnet point
                    device = BAC0.device(device_address, device_id_found, bacnet)

                    # Give BAC0 a moment to read the device's object list
                    await asyncio.sleep(1)

                    # device.points is a list of all data points on this device
                    # Each point has properties like name, lastValue, units_state
                    for point in device.points:
                        try:
                            # Read the last known value for this point
                            value = point.lastValue

                            # Get the human-readable name of this point
                            # e.g. "red_light", "supply_temp", "zone_co2"
                            point_name = point.properties.name

                            # Get the engineering unit if available
                            # e.g. "degC", "Pa", "%RH", "active"
                            # Not all points have units (binary values often don't)
                            unit = str(point.properties.units_state) \
                                if hasattr(point.properties, 'units_state') else ""

                            # Normalize the raw data into our standard format
                            message = normalize(
                                protocol   = "bacnet",
                                device_id  = f"bacnet:{device_id_found}",
                                point_name = point_name,
                                value      = str(value),
                                unit       = unit,
                                metadata   = {
                                    # Store extra BACnet-specific info for traceability
                                    "address":     device_address,      # e.g. "192.168.30.12"
                                    "object_type": str(point.properties.type),  # e.g. "binaryValue"
                                    "instance":    point.properties.address     # e.g. 1, 2, 3, 4
                                }
                            )

                            # Publish the normalized message to RabbitMQ
                            # Routing key will be: "point.bacnet.red_light" etc.
                            publisher.publish(message, "bacnet", point_name)

                        except Exception as e:
                            # If one point fails, log it but keep reading other points
                            # We don't want one bad point to stop the whole device scan
                            logger.warning(f"Failed to read point '{point}' on device {device_id_found}: {e}")

                except Exception as e:
                    # If one device fails, log it but keep scanning other devices
                    logger.warning(f"Failed to read device {device_id_found} at {device_address}: {e}")

        except Exception as e:
            # If the whole scan fails (e.g. network error), log and continue
            # The loop will try again after POLL_INTERVAL seconds
            logger.error(f"BACnet scan error: {e}")

        # Wait before the next full scan
        # await asyncio.sleep() pauses THIS task but lets other async tasks run
        # (like Modbus or OPC-UA handlers that are also running concurrently)
        logger.info(f"BACnet scan complete. Next scan in {POLL_INTERVAL} seconds.")
        await asyncio.sleep(POLL_INTERVAL)
