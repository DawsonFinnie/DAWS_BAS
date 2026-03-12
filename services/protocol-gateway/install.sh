#!/bin/bash
# =============================================================================
# services/protocol-gateway/install.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs on the PROXMOX HOST to create and configure an LXC
# container running the DAWS_BAS Protocol Gateway.
#
# WHAT IS THE PROTOCOL GATEWAY?
# The Protocol Gateway is the "field interface" of DAWS_BAS. It sits between
# your physical building automation devices and the rest of the system.
# It speaks BACnet (and optionally Modbus, MQTT, OPC-UA, LON), reads data
# from field devices, normalizes everything into the standard DAWS_BAS JSON
# format, and publishes to RabbitMQ.
#
# Think of it as the equivalent of a Metasys NAE or SNE — the network
# engine that talks to field controllers and feeds data upstream.
#
# WHAT PROTOCOLS ARE SUPPORTED?
#   BACnet  — Always enabled. Discovers devices via WhoIs/IAm broadcast.
#   Modbus  — Enabled if MODBUS_DEVICES env var is set (JSON config)
#   MQTT    — Enabled if MQTT_BROKER env var is set
#   OPC-UA  — Enabled if OPCUA_SERVERS env var is set (JSON config)
#   LON     — Enabled if LON_SERVERS env var is set (JSON config)
#
# WHAT THIS SCRIPT DOES:
#   1. Prompts for RabbitMQ password and BACnet network settings
#   2. Downloads the Ubuntu 22.04 LXC template if not already present
#   3. Creates LXC container 118 at 192.168.30.18
#   4. Writes all configuration to /etc/environment inside the container
#   5. Downloads and runs setup.sh inside the container
#
# HOW TO RUN:
#   On the Proxmox host:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/protocol-gateway/install.sh)"
#
# =============================================================================

set -e

# =============================================================================
# CONFIGURATION — Edit these defaults if your network is different
# =============================================================================
CT_ID=118
CT_IP="192.168.30.18/24"
CT_GW="192.168.30.1"
CT_HOSTNAME="daws-gateway"
CT_CORES=2
CT_RAM=1024       # MB
CT_DISK=8         # GB
CT_BRIDGE="vmbr0"
CT_VLAN=30
TEMPLATE="local:vztmpl/ubuntu-22.04-standard_22.04-1_amd64.tar.zst"
SETUP_URL="https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/protocol-gateway/setup.sh"


# =============================================================================
# STEP 1: Collect configuration via whiptail dialogs
# =============================================================================

# RabbitMQ password — gateway needs this to publish messages
RABBITMQ_PASS=$(whiptail --passwordbox \
    "RabbitMQ password\n(same password used when setting up RabbitMQ LXC)" \
    10 60 --title "DAWS_BAS Protocol Gateway Setup" 3>&1 1>&2 2>&3)

# BACnet network — which subnet to broadcast WhoIs on
# The gateway needs to know which network interface to use
BACNET_NETWORK=$(whiptail \
    --inputbox "BACnet network (CIDR format)\nThis is the subnet your BACnet devices are on.\nExample: 192.168.30.0/24" \
    10 60 "192.168.30.0/24" \
    --title "DAWS_BAS Protocol Gateway Setup" 3>&1 1>&2 2>&3)

# BACnet Device ID for the gateway itself
# Every BACnet device on a network needs a unique ID number
# We use 9001 by default — change if it conflicts with another device
BACNET_DEVICE_ID=$(whiptail \
    --inputbox "BACnet Device ID for this gateway\n(Must be unique on your BACnet network.\nDefault 9001 is safe unless you have another device with that ID)" \
    10 70 "9001" \
    --title "DAWS_BAS Protocol Gateway Setup" 3>&1 1>&2 2>&3)


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
#
# IMPORTANT NOTE ON BACnet:
# BACnet uses UDP broadcast packets on port 47808.
# For BACnet broadcasts to work from inside an LXC container, the container
# needs to be on the same Layer 2 network as the BACnet devices.
# The VLAN tag ensures the container is on VLAN 30 where the BACnet devices live.
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
# STEP 4: Write configuration to /etc/environment
# These become environment variables available to the gateway service.
# The gateway reads them at startup to know how to connect to everything.
# =============================================================================
echo "Writing configuration to container..."

printf '\n# DAWS_BAS Protocol Gateway\nRABBITMQ_HOST=192.168.30.13\nRABBITMQ_USER=daws\nRABBITMQ_PASS=%s\nRABBITMQ_VHOST=bas\nBACNET_NETWORK=%s\nBACNET_DEVICE_ID=%s\nGATEWAY_POLL_INTERVAL=30\n' \
    "${RABBITMQ_PASS}" "${BACNET_NETWORK}" "${BACNET_DEVICE_ID}" \
    | pct exec ${CT_ID} -- bash -c "cat >> /etc/environment"


# =============================================================================
# STEP 5: Download and run setup.sh inside the container
# =============================================================================
echo "Running Protocol Gateway setup inside container..."

pct exec ${CT_ID} -- bash -c \
    "wget -qO /tmp/setup.sh '${SETUP_URL}' && bash /tmp/setup.sh"


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  DAWS_BAS — Protocol Gateway Installation Complete"
echo "============================================"
echo ""
echo "  Container:      CT ${CT_ID}"
echo "  IP:             192.168.30.18"
echo "  BACnet Network: ${BACNET_NETWORK}"
echo "  BACnet DeviceID:${BACNET_DEVICE_ID}"
echo ""
echo "  To check gateway logs:"
echo "    pct exec ${CT_ID} -- journalctl -u daws-gateway -f"
echo ""
echo "  To check what devices were found:"
echo "    pct exec ${CT_ID} -- journalctl -u daws-gateway | grep 'Found\|device'"
echo ""
echo "  To access the container:"
echo "    pct enter ${CT_ID}"
