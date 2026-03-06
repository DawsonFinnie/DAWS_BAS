#!/bin/bash
# =============================================================================
# services/rabbitmq/setup.sh
# =============================================================================
#
# WHAT IS THIS FILE?
# This script runs INSIDE the RabbitMQ LXC container.
# It is called automatically by install.sh after the container is created.
#
# WHAT DOES IT DO?
#   1. Fixes locale warnings
#   2. Installs prerequisites
#   3. Adds the official RabbitMQ + Erlang repositories via Cloudsmith
#      (RabbitMQ's current recommended install method as of 2024/2025)
#   4. Installs a compatible Erlang version and RabbitMQ server
#   5. Enables the management web UI plugin
#   6. Starts RabbitMQ and enables it on boot
#   7. Creates the DAWS_BAS user, virtual host, and permissions
#   8. Removes the default insecure guest user
#
# WHY CLOUDSMITH?
# RabbitMQ's official documentation now recommends using their Cloudsmith
# hosted repositories instead of packagecloud.io (which is deprecated)
# or Erlang Solutions (which has reliability issues).
# Cloudsmith provides both the correct Erlang version and RabbitMQ together,
# ensuring compatibility between them.
#
# Reference: https://www.rabbitmq.com/docs/install-debian
#
# =============================================================================

set -e

echo "============================================"
echo "  DAWS_BAS — RabbitMQ Setup"
echo "============================================"


# =============================================================================
# STEP 0: Fix locale warnings
# Fresh Ubuntu LXC templates are missing locale configuration.
# This causes harmless but noisy "perl: warning: Setting locale failed" messages.
# We fix it before anything else so all subsequent output is clean.
# =============================================================================
echo "Step 0/5: Fixing locale configuration..."

apt-get install -y -qq locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install prerequisite packages
# curl    - downloads files and GPG keys from URLs
# gnupg   - handles GPG key operations for package verification
# apt-transport-https - allows apt to use HTTPS repository URLs
# =============================================================================
echo "Step 1/5: Installing prerequisites..."

apt-get update -qq
apt-get install -y -qq curl gnupg apt-transport-https


# =============================================================================
# STEP 2: Add Cloudsmith repositories for Erlang and RabbitMQ
#
# RabbitMQ's official recommended install method uses two Cloudsmith repos:
#   1. rabbitmq/rabbitmq-erlang  - provides a compatible Erlang version
#   2. rabbitmq/rabbitmq-server  - provides RabbitMQ itself
#
# This ensures the Erlang and RabbitMQ versions are always compatible with
# each other, which is the most common source of installation failures.
#
# GPG KEY VERIFICATION:
# Each repo's signing key is downloaded and stored in /usr/share/keyrings/
# The apt source entry references the key with [signed-by=...] so apt can
# verify packages haven't been tampered with.
# This is the modern replacement for the deprecated "apt-key add" method.
# =============================================================================
echo "Step 2/5: Adding Cloudsmith Erlang and RabbitMQ repositories..."

# Create keyrings directory if it doesn't exist
mkdir -p /usr/share/keyrings

# --- Erlang (from RabbitMQ's Cloudsmith repo) ---
# This gives us a Erlang version that is tested and compatible with RabbitMQ
curl -fsSL https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-erlang/gpg.E495BB49CC4BBE5B.key \
    | gpg --dearmor -o /usr/share/keyrings/rabbitmq-erlang.gpg

echo "deb [signed-by=/usr/share/keyrings/rabbitmq-erlang.gpg] https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-erlang/deb/ubuntu jammy main" \
    > /etc/apt/sources.list.d/rabbitmq-erlang.list

# --- RabbitMQ server (from RabbitMQ's Cloudsmith repo) ---
curl -fsSL https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-server/gpg.9F4587F226208342.key \
    | gpg --dearmor -o /usr/share/keyrings/rabbitmq-server.gpg

echo "deb [signed-by=/usr/share/keyrings/rabbitmq-server.gpg] https://dl.cloudsmith.io/public/rabbitmq/rabbitmq-server/deb/ubuntu jammy main" \
    > /etc/apt/sources.list.d/rabbitmq-server.list

# Refresh package list with the new repos
apt-get update -qq


# =============================================================================
# STEP 3: Install Erlang and RabbitMQ
#
# We install erlang-base and the specific Erlang modules RabbitMQ needs.
# Installing only what's required keeps the container lean.
#
# Key modules:
#   erlang-base         - Core Erlang runtime
#   erlang-crypto       - Cryptography (TLS connections)
#   erlang-ssl          - SSL/TLS support
#   erlang-mnesia       - Database engine used by RabbitMQ internally
#   erlang-os-mon       - OS monitoring for RabbitMQ resource alarms
#   erlang-public-key   - Certificate handling
#   erlang-asn1         - ASN.1 support (needed for certificates)
#   erlang-inets        - HTTP client (used by management plugin)
#   erlang-xmerl        - XML processing
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

apt-get install -y rabbitmq-server


# =============================================================================
# STEP 4: Enable the Management Plugin and start the service
#
# The management plugin adds a web UI on port 15672.
# Open http://192.168.30.13:15672 in your browser to:
#   - See all exchanges and queues
#   - Watch message rates in real time
#   - See which consumers (Telegraf, etc.) are connected
#   - Monitor broker memory and disk usage
# =============================================================================
echo "Step 4/5: Enabling management plugin and starting RabbitMQ..."

rabbitmq-plugins enable rabbitmq_management

# Start automatically on boot
systemctl enable rabbitmq-server

# Start now
systemctl start rabbitmq-server

# Wait for full initialization before running rabbitmqctl commands
# Running too soon causes "node not running" errors
echo "Waiting for RabbitMQ to initialize..."
sleep 5


# =============================================================================
# STEP 5: Configure users, virtual host, and permissions
# =============================================================================
echo "Step 5/5: Configuring users and virtual host..."

# Load environment variables set by install.sh
# Provides: RABBITMQ_USER, RABBITMQ_PASS, RABBITMQ_VHOST
source /etc/environment

# Create the DAWS admin user
rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
echo "  Created user: $RABBITMQ_USER"

# Create the virtual host — an isolated namespace for DAWS_BAS messages
rabbitmqctl add_vhost "$RABBITMQ_VHOST"
echo "  Created virtual host: $RABBITMQ_VHOST"

# Grant administrator tag — gives full management UI access
rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
echo "  Granted administrator role to: $RABBITMQ_USER"

# Set full permissions on the virtual host
# ".*" = allow all configure, write, and read operations
rabbitmqctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" ".*" ".*" ".*"
echo "  Set full permissions on /$RABBITMQ_VHOST for $RABBITMQ_USER"

# Remove the default guest/guest user — a well-known security risk
# "|| true" prevents failure if guest was already removed
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
systemctl status rabbitmq-server --no-pager
