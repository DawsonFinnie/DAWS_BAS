#!/bin/bash
# =============================================================================
# services/neo4j/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# Runs INSIDE CT 117. Installs Neo4j and the DAWS_BAS graph updater service.
#
# HOW IT WORKS:
# 1. Installs Neo4j Community Edition from the official APT repo
# 2. Configures Neo4j to listen on all interfaces (not just localhost)
# 3. Sets the admin password
# 4. Installs the daws-neo4j-updater Python service
#    - Consumes ALL point_update messages from RabbitMQ (point.#)
#    - Creates/updates Device and Point nodes in the graph
#    - Records the latest value on each Point node
#
# GRAPH SCHEMA:
#   (:Device {device_id, name, address, protocol, last_seen})
#     -[:HAS_POINT]->
#   (:Point {device_id, point_name, unit, object_type, instance, last_value, last_updated})
#
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${YELLOW}Loading environment...${NC}"
set -a; source /etc/environment; set +a

echo -e "${YELLOW}Installing system dependencies...${NC}"
apt-get update -qq
apt-get install -y -qq curl wget gnupg apt-transport-https python3 python3-pip python3-venv

# =============================================================================
# INSTALL NEO4J
# Neo4j provides their own APT repository with signing key
# =============================================================================
echo -e "${YELLOW}Adding Neo4j APT repository...${NC}"

# Download and install the Neo4j GPG signing key
curl -fsSL https://debian.neo4j.com/neotechnology.gpg.key \
    | gpg --dearmor -o /usr/share/keyrings/neo4j.gpg

# Add the Neo4j 5.x stable repository
echo "deb [signed-by=/usr/share/keyrings/neo4j.gpg] https://debian.neo4j.com stable 5" \
    > /etc/apt/sources.list.d/neo4j.list

echo -e "${YELLOW}Installing Neo4j Community Edition...${NC}"
apt-get update -qq
apt-get install -y neo4j

# =============================================================================
# CONFIGURE NEO4J
# By default Neo4j only listens on localhost. We need it on the VLAN interface.
# =============================================================================
echo -e "${YELLOW}Configuring Neo4j...${NC}"

NEO4J_CONF=/etc/neo4j/neo4j.conf

# Listen on all interfaces for both HTTP (browser) and Bolt (app connections)
sed -i 's/#server.default_listen_address=0.0.0.0/server.default_listen_address=0.0.0.0/' $NEO4J_CONF

# Explicitly set HTTP and Bolt ports
sed -i 's/#server.http.listen_address=:7474/server.http.listen_address=0.0.0.0:7474/' $NEO4J_CONF
sed -i 's/#server.bolt.listen_address=:7687/server.bolt.listen_address=0.0.0.0:7687/' $NEO4J_CONF

# Disable HTTPS (not needed for internal BAS network)
sed -i 's/#server.https.enabled=true/server.https.enabled=false/' $NEO4J_CONF

# Set initial password using neo4j-admin
# neo4j-admin dbms set-initial-password sets the password before first start
neo4j-admin dbms set-initial-password "${NEO4J_PASS}"

echo -e "${YELLOW}Starting Neo4j...${NC}"
systemctl enable neo4j
systemctl start neo4j

# Wait for Neo4j to be ready (it takes 15-30 seconds to start)
echo -e "${YELLOW}Waiting for Neo4j to be ready (up to 60s)...${NC}"
for i in $(seq 1 12); do
    if curl -s http://localhost:7474 > /dev/null 2>&1; then
        echo -e "${GREEN}Neo4j is ready.${NC}"
        break
    fi
    echo -e "${YELLOW}  Waiting... ($((i*5))s)${NC}"
    sleep 5
done

# =============================================================================
# CREATE CONSTRAINTS AND INDEXES
# Constraints ensure uniqueness. Indexes make lookups fast.
# We use cypher-shell to run Cypher queries from the command line.
# =============================================================================
echo -e "${YELLOW}Creating graph constraints and indexes...${NC}"

cypher-shell -u neo4j -p "${NEO4J_PASS}" --format plain << 'CYPHER'
CREATE CONSTRAINT device_id IF NOT EXISTS
  FOR (d:Device) REQUIRE d.device_id IS UNIQUE;

CREATE CONSTRAINT point_unique IF NOT EXISTS
  FOR (p:Point) REQUIRE (p.device_id, p.point_name) IS UNIQUE;

