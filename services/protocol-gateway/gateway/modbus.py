# =============================================================================
# modbus.py  (Modbus Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file polls Modbus TCP devices on the network and publishes their
# register values to RabbitMQ via the Publisher.
#
# WHAT IS MODBUS?
# Modbus is one of the oldest industrial communication protocols (1979).
# It is extremely simple and widely used in:
#   - Chillers and boilers
#   - Variable frequency drives (VFDs)
#   - Energy meters and power monitors
#   - Some older HVAC equipment
#
# Unlike BACnet (which has self-describing objects with names), Modbus
# is just numbered memory registers with no built-in names or units.
# You must have the device's "register map" document to know what
# register 100 means (e.g. "supply water temperature in 0.1°C units").
#
# MODBUS REGISTER TYPES:
#   Coil             (type "coil")     - Single bit, read/write. On/off values.
#   Discrete Input   (type "discrete") - Single bit, read only. Sensor states.
#   Input Register   (type "input")    - 16-bit integer, read only. Sensor values.
#   Holding Register (type "holding")  - 16-bit integer, read/write. Most common.
#                                        Setpoints, config, and sensor values.
#
# HOW MODBUS WORKS:
#   - There is NO automatic discovery. You must know device IPs in advance.
#   - You poll each device by sending "read register" requests over TCP
#   - The device responds with the raw value
#   - You apply any scaling (e.g. divide by 10 for temperature)
#
# CONFIGURATION:
# Devices are configured via the MODBUS_DEVICES environment variable as JSON.
# Example (set in your .env file or docker-compose.yml):
#
#   MODBUS_DEVICES=[
#     {
#       "id": "chiller-01",
#       "host": "192.168.30.50",
#       "port": 502,
#       "unit_id": 1,
#       "registers": [
#         {"type": "holding", "address": 100, "name": "supply_temp",  "unit": "degC", "scale": 0.1},
#         {"type": "holding", "address": 101, "name": "return_temp",  "unit": "degC", "scale": 0.1},
#         {"type": "coil",    "address": 0,   "name": "running",      "unit": ""},
#         {"type": "holding", "address": 200, "name": "fault_code",   "unit": ""}
#       ]
#     }
#   ]
#
# HOW IT FITS IN THE SYSTEM:
#   main.py calls run_modbus_gateway(publisher) if MODBUS_DEVICES is set
#       For each device in the config → open TCP connection
#           For each register → read value → apply scale → normalize() → publish()
#               RabbitMQ receives "point.modbus.supply_temp" etc.
#
# =============================================================================

import asyncio      # For async/await and concurrent operation
import logging      # For writing log messages
import os           # For reading environment variables
import json         # For parsing the MODBUS_DEVICES JSON string

# AsyncModbusTcpClient is the async version of the Modbus TCP client
# It can be used with Python's async/await syntax
from pymodbus.client import AsyncModbusTcpClient

from gateway.normalizer import normalize    # Standard message format converter
from gateway.publisher  import Publisher    # RabbitMQ message sender

logger = logging.getLogger(__name__)

POLL_INTERVAL = int(os.environ.get("GATEWAY_POLL_INTERVAL", 30))


