#!/bin/bash
# =============================================================================
# services/grafana/install.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs on the PROXMOX HOST to create and configure an LXC
# container running Grafana.
#
# WHAT IS GRAFANA?
# Grafana is an open-source visualization and dashboarding tool. It connects
# to InfluxDB (our time-series historian) and turns raw data into live charts,
# graphs, and status panels. This is the "front end" of DAWS_BAS — the screen
# operators and engineers look at to see what's happening in the building.
#
# HOW GRAFANA CONNECTS TO INFLUXDB:
# Grafana uses a "datasource" — a pre-configured connection to InfluxDB.
# We provision this datasource automatically using a YAML file so you don't
# have to set it up manually in the UI every time.
#
# WHAT THIS SCRIPT DOES:
#   1. Prompts for the InfluxDB API token (needed to read from InfluxDB)
#   2. Downloads the Ubuntu 22.04 LXC template if not already present
#   3. Creates LXC container 116 at 192.168.30.16
#   4. Writes configuration to /etc/environment inside the container
#   5. Downloads and runs setup.sh inside the container
#
# HOW TO RUN:
#   On the Proxmox host:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/grafana/install.sh)"
#
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION - Edit these defaults if your network is different
# =============================================================================
CT_ID=116
CT_IP="192.168.30.16/24"
CT_GW="192.168.30.1"
CT_HOSTNAME="daws-grafana"
CT_CORES=2
CT_RAM=1024       # MB - Grafana is lightweight
CT_DISK=8         # GB - Dashboards and plugins don't need much space
CT_BRIDGE="vmbr0"
CT_VLAN=30
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
SETUP_URL="https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/grafana/setup.sh"


# =============================================================================
# STEP 1: Collect configuration via whiptail dialogs
# =============================================================================

# InfluxDB API token - Grafana uses this to authenticate with InfluxDB
INFLUXDB_TOKEN=$(whiptail --passwordbox \
    "InfluxDB API token\n(same token used when setting up InfluxDB LXC)" \
    10 60 --title "DAWS_BAS Grafana Setup" 3>&1 1>&2 2>&3)

# Grafana admin password
GRAFANA_PASS=$(whiptail --passwordbox \
    "Grafana admin password\n(for the 'admin' user in the Grafana UI)" \
    10 50 --title "DAWS_BAS Grafana Setup" 3>&1 1>&2 2>&3)


# =============================================================================
# STEP 2: Check for Ubuntu 22.04 LXC template
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
# tag=${CT_VLAN} puts the container on VLAN 30 — required for this network
# =============================================================================
echo "Creating LXC container ${CT_ID}..."

pct create ${CT_ID} ${TEMPLATE} \
    --hostname ${CT_HOSTNAME} \
    --cores ${CT_CORES} \
    --memory ${CT_RAM} \
    --rootfs local-lvm:${CT_DISK} \
    --net0 name=eth0,bridge=${CT_BRIDGE},ip=${CT_IP},gw=${CT_GW},tag=${CT_VLAN} \
    --start 1 \
    --onboot 1

echo "Waiting for container to start..."
sleep 5


# =============================================================================
# STEP 4: Write configuration to the container's /etc/environment
# Grafana reads these at startup to connect to InfluxDB
# =============================================================================
echo "Writing configuration to container..."

pct exec ${CT_ID} -- bash -c "cat >> /etc/environment << 'ENVEOF'
# Grafana admin credentials
GF_SECURITY_ADMIN_USER=admin
GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASS}

# InfluxDB connection settings (Grafana datasource)
INFLUXDB_URL=http://192.168.30.14:8086
INFLUXDB_TOKEN=${INFLUXDB_TOKEN}
INFLUXDB_ORG=DAWS
INFLUXDB_BUCKET=bas
ENVEOF"


# =============================================================================
# STEP 5: Download and run setup.sh inside the container
# =============================================================================
echo "Running Grafana setup inside container..."

pct exec ${CT_ID} -- bash -c \
    "wget -qO /tmp/setup.sh '${SETUP_URL}' && bash /tmp/setup.sh"


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  DAWS_BAS — Grafana Installation Complete"
echo "============================================"
echo ""
echo "  Grafana UI:  http://192.168.30.16:3000"
echo "  Username:    admin"
echo ""
echo "  To access the container:"
echo "    pct enter ${CT_ID}"
echo ""
echo "  To check service status:"
echo "    pct exec ${CT_ID} -- systemctl status grafana-server"
