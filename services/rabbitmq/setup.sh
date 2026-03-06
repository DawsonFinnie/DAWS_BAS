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
#   3. Adds the official RabbitMQ repositories (deb1/deb2.rabbitmq.com)
#      using a single signing key for both Erlang and RabbitMQ
#   4. Installs a compatible Erlang version and RabbitMQ server
#   5. Enables the management web UI plugin
#   6. Starts RabbitMQ and enables it on boot
#   7. Creates the DAWS_BAS user, virtual host, and permissions
#   8. Removes the default insecure guest user
#
# REPO HISTORY (why we use this method):
#   - packagecloud.io   → deprecated, broken GPG key method
#   - Erlang Solutions  → unreliable (502 errors)
#   - Cloudsmith        → moved/renamed, 404 errors
#   - deb1/deb2.rabbitmq.com → current official method (July 2025 onwards)
#     Source: https://www.rabbitmq.com/blog/2025/07/16/debian-apt-repositories-are-moving
#
# This method uses ONE signing key for BOTH the Erlang and RabbitMQ repos,
# which simplifies setup and is maintained directly by the RabbitMQ team.
#
# =============================================================================

set -e

echo "============================================"
echo "  DAWS_BAS — RabbitMQ Setup"
echo "============================================"


# =============================================================================
# STEP 0: Fix locale warnings
# Fresh Ubuntu LXC templates are missing locale configuration.
# Without this, many commands print "perl: warning: Setting locale failed".
# These are harmless but noisy — this step silences them.
# =============================================================================
echo "Step 0/5: Fixing locale configuration..."

apt-get install -y -qq locales
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8


# =============================================================================
# STEP 1: Install prerequisite packages
#   curl                - downloads files and GPG keys from URLs
#   gnupg               - handles GPG key operations for package verification
#   apt-transport-https - allows apt to use HTTPS repository URLs
# =============================================================================
echo "Step 1/5: Installing prerequisites..."

apt-get update -qq
apt-get install -y -qq curl gnupg apt-transport-https


# =============================================================================
# STEP 2: Add the official RabbitMQ repositories
#
# RabbitMQ moved their apt repositories to deb1.rabbitmq.com and deb2.rabbitmq.com
# in July 2025. Both mirrors serve the same packages — having two listed
# means apt will try deb2 if deb1 is temporarily unavailable (redundancy).
#
# ONE signing key covers BOTH the Erlang and RabbitMQ packages.
# This is simpler than the old method which required separate keys.
#
# HOW GPG KEY VERIFICATION WORKS:
#   1. Download the signing key from keys.openpgp.org
#   2. Convert it to binary format with "gpg --dearmor"
#   3. Save to /usr/share/keyrings/ (the modern location for apt keys)
#   4. Reference it in each apt source line with [signed-by=...]
#   This replaces the deprecated "apt-key add" method.
# =============================================================================
echo "Step 2/5: Adding official RabbitMQ repositories..."

mkdir -p /usr/share/keyrings

# Download the single Team RabbitMQ signing key
# This key is used to verify BOTH the Erlang and RabbitMQ packages
# -1sLf = use HTTP/1.1, silent, follow redirects, fail on HTTP errors
# | gpg --dearmor = convert from ASCII armored to binary format
# | tee = write to the file (tee allows piping to a file as root)
# > /dev/null = suppress tee's stdout output (we only want the file)
curl -1sLf "https://keys.openpgp.org/vks/v1/by-fingerprint/0A9AF2115F4687BD29803A206B73A36E6026DFCA" \
    | gpg --dearmor \
    | tee /usr/share/keyrings/com.rabbitmq.team.gpg > /dev/null

# Write the apt sources file with both Erlang and RabbitMQ repos
# "tee" writes to the file (required when redirecting as root in scripts)
# "EOF" is a heredoc — everything between <<EOF and EOF is written as-is
# deb1 and deb2 are redundant mirrors — apt uses whichever responds first
tee /etc/apt/sources.list.d/rabbitmq.list << EOF
## Erlang/OTP releases from Team RabbitMQ
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-erlang/ubuntu/jammy jammy main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-erlang/ubuntu/jammy jammy main

## RabbitMQ server releases from Team RabbitMQ
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb1.rabbitmq.com/rabbitmq-server/ubuntu/jammy jammy main
deb [arch=amd64 signed-by=/usr/share/keyrings/com.rabbitmq.team.gpg] https://deb2.rabbitmq.com/rabbitmq-server/ubuntu/jammy jammy main
EOF

# Refresh the package list with the new repositories
apt-get update -qq


# =============================================================================
# STEP 3: Install Erlang and RabbitMQ
#
# We install specific Erlang modules rather than the full erlang meta-package
# to keep the container lean. These are exactly what RabbitMQ requires.
#
#   erlang-base         - Core Erlang runtime (required)
#   erlang-crypto       - Cryptography support for TLS connections
#   erlang-ssl          - SSL/TLS protocol implementation
#   erlang-mnesia       - Database engine used by RabbitMQ internally
#   erlang-os-mon       - OS monitoring for RabbitMQ resource alarms
#   erlang-public-key   - Certificate and public key handling
#   erlang-asn1         - ASN.1 support needed for certificates
#   erlang-inets        - HTTP client used by management plugin
#   erlang-xmerl        - XML processing
#   (others)            - Additional modules required by RabbitMQ features
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
# STEP 4: Enable Management Plugin and start service
#
# The management plugin adds a web UI on port 15672.
# Open http://192.168.30.13:15672 to:
#   - Watch messages flowing between the gateway and consumers
#   - See queue depths and message rates
#   - Monitor broker memory and disk usage
#   - Verify Telegraf and other consumers are connected
# =============================================================================
echo "Step 4/5: Enabling management plugin and starting RabbitMQ..."

rabbitmq-plugins enable rabbitmq_management

# Enable automatic start on LXC boot
systemctl enable rabbitmq-server

# Start now
systemctl start rabbitmq-server

# Wait for full initialization before running rabbitmqctl
# Starting rabbitmqctl too soon after service start causes "node not running" errors
echo "Waiting for RabbitMQ to initialize..."
sleep 5


# =============================================================================
# STEP 5: Configure users, virtual host, and permissions
# =============================================================================
echo "Step 5/5: Configuring users and virtual host..."

# Load environment variables written by install.sh into /etc/environment
# Provides: RABBITMQ_USER, RABBITMQ_PASS, RABBITMQ_VHOST
source /etc/environment

# Create the DAWS admin user
rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
echo "  Created user: $RABBITMQ_USER"

# Create the virtual host — an isolated namespace for DAWS_BAS messages
# Keeps DAWS_BAS traffic completely separate from any other RabbitMQ usage
rabbitmqctl add_vhost "$RABBITMQ_VHOST"
echo "  Created virtual host: $RABBITMQ_VHOST"

# Grant administrator tag — gives full management web UI access
rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
echo "  Granted administrator role to: $RABBITMQ_USER"

# Set full permissions on our virtual host
# Format: set_permissions -p <vhost> <user> <configure> <write> <read>
# ".*" = allow all operations in each category
rabbitmqctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" ".*" ".*" ".*"
echo "  Set full permissions on /$RABBITMQ_VHOST for $RABBITMQ_USER"

# Remove default guest/guest user — a well-known security risk on any network
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
