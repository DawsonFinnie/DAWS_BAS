# =============================================================================
# opcua.py  (OPC-UA Protocol Handler)
# =============================================================================
#
# WHAT IS THIS FILE?
# This file connects to OPC-UA servers, subscribes to data node changes,
# and forwards value updates to RabbitMQ via the Publisher.
#
# WHAT IS OPC-UA?
# OPC-UA (Open Platform Communications - Unified Architecture) is a modern
# industrial protocol designed to replace older protocols like OPC-DA and Modbus.
# It is increasingly common in:
#   - Modern HVAC equipment and controllers
#   - Industrial PLCs and SCADA systems
#   - Newer building automation equipment
#   - Energy management systems
#
# OPC-UA VS BACNET:
# Both OPC-UA and BACnet are "self-describing" — you can browse a device's
# data without knowing its register map in advance. The key differences:
#   - BACnet is purpose-built for buildings (HVAC, lighting, access control)
#   - OPC-UA comes from industrial automation and is more general-purpose
#   - OPC-UA has stronger security (certificates, encryption)
#   - OPC-UA is more common in newer equipment; BACnet in older buildings
#
# KEY OPC-UA CONCEPTS:
#
#   Server:
#     The device or software exposing data. Each server has an endpoint URL.
#     Example: "opc.tcp://192.168.30.50:4840"
#     (opc.tcp = OPC-UA TCP transport, like http:// for web pages)
#
#   Node:
#     The fundamental unit of data in OPC-UA. Every piece of data has a NodeId.
#     NodeId format: "ns=<namespace>;<type>=<identifier>"
#     Examples:
#       "ns=2;i=1001"   → namespace 2, integer ID 1001
#       "ns=2;s=Temp"   → namespace 2, string ID "Temp"
#     You get NodeIds by browsing the server or reading the device manual.
#
#   Subscription:
#     Instead of polling (ask → receive), OPC-UA supports subscriptions
#     (tell the server: "notify me when this node changes").
#     This is similar to BACnet COV (Change of Value) subscriptions.
#     The server sends updates automatically, which is more efficient.
#
#   Namespace:
#     A way to organize nodes. Namespace 0 is reserved for OPC-UA standard nodes.
#     Namespace 1+ are defined by the device/server vendor.
#     You'll always use ns=2 or higher for device-specific data.
#
# HOW THIS FILE WORKS:
#   1. Connect to each configured OPC-UA server endpoint
#   2. Create a subscription (tells the server to push changes to us)
#   3. Subscribe to each configured NodeId
#   4. When a value changes, the ValueChangeHandler.datachange_notification() is called
#   5. We normalize and publish to RabbitMQ
#   6. The connection stays open indefinitely receiving push notifications
#
# CONFIGURATION:
# Set OPCUA_SERVERS in your .env file as a JSON array:
#   OPCUA_SERVERS=[
#     {
#       "id": "ahu-controller",
#       "url": "opc.tcp://192.168.30.50:4840",
#       "nodes": ["ns=2;i=1001", "ns=2;i=1002", "ns=2;i=1003"]
#     }
#   ]
#
# =============================================================================

import asyncio      # For async/await - asyncua requires an event loop
import logging      # For writing log messages
import os           # For reading environment variables
import json         # For parsing the OPCUA_SERVERS JSON config

# asyncua is the Python OPC-UA library
# Client is the connection class, ua contains OPC-UA type definitions
from asyncua import Client, ua

from gateway.normalizer import normalize    # Standard message format converter
from gateway.publisher  import Publisher    # RabbitMQ message sender

logger = logging.getLogger(__name__)


