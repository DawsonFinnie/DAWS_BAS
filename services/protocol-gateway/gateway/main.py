# =============================================================================
# main.py  (Protocol Gateway Entry Point)
# =============================================================================

import asyncio
import logging
import os
from threading import Thread

from gateway.publisher   import Publisher
from gateway.commander   import Commander
from gateway.bacnet      import run_bacnet_gateway
from gateway.modbus      import run_modbus_gateway
from gateway.mqtt_client import run_mqtt_gateway
from gateway.opcua       import run_opcua_gateway
from gateway.lon         import run_lon_gateway

logging.basicConfig(
    level  = logging.INFO,
    format = "%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger(__name__)


async def main():

    logger.info("=" * 50)
    logger.info("Starting DAWS_BAS Protocol Gateway")
    logger.info("=" * 50)

    # Connect to RabbitMQ for publishing point data
    publisher = Publisher()
    publisher.connect()
    logger.info("RabbitMQ publisher connected")

    # Create the asyncio queue that bridges the Commander thread → BACnet coroutine
    # Commander puts commands in; BACnet drains and executes them
    command_queue: asyncio.Queue = asyncio.Queue()

    # Start the Commander (runs in a daemon thread — blocking pika consume loop)
    # It needs the running event loop to safely put items on the asyncio queue
    loop = asyncio.get_running_loop()
    commander = Commander(command_queue)
    commander.start(loop)
    logger.info("Command consumer (Commander) started")

    # Build task list — BACnet always runs; pass command_queue for write support
    tasks = [
        run_bacnet_gateway(publisher, command_queue),
    ]

    if os.environ.get("MODBUS_DEVICES"):
        logger.info("Modbus gateway enabled")
        tasks.append(run_modbus_gateway(publisher))
    else:
        logger.info("Modbus gateway disabled (set MODBUS_DEVICES to enable)")

    if os.environ.get("OPCUA_SERVERS"):
        logger.info("OPC-UA gateway enabled")
        tasks.append(run_opcua_gateway(publisher))
    else:
        logger.info("OPC-UA gateway disabled (set OPCUA_SERVERS to enable)")

    if os.environ.get("LON_SERVERS"):
        logger.info("LON gateway enabled")
        tasks.append(run_lon_gateway(publisher))
    else:
        logger.info("LON gateway disabled (set LON_SERVERS to enable)")

    if os.environ.get("MQTT_BROKER"):
        logger.info("MQTT gateway enabled")
        Thread(
            target = run_mqtt_gateway,
            args   = (publisher,),
            daemon = True
        ).start()
    else:
        logger.info("MQTT gateway disabled (set MQTT_BROKER to enable)")

    logger.info(f"Starting {len(tasks)} async protocol gateway(s)...")
    await asyncio.gather(*tasks)


if __name__ == "__main__":
    asyncio.run(main())
