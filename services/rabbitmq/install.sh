#!/bin/bash
# =============================================================================
# services/rabbitmq/install.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs on your Proxmox HOST (not inside a container).
# It creates a new LXC container and installs RabbitMQ inside it.
#
# HOW TO RUN IT:
# On your Proxmox host shell, run:
#   bash -c "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/rabbitmq/install.sh)"
#
# WHAT IS RABBITMQ?
# RabbitMQ is the central message broker for DAWS_BAS.
# Every piece of data from every field device flows through it.
# Think of it as the post office for your building automation data:
#   - Protocol Gateway delivers messages TO RabbitMQ
#   - Telegraf, Neo4j, and the Web UI pick up messages FROM RabbitMQ
#
# WHAT PORTS DOES IT USE?
#   5672  → AMQP protocol port (what services connect to for messaging)
#   15672 → Management web UI (open in browser to see queues, messages, etc.)
#
# WHAT WILL THIS SCRIPT DO?
#   1. Show a welcome message
#   2. Ask you for configuration settings via dialog boxes (whiptail)
#   3. Download the Ubuntu 22.04 LXC template if not already present
#   4. Create a new LXC container with your settings
#   5. Write environment variables into the container
#   6. Download and run setup.sh inside the container to install RabbitMQ
#   7. Print a summary with URLs and credentials
#
# =============================================================================

# "set -e" means: stop the script immediately if any command fails
# Without this, the script would keep running even after an error,
# which could leave things in a broken state
set -e

# Define color codes for terminal output
# These are ANSI escape codes that change text color in the terminal
# \033[0;31m = red, \033[0;32m = green, \033[1;33m = yellow, \033[0m = reset to default
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'    # NC = No Color (resets to default)

# Check that this script is being run on a Proxmox host
# "command -v pct" checks if the "pct" command exists
# pct is the Proxmox Container Toolkit command - only exists on Proxmox hosts
# "&> /dev/null" silences any output from the check
if ! command -v pct &> /dev/null; then
    echo -e "${RED}Error: This script must be run on a Proxmox host.${NC}"
    echo -e "${RED}The 'pct' command was not found.${NC}"
    exit 1  # Exit with error code 1
fi

# =============================================================================
# WHIPTAIL DIALOG BOXES
# whiptail is a text-based UI tool that shows dialog boxes in the terminal.
# It is pre-installed on Proxmox and most Debian/Ubuntu systems.
# Each line below shows one dialog box and saves the user's input to a variable.
#
# The "3>&1 1>&2 2>&3" at the end of each whiptail command is a file descriptor
# trick that captures the dialog output into a variable:
#   - Normally: stdin(0), stdout(1), stderr(2)
#   - whiptail puts its result on stderr (2), not stdout (1)
#   - This redirection swaps them so we can capture it with $()
# =============================================================================

# Show an introduction message box (just informational, no input needed)
whiptail --title "DAWS_BAS — RabbitMQ Installer" \
    --msgbox "This installer will create a Proxmox LXC and install RabbitMQ.\n\nRabbitMQ is the message broker at the core of DAWS_BAS.\nAll protocol data from field devices flows through it.\n\nManagement web UI will be available on port 15672 after install.\n\nPress OK to continue and configure your settings." 15 65

# Ask for the LXC Container ID (CT ID)
# This is the unique numeric ID Proxmox uses to identify each container
# Proxmox containers start at 100 by default; we suggest 113 for RabbitMQ
CT_ID=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Proxmox Container ID (CT ID):\nMust be unique on your Proxmox server." \
    9 50 "113" \
    3>&1 1>&2 2>&3)

# Ask for the container hostname
# This becomes the container's hostname and shows in Proxmox's web UI
HOSTNAME=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Container hostname:" \
    8 50 "daws-rabbitmq" \
    3>&1 1>&2 2>&3)

# Ask for the static IP address in CIDR notation
# CIDR notation includes the subnet mask: 192.168.30.13/24
# /24 means the subnet mask is 255.255.255.0
IP=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Static IP address (CIDR format):\nExample: 192.168.30.13/24" \
    9 50 "192.168.30.13/24" \
    3>&1 1>&2 2>&3)

# Ask for the default gateway (your router's IP)
GATEWAY=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Default gateway (your router IP):" \
    8 50 "192.168.30.1" \
    3>&1 1>&2 2>&3)

# Ask for the VLAN tag
# If your BAS network is on VLAN 30, set this to 30
# Leave blank if you don't use VLANs
VLAN=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "VLAN tag (leave blank if not using VLANs):" \
    8 50 "30" \
    3>&1 1>&2 2>&3)

# Ask which Proxmox storage pool to use for the container's disk
# "local-lvm" is the default on most Proxmox installations
STORAGE=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Proxmox storage pool for container disk:" \
    8 50 "local-lvm" \
    3>&1 1>&2 2>&3)

# Ask which network bridge to attach the container to
# "vmbr0" is the default bridge on most Proxmox installations
BRIDGE=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "Proxmox network bridge:" \
    8 50 "vmbr0" \
    3>&1 1>&2 2>&3)

# Ask for the RabbitMQ admin username to create
MQ_USER=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "RabbitMQ admin username to create:" \
    8 50 "daws" \
    3>&1 1>&2 2>&3)

# Ask for the RabbitMQ password
# --passwordbox hides the input (shows asterisks instead of characters)
MQ_PASS=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --passwordbox "RabbitMQ admin password:" \
    8 50 \
    3>&1 1>&2 2>&3)