async def subscribe_to_server(server_config: dict, publisher: Publisher):
    """
    Connects to one OPC-UA server and subscribes to configured nodes.
    Runs forever, receiving value change notifications from the server.

    If the connection fails, waits 30 seconds and tries again (retry loop).

    Parameters:
        server_config - Dict with "id", "url", and "nodes" keys
        publisher     - The RabbitMQ publisher to send messages through
    """

    url       = server_config["url"]        # OPC-UA endpoint URL
    device_id = server_config["id"]         # Human-readable device identifier
    nodes     = server_config.get("nodes", [])  # List of NodeId strings to subscribe to

    # -------------------------------------------------------------------------
    # DEFINE THE VALUE CHANGE HANDLER
    # This class is called by asyncua whenever a subscribed node changes value.
    # We define it inside subscribe_to_server() so it can access publisher
    # and other local variables via closure.
    # -------------------------------------------------------------------------
    class ValueChangeHandler:
        """
        Called by asyncua when a subscribed node's value changes.
        This is the OPC-UA equivalent of a BACnet COV notification handler.
        """

        def datachange_notification(self, node, val, data):
            """
            Called automatically when a subscribed node's value changes.

            Parameters:
                node - The OPC-UA Node object that changed
                val  - The new value (type depends on the node's data type)
                data - Additional change data (not used here)
            """
            try:
                # Convert the node object to a string to use as the point name
                # Node.__str__() returns something like "Node(NodeId(i=1001, ns=2))"
                # We extract just the numeric ID part after "i=" for a clean name
                # e.g. "Node(NodeId(i=1001, ns=2))" → "1001"
                # This isn't a great point name - in production you'd map NodeIds
                # to human-readable names in the device config
                node_str   = str(node)
                point_name = node_str.split("i=")[-1].rstrip(")")   # Extract the ID number

                # Normalize and publish to RabbitMQ
                message = normalize(
                    protocol   = "opcua",
                    device_id  = f"opcua:{device_id}",
                    point_name = point_name,
                    value      = str(val),      # Convert to string (val could be any OPC-UA type)
                    unit       = "",            # OPC-UA values may have units but we skip for now
                    metadata   = {
                        "node_id": node_str,    # Full node ID for reference
                        "url":     url          # Server URL for traceability
                    }
                )
                publisher.publish(message, "opcua", point_name)

            except Exception as e:
                logger.warning(f"OPC-UA value change handler error for node {node}: {e}")


    # -------------------------------------------------------------------------
    # MAIN CONNECTION AND SUBSCRIPTION LOOP
    # We wrap everything in a while True so if the connection drops,
    # we wait and reconnect automatically
    # -------------------------------------------------------------------------
    while True:
        try:
            # Connect to the OPC-UA server using an async context manager
            # The "async with" block automatically handles connect/disconnect
            async with Client(url=url) as client:
                logger.info(f"Connected to OPC-UA server at {url}")

                # Create a subscription on the server
                # 500 = requested publishing interval in milliseconds
                # The server will send value changes at most every 500ms
                # handler = our ValueChangeHandler instance
                handler      = ValueChangeHandler()
                subscription = await client.create_subscription(500, handler)

                # Subscribe to each configured node
                # This tells the server: "send me updates when these nodes change"
                subscribed_nodes = []
                for node_id in nodes:
                    try:
                        # Get a Node object from the NodeId string
                        node = client.get_node(node_id)

                        # Add this node to our subscription
                        # From now on, when this node changes, handler.datachange_notification() fires
                        await subscription.subscribe_data_change(node)
                        subscribed_nodes.append(node)
                        logger.info(f"Subscribed to OPC-UA node {node_id} on {device_id}")

                    except Exception as e:
                        logger.warning(f"Failed to subscribe to OPC-UA node {node_id}: {e}")

                logger.info(f"OPC-UA: subscribed to {len(subscribed_nodes)} nodes on {device_id}")

                # Keep the connection alive and wait for notifications
                # asyncio.sleep() pauses here but lets other tasks run
                # The server will push updates to our handler as values change
                while True:
                    await asyncio.sleep(10)     # Just keep the connection alive

        except Exception as e:
            # Connection failed (server offline, wrong URL, network issue, etc.)
            logger.error(f"OPC-UA connection failed for {url}: {e}")
            logger.info("Retrying OPC-UA connection in 30 seconds...")
            await asyncio.sleep(30)     # Wait before retrying


async def run_opcua_gateway(publisher: Publisher):
    """
    Main OPC-UA gateway.
    Reads server list from OPCUA_SERVERS environment variable and
    connects to all servers concurrently.

    Each server runs in its own async task so one failing server
    doesn't affect the others.
    """

    # Read configuration from environment variable
    servers_json = os.environ.get("OPCUA_SERVERS", "[]")
    servers      = json.loads(servers_json)

    # If no servers are configured, exit gracefully
    if not servers:
        logger.info("No OPC-UA servers configured. Set OPCUA_SERVERS environment variable to enable.")
        return

    logger.info(f"Starting OPC-UA gateway for {len(servers)} server(s)")

    # Create one async task per server so they all run concurrently
    # If one server is slow or disconnects, the others keep running normally
    tasks = [subscribe_to_server(s, publisher) for s in servers]

    # asyncio.gather() runs all tasks concurrently
    # return_exceptions=True means if one task raises an exception,
    # the others keep running instead of all being cancelled
    await asyncio.gather(*tasks, return_exceptions=True)
