#!/bin/bash
# =============================================================================
# services/rabbitmq/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs INSIDE the RabbitMQ LXC container.
# It is called automatically by install.sh after the container is created.
# You should not need to run this manually.
#
# WHAT DOES IT DO?
#   1. Fixes locale warnings (cosmetic but annoying without this)
#   2. Installs prerequisite packages
#   3. Adds the official Erlang repository
#   4. Adds the official RabbitMQ repository
#   5. Installs Erlang (required by RabbitMQ) and RabbitMQ server
#   6. Enables the management web UI plugin
#   7. Starts RabbitMQ and enables it to start on boot
#   8. Creates the DAWS_BAS user, virtual host, and permissions
#   9. Removes the default insecure "guest" user
#
# WHY DO WE INSTALL ERLANG SEPARATELY?
# RabbitMQ is written in Erlang, so Erlang must be installed first.
# Ubuntu's default apt repository has an older version of Erlang that is
# not compatible with recent RabbitMQ versions.
# We add the official Erlang Solutions repository to get a compatible version.
#
# WHY THE NEW REPO METHOD?
# The old method used "apt-key add" and packagecloud.io which are both
# deprecated. The modern approach uses "gpg --dearmor" to store keys in
# /usr/share/keyrings/ and references them with [signed-by=...] in the
# apt source list. This is the currently recommended method.
#
# =============================================================================

# Stop the script immediately if any command fails
set -e

echo "============================================"
echo "  DAWS_BAS — RabbitMQ Setup"
echo "============================================"


# =============================================================================
# STEP 0: Fix locale warnings
# The fresh Ubuntu LXC template is missing locale configuration.
# Without this, many commands print warnings like:
#   "perl: warning: Setting locale failed"
# These are harmless but noisy. This step silences them.
# =============================================================================
echo "Step 0/5: Fixing locale configuration..."

apt-get install -y -qq locales

# locale-gen generates the locale files for en_US.UTF-8
# UTF-8 is the standard character encoding that supports all languages
locale-gen en_US.UTF-8

# Set the system default locale
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install prerequisite packages
# These are needed to add new repositories and download their signing keys
# =============================================================================
echo "Step 1/5: Installing prerequisites..."

apt-get update -qq

# curl               - downloads files from URLs (used to fetch GPG keys)
# gnupg              - GNU Privacy Guard - handles GPG key operations
# apt-transport-https - allows apt to fetch packages over HTTPS connections
apt-get install -y -qq curl gnupg apt-transport-https


# =============================================================================
# STEP 2: Add official Erlang and RabbitMQ repositories
#
# WHY TWO REPOSITORIES?
# RabbitMQ is written in the Erlang programming language, so Erlang must be
# installed before RabbitMQ. Ubuntu's built-in Erlang version is often too old
# for the latest RabbitMQ, so we add the official Erlang Solutions repo.
#
# HOW GPG KEY VERIFICATION WORKS:
# Each repository has a GPG signing key. When apt downloads packages,
# it verifies the package was signed by that key — this proves the package
# is genuine and hasn't been tampered with.
#
# The modern method:
#   1. Download the key with curl
#   2. Convert it to binary format with "gpg --dearmor"
#   3. Save it to /usr/share/keyrings/
#   4. Reference it in the apt source line with [signed-by=path/to/key.gpg]
#
# This replaces the old "apt-key add" method which is now deprecated.
# =============================================================================
echo "Step 2/5: Adding Erlang and RabbitMQ repositories..."

# --- Erlang repository ---
# Download the Erlang Solutions GPG key and convert it to binary (.gpg) format
# curl -fsSL = fetch silently, follow redirects, fail on HTTP errors
# | gpg --dearmor = pipe the key through gpg to convert from ASCII to binary
# -o = write output to this file path
curl -fsSL https://packages.erlang-solutions.com/ubuntu/erlang_solutions.asc \
    | gpg --dearmor -o /usr/share/keyrings/erlang.gpg

# Add the Erlang apt source, referencing the key we just saved
# [signed-by=...] tells apt which key to use to verify packages from this source
# "jammy" is the Ubuntu 22.04 codename
echo "deb [signed-by=/usr/share/keyrings/erlang.gpg] https://packages.erlang-solutions.com/ubuntu jammy contrib" \
    > /etc/apt/sources.list.d/erlang.list

# --- RabbitMQ repository ---
# Download the RabbitMQ GPG key (identified by its fingerprint)
curl -fsSL https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA \
    | gpg --dearmor -o /usr/share/keyrings/rabbitmq.gpg

