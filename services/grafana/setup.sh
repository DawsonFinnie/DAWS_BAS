#!/bin/bash
# =============================================================================
# services/grafana/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs INSIDE the Grafana LXC container (CT 116).
# It installs Grafana, provisions the InfluxDB datasource automatically,
# and deploys a starter dashboard for the traffic light.
#
# HOW GRAFANA PROVISIONING WORKS:
# Instead of clicking through the Grafana UI to add a datasource, we drop
# YAML files into /etc/grafana/provisioning/datasources/. Grafana reads
# these at startup and configures itself automatically. This is the
# "infrastructure as code" approach — repeatable and version-controlled.
#
# WHAT THIS SCRIPT DOES:
#   0. Fix locale (prevents apt warnings in Ubuntu minimal containers)
#   1. Install prerequisites (curl, gnupg, apt-transport-https)
#   2. Add the Grafana apt repository and GPG key
#   3. Install Grafana
#   4. Write the InfluxDB datasource provisioning file
#   5. Write a starter DAWS_BAS dashboard
#   6. Start and enable the grafana-server systemd service
#
# =============================================================================

set -e

echo "============================================"
echo "  DAWS_BAS — Grafana Setup"
echo "============================================"

# Load environment variables written by install.sh
# These tell us the InfluxDB token, org, bucket, and Grafana password
source /etc/environment


# =============================================================================
# STEP 0: Fix locale
# Ubuntu minimal containers often have broken locale settings which cause
# dozens of "perl: warning: Setting locale failed" messages during apt
# =============================================================================
echo "Step 0/5: Fixing locale..."
apt-get install -y -qq locales > /dev/null
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install prerequisites
# =============================================================================
echo "Step 1/5: Installing prerequisites..."
apt-get install -y -qq \
    apt-transport-https \
    curl \
    gnupg \
    ca-certificates \
    software-properties-common > /dev/null


# =============================================================================
# STEP 2: Add Grafana apt repository
#
# Grafana maintains their own apt repo. We add their GPG signing key first
# to verify package authenticity, then add the repo to apt sources.
# =============================================================================
echo "Step 2/5: Adding Grafana repository..."

mkdir -p /etc/apt/keyrings

# Download and verify the Grafana GPG key
curl -fsSL https://apt.grafana.com/gpg.key \
    | gpg --dearmor \
    | tee /etc/apt/keyrings/grafana.gpg > /dev/null

# Add the Grafana stable apt repository
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | tee /etc/apt/sources.list.d/grafana.list

apt-get update -qq


# =============================================================================
# STEP 3: Install Grafana
# grafana-oss = Open Source edition (free, full featured)
# =============================================================================
echo "Step 3/5: Installing Grafana..."
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana-oss

# Set the admin password from environment variable
grafana-cli admin reset-admin-password "${GF_SECURITY_ADMIN_PASSWORD}" 2>/dev/null || true


# =============================================================================
# STEP 4: Provision InfluxDB datasource
#
# This YAML file tells Grafana how to connect to InfluxDB automatically.
# The "flux" query language is the modern way to query InfluxDB v2.
# Without this file, you'd have to click through Settings → Data Sources
# in the Grafana UI every time you set up a new instance.
# =============================================================================
echo "Step 4/5: Provisioning InfluxDB datasource..."

mkdir -p /etc/grafana/provisioning/datasources

cat > /etc/grafana/provisioning/datasources/influxdb.yml << DATASOURCE_EOF
# =============================================================================
# Grafana datasource provisioning for InfluxDB v2
# This file is read by Grafana at startup.
# Changes here are applied on the next grafana-server restart.
# =============================================================================
apiVersion: 1

datasources:
  - name: InfluxDB
    type: influxdb
    access: proxy       # Grafana server connects to InfluxDB (not the browser)
    url: ${INFLUXDB_URL}
    isDefault: true     # This is the default datasource for new panels

    # InfluxDB v2 uses the Flux query language
    # jsonData tells Grafana which InfluxDB version and org to use
    jsonData:
      version: Flux
      organization: ${INFLUXDB_ORG}
      defaultBucket: ${INFLUXDB_BUCKET}
      tlsSkipVerify: true

    # The API token is stored as a secure field
    # It authenticates Grafana's queries to InfluxDB
    secureJsonData:
      token: ${INFLUXDB_TOKEN}