CREATE INDEX point_name IF NOT EXISTS
  FOR (p:Point) ON (p.point_name);

CREATE INDEX device_protocol IF NOT EXISTS
  FOR (d:Device) ON (d.protocol);
CYPHER

echo -e "${GREEN}Graph constraints and indexes created.${NC}"

# =============================================================================
# INSTALL DAWS NEO4J UPDATER
# This Python service consumes RabbitMQ messages and updates the graph.
# =============================================================================
echo -e "${YELLOW}Installing daws-neo4j-updater...${NC}"

mkdir -p /opt/daws-neo4j
python3 -m venv /opt/daws-neo4j/venv
/opt/daws-neo4j/venv/bin/pip install --quiet pika neo4j

# Write the updater script
cat > /opt/daws-neo4j/updater.py << 'PYEOF'
# =============================================================================
# updater.py — DAWS_BAS Neo4j Graph Updater
# =============================================================================
#
# WHAT DOES THIS DO?
# Subscribes to ALL point_update messages from RabbitMQ (routing key: point.#)
# For each message, creates or updates Device and Point nodes in Neo4j.
#
# GRAPH SCHEMA:
#   (:Device {device_id, protocol, address, last_seen})
#     -[:HAS_POINT]->
#   (:Point {device_id, point_name, unit, object_type, instance,
#            last_value, last_updated})
#
# MERGE vs CREATE:
# We use MERGE (not CREATE) throughout. MERGE = "create if not exists,
# update if it does". This means running the updater multiple times is safe
# — it won't create duplicate nodes.
#
# =============================================================================

import json
import logging
import os
import time
import pika
from neo4j import GraphDatabase

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(name)s: %(message)s"
)
logger = logging.getLogger("daws.neo4j.updater")

# Read config from environment
RABBITMQ_HOST     = os.environ.get("RABBITMQ_HOST",     "192.168.30.13")
RABBITMQ_USER     = os.environ.get("RABBITMQ_USER",     "daws")
RABBITMQ_PASS     = os.environ.get("RABBITMQ_PASS",     "changeme")
RABBITMQ_VHOST    = os.environ.get("RABBITMQ_VHOST",    "bas")
RABBITMQ_EXCHANGE = os.environ.get("RABBITMQ_EXCHANGE", "daws.bas")
NEO4J_URI         = os.environ.get("NEO4J_URI",         "bolt://localhost:7687")
NEO4J_USER        = os.environ.get("NEO4J_USER",        "neo4j")
NEO4J_PASS        = os.environ.get("NEO4J_PASS",        "changeme")


def connect_neo4j():
    """Connect to Neo4j and return a driver instance."""
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASS))
    driver.verify_connectivity()
    logger.info(f"Connected to Neo4j at {NEO4J_URI}")
    return driver


def upsert_device_and_point(driver, msg: dict):
    """
    MERGE a Device node and a Point node, then link them with HAS_POINT.
    Also records the latest value on the Point node.

    Cypher MERGE works like "INSERT OR UPDATE":
      - If the node exists, match it
      - If not, create it
    ON CREATE sets properties only when first created.
    ON MATCH sets properties every time (updates).
    """
    device_id  = msg.get("device_id", "unknown")
    point_name = msg.get("point_name", "unknown")
    protocol   = msg.get("protocol",  "unknown")
    value      = msg.get("value",     "")
    unit       = msg.get("unit",      "")
    timestamp  = msg.get("timestamp", 0)
    metadata   = msg.get("metadata",  {})

    address     = metadata.get("address",     "")
    object_type = metadata.get("object_type", "")
    instance    = str(metadata.get("instance", ""))

    with driver.session() as session:
        session.run("""
            // Merge Device node
            MERGE (d:Device {device_id: $device_id})
            ON CREATE SET
                d.protocol  = $protocol,
                d.address   = $address,
                d.last_seen = $timestamp,
                d.created   = $timestamp
            ON MATCH SET
                d.last_seen = $timestamp,
                d.address   = $address

            // Merge Point node
            WITH d
            MERGE (p:Point {device_id: $device_id, point_name: $point_name})
            ON CREATE SET
                p.unit        = $unit,
                p.object_type = $object_type,
                p.instance    = $instance,
                p.created     = $timestamp
            ON MATCH SET
                p.last_value   = $value,
                p.last_updated = $timestamp,
                p.unit         = $unit

            // Ensure relationship exists
            WITH d, p
            MERGE (d)-[:HAS_POINT]->(p)
        """,
        device_id=device_id, protocol=protocol, address=address,
        timestamp=timestamp, point_name=point_name, value=value,
        unit=unit, object_type=object_type, instance=instance)