# Ask for the RabbitMQ virtual host name
# Virtual hosts let you run multiple isolated RabbitMQ environments on one server
# We use "bas" to keep DAWS_BAS messages separate from anything else
MQ_VHOST=$(whiptail \
    --title "DAWS_BAS — RabbitMQ" \
    --inputbox "RabbitMQ virtual host name:" \
    8 50 "bas" \
    3>&1 1>&2 2>&3)

# Show a confirmation dialog with all settings before proceeding
# The user can press No to cancel without making any changes
whiptail --title "DAWS_BAS — Confirm Settings" --yesno \
"Please review your settings:

  CT ID:       $CT_ID
  Hostname:    $HOSTNAME
  IP Address:  $IP
  Gateway:     $GATEWAY
  VLAN Tag:    $VLAN
  Storage:     $STORAGE
  Bridge:      $BRIDGE
  MQ User:     $MQ_USER
  MQ VHost:    $MQ_VHOST

Press Yes to create the container, No to cancel." 22 55

# =============================================================================
# DOWNLOAD LXC TEMPLATE IF NEEDED
# Proxmox LXC containers are built from templates (pre-built OS images).
# We use Ubuntu 22.04 LTS (Jammy Jellyfish) as our base OS.
# =============================================================================
echo -e "${YELLOW}Checking for Ubuntu 22.04 LXC template...${NC}"

# Check if we already have a Ubuntu 22.04 template downloaded
# "pveam list local" lists all templates on local storage
# "grep -q" does a quiet search (no output), returns 0 if found, 1 if not found
if ! pveam list local | grep -q "ubuntu-22.04"; then
    echo -e "${YELLOW}Template not found. Downloading Ubuntu 22.04...${NC}"
    pveam update  # Refresh the template list from the internet
    pveam download local ubuntu-22.04-standard_22.04-1_amd64.tar.zst
fi

# Get the full template path (needed for pct create below)
# "awk '{print $1}'" extracts just the first column (the template path)
# "head -1" takes just the first result in case there are multiple matches
TEMPLATE=$(pveam list local | grep "ubuntu-22.04" | awk '{print $1}' | head -1)
echo -e "${GREEN}Using template: $TEMPLATE${NC}"

# =============================================================================
# BUILD THE NETWORK CONFIGURATION STRING
# Proxmox's pct create command takes network settings as a comma-separated string
# =============================================================================

# Start with the base network config
NET_CONFIG="name=eth0,bridge=${BRIDGE},ip=${IP},gw=${GATEWAY}"

# Add VLAN tag if one was specified
# "-n" means "string is not empty"
[ -n "$VLAN" ] && NET_CONFIG="${NET_CONFIG},tag=${VLAN}"

# =============================================================================
# CREATE THE LXC CONTAINER
# pct create is the Proxmox command to create a new container
# =============================================================================
echo -e "${YELLOW}Creating LXC container ${CT_ID}...${NC}"

pct create $CT_ID $TEMPLATE \
    --hostname $HOSTNAME \
    --storage $STORAGE \
    --rootfs ${STORAGE}:4 \
    --memory 1024 \
    --cores 2 \
    --net0 $NET_CONFIG \
    --unprivileged 1 \
    --features nesting=1 \
    --start 1 \
    --onboot 1

# Wait for the container to fully start before running commands inside it
echo -e "${YELLOW}Waiting for container to start...${NC}"
sleep 5

# =============================================================================
# WRITE ENVIRONMENT VARIABLES INTO THE CONTAINER
# These variables are read by setup.sh and by the RabbitMQ service
# /etc/environment is loaded for all users and sessions on Linux
# =============================================================================
echo -e "${YELLOW}Writing configuration to container...${NC}"

# "pct exec $CT_ID -- bash -c '...'" runs a command inside the container
# The ">>" appends to the file (doesn't overwrite it)
pct exec $CT_ID -- bash -c "echo 'RABBITMQ_USER=${MQ_USER}'   >> /etc/environment"
pct exec $CT_ID -- bash -c "echo 'RABBITMQ_PASS=${MQ_PASS}'   >> /etc/environment"
pct exec $CT_ID -- bash -c "echo 'RABBITMQ_VHOST=${MQ_VHOST}' >> /etc/environment"

# =============================================================================
# RUN SETUP SCRIPT INSIDE THE CONTAINER
# Download setup.sh from GitHub and run it directly inside the container
# setup.sh handles the actual RabbitMQ installation and configuration
# =============================================================================
echo -e "${YELLOW}Running RabbitMQ setup inside container...${NC}"

pct exec $CT_ID -- bash -c \
    "$(wget -qLO - https://raw.githubusercontent.com/DawsonFinnie/DAWS_BAS/main/services/rabbitmq/setup.sh)"

# =============================================================================
# DONE - Print summary
# ${IP%/*} removes the subnet mask: "192.168.30.13/24" → "192.168.30.13"
# The % is a bash parameter expansion that strips the shortest match of /* from the end
# =============================================================================
echo -e "${GREEN}"
echo "============================================"
echo "  DAWS_BAS — RabbitMQ Installation Complete"
echo "============================================"
echo -e "${NC}"
echo -e "  Management UI:  http://${IP%/*}:15672"
echo -e "  AMQP Port:      ${IP%/*}:5672"
echo -e "  Username:       ${MQ_USER}"
echo -e "  Virtual Host:   ${MQ_VHOST}"
echo ""
echo -e "  To access the container:"
echo -e "    pct enter ${CT_ID}"
echo ""
echo -e "  To check RabbitMQ status:"
echo -e "    pct exec ${CT_ID} -- systemctl status rabbitmq-server"
echo -e "${GREEN}============================================${NC}"
