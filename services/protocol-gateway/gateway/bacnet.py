# =============================================================================
# bacnet.py  (BACnet Protocol Handler)
# =============================================================================
#
# BAC0 2025.x API notes:
#   - BAC0.lite() is the only startup method (lite/complete are merged)
#   - Discovery: await bacnet.who_is()  ← async, must be awaited
#   - bacnet.discover(global_broadcast=True) ← async background scan
#   - bacnet.devices  ← dict of discovered devices after who_is
#   - BAC0.device()   ← connect to a specific device and read its points
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

    # BAC0.lite() is the unified startup in 2025.x
    # It auto-detects the network interface from the system
    bacnet = BAC0.lite(deviceId=device_id)

    # Wait for BAC0 to fully initialize before sending any requests
    await asyncio.sleep(5)
    logger.info("BAC0 initialized. Beginning network scan loop.")

    # Cache connected device objects so we only call BAC0.device() once per device
    known_devices = {}

    while True:
        try:
            logger.info("Scanning BACnet network for devices...")

            # who_is() is async in BAC0 2025.x — must be awaited
            # No arguments = global broadcast to all devices on the subnet
            # Returns a list of IAm response objects
            iams = await bacnet.who_is()

            await asyncio.sleep(2)

            if not iams:
                logger.warning("No BACnet devices responded to WhoIs. Check network/VLAN.")
            else:
                logger.info(f"WhoIs got {len(iams)} response(s): {iams}")

            # bacnet.devices is populated after who_is()
            # It is a dict: { device_id: (address, device_id) }
            devices = bacnet.devices
            if not devices:
                logger.warning("bacnet.devices is empty after WhoIs.")
            else:
                logger.info(f"Found {len(devices)} device(s) in bacnet.devices")

            for dev_entry in devices:
                try:
                    # dev_entry format depends on BAC0 version
                    # Could be (address, id) tuple or just an id — handle both
                    if isinstance(dev_entry, tuple):
                        device_address, device_id_found = dev_entry
                    else:
                        device_id_found = dev_entry
                        device_address  = devices[dev_entry] if isinstance(devices, dict) else None

                    if device_id_found not in known_devices:
                        logger.info(f"Connecting to device {device_id_found} at {device_address}")
                        dev = BAC0.device(device_address, device_id_found, bacnet)
                        await asyncio.sleep(2)
                        known_devices[device_id_found] = dev
                        logger.info(f"Device {device_id_found}: {len(dev.points)} points discovered")
                    else:
                        dev = known_devices[device_id_found]

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
                                    "address":     str(device_address),
                                    "object_type": str(point.properties.type),
                                    "instance":    point.properties.address
                                }
                            )
                            publisher.publish(message, "bacnet", point_name)

                        except Exception as e:
                            logger.warning(f"  Point read failed '{point}' on {device_id_found}: {e}")

                except Exception as e:
                    logger.warning(f"Device entry {dev_entry} failed: {e}")
                    if isinstance(dev_entry, tuple):
                        known_devices.pop(dev_entry[1], None)
                    else:
                        known_devices.pop(dev_entry, None)

        except Exception as e:
            logger.error(f"BACnet scan error: {e}", exc_info=True)

        logger.info(f"Scan complete. Next scan in {POLL_INTERVAL}s.")
        await asyncio.sleep(POLL_INTERVAL)