def on_message(ch, method, properties, body, driver):
    """Called by pika when a point_update message arrives."""
    try:
        msg = json.loads(body.decode())
        upsert_device_and_point(driver, msg)
        ch.basic_ack(delivery_tag=method.delivery_tag)
    except Exception as e:
        logger.error(f"Failed to process message: {e} | body: {body[:200]}")
        ch.basic_nack(delivery_tag=method.delivery_tag, requeue=False)


def connect_rabbitmq(driver):
    """Connect to RabbitMQ and start consuming point_update messages."""
    credentials = pika.PlainCredentials(RABBITMQ_USER, RABBITMQ_PASS)
    params = pika.ConnectionParameters(
        host=RABBITMQ_HOST,
        virtual_host=RABBITMQ_VHOST,
        credentials=credentials,
        heartbeat=60
    )
    connection = pika.BlockingConnection(params)
    channel    = connection.channel()

    # Declare exchange (idempotent — safe to declare even if it already exists)
    channel.exchange_declare(
        exchange=RABBITMQ_EXCHANGE,
        exchange_type="topic",
        durable=True
    )

    # Durable queue for Neo4j updater
    channel.queue_declare(queue="neo4j.updater", durable=True)

    # Bind to all point_update messages
    channel.queue_bind(
        exchange=RABBITMQ_EXCHANGE,
        queue="neo4j.updater",
        routing_key="point.#"
    )

    channel.basic_qos(prefetch_count=10)
    channel.basic_consume(
        queue="neo4j.updater",
        on_message_callback=lambda ch, method, props, body: on_message(
            ch, method, props, body, driver
        ),
        auto_ack=False
    )

    logger.info("Neo4j updater consuming from RabbitMQ (point.#)...")
    channel.start_consuming()


def main():
    logger.info("Starting DAWS_BAS Neo4j Updater")

    # Connect to Neo4j with retry
    driver = None
    for attempt in range(10):
        try:
            driver = connect_neo4j()
            break
        except Exception as e:
            logger.warning(f"Neo4j connection attempt {attempt+1}/10 failed: {e}")
            time.sleep(5)

    if not driver:
        logger.error("Could not connect to Neo4j after 10 attempts. Exiting.")
        raise SystemExit(1)

    # Connect to RabbitMQ with retry loop
    while True:
        try:
            connect_rabbitmq(driver)
        except Exception as e:
            logger.error(f"RabbitMQ connection lost: {e}. Reconnecting in 10s...")
            time.sleep(10)


if __name__ == "__main__":
    main()
PYEOF

# Write the systemd service unit
cat > /etc/systemd/system/daws-neo4j-updater.service << 'SVCEOF'
[Unit]
Description=DAWS_BAS Neo4j Graph Updater
After=network.target neo4j.service
Wants=neo4j.service

[Service]
Type=simple
User=root
EnvironmentFile=/etc/environment
ExecStart=/opt/daws-neo4j/venv/bin/python /opt/daws-neo4j/updater.py
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal
SyslogIdentifier=daws-neo4j-updater

[Install]
WantedBy=multi-user.target
SVCEOF

systemctl daemon-reload
systemctl enable daws-neo4j-updater
systemctl start daws-neo4j-updater

echo -e "${GREEN}"
echo "============================================"
echo "  DAWS_BAS — Neo4j Setup Complete"
echo "============================================"
echo -e "${NC}"
echo -e "  Neo4j Browser:    http://$(hostname -I | awk '{print $1}'):7474"
echo -e "  Bolt:             bolt://$(hostname -I | awk '{print $1}'):7687"
echo -e "  Updater service:  daws-neo4j-updater"
echo ""
echo -e "  Try this Cypher query in the browser:"
echo -e "    MATCH (d:Device)-[:HAS_POINT]->(p:Point) RETURN d,p LIMIT 50"
echo -e "${GREEN}============================================${NC}"
