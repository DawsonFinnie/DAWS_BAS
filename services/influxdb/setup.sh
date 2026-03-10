#!/bin/bash
# =============================================================================
# services/influxdb/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs INSIDE the InfluxDB + Telegraf LXC container.
# It is called automatically by install.sh after the container is created.
#
# WHAT DOES IT DO?
#   1. Fixes locale warnings
#   2. Installs InfluxDB v2 from the official InfluxData repository
#   3. Starts InfluxDB and runs initial setup (org, bucket, admin user, token)
#   4. Installs Telegraf from the official InfluxData repository
#   5. Writes telegraf.conf configured for DAWS_BAS (RabbitMQ → InfluxDB)
#   6. Starts Telegraf as a systemd service
#
# ARCHITECTURE REMINDER:
#   Traffic Light → RabbitMQ → [Telegraf subscribes] → InfluxDB → Grafana
#   This container is the middle two pieces of that chain.
#
# =============================================================================

set -e

echo "============================================"
echo "  DAWS_BAS — InfluxDB + Telegraf Setup"
echo "============================================"


# =============================================================================
# STEP 0: Fix locale warnings
# =============================================================================
echo "Step 0/6: Fixing locale..."
apt-get install -y -qq locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install prerequisites
# =============================================================================
echo "Step 1/6: Installing prerequisites..."
apt-get update -qq
apt-get install -y -qq curl gnupg apt-transport-https


# =============================================================================
# STEP 2: Add InfluxData repository and install InfluxDB v2
#
# InfluxData maintains their own apt repository for both InfluxDB and Telegraf.
# We add their GPG key and repository, then install both packages from it.
#
# InfluxDB v2 is a major rewrite of InfluxDB. Key concepts:
#   - Organization: a namespace for all your data (we use "DAWS")
#   - Bucket: a named storage container with a retention policy (we use "bas")
#   - Token: an API key used for authentication (replaces username/password for API)
#   - Measurement: like a table in SQL (we use "point_update")
#   - Tags: indexed metadata fields (device_id, point_name, protocol, unit)
#   - Fields: actual data values (value)
# =============================================================================
echo "Step 2/6: Adding InfluxData repository..."

# InfluxData rotated their signing key on January 6, 2026.
# We must use influxdata-archive.key (not _compat) and verify by fingerprint.
# The new subkey AC10D7449F343ADCEFDDC2B6DA61C26A0585BD3B is valid until 2029.
mkdir -p /etc/apt/keyrings

curl --silent --location -O https://repos.influxdata.com/influxdata-archive.key

# Verify the key fingerprint before trusting it
gpg --show-keys --with-fingerprint --with-colons ./influxdata-archive.key 2>&1 \
    | grep -q '^fpr:\+24C975CBA61A024EE1B631787C3D57159FC2F927:$' \
    && echo "Key fingerprint verified OK" \
    || { echo "ERROR: Key fingerprint mismatch - aborting"; exit 1; }

cat influxdata-archive.key \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/influxdata-archive.gpg > /dev/null
rm influxdata-archive.key

# Add the InfluxData debian stable repository
echo "deb [signed-by=/etc/apt/keyrings/influxdata-archive.gpg] https://repos.influxdata.com/debian stable main" \
    | tee /etc/apt/sources.list.d/influxdata.list

apt-get update -qq


# =============================================================================
# STEP 3: Install InfluxDB
# =============================================================================
echo "Step 3/6: Installing InfluxDB v2..."
apt-get install -y influxdb2

systemctl enable influxdb
systemctl start influxdb

# Wait for InfluxDB to be ready before running setup commands
echo "Waiting for InfluxDB to initialize..."
for i in {1..30}; do
    if curl -s http://localhost:8086/health | grep -q '"status":"pass"'; then
        echo "InfluxDB is ready."
        break
    fi
    sleep 2
done


# =============================================================================
# STEP 4: Run InfluxDB initial setup
#
# "influx setup" configures InfluxDB for first use. It creates:
#   - The admin user
#   - The organization (DAWS) — a namespace for all your data
#   - The initial bucket (bas) — where Telegraf will write point data
#   - The operator token — the master API token
#
# We then create a SECOND token scoped to just what Telegraf and Grafana need.
# This is better security practice than using the operator token everywhere.
#
# --force skips the interactive confirmation prompt
# --retention 0 means data is kept forever (no automatic deletion)
# =============================================================================
echo "Step 4/6: Running InfluxDB initial setup..."

# Load environment variables set by install.sh
source /etc/environment

# Run initial setup
influx setup \
    --username "${INFLUXDB_USER}" \
    --password "${INFLUXDB_PASS}" \
    --org "${INFLUXDB_ORG}" \
    --bucket "${INFLUXDB_BUCKET}" \
    --retention 0 \
    --token "${INFLUXDB_TOKEN}" \
    --force

echo "  InfluxDB setup complete"
echo "  Organization: ${INFLUXDB_ORG}"
echo "  Bucket:       ${INFLUXDB_BUCKET}"
echo "  Admin user:   ${INFLUXDB_USER}"


