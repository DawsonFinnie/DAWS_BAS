# =============================================================================
# main.py  (Protocol Gateway Entry Point)
# =============================================================================
#
# WHAT IS THIS FILE?
# This is the starting point for the Protocol Gateway service.
# When the gateway starts (via Docker or systemd), Python runs this file first.
#
# WHAT DOES THE PROTOCOL GATEWAY DO?
# It sits between your field devices (BACnet controllers, Modbus sensors,
# MQTT devices, OPC-UA servers, LON networks) and the rest of DAWS_BAS.
# Its job is to:
#   1. Connect to RabbitMQ (the message broker)
#   2. Start each enabled protocol handler
#   3. Each handler discovers/polls devices and publishes normalized data
#
# Think of the Protocol Gateway as the "field interface" layer — equivalent
# to what a Metasys NAE/SNE does, but open source and configurable.
#
# HOW PROTOCOLS ARE ENABLED/DISABLED:
# Each protocol is enabled by setting the corresponding environment variable.
# If the variable is not set, that protocol handler simply doesn't start.
# This means you can run the gateway with just BACnet on day one, and add
# Modbus support later just by setting MODBUS_DEVICES and restarting.
#
#   Protocol   | Environment Variable | Example Value
#   -----------|---------------------|----------------------------------------
#   BACnet     | Always enabled      | —
#   Modbus     | MODBUS_DEVICES      | JSON list of devices and registers
#   MQTT       | MQTT_BROKER         | "192.168.30.50"
#   OPC-UA     | OPCUA_SERVERS       | JSON list of server URLs and nodes
#   LON        | LON_SERVERS         | JSON list of SmartServer configs
#
# THREADING MODEL:
# This gateway uses Python's asyncio for BACnet, Modbus, OPC-UA, and LON
# because those are all async-friendly (they use await for network waits).
# MQTT uses paho-mqtt which is NOT async, so it runs in a separate thread.
#
# asyncio.gather() runs multiple async functions concurrently on one thread,
# switching between them whenever one is waiting (e.g. during a poll delay).
#
# =============================================================================

import asyncio      # Python's async library - lets us run multiple tasks concurrently
import logging      # Python's logging library - for writing status messages
import os           # For reading environment variables
from threading import Thread    # For running MQTT in its own thread (paho is not async)

# Import the Publisher class that handles RabbitMQ connection and message sending
from gateway.publisher   import Publisher

# Import each protocol handler function
# Each one is an async function that runs forever, polling or subscribing to devices
from gateway.bacnet      import run_bacnet_gateway
from gateway.modbus      import run_modbus_gateway
from gateway.mqtt_client import run_mqtt_gateway
from gateway.opcua       import run_opcua_gateway
from gateway.lon         import run_lon_gateway


# Configure logging for the entire application
# This sets the format and minimum level for ALL log messages
# INFO level means we see: INFO, WARNING, ERROR, CRITICAL (but not DEBUG)
logging.basicConfig(
    level  = logging.INFO,
    format = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
    # Example output:
    # 2026-03-05 10:23:01 [INFO] gateway.bacnet: Found BACnet device 3001
)

# Get a logger specifically for this file (main.py)
# Using __name__ means log messages from this file show "gateway.main" as the source
logger = logging.getLogger(__name__)


async def main():
    """
    The main async function that starts everything.

    This is called by asyncio.run() at the bottom of this file.
    asyncio.run() creates the event loop and runs this coroutine inside it.
    """

    logger.info("=" * 50)
    logger.info("Starting DAWS_BAS Protocol Gateway")
    logger.info("=" * 50)

    # --- STEP 1: Connect to RabbitMQ ---
    # Create a Publisher instance (reads config from environment variables)
    publisher = Publisher()

    # Open the actual TCP connection to RabbitMQ
    # If RabbitMQ is not running, this will raise an exception and the gateway will exit
    publisher.connect()
    logger.info("RabbitMQ connection established")

    # --- STEP 2: Build the list of async tasks to run ---
    # tasks is a list of coroutines (async functions) that will run concurrently
    # We always include BACnet because it is the core building automation protocol
    tasks = [
        run_bacnet_gateway(publisher),  # Always enabled - BACnet is the foundation
    ]

    # --- STEP 3: Conditionally start other protocol handlers ---
    # Each protocol is only started if its environment variable is set.
    # os.environ.get() returns None if the variable is not set.
    # Python treats None as False in an if statement.

    if os.environ.get("MODBUS_DEVICES"):
        # MODBUS_DEVICES is set - there are Modbus devices to poll
        logger.info("Modbus gateway enabled (MODBUS_DEVICES is set)")
        tasks.append(run_modbus_gateway(publisher))
    else:
        logger.info("Modbus gateway disabled (set MODBUS_DEVICES to enable)")

    if os.environ.get("OPCUA_SERVERS"):
        # OPCUA_SERVERS is set - there are OPC-UA servers to subscribe to
        logger.info("OPC-UA gateway enabled (OPCUA_SERVERS is set)")
        tasks.append(run_opcua_gateway(publisher))
    else:
        logger.info("OPC-UA gateway disabled (set OPCUA_SERVERS to enable)")

    if os.environ.get("LON_SERVERS"):
        # LON_SERVERS is set - there are LON SmartServers to poll
        logger.info("LON gateway enabled (LON_SERVERS is set)")
        tasks.append(run_lon_gateway(publisher))
    else:
        logger.info("LON gateway disabled (set LON_SERVERS to enable)")

    if os.environ.get("MQTT_BROKER"):
        # MQTT_BROKER is set - start the MQTT subscriber
        # NOTE: paho-mqtt is NOT async, so it must run in a separate thread
        # Thread() creates a new OS thread. daemon=True means it stops when main exits.
        logger.info("MQTT gateway enabled (MQTT_BROKER is set)")
        Thread(
            target = run_mqtt_gateway,  # The function to run in the thread
            args   = (publisher,),      # Arguments to pass to the function
            daemon = True               # Thread dies automatically when main program exits
        ).start()
    else:
        logger.info("MQTT gateway disabled (set MQTT_BROKER to enable)")

    # --- STEP 4: Run all async tasks concurrently ---
    logger.info(f"Starting {len(tasks)} async protocol gateway(s)...")

    # asyncio.gather() takes a list of coroutines and runs them all at the same time
    # It switches between them whenever one is waiting (e.g. during sleep or network I/O)
    # This is more efficient than using threads for async tasks because:
    #   - No thread overhead
    #   - No risk of race conditions between tasks
    #   - Python's asyncio handles the switching automatically
    #
    # This line blocks here forever (all tasks run forever in loops)
    # The gateway stays alive as long as the tasks are running
    await asyncio.gather(*tasks)   # The * unpacks the list: gather(task1, task2, task3...)


# =============================================================================
# ENTRY POINT
# This block only runs when you execute this file directly:
#   python -m gateway.main
# It does NOT run when this file is imported by another module.
# =============================================================================
if __name__ == "__main__":

    # asyncio.run() does three things:
    #   1. Creates a new event loop (the asyncio scheduler)
    #   2. Runs the main() coroutine inside that event loop
    #   3. Closes the event loop when main() returns (which it never does
    #      in normal operation because all tasks run forever)
    asyncio.run(main())
