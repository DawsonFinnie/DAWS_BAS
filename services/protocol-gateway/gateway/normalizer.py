# =============================================================================
# normalizer.py
# =============================================================================
#
# WHAT IS THIS FILE?
# This file converts raw data from any protocol into one consistent format
# before it gets sent to RabbitMQ.
#
# WHY DO WE NEED THIS?
# Every protocol speaks a different "language":
#
#   BACnet says:  {"objectIdentifier": "analogInput:1", "presentValue": 21.5}
#   Modbus says:  register[100] = 215  (raw integer, needs scaling by 0.1)
#   MQTT says:    topic="building/ahu01/temp", payload="21.5"
#   OPC-UA says:  NodeId="ns=2;i=1001", Variant=21.5
#
# Without normalization, every consumer (InfluxDB, Neo4j, Web UI) would
# need to understand all five protocols separately. That gets very complex.
#
# With normalization, every consumer receives the same simple format
# regardless of where the data came from:
#
#   {
#       "protocol":   "bacnet",
#       "device_id":  "bacnet:3001",
#       "point_name": "supply_temp",
#       "value":      "21.5",
#       "unit":       "degC",
#       "timestamp":  1709123456789,
#       "metadata":   { ... }
#   }
#
# This is called a "canonical data model" in software architecture.
# Metasys does the exact same thing internally — it normalizes BACnet,
# LON, and other field protocols into its own internal format before
# storing or displaying data.
#
# HOW IT FITS IN THE SYSTEM:
#
#   bacnet.py reads a BACnet point
#       calls normalize("bacnet", "bacnet:3001", "red_light", "active")
#           normalize() returns a dict
#               publisher.publish() sends it to RabbitMQ
#                   Telegraf reads it from RabbitMQ → writes to InfluxDB
#                   Neo4j consumer reads it → updates graph
#                   Web UI reads it → updates browser
#
# =============================================================================

import time     # Python built-in library for getting the current time


def normalize(
    protocol:   str,        # Which protocol produced this reading
                            # One of: "bacnet", "modbus", "mqtt", "opcua", "lon"

    device_id:  str,        # Unique string identifying the source device
                            # Convention is "<protocol>:<identifier>"
                            # e.g. "bacnet:3001", "modbus:chiller-01", "mqtt:ahu-west"

    point_name: str,        # Name of the specific data point (tag) being reported
                            # e.g. "supply_temp", "red_light", "fan_speed", "zone_co2"

    value,                  # The actual reading - any Python type is accepted:
                            #   float  → 21.5       (temperature, pressure, etc.)
                            #   int    → 100         (percentage, counts, etc.)
                            #   str    → "active"    (binary states)
                            #   bool   → True/False  (on/off states)

    unit:       str = "",   # Engineering unit for the value
                            # e.g. "degC", "degF", "%RH", "Pa", "L/s", "active"
                            # Use empty string "" if there is no unit

    metadata:   dict = {}   # Optional extra information specific to the protocol
                            # Used for debugging and traceability downstream
                            # BACnet example: {"object_type": "analogInput", "instance": 1}
                            # Modbus example: {"register_address": 100, "scale": 0.1}
                            # MQTT example:   {"topic": "building/ahu01/temp", "qos": 0}

) -> dict:                  # This function always returns a Python dictionary

    """
    Converts raw point data from any protocol into a standard dictionary
    that can be published to RabbitMQ.

    All five protocol handlers (bacnet.py, modbus.py, mqtt_client.py,
    opcua.py, lon.py) call this function before publishing. This ensures
    every message flowing through the system has identical structure.
    """

    # Build the normalized message and return it as a Python dictionary.
    # A dictionary is a collection of key:value pairs, written with curly braces {}.
    # The keys are strings (in quotes), the values are whatever type makes sense.
    return {

        # Which protocol this reading came from
        "protocol":   protocol,

        # Which device produced this reading
        "device_id":  device_id,

        # What data point (tag) this reading represents
        "point_name": point_name,

        # The value, converted to string.
        # We use str() to convert any type to a string because:
        #   - JSON (the format we send to RabbitMQ) handles strings consistently
        #   - InfluxDB and Neo4j can handle strings from any protocol uniformly
        #   - str(21.5) = "21.5", str(True) = "True", str("active") = "active"
        "value":      str(value),

        # Engineering unit - empty string if none applies
        "unit":       unit,

        # Current time as Unix milliseconds (ms since Jan 1 1970 UTC)
        # time.time() returns seconds as a float, e.g. 1709123456.789
        # Multiplying by 1000 gives milliseconds: 1709123456789
        # int() removes the decimal part
        # Most time-series databases expect timestamps in milliseconds
        "timestamp":  int(time.time() * 1000),

        # Protocol-specific extra info.
        # Defaults to empty dict {} if not provided.
        # Stored in the message for traceability but not used for routing.
        "metadata":   metadata
    }