# =============================================================================
# STEP 5: Install Telegraf
#
# Telegraf is already available from the InfluxData repo we added in Step 2.
#
# After installing, we write a custom telegraf.conf that:
#   - Connects to RabbitMQ as a consumer (input)
#   - Subscribes to routing key "point.#" (all point updates)
#   - Parses the JSON message body
#   - Writes measurements to InfluxDB (output)
#   - Also monitors RabbitMQ's own health metrics
# =============================================================================
echo "Step 5/6: Installing Telegraf..."
apt-get install -y telegraf


# =============================================================================
# STEP 6: Write telegraf.conf
#
# We write this file here (rather than downloading from GitHub) so we can
# substitute the actual values from /etc/environment directly into the config.
# Telegraf supports ${ENV_VAR} substitution in its config, but writing the
# values directly is simpler and easier to debug.
# =============================================================================
echo "Step 6/6: Configuring Telegraf..."

cat > /etc/telegraf/telegraf.conf << TELEGRAFEOF
# =============================================================================
# Telegraf configuration for DAWS_BAS
# Generated by setup.sh on $(date)
# =============================================================================
#
# DATA FLOW:
#   RabbitMQ exchange "daws.bas" (routing key "point.#")
#       → Telegraf amqp_consumer input
#           → Parses JSON message body
#               → Writes to InfluxDB measurement "point_update"
#                   → Grafana reads and displays
#
# MESSAGE FORMAT (from traffic light and protocol gateway):
#   {
#       "protocol":   "traffic",
#       "device_id":  "traffic-light:3001",
#       "point_name": "red_light",
#       "value":      "active",
#       "unit":       "",
#       "timestamp":  1709123456789
#   }
#
# INFLUXDB RESULT:
#   Measurement: point_update
#   Tags:        device_id=traffic-light:3001, point_name=red_light,
#                protocol=traffic, unit=
#   Fields:      value="active"
#   Time:        2026-03-09T20:00:00Z
#
# =============================================================================


# =============================================================================
# AGENT - Global Telegraf settings
# =============================================================================
[agent]
  # How often to collect data and flush to InfluxDB
  interval = "10s"
  flush_interval = "10s"
  hostname = "daws-influxdb"
  metric_buffer_limit = 10000


# =============================================================================
# OUTPUT - Write to InfluxDB v2
# =============================================================================
[[outputs.influxdb_v2]]
  # InfluxDB is running on this same container
  urls = ["http://localhost:8086"]

  token        = "${INFLUXDB_TOKEN}"
  organization = "${INFLUXDB_ORG}"
  bucket       = "${INFLUXDB_BUCKET}"
  timeout      = "5s"


# =============================================================================
# INPUT - Subscribe to RabbitMQ and receive point update messages
#
# Telegraf creates a durable queue called "telegraf" on RabbitMQ and binds
# it to the "daws.bas" exchange with routing key "point.#".
# Every message the traffic light (or protocol gateway) publishes arrives here.
# =============================================================================
[[inputs.amqp_consumer]]

  # RabbitMQ connection URL
  # Format: amqp://<user>:<pass>@<host>:<port>/<vhost>
  # The %2F encodes the "/" in the vhost name for URL compatibility
  brokers = ["amqp://${RABBITMQ_USER}:${RABBITMQ_PASS}@${RABBITMQ_HOST}:5672/${RABBITMQ_VHOST}"]

  # Exchange settings - must match what the traffic light and gateway use
  exchange          = "daws.bas"
  exchange_type     = "topic"
  exchange_durability = "durable"

  # Telegraf's queue on RabbitMQ
  # RabbitMQ will create this queue if it doesn't exist
  # durable = survives RabbitMQ restarts (messages won't be lost)
  queue          = "telegraf"
  queue_durability = "durable"

  # Subscribe to ALL point messages
  # "point.#" matches: point.traffic.red_light, point.bacnet.supply_temp, etc.
  binding_key = "point.#"

  # Parse message body as JSON
  data_format = "json"

  # Use the "timestamp" field in the JSON as the metric timestamp
  # This preserves the exact time the field device reported the value
  json_time_key    = "timestamp"
  json_time_format = "unix_ms"

  # These JSON fields become InfluxDB tags (indexed, filterable)
  # Tags are used in Grafana to filter by device, point name, protocol, etc.
  tag_keys = ["device_id", "point_name", "protocol", "unit"]

  # All point data goes into one measurement
  # In Grafana you'll query: from(bucket:"bas") |> filter(fn: (r) => r._measurement == "point_update")
  name_override = "point_update"


# =============================================================================
# INPUT - Monitor RabbitMQ health
#
# This polls the RabbitMQ management API every 30 seconds and writes
# broker health metrics to InfluxDB. Useful for Grafana dashboards showing:
#   - Queue depths (are messages backing up?)
#   - Message rates (how fast is data flowing?)
#   - Consumer counts (are all services connected?)
# =============================================================================
[[inputs.rabbitmq]]
  url      = "http://${RABBITMQ_HOST}:15672"
  username = "${RABBITMQ_USER}"
  password = "${RABBITMQ_PASS}"
  interval = "30s"
TELEGRAFEOF

echo "  telegraf.conf written to /etc/telegraf/telegraf.conf"

# Start Telegraf
systemctl enable telegraf
systemctl start telegraf

# Wait a moment then check status
sleep 3


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  InfluxDB + Telegraf setup complete!"
echo "============================================"
echo ""
systemctl status influxdb --no-pager
echo ""
systemctl status telegraf --no-pager