DATASOURCE_EOF

echo "  InfluxDB datasource provisioned"
echo "  URL:    ${INFLUXDB_URL}"
echo "  Org:    ${INFLUXDB_ORG}"
echo "  Bucket: ${INFLUXDB_BUCKET}"


# =============================================================================
# STEP 5: Deploy starter dashboard
#
# This JSON dashboard shows traffic light state over time.
# It's a starting point — you can build more panels in the Grafana UI.
#
# HOW GRAFANA DASHBOARD PROVISIONING WORKS:
# Drop a JSON file into /etc/grafana/provisioning/dashboards/ along with
# a YAML "provider" file that tells Grafana where to look for dashboard JSON.
# =============================================================================
echo "Step 5/5: Deploying starter dashboard..."

mkdir -p /etc/grafana/provisioning/dashboards
mkdir -p /var/lib/grafana/dashboards

# Dashboard provider - tells Grafana to load JSON files from the dashboards dir
cat > /etc/grafana/provisioning/dashboards/daws_bas.yml << PROVIDER_EOF
apiVersion: 1

providers:
  - name: DAWS_BAS
    orgId: 1
    type: file
    disableDeletion: false
    updateIntervalSeconds: 30   # Check for dashboard file changes every 30s
    allowUiUpdates: true        # Allow editing dashboards in the UI
    options:
      path: /var/lib/grafana/dashboards
PROVIDER_EOF