# Add the RabbitMQ apt source
echo "deb [signed-by=/usr/share/keyrings/rabbitmq.gpg] https://ppa1.rabbitmq.com/rabbitmq/rabbitmq-server/deb/ubuntu jammy main" \
    > /etc/apt/sources.list.d/rabbitmq.list

# Refresh the package list now that we have the new repositories
apt-get update -qq


# =============================================================================
# STEP 3: Install Erlang and RabbitMQ
#
# WHY SO MANY ERLANG PACKAGES?
# Erlang is modular — split into many sub-packages, each providing different
# functionality. RabbitMQ requires specific modules to be present.
# Installing them explicitly ensures compatibility:
#
#   erlang-base         - Core Erlang runtime
#   erlang-crypto       - Cryptography (for TLS/SSL connections)
#   erlang-public-key   - Public key infrastructure (for certificates)
#   erlang-ssl          - SSL/TLS support
#   erlang-mnesia       - Database engine (RabbitMQ uses this internally)
#   erlang-os-mon       - OS monitoring (for RabbitMQ resource alarms)
#   erlang-tools        - Development tools
#   ... and others required by RabbitMQ features
# =============================================================================
echo "Step 3/5: Installing Erlang and RabbitMQ server..."

apt-get install -y \
    erlang-base \
    erlang-asn1 \
    erlang-crypto \
    erlang-eldap \
    erlang-ftp \
    erlang-inets \
    erlang-mnesia \
    erlang-os-mon \
    erlang-parsetools \
    erlang-public-key \
    erlang-runtime-tools \
    erlang-snmp \
    erlang-ssl \
    erlang-syntax-tools \
    erlang-tftp \
    erlang-tools \
    erlang-xmerl

# Now install RabbitMQ itself
# Erlang is already installed so RabbitMQ can find its dependency
apt-get install -y rabbitmq-server


# =============================================================================
# STEP 4: Enable the Management Plugin
# The management plugin adds a web UI on port 15672.
# It shows queues, exchanges, message rates, connected consumers,
# and broker memory/disk usage — essential for debugging DAWS_BAS.
# =============================================================================
echo "Step 4/5: Enabling RabbitMQ management web UI..."

rabbitmq-plugins enable rabbitmq_management

# Enable RabbitMQ to start automatically when the LXC boots
systemctl enable rabbitmq-server

# Start RabbitMQ now
systemctl start rabbitmq-server

# Wait for RabbitMQ to fully initialize before running configuration commands
# Running rabbitmqctl too soon after start causes "node not running" errors
echo "Waiting for RabbitMQ to initialize..."
sleep 5


# =============================================================================
# STEP 5: Configure users, virtual host, and permissions
# =============================================================================
echo "Step 5/5: Configuring RabbitMQ users and virtual host..."

# Load the environment variables written by install.sh into /etc/environment
# We need: RABBITMQ_USER, RABBITMQ_PASS, RABBITMQ_VHOST
source /etc/environment

# Create the DAWS admin user
# rabbitmqctl is RabbitMQ's command-line management tool
rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
echo "  Created user: $RABBITMQ_USER"

# Create the virtual host for DAWS_BAS
# Virtual hosts are isolated messaging namespaces within one RabbitMQ server
# Using a dedicated vhost keeps DAWS_BAS traffic separate from anything else
rabbitmqctl add_vhost "$RABBITMQ_VHOST"
echo "  Created virtual host: $RABBITMQ_VHOST"

# Grant administrator tag — gives full access to the management web UI
rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
echo "  Granted administrator role to: $RABBITMQ_USER"

# Set full permissions on our virtual host for our user
# Format: set_permissions -p <vhost> <user> <configure> <write> <read>
# ".*" means "allow all" for each permission category
rabbitmqctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" ".*" ".*" ".*"
echo "  Set full permissions on /$RABBITMQ_VHOST for $RABBITMQ_USER"

# Delete the default guest user — guest/guest is a well-known security risk
# "|| true" means: don't fail if guest was already deleted
rabbitmqctl delete_user guest || true
echo "  Removed default guest user"


# =============================================================================
# DONE
# =============================================================================
echo ""
echo "============================================"
echo "  RabbitMQ setup complete!"
echo "============================================"
echo ""

# Print service status to confirm everything is running
# "--no-pager" prevents systemctl from opening an interactive pager
systemctl status rabbitmq-server --no-pager
