# =============================================================================
# bacnet.py  (BACnet Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file discovers BACnet devices on your network, reads their points,
# and publishes the values to RabbitMQ via the Publisher.
#
# BAC0 VERSION NOTE — important:
# BAC0 2025.x has two modes:
#   BAC0.lite()    → used for SERVING BACnet objects (like the traffic light)
#   BAC0.connect() → used for READING from other devices on the network
#
# The traffic light uses BAC0.lite() because it IS a BACnet device.
# This gateway uses BAC0.connect() because it READS from other devices.
# The .whois() method only exists on BAC0.connect(), not BAC0.lite().
# This was the bug: we were calling whois() on a lite() object.
#
# HOW BACNET DISCOVERY WORKS:
#   1. bacnet = BAC0.connect()  — create a network client
#   2. bacnet.whois()           — broadcast "who is out there?"
#   3. Every device replies with IAm — "I am device 3001 at 192.168.30.12"
#   4. BAC0.device() connects to each and reads its full object/point list
#   5. We read presentValue for each point, normalize, publish to RabbitMQ
#   6. Wait POLL_INTERVAL seconds, repeat
#
# =============================================================================

import asyncio
import logging
import os
import BAC0

from gateway.normalizer import normalize
from gateway.publisher  import Publisher

logger = logging.getLogger(__name__)

POLL_INTERVAL = int(os.environ.get("GATEWAY_POLL_INTERVAL", 30))


async def run_bacnet_gateway(publisher: Publisher):
    """
    Main BACnet gateway loop. Runs forever.
    Discovers all BACnet devices on the network and publishes their
    point values to RabbitMQ every POLL_INTERVAL seconds.
    """

    device_id = int(os.environ.get("BACNET_DEVICE_ID", 9001))

    logger.info(f"Starting BACnet gateway | Device ID: {device_id}")

    # BAC0.connect() — the network scanning client
    # This is NOT the same as BAC0.lite() used in the traffic light.
    # connect() creates a BACnet client that can discover and read other devices.
    bacnet = BAC0.connect(deviceId=device_id)

    # Wait for BAC0 to fully initialize
    await asyncio.sleep(5)

    logger.info("BAC0 initialized. Beginning network scan loop.")

    # Cache discovered device objects so we don't reconnect on every poll
    # Key: device_id (int), Value: BAC0 device object
    known_devices = {}

    while True:
        try:
            logger.info("Scanning BACnet network for devices...")

            # whois() broadcasts a WhoIs packet to the entire BACnet network
            # Returns a list of (address, device_id) tuples — one per responding device
            # Empty call = global broadcast (no address or ID range filter)
            responses = bacnet.whois()

            # Give devices time to respond before we start reading
            await asyncio.sleep(3)

            if not responses:
                logger.warning("No BACnet devices responded to WhoIs. Check network/VLAN.")
            else:
                logger.info(f"Found {len(responses)} BACnet device(s): {responses}")

            for device_address, device_id_found in (responses or []):
                try:
                    # Connect to new devices and cache them
                    # BAC0.device() reads the full object list — only do this once per device
                    if device_id_found not in known_devices:
                        logger.info(f"Connecting to new device {device_id_found} at {device_address}")
                        dev = BAC0.device(device_address, device_id_found, bacnet)
                        await asyncio.sleep(2)
                        known_devices[device_id_found] = dev
                        logger.info(f"Device {device_id_found}: {len(dev.points)} points discovered")
                    else:
                        dev = known_devices[device_id_found]

                    # Read and publish every point on this device
                    for point in dev.points:
                        try:
                            value      = point.lastValue
                            point_name = point.properties.name
                            unit       = str(point.properties.units_state) \
                                         if hasattr(point.properties, "units_state") else ""

                            message = normalize(
                                protocol   = "bacnet",
                                device_id  = f"bacnet:{device_id_found}",
                                point_name = point_name,
                                value      = str(value),
                                unit       = unit,
                                metadata   = {
                                    "address":     device_address,
                                    "object_type": str(point.properties.type),
                                    "instance":    point.properties.address
                                }
                            )
                            publisher.publish(message, "bacnet", point_name)

                        except Exception as e:
                            logger.warning(f"  Point read failed '{point}' on {device_id_found}: {e}")

                except Exception as e:
                    logger.warning(f"Device {device_id_found} at {device_address} failed: {e}")
                    known_devices.pop(device_id_found, None)

        except Exception as e:
            logger.error(f"BACnet scan error: {e}")

        logger.info(f"BACnet scan complete. Next scan in {POLL_INTERVAL} seconds.")
        await asyncio.sleep(POLL_INTERVAL)
