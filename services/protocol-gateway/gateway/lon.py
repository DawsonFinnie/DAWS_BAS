# =============================================================================
# lon.py  (LON Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file polls LON (LonWorks) devices via a SmartServer REST API
# and publishes values to RabbitMQ via the Publisher.
#
# WHAT IS LON/LONWORKS?
# LonWorks is a building automation protocol developed by Echelon Corporation
# in the 1990s. It was widely adopted before BACnet became dominant.
# You will still find LON in many older buildings, particularly in:
#   - VAV (Variable Air Volume) terminal units
#   - Lighting control systems
#   - Older JCI, Siemens, and Honeywell controllers
#   - Campus-wide building networks from the late 1990s/early 2000s
#
# WHY IS LON DIFFERENT FROM THE OTHER PROTOCOLS?
# LON uses a physical twisted-pair cable network (TP/FT-10) that is
# completely separate from your IP network. LON devices do not have
# IP addresses — they communicate using their own addressing scheme.
#
# To integrate LON into an IP-based system like DAWS_BAS, you need
# a LON/IP bridge device. The most common options are:
#
#   SmartServer (Echelon/Adesto):
#     A hardware device that connects to your LON network on one side
#     and your IP network on the other. It exposes LON network variables
#     via a REST API over HTTP. This is what this file supports.
#
#   i.LON 100 (older Echelon device):
#     Similar concept but with an XML-based API. Older and less common.
#
#   LON/BACnet Gateway (JCI, Tridium, etc.):
#     Some vendors make gateways that translate LON devices into BACnet objects.
#     If you have one of these, your LON devices will appear as BACnet devices
#     and the BACnet handler (bacnet.py) will handle them automatically.
#
# LON NETWORK VARIABLES:
# In LON, data points are called "Network Variables" (NVs).
# They follow a standard naming convention defined by SNVT (Standard Network
# Variable Types):
#   nviSpaceTemp    → network variable INPUT for space temperature
#   nvoFanSpeed     → network variable OUTPUT for fan speed
#   nciSetpoint     → network configuration input for setpoint
#
# "nvi" = network variable input  (we WRITE to these to send commands)
# "nvo" = network variable output (we READ these for sensor values)
# "nci" = network configuration input (configuration values)
#
# HOW THIS FILE WORKS:
#   1. Read the list of SmartServer devices from LON_SERVERS env var
#   2. For each SmartServer, make HTTP GET requests to its REST API
#   3. Each GET request reads one LON network variable value
#   4. Normalize and publish to RabbitMQ
#   5. Wait POLL_INTERVAL seconds and repeat
#
# NOTE: This is a polling approach. SmartServer also supports subscriptions
# (webhooks) for push-based updates, which would be more efficient for
# high-frequency data. Polling is simpler to implement and works fine for
# typical BAS data that changes every 30-60 seconds.
#
# CONFIGURATION:
# Set LON_SERVERS in your .env file as a JSON array:
#   LON_SERVERS=[
#     {
#       "id": "vav-box-301",
#       "host": "192.168.30.60",
#       "username": "ilon",
#       "password": "ilon",
#       "points": [
#         {"nv": "nvoSpaceTemp",   "name": "space_temp",  "unit": "degC"},
#         {"nv": "nvoFanSpeed",    "name": "fan_speed",   "unit": "%"},
#         {"nv": "nviSetpoint",    "name": "setpoint",    "unit": "degC"}
#       ]
#     }
#   ]
#
# =============================================================================

import asyncio      # For async/await
import logging      # For writing log messages
import os           # For reading environment variables
import json         # For parsing the LON_SERVERS JSON config
import aiohttp      # Async HTTP client library (like requests, but async)
                    # Used to make REST API calls to the SmartServer

from gateway.normalizer import normalize    # Standard message format converter
from gateway.publisher  import Publisher    # RabbitMQ message sender

logger = logging.getLogger(__name__)

POLL_INTERVAL = int(os.environ.get("GATEWAY_POLL_INTERVAL", 30))


