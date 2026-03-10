#!/bin/bash
# =============================================================================
# services/influxdb/install.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs on the PROXMOX HOST to create and configure an LXC
# container running InfluxDB and Telegraf.
#
# WHAT IS INFLUXDB?
# InfluxDB is a time-series database — a database specifically designed
# for storing data that changes over time (temperatures, states, sensor readings).
# Every point update from the traffic light (and eventually all field devices)
# gets stored here with a precise timestamp. This is called a "historian" in
# building automation — the permanent record of everything that happened.
#
# WHAT IS TELEGRAF?
# Telegraf is a data collection agent made by InfluxData (same company as
# InfluxDB). It subscribes to RabbitMQ, receives normalized point messages,
# and writes them to InfluxDB automatically. No custom code needed.
#
# WHY ONE CONTAINER FOR BOTH?
# InfluxDB and Telegraf are made by the same company and designed to run
# together. Putting them in one LXC keeps the architecture simple at this
# stage. They can be separated later if needed.
#
# WHAT THIS SCRIPT DOES:
#   1. Prompts for configuration (passwords, tokens) via whiptail dialogs
#   2. Downloads the Ubuntu 22.04 LXC template if not already present
#   3. Creates LXC container 114 at 192.168.30.14
#   4. Writes all configuration to /etc/environment inside the container
#   5. Downloads and runs setup.sh inside the container
#
# HOW TO RUN:
#   On the Proxmox host:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/influxdb/install.sh)"
#
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION - Edit these defaults if your network is different
# =============================================================================
CT_ID=114
CT_IP="192.168.30.14/24"
CT_GW="192.168.30.1"
CT_HOSTNAME="daws-influxdb"
CT_CORES=2
CT_RAM=2048       # MB - InfluxDB benefits from more RAM
CT_DISK=16        # GB - Time series data grows over time
CT_BRIDGE="vmbr1"
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
SETUP_URL="https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/influxdb/setup.sh"


# =============================================================================
# STEP 1: Collect configuration via whiptail dialogs
# =============================================================================

# InfluxDB admin password
INFLUXDB_PASS=$(whiptail --passwordbox \
    "InfluxDB admin password\n(for the 'admin' user)" \
    10 50 --title "DAWS_BAS InfluxDB Setup" 3>&1 1>&2 2>&3)

# InfluxDB API token - used by Telegraf and Grafana to authenticate
INFLUXDB_TOKEN=$(whiptail --passwordbox \
    "InfluxDB API token\n(Telegraf and Grafana use this to connect.\nMake it long and random, e.g. a UUID)" \
    10 60 --title "DAWS_BAS InfluxDB Setup" 3>&1 1>&2 2>&3)

# RabbitMQ password - Telegraf needs this to subscribe to messages
RABBITMQ_PASS=$(whiptail --passwordbox \
    "RabbitMQ password\n(same password used when setting up RabbitMQ LXC)" \
    10 60 --title "DAWS_BAS InfluxDB Setup" 3>&1 1>&2 2>&3)


# =============================================================================
# STEP 2: Check for Ubuntu 22.04 LXC template
# Download it if not already present on this Proxmox host
# =============================================================================
echo "Checking for Ubuntu 22.04 LXC template..."

if ! pveam list local | grep -q "ubuntu-22.04-standard_22.04-1_amd64"; then
    echo "Downloading Ubuntu 22.04 template..."
    pveam update
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
else
    echo "Using template: $TEMPLATE"
fi


# =============================================================================
# STEP 3: Create the LXC container
# pct create = Proxmox Container Toolkit create command
# Each flag configures one aspect of the container
# =============================================================================
echo "Creating LXC container ${CT_ID}..."

pct create ${CT_ID} ${TEMPLATE} \
    --hostname ${CT_HOSTNAME} \
    --cores ${CT_CORES} \
    --memory ${CT_RAM} \
    --rootfs local-lvm:${CT_DISK} \
    --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW} \
    --unprivileged 1 \
    --features nesting=1 \
    --start 1 \
    --onboot 1

echo "Waiting for container to start..."
sleep 5


# =============================================================================
# STEP 4: Write configuration to the container's /etc/environment
# This file is read by systemd services as environment variables.
# Telegraf reads these to know how to connect to RabbitMQ and InfluxDB.
# =============================================================================
echo "Writing configuration to container..."

pct exec ${CT_ID} -- bash -c "cat >> /etc/environment << 'ENVEOF'
# InfluxDB connection settings
INFLUXDB_URL=http://localhost:8086
INFLUXDB_ORG=DAWS
INFLUXDB_BUCKET=bas
INFLUXDB_USER=admin
INFLUXDB_PASS=${INFLUXDB_PASS}
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}

# RabbitMQ connection settings (for Telegraf to subscribe)
RABBITMQ_HOST=192.168.30.13
RABBITMQ_USER=daws
RABBITMQ_PASS=${RABBITMQ_PASS}
RABBITMQ_VHOST=bas
ENVEOF"


# =============================================================================
# STEP 5: Download and run setup.sh inside the container
# wget downloads setup.sh from GitHub, bash runs it immediately
# =============================================================================
echo "Running InfluxDB + Telegraf setup inside container..."

pct exec ${CT_ID} -- bash -c \
    "wget -qO /tmp/setup.sh '${SETUP_URL}' && bash /tmp/setup.sh"


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  DAWS_BAS — InfluxDB + Telegraf Installation Complete"
echo "============================================"
echo ""
echo "  InfluxDB UI:    http://192.168.30.14:8086"
echo "  Username:       admin"
echo "  Organization:   DAWS"
echo "  Bucket:         bas"
echo ""
echo "  To access the container:"
echo "    pct enter ${CT_ID}"
echo ""
echo "  To check service status:"
echo "    pct exec ${CT_ID} -- systemctl status influxdb"
echo "    pct exec ${CT_ID} -- systemctl status telegraf"