async def poll_device(client, device_config: dict, publisher: Publisher):
    """
    Reads all configured registers from one Modbus device and publishes values.

    Parameters:
        client        - An open AsyncModbusTcpClient connection to the device
        device_config - Dict with device settings from MODBUS_DEVICES config
        publisher     - The RabbitMQ publisher to send messages through
    """

    # Unique identifier for this device (from config)
    device_id = device_config["id"]

    # Modbus unit/slave ID - some devices have multiple sub-devices on one IP
    # Default is 1 which works for most standalone devices
    unit_id = device_config.get("unit_id", 1)

    # Loop through each register defined in this device's config
    for register in device_config.get("registers", []):
        try:
            # Pull register settings from the config dict
            reg_type   = register["type"]           # "holding", "input", or "coil"
            address    = register["address"]         # Register number (from device manual)
            point_name = register["name"]            # Human-readable name we assign
            unit       = register.get("unit", "")   # Engineering unit (from device manual)
            scale      = register.get("scale", 1)   # Scaling factor (from device manual)
                                                     # e.g. 0.1 means divide raw value by 10

            # Read the register based on its type
            # Each type uses a different Modbus function code internally
            if reg_type == "holding":
                # Holding registers: most common, 16-bit integers, read/write
                # count=1 means read 1 register (some values span 2 registers for 32-bit)
                # slave=unit_id identifies which sub-device on this connection
                result = await client.read_holding_registers(address, count=1, slave=unit_id)
                value  = result.registers[0] * scale    # Apply scaling factor

            elif reg_type == "input":
                # Input registers: read-only sensor values, 16-bit integers
                result = await client.read_input_registers(address, count=1, slave=unit_id)
                value  = result.registers[0] * scale

            elif reg_type == "coil":
                # Coils: single bit values (on/off, true/false)
                # No scaling needed - the value is already a boolean
                result = await client.read_coils(address, count=1, slave=unit_id)
                value  = result.bits[0]     # True or False

            else:
                logger.warning(f"Unknown register type '{reg_type}' for {point_name} - skipping")
                continue    # Skip this register and move to the next one

            # Normalize the raw Modbus value into our standard message format
            message = normalize(
                protocol   = "modbus",
                device_id  = f"modbus:{device_id}",
                point_name = point_name,
                value      = value,
                unit       = unit,
                metadata   = {
                    # Store Modbus-specific details for traceability and debugging
                    "register_type":    reg_type,
                    "register_address": address,
                    "unit_id":          unit_id,
                    "scale":            scale
                }
            )

            # Publish to RabbitMQ
            # Routing key: "point.modbus.supply_temp" etc.
            publisher.publish(message, "modbus", point_name)

        except Exception as e:
            # If one register fails (device offline, wrong address, etc.)
            # log it and continue to the next register
            logger.warning(f"Failed to read Modbus register {register.get('name', register)}: {e}")


async def run_modbus_gateway(publisher: Publisher):
    """
    Main Modbus gateway loop. Runs forever.

    Reads the device list from the MODBUS_DEVICES environment variable,
    then polls each device on every POLL_INTERVAL cycle.
    """

    # Read the device configuration from environment variable
    # os.environ.get() returns the string value or "[]" (empty JSON array) if not set
    devices_json = os.environ.get("MODBUS_DEVICES", "[]")

    # json.loads() converts the JSON string into a Python list of dicts
    # e.g. '[{"id": "chiller-01", ...}]' → [{"id": "chiller-01", ...}]
    devices = json.loads(devices_json)

    # If no devices are configured, exit the function
    if not devices:
        logger.info("No Modbus devices configured. Set MODBUS_DEVICES environment variable to enable.")
        return  # Return exits this function - it won't run the loop below

    logger.info(f"Starting Modbus gateway for {len(devices)} device(s)")

    # Main poll loop - runs forever
    while True:
        # Poll each configured device one by one
        for device_config in devices:
            host = device_config.get("host")    # IP address of the Modbus device
            port = device_config.get("port", 502)  # Modbus TCP default port is 502

            try:
                # AsyncModbusTcpClient used as a context manager (with ... as client:)
                # This automatically opens the TCP connection when entering the block
                # and closes it when leaving - even if an error occurs
                async with AsyncModbusTcpClient(host, port=port) as client:
                    logger.info(f"Connected to Modbus device at {host}:{port}")
                    # Poll all registers on this device
                    await poll_device(client, device_config, publisher)

            except Exception as e:
                # Connection failed - device may be offline, wrong IP, or port blocked
                logger.error(f"Modbus connection failed for {host}:{port} - {e}")

        # Wait before the next round of polling
        logger.info(f"Modbus poll complete. Next poll in {POLL_INTERVAL} seconds.")
        await asyncio.sleep(POLL_INTERVAL)