async def poll_smartserver(server_config: dict, publisher: Publisher):
    """
    Polls all configured network variables from one SmartServer
    and publishes their values to RabbitMQ.

    The SmartServer exposes each LON network variable as a REST endpoint:
    GET http://<host>/ilon100/data/<nv_name>
    Returns JSON like: {"value": "21.5"}

    Parameters:
        server_config - Dict with host, credentials, and points list
        publisher     - The RabbitMQ publisher to send messages through
    """

    host      = server_config["host"]           # SmartServer IP address
    device_id = server_config["id"]             # Human-readable device identifier
    points    = server_config.get("points", []) # List of network variables to read
    username  = server_config.get("username", "ilon")   # Default SmartServer username
    password  = server_config.get("password", "ilon")   # Default SmartServer password

    # aiohttp.BasicAuth creates an HTTP Basic Authentication credential object
    # Basic auth sends username:password encoded in the HTTP header
    auth = aiohttp.BasicAuth(username, password)

    # Create an aiohttp session - this is like opening a browser session
    # The session reuses TCP connections efficiently across multiple requests
    # "async with" ensures the session is properly closed when we're done
    async with aiohttp.ClientSession(auth=auth) as session:

        # Read each configured network variable one by one
        for point in points:
            try:
                nv_name    = point["nv"]            # LON network variable name e.g. "nvoSpaceTemp"
                point_name = point["name"]           # Our human-readable name e.g. "space_temp"
                unit       = point.get("unit", "")  # Engineering unit e.g. "degC"

                # Build the SmartServer REST API URL for this network variable
                # The SmartServer maps each LON NV to a URL like this
                url = f"http://{host}/ilon100/data/{nv_name}"

                # Make the HTTP GET request to read the current value
                # ClientTimeout limits how long we wait for a response
                # total=5 means give up after 5 seconds (prevents hanging on offline devices)
                async with session.get(url, timeout=aiohttp.ClientTimeout(total=5)) as resp:

                    if resp.status == 200:
                        # Successful response - parse the JSON body
                        # resp.json() is async because it reads the response body from the network
                        data  = await resp.json()

                        # Extract the value - SmartServer returns {"value": "21.5"} format
                        # If "value" key doesn't exist, use the whole response dict
                        value = data.get("value", data)

                        # Normalize and publish to RabbitMQ
                        message = normalize(
                            protocol   = "lon",
                            device_id  = f"lon:{device_id}",
                            point_name = point_name,
                            value      = str(value),
                            unit       = unit,
                            metadata   = {
                                "nv_name": nv_name,     # Original LON NV name for reference
                                "host":    host          # SmartServer IP for traceability
                            }
                        )
                        publisher.publish(message, "lon", point_name)

                    else:
                        # HTTP error - device may be offline or the NV name may be wrong
                        logger.warning(
                            f"LON SmartServer at {host} returned HTTP {resp.status} "
                            f"for NV '{nv_name}'. Check the NV name and device connection."
                        )

            except aiohttp.ClientConnectorError:
                # Cannot reach the SmartServer at all - it may be offline or wrong IP
                logger.error(f"Cannot connect to LON SmartServer at {host}. Is it online?")
                break   # Stop trying other points on this device - all will fail too

            except asyncio.TimeoutError:
                # Request took longer than 5 seconds - device may be overloaded
                logger.warning(f"LON SmartServer at {host} timed out reading '{point_name}'")

            except Exception as e:
                # Unexpected error - log and continue to next point
                logger.warning(f"Failed to read LON point '{point_name}' from {host}: {e}")


async def run_lon_gateway(publisher: Publisher):
    """
    Main LON gateway loop. Runs forever.

    Reads the server list from the LON_SERVERS environment variable,
    then polls each SmartServer on every POLL_INTERVAL cycle.
    """

    # Read configuration from environment variable
    servers_json = os.environ.get("LON_SERVERS", "[]")
    servers      = json.loads(servers_json)

    # If no servers are configured, exit gracefully
    if not servers:
        logger.info("No LON servers configured. Set LON_SERVERS environment variable to enable.")
        return

    logger.info(f"Starting LON gateway for {len(servers)} SmartServer(s)")

    # Main poll loop - runs forever
    while True:
        # Poll each configured SmartServer
        for server_config in servers:
            try:
                await poll_smartserver(server_config, publisher)
            except Exception as e:
                logger.error(f"LON poll failed for {server_config.get('host', 'unknown')}: {e}")

        # Wait before the next round of polling
        logger.info(f"LON poll complete. Next poll in {POLL_INTERVAL} seconds.")
        await asyncio.sleep(POLL_INTERVAL)
