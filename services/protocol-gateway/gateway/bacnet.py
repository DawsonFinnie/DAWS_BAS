# =============================================================================
# bacnet.py  (BACnet Protocol Handler)
# =============================================================================
#
# BAC0 2025.x API:
#   - await bacnet.who_is()  → returns list of IAmRequest PDU objects
#   - await bacnet.devices   → coroutine, returns discovered device list
#   - Each IAm PDU has:
#       .iAmDeviceIdentifier  → ('device', 3001)
#       .pduSource            → address string e.g. "192.168.30.12"
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
    Discovers BACnet devices via WhoIs/IAm, reads their points,
    and publishes normalized JSON to RabbitMQ.
    """

    device_id = int(os.environ.get("BACNET_DEVICE_ID", 9001))
    logger.info(f"Starting BACnet gateway | Device ID: {device_id}")

    bacnet = BAC0.lite(deviceId=device_id)
    await asyncio.sleep(5)
    logger.info("BAC0 initialized. Beginning network scan loop.")

    # Cache connected BAC0.device() objects — connecting is expensive
    # Key: device_id (int), Value: BAC0 device object
    known_devices = {}

    while True:
        try:
            logger.info("Scanning BACnet network for devices...")

            # who_is() returns a list of IAmRequest PDU objects
            # Each PDU has .iAmDeviceIdentifier and .pduSource
            iams = await bacnet.who_is()
            await asyncio.sleep(2)

            if not iams:
                logger.warning("No BACnet devices responded to WhoIs.")
                logger.info(f"Scan complete. Next scan in {POLL_INTERVAL}s.")
                await asyncio.sleep(POLL_INTERVAL)
                continue

            logger.info(f"WhoIs got {len(iams)} response(s)")

            # Parse each IAm response to get address and device ID
            for iam in iams:
                try:
                    # iAmDeviceIdentifier is a tuple: ('device', <id>)
                    device_id_found = int(iam.iAmDeviceIdentifier[1])
                    # pduSource is the address — convert to string
                    device_address  = str(iam.pduSource)

                    logger.info(f"  IAm from device {device_id_found} at {device_address}")

                    # Connect to device if first time seeing it
                    if device_id_found not in known_devices:
                        logger.info(f"  Connecting to new device {device_id_found}...")
                        dev = await BAC0.device(device_address, device_id_found, bacnet)
                        await asyncio.sleep(2)
                        known_devices[device_id_found] = dev
                        logger.info(f"  Device {device_id_found}: {len(dev.points)} points discovered")
                    else:
                        dev = known_devices[device_id_found]

                    # Read and publish all points
                    point_count = 0
                    for point in dev.points:
                        try:
                            if point is None or not hasattr(point, 'properties'):
                                continue
                            point_name = point.properties.name

                            # BAC0 2025.x: _history.value may be a list not pandas Series
                            try:
                                value = point.lastValue
                            except (AttributeError, TypeError):
                                hist = point._history.value
                                value = hist[-1] if hist else None

                            if value is None:
                                continue

                            unit = str(point.properties.units_state) \
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
                            point_count += 1

                        except Exception as e:
                            logger.warning(f"    Point read failed '{point}': {e}")

                    logger.info(f"  Published {point_count} points from device {device_id_found}")

                except Exception as e:
                    logger.warning(f"Failed processing IAm response: {e}", exc_info=True)
                    # Remove from cache to force reconnect next scan
                    if 'device_id_found' in dir():
                        known_devices.pop(device_id_found, None)

        except Exception as e:
            logger.error(f"BACnet scan error: {e}", exc_info=True)

        logger.info(f"Scan complete. Next scan in {POLL_INTERVAL}s.")
        await asyncio.sleep(POLL_INTERVAL)