# Traffic Light starter dashboard
# Shows red/yellow/green/running point values as time series
cat > /var/lib/grafana/dashboards/traffic_light.json << 'DASHBOARD_EOF'
{
  "__inputs": [],
  "__requires": [],
  "annotations": { "list": [] },
  "description": "DAWS_BAS Traffic Light — point states over time",
  "editable": true,
  "fiscalYearStartMonth": 0,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [
    {
      "datasource": { "type": "influxdb", "uid": "${DS_INFLUXDB}" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "palette-classic" },
          "custom": {
            "axisBorderShow": false,
            "axisCenteredZero": false,
            "axisColorMode": "text",
            "axisLabel": "",
            "axisPlacement": "auto",
            "barAlignment": 0,
            "drawStyle": "line",
            "fillOpacity": 10,
            "gradientMode": "none",
            "hideFrom": { "legend": false, "tooltip": false, "viz": false },
            "insertNulls": false,
            "lineInterpolation": "stepAfter",
            "lineWidth": 2,
            "pointSize": 5,
            "scaleDistribution": { "type": "linear" },
            "showPoints": "auto",
            "spanNulls": false,
            "stacking": { "group": "A", "mode": "none" },
            "thresholdsStyle": { "mode": "off" }
          },
          "mappings": [
            { "options": { "active": { "index": 0, "text": "1" }, "inactive": { "index": 1, "text": "0" } }, "type": "value" }
          ],
          "thresholds": { "mode": "absolute", "steps": [ { "color": "green", "value": null } ] }
        },
        "overrides": [
          { "matcher": { "id": "byName", "options": "red_light" },   "properties": [ { "id": "color", "value": { "fixedColor": "red",    "mode": "fixed" } } ] },
          { "matcher": { "id": "byName", "options": "yellow_light" }, "properties": [ { "id": "color", "value": { "fixedColor": "yellow", "mode": "fixed" } } ] },
          { "matcher": { "id": "byName", "options": "green_light" },  "properties": [ { "id": "color", "value": { "fixedColor": "green",  "mode": "fixed" } } ] }
        ]
      },
      "gridPos": { "h": 10, "w": 24, "x": 0, "y": 0 },
      "id": 1,
      "options": {
        "legend": { "calcs": [], "displayMode": "list", "placement": "bottom", "showLegend": true },
        "tooltip": { "mode": "multi", "sort": "none" }
      },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "${DS_INFLUXDB}" },
          "query": "from(bucket: \"bas\")\n  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)\n  |> filter(fn: (r) => r._measurement == \"point_update\")\n  |> filter(fn: (r) => r.device_id == \"traffic-light:3001\")\n  |> filter(fn: (r) => r._field == \"value\")\n  |> map(fn: (r) => ({ r with _value: if r._value == \"active\" then 1.0 else 0.0 }))\n  |> pivot(rowKey: [\"_time\"], columnKey: [\"point_name\"], valueColumn: \"_value\")",
          "refId": "A"
        }
      ],
      "title": "Traffic Light States",
      "type": "timeseries"
    },
    {
      "datasource": { "type": "influxdb", "uid": "${DS_INFLUXDB}" },
      "fieldConfig": {
        "defaults": {
          "color": { "mode": "thresholds" },
          "mappings": [
            { "options": { "0": { "color": "grey", "index": 1, "text": "OFF" }, "1": { "color": "red", "index": 0, "text": "ON" } }, "type": "value" }
          ],
          "thresholds": { "mode": "absolute", "steps": [ { "color": "grey", "value": null }, { "color": "red", "value": 1 } ] }
        },
        "overrides": [
          { "matcher": { "id": "byName", "options": "yellow_light" }, "properties": [ { "id": "thresholds", "value": { "mode": "absolute", "steps": [ { "color": "grey", "value": null }, { "color": "yellow", "value": 1 } ] } }, { "id": "mappings", "value": [ { "options": { "0": { "color": "grey", "index": 1, "text": "OFF" }, "1": { "color": "yellow", "index": 0, "text": "ON" } }, "type": "value" } ] } ] },
          { "matcher": { "id": "byName", "options": "green_light" },  "properties": [ { "id": "thresholds", "value": { "mode": "absolute", "steps": [ { "color": "grey", "value": null }, { "color": "green",  "value": 1 } ] } }, { "id": "mappings", "value": [ { "options": { "0": { "color": "grey", "index": 1, "text": "OFF" }, "1": { "color": "green",  "index": 0, "text": "ON" } }, "type": "value" } ] } ] }
        ]
      },
      "gridPos": { "h": 4, "w": 8, "x": 0, "y": 10 },
      "id": 2,
      "options": { "colorMode": "background", "graphMode": "none", "justifyMode": "center", "orientation": "auto", "reduceOptions": { "calcs": ["lastNotNull"], "fields": "", "values": false }, "textMode": "auto" },
      "targets": [
        {
          "datasource": { "type": "influxdb", "uid": "${DS_INFLUXDB}" },
          "query": "from(bucket: \"bas\")\n  |> range(start: -5m)\n  |> filter(fn: (r) => r._measurement == \"point_update\")\n  |> filter(fn: (r) => r.device_id == \"traffic-light:3001\")\n  |> filter(fn: (r) => r._field == \"value\")\n  |> map(fn: (r) => ({ r with _value: if r._value == \"active\" then 1.0 else 0.0 }))\n  |> last()\n  |> pivot(rowKey: [\"_time\"], columnKey: [\"point_name\"], valueColumn: \"_value\")",
          "refId": "A"
        }
      ],
      "title": "Current State",
      "type": "stat"
    }
  ],
  "refresh": "5s",
  "schemaVersion": 38,
  "tags": ["daws-bas", "traffic-light"],
  "templating": { "list": [] },
  "time": { "from": "now-1h", "to": "now" },
  "timepicker": {},
  "timezone": "browser",
  "title": "Traffic Light",
  "uid": "daws-traffic-light",
  "version": 1
}
DASHBOARD_EOF

echo "  Starter dashboard deployed: Traffic Light"


# =============================================================================
# STEP 6: Start Grafana
# =============================================================================
systemctl daemon-reload
systemctl enable grafana-server
systemctl start grafana-server

# Wait for Grafana to be ready
echo "Waiting for Grafana to initialize..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:3000/api/health > /dev/null 2>&1; then
        echo "Grafana is ready."
        break
    fi
    sleep 2
done


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  Grafana setup complete!"
echo "============================================"
echo ""

systemctl status grafana-server --no-pager
