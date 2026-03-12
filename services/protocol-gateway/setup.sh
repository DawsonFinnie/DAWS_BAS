#!/bin/bash
# =============================================================================
# services/protocol-gateway/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs INSIDE the Protocol Gateway LXC container (CT 118).
# It installs Python, clones the DAWS_BAS gateway code, installs its
# dependencies, and sets up a systemd service to keep it running.
#
# WHAT IS A PYTHON VIRTUAL ENVIRONMENT?
# A virtual environment (venv) is an isolated Python installation.
# Instead of installing packages system-wide (which can break things),
# we install them into /opt/daws-gateway/venv — a self-contained folder.
# This means:
#   - The gateway's packages don't conflict with system Python packages
#   - We can install exact pinned versions without affecting anything else
#   - Deleting /opt/daws-gateway removes everything cleanly
#
# WHAT IS SYSTEMD?
# systemd is Linux's service manager. It starts services automatically
# at boot, restarts them if they crash, and manages their logs.
# We create a systemd unit file that tells systemd how to run the gateway.
#
# WHY BAC0 NEEDS SPECIAL SETUP:
# BAC0 uses UDP broadcasts on port 47808 (the standard BACnet port).
# In an LXC container, Python needs permission to bind to UDP ports.
# We handle this by running the service as root (acceptable for a lab).
# In production, you'd use setcap to grant just the needed permissions.
#
# =============================================================================

set -e

echo "============================================"
echo "  DAWS_BAS — Protocol Gateway Setup"
echo "============================================"

# Load environment variables written by install.sh
source /etc/environment


# =============================================================================
# STEP 0: Fix locale
# =============================================================================
echo "Step 0/5: Fixing locale..."
apt-get install -y -qq locales > /dev/null 2>&1
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install system dependencies
#
# python3-pip  — pip package manager for Python
# python3-venv — virtual environment support
# python3-dev  — Python header files needed to compile some packages
# build-essential — C compiler, needed for some Python packages that have C extensions
# git          — to clone the gateway code from GitHub
# libffi-dev   — Foreign Function Interface library (needed by some crypto packages)
# libssl-dev   — SSL library headers (needed for secure connections)
# =============================================================================
echo "Step 1/5: Installing system dependencies..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    python3-pip \
    python3-venv \
    python3-dev \
    build-essential \
    git \
    libffi-dev \
    libssl-dev > /dev/null


# =============================================================================
# STEP 2: Clone the DAWS_BAS gateway code
#
# We clone just the gateway service directory from the DAWS_BAS repo.
# The gateway lives at /opt/daws-gateway on the container.
#
# WHY /opt?
# /opt is the standard Linux location for optional/add-on software
# (as opposed to /usr/local for user-installed tools or /home for user data)
# =============================================================================
echo "Step 2/5: Cloning gateway code..."

if [ -d "/opt/daws-gateway" ]; then
    echo "  Updating existing installation..."
    git -C /opt/daws-gateway pull
else
    echo "  Fresh install..."
    # Clone only the protocol-gateway subdirectory using sparse checkout
    # This avoids downloading the entire DAWS_BAS repo (Grafana files, docs, etc.)
    git clone \
        --depth 1 \
        --filter=blob:none \
        --sparse \
        https://github.com/DawsonFinnie/DAWS_BAS.git \
        /opt/daws-gateway

    git -C /opt/daws-gateway sparse-checkout set services/protocol-gateway
fi

# The actual gateway code is inside the cloned directory
GATEWAY_SRC="/opt/daws-gateway/services/protocol-gateway"


# =============================================================================
# STEP 3: Create Python virtual environment and install packages
#
# pip install -r requirements.txt reads the requirements.txt file and
# installs every package listed at the exact pinned version.
#
# This takes a few minutes — BAC0 and its dependencies are fairly large
# because they include the full BACnet protocol stack.
# =============================================================================
echo "Step 3/5: Creating Python virtual environment and installing packages..."
echo "  (This may take 3-5 minutes — BAC0 is a large package)"

python3 -m venv /opt/daws-gateway/venv

# Upgrade pip first — older pip versions sometimes fail on newer packages
/opt/daws-gateway/venv/bin/pip install --upgrade pip --quiet

# Install all gateway dependencies
/opt/daws-gateway/venv/bin/pip install \
    -r ${GATEWAY_SRC}/requirements.txt \
    --quiet

echo "  Packages installed successfully"


# =============================================================================
# STEP 4: Create the systemd service unit file
#
# A systemd unit file is a configuration file that tells systemd:
#   - What command to run (ExecStart)
#   - What user to run it as (User)
#   - What environment variables to load (EnvironmentFile)
#   - When to start it (WantedBy=multi-user.target = at normal boot)
#   - What to do if it crashes (Restart=on-failure)
#
# After = network.target means systemd waits for the network to be up
# before starting the gateway. This prevents the gateway from starting
# before it can reach RabbitMQ.
# =============================================================================
echo "Step 4/5: Creating systemd service..."

cat > /etc/systemd/system/daws-gateway.service << 'SERVICE_EOF'
[Unit]
Description=DAWS_BAS Protocol Gateway
Documentation=https://github.com/DawsonFinnie/DAWS_BAS
# Wait for network before starting — gateway needs to reach RabbitMQ
After=network.target
# Restart automatically if RabbitMQ isn't ready yet at boot
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple

# Load environment variables from /etc/environment
# This is where install.sh wrote RABBITMQ_PASS, BACNET_NETWORK, etc.
EnvironmentFile=/etc/environment

# Working directory — where the gateway code lives
WorkingDirectory=/opt/daws-gateway/services/protocol-gateway

# The command to start the gateway
# -m gateway.main means "run the main() function in gateway/main.py as a module"
# This is the correct way to run a Python package (vs python gateway/main.py)
ExecStart=/opt/daws-gateway/venv/bin/python -m gateway.main

# Restart the service if it exits with an error
# on-failure = restart on non-zero exit code or signal
# This handles: RabbitMQ not available yet, temporary network errors
Restart=on-failure
RestartSec=10

# Log to systemd journal (viewable with: journalctl -u daws-gateway)
StandardOutput=journal
StandardError=journal
SyslogIdentifier=daws-gateway

[Install]
# Start this service at normal boot (multi-user = standard Linux runlevel)
WantedBy=multi-user.target
SERVICE_EOF


# =============================================================================
# STEP 5: Enable and start the service
# =============================================================================
echo "Step 5/5: Starting gateway service..."

systemctl daemon-reload
systemctl enable daws-gateway
systemctl start daws-gateway

# Give it a moment to start up
sleep 5

# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  Protocol Gateway setup complete!"
echo "============================================"
echo ""

systemctl status daws-gateway --no-pager

echo ""
echo "  To follow live logs:"
echo "    journalctl -u daws-gateway -f"
echo ""
echo "  To check what BACnet devices were found:"
echo "    journalctl -u daws-gateway | grep -i 'found\|device\|bacnet'"
