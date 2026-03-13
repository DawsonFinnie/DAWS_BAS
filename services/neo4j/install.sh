#!/bin/bash
# =============================================================================
# services/neo4j/install.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# Runs on your Proxmox HOST. Creates LXC CT 117 and installs Neo4j inside it.
#
# HOW TO RUN:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/neo4j/install.sh)"
#
# WHAT IS NEO4J?
# Neo4j is a graph database. Instead of tables and rows, it stores data as
# nodes (things) and relationships (connections between things).
#
# In DAWS_BAS, Neo4j models your building automation network:
#   (:Device) -[:HAS_POINT]-> (:Point)
#   (:Device) -[:COMMUNICATES_VIA]-> (:Protocol)
#
# This lets you ask questions like:
#   "Show me all points on devices that communicate via BACnet"
#   "Which devices have analog inputs?"
#   "What is the SNE supervising?"
#
# WHAT PORTS DOES IT USE?
#   7474 → HTTP browser interface (Neo4j Browser)
#   7687 → Bolt protocol (what applications connect to)
#
# =============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if ! command -v pct &> /dev/null; then
    echo -e "${RED}Error: This script must be run on a Proxmox host.${NC}"
    exit 1
fi

whiptail --title "DAWS_BAS — Neo4j Installer" \
    --msgbox "This installer will create a Proxmox LXC and install Neo4j.\n\nNeo4j is the graph database for DAWS_BAS.\nIt models relationships between devices, points, and protocols.\n\nBrowser UI will be available on port 7474 after install.\nBolt connection on port 7687.\n\nPress OK to continue." 16 65

CT_ID=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Proxmox Container ID (CT ID):" \
    8 50 "117" 3>&1 1>&2 2>&3)

HOSTNAME=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Container hostname:" \
    8 50 "daws-neo4j" 3>&1 1>&2 2>&3)

IP=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Static IP address (CIDR format):\nExample: 192.168.30.17/24" \
    9 50 "192.168.30.17/24" 3>&1 1>&2 2>&3)

GATEWAY=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Default gateway:" \
    8 50 "192.168.30.1" 3>&1 1>&2 2>&3)

VLAN=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "VLAN tag (leave blank if not using VLANs):" \
    8 50 "30" 3>&1 1>&2 2>&3)

STORAGE=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Proxmox storage pool:" \
    8 50 "local-lvm" 3>&1 1>&2 2>&3)

BRIDGE=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "Proxmox network bridge:" \
    8 50 "vmbr0" 3>&1 1>&2 2>&3)

NEO4J_PASS=$(whiptail --title "DAWS_BAS — Neo4j" \
    --passwordbox "Neo4j admin password (username will be 'neo4j'):" \
    8 55 3>&1 1>&2 2>&3)

RABBITMQ_HOST=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "RabbitMQ host IP (for the graph updater):" \
    8 50 "192.168.30.13" 3>&1 1>&2 2>&3)

RABBITMQ_USER=$(whiptail --title "DAWS_BAS — Neo4j" \
    --inputbox "RabbitMQ username:" \
    8 50 "daws" 3>&1 1>&2 2>&3)

RABBITMQ_PASS=$(whiptail --title "DAWS_BAS — Neo4j" \
    --passwordbox "RabbitMQ password:" \
    8 50 3>&1 1>&2 2>&3)

whiptail --title "DAWS_BAS — Confirm Settings" --yesno \
"Please review your settings:

  CT ID:          $CT_ID
  Hostname:       $HOSTNAME
  IP Address:     $IP
  Gateway:        $GATEWAY
  VLAN Tag:       $VLAN
  Storage:        $STORAGE
  Bridge:         $BRIDGE
  Neo4j Password: (set)
  RabbitMQ Host:  $RABBITMQ_HOST
  RabbitMQ User:  $RABBITMQ_USER

Press Yes to create the container, No to cancel." 24 55

echo -e "${YELLOW}Checking for Debian 12 LXC template...${NC}"
if ! pveam list local | grep -q "debian-12"; then
    echo -e "${YELLOW}Template not found. Downloading Debian 12...${NC}"
    pveam update
    pveam download local debian-12-standard_12.7-1_amd64.tar.zst
fi

TEMPLATE=$(pveam list local | grep "debian-12" | awk '{print $1}' | head -1)
echo -e "${GREEN}Using template: $TEMPLATE${NC}"

NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}"
[ -n "$VLAN" ] && NET_CONFIG="${NET_CONFIG},tag=${VLAN}"

echo -e "${YELLOW}Creating LXC container ${CT_ID}...${NC}"

pct create $CT_ID $TEMPLATE \
    --hostname    $HOSTNAME \
    --storage     $STORAGE \
    --rootfs      ${STORAGE}:8 \
    --memory      2048 \
    --cores       2 \
    --net0        $NET_CONFIG \
    --unprivileged 1 \
    --features    nesting=1 \
    --start       1 \
    --onboot      1

echo -e "${YELLOW}Waiting for container to start...${NC}"
sleep 5

echo -e "${YELLOW}Writing configuration to container...${NC}"
pct exec $CT_ID -- bash -c "printf 'NEO4J_PASS=%s\n'        '${NEO4J_PASS}'       >> /etc/environment"
pct exec $CT_ID -- bash -c "printf 'RABBITMQ_HOST=%s\n'     '${RABBITMQ_HOST}'    >> /etc/environment"
pct exec $CT_ID -- bash -c "printf 'RABBITMQ_USER=%s\n'     '${RABBITMQ_USER}'    >> /etc/environment"
pct exec $CT_ID -- bash -c "printf 'RABBITMQ_PASS=%s\n'     '${RABBITMQ_PASS}'    >> /etc/environment"
pct exec $CT_ID -- bash -c "printf 'RABBITMQ_VHOST=%s\n'    'bas'                 >> /etc/environment"
pct exec $CT_ID -- bash -c "printf 'RABBITMQ_EXCHANGE=%s\n' 'daws.bas'            >> /etc/environment"

echo -e "${YELLOW}Running Neo4j setup inside container...${NC}"
pct exec $CT_ID -- bash -c \
    "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/neo4j/setup.sh)"

echo -e "${GREEN}"
echo "============================================"
echo "  DAWS_BAS — Neo4j Installation Complete"
echo "============================================"
echo -e "${NC}"
echo -e "  Neo4j Browser:  http://${IP%/*}:7474"
echo -e "  Bolt URL:       bolt://${IP%/*}:7687"
echo -e "  Username:       neo4j"
echo -e "  Password:       (as set)"
echo ""
echo -e "  Graph updater service: daws-neo4j-updater"
echo -e "  Consumes from RabbitMQ, builds device/point graph"
echo ""
echo -e "  To access the container:"
echo -e "    pct enter ${CT_ID}"
echo -e "${GREEN}============================================${NC}"
