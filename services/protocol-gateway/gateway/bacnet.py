# =============================================================================
# bacnet.py  (BACnet Protocol Handler)
# =============================================================================
#
# BAC0 2025.x API notes:
#   - BAC0.lite()            → synchronous init
#   - await bacnet.who_is()  → returns list of IAmRequest PDU objects
#   - await BAC0.device()    → connects to a device (must be awaited)
#   - dev.points             → list of point objects
#   - point.lastValue        → may raise AttributeError if pandas not installed
#   - point._history.value   → raw list, use [-1] for latest value
#   - bacnet.write()         → WriteProperty (synchronous in BAC0 2025.x)
#
# WRITE COMMAND FORMAT (from daws.bas.commands exchange):
# {
#   "device_id":  "bacnet:1",
#   "point_name": "ZN-SP",
#   "value":      "74.0",
#   "priority":   8           # optional, defaults to 8
# }
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


def _clean_unit(raw) -> str:
    """
    Convert BAC0 units_state to a clean string.
    Filters out ErrorType objects and other garbage that BAC0 returns
    for binary points that have no meaningful engineering unit.
    """
    s = str(raw)
    # Discard Python object reprs like <bacpypes3.primitivedata.ErrorType ...>
    if s.startswith("<") or "ErrorType" in s or "object at 0x" in s:
        return ""
    return s


async def run_bacnet_gateway(publisher: Publisher,
                              command_queue: asyncio.Queue = None):
    """
    Main BACnet gateway loop. Runs forever.
    Discovers BACnet devices via WhoIs/IAm, reads their points, and
    publishes normalized JSON to RabbitMQ.

    Also drains command_queue for write requests (if provided).
    """

    device_id = int(os.environ.get("BACNET_DEVICE_ID", 9001))
    logger.info(f"Starting BACnet gateway | Device ID: {device_id}")

    bacnet = BAC0.lite(deviceId=device_id)
    await asyncio.sleep(5)
    logger.info("BAC0 initialized. Beginning network scan loop.")

    # Cache connected BAC0.device() objects — connecting is expensive
    # Key: device_id (int), Value: BAC0 device object
    known_devices = {}

    # Build a reverse map: "bacnet:<id>" → device object (for write routing)
    def _device_by_label(label: str):
        """Return cached device for 'bacnet:<id>' label, or None."""
        try:
            dev_id = int(label.split(":")[1])
            return known_devices.get(dev_id)
        except Exception:
            return None

    while True:
        # --- Drain any pending write commands first ---
        if command_queue:
            while not command_queue.empty():
                cmd = command_queue.get_nowait()
                await _execute_write(bacnet, known_devices, publisher, cmd)

        try:
            logger.info("Scanning BACnet network for devices...")

            iams = await bacnet.who_is()
            await asyncio.sleep(2)

            if not iams:
                logger.warning("No BACnet devices responded to WhoIs.")
                logger.info(f"Scan complete. Next scan in {POLL_INTERVAL}s.")
                await asyncio.sleep(POLL_INTERVAL)
                continue

            logger.info(f"WhoIs got {len(iams)} response(s)")

            for iam in iams:
                try:
                    device_id_found = int(iam.iAmDeviceIdentifier[1])
                    device_address  = str(iam.pduSource)

                    logger.info(f"  IAm from device {device_id_found} at {device_address}")

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

                            unit = _clean_unit(
                                point.properties.units_state
                                if hasattr(point.properties, "units_state") else ""
                            )

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
                            publisher.publish(
                                message,
                                protocol  = "bacnet",
                                point_name = point_name,
                                address   = device_address,   # e.g. "192.168.30.54" or "2501:4"
                                device_id = f"bacnet:{device_id_found}"  # e.g. "bacnet:539035"
                                # Together these guarantee a unique routing key:
                                # point.bacnet.192_168_30_54.bacnet_539035.ZN-T
                                # even if two devices share device IDs or point names
                            )
                            point_count += 1

                        except Exception as e:
                            logger.warning(f"    Point read failed '{point}': {e}")

                    logger.info(f"  Published {point_count} points from device {device_id_found}")

                except Exception as e:
                    logger.warning(f"Failed processing IAm response: {e}", exc_info=True)
                    if 'device_id_found' in dir():
                        known_devices.pop(device_id_found, None)

        except Exception as e:
            logger.error(f"BACnet scan error: {e}", exc_info=True)

        logger.info(f"Scan complete. Next scan in {POLL_INTERVAL}s.")
        await asyncio.sleep(POLL_INTERVAL)


async def _execute_write(bacnet, known_devices: dict,
                          publisher: Publisher, cmd: dict):
    """
    Execute a BACnet WriteProperty command from the command queue.

    cmd format:
      {"device_id": "bacnet:1", "point_name": "ZN-SP",
       "value": "74.0", "priority": 8}

    BAC0 write syntax:
      bacnet.write('<address> <objectType> <instance> presentValue <value> - <priority>')
    """
    device_label = cmd.get("device_id", "")
    point_name   = cmd.get("point_name", "")
    value        = cmd.get("value", "")
    priority     = int(cmd.get("priority", 8))

    status  = "error"
    message = "Unknown error"

    try:
        dev_id_int = int(device_label.split(":")[1])
        dev = known_devices.get(dev_id_int)

        if dev is None:
            raise ValueError(f"Device {device_label} not in known_devices — not yet discovered")

        # Find the point object by name
        target_point = None
        for p in dev.points:
            if p is not None and hasattr(p, 'properties') and p.properties.name == point_name:
                target_point = p
                break

        if target_point is None:
            raise ValueError(f"Point '{point_name}' not found on device {device_label}")

        obj_type = str(target_point.properties.type)
        instance = target_point.properties.address
        address  = str(dev.properties.address)

        # BAC0 write string format:
        # '<address> <objectType> <instance> presentValue <value> - <priority>'
        write_str = f"{address} {obj_type} {instance} presentValue {value} - {priority}"
        logger.info(f"Writing: {write_str}")

        bacnet.write(write_str)

        status  = "ok"
        message = f"WriteProperty OK: {point_name} = {value} @ priority {priority}"
        logger.info(f"Write success: {message}")

    except Exception as e:
        message = str(e)
        logger.error(f"Write failed for {device_label}.{point_name}: {e}")

    # Publish confirmation back to daws.bas exchange
    confirm = {
        "status":     status,
        "device_id":  device_label,
        "point_name": point_name,
        "value":      value,
        "priority":   priority,
        "message":    message
    }

    try:
        publisher.publish(
            confirm,
            protocol   = "command",
            point_name = f"confirm.{device_label}.{point_name}",
            # No address/device_id on confirmations — they use the
            # fallback format: point.command.confirm.<device_label>.<point_name>
            # This keeps confirmation routing keys short and predictable
            # for Node-RED and future UI subscribers
        )
    except Exception as e:
        logger.error(f"Failed to publish write confirmation: {e}")
