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
#   1. Installs prerequisite packages (curl, gnupg, etc.)
#   2. Adds the official RabbitMQ package repository
#   3. Installs RabbitMQ server
#   4. Enables the management web UI plugin
#   5. Starts RabbitMQ and enables it to start on boot
#   6. Creates the DAWS_BAS user, virtual host, and permissions
#   7. Removes the default insecure "guest" user
#
# WHY DO WE ADD THE OFFICIAL REPO INSTEAD OF USING APT DIRECTLY?
# Ubuntu's default apt repository often has older versions of RabbitMQ.
# We add RabbitMQ's official packagecloud.io repository to get the latest
# stable version with current security patches.
#
# =============================================================================

# Stop the script immediately if any command fails
# This prevents partial installations that could be hard to debug
set -e

echo "============================================"
echo "  DAWS_BAS — RabbitMQ Setup"
echo "============================================"

# =============================================================================
# STEP 1: Install prerequisite packages
# These are needed to add the RabbitMQ repository and download its packages
# =============================================================================
echo "Step 1/5: Installing prerequisites..."

# "apt-get update -qq" refreshes the package list quietly (-qq = very quiet)
apt-get update -qq

# Install required packages:
#   curl                    - Command-line tool to download files over HTTP
#   gnupg                   - GNU Privacy Guard - for verifying package signatures
#   debian-keyring          - Debian's GPG keys
#   debian-archive-keyring  - Additional Debian archive keys
#   apt-transport-https     - Allows apt to download packages over HTTPS
apt-get install -y -qq \
    curl \
    gnupg \
    debian-keyring \
    debian-archive-keyring \
    apt-transport-https

# =============================================================================
# STEP 2: Add the official RabbitMQ package repository
# This gives us access to the latest RabbitMQ version
# =============================================================================
echo "Step 2/5: Adding RabbitMQ official repository..."

# Download RabbitMQ's GPG signing key and add it to apt's trusted keys
# The GPG key allows apt to verify that packages are genuinely from RabbitMQ
# and haven't been tampered with
curl -fsSL https://packagecloud.io/rabbitmq/rabbitmq-server/gpgkey | apt-key add -

# Add the RabbitMQ repository to apt's source list
# "jammy" is the Ubuntu 22.04 codename
# ">" overwrites the file (creates it fresh)
echo "deb https://packagecloud.io/rabbitmq/rabbitmq-server/ubuntu/ jammy main" \
    > /etc/apt/sources.list.d/rabbitmq.list

# Refresh the package list now that we've added the new repository
apt-get update -qq

# =============================================================================
# STEP 3: Install RabbitMQ
# =============================================================================
echo "Step 3/5: Installing RabbitMQ server..."

apt-get install -y -qq rabbitmq-server

# =============================================================================
# STEP 4: Enable the Management Plugin
# The management plugin adds a web UI on port 15672
# It lets you see queues, exchanges, message rates, and connected consumers
# This is very useful for debugging your DAWS_BAS setup
# =============================================================================
echo "Step 4/5: Enabling RabbitMQ management web UI..."

rabbitmq-plugins enable rabbitmq_management

# Enable RabbitMQ to start automatically when the container boots
systemctl enable rabbitmq-server

# Start RabbitMQ now
systemctl start rabbitmq-server

# Wait 5 seconds for RabbitMQ to fully initialize before we try to configure it
# If we try to run rabbitmqctl commands too quickly, RabbitMQ may not be ready yet
echo "Waiting for RabbitMQ to initialize..."
sleep 5

# =============================================================================
# STEP 5: Configure users, virtual host, and permissions
# =============================================================================
echo "Step 5/5: Configuring RabbitMQ users and virtual host..."

# Load the environment variables that install.sh wrote to /etc/environment
# "source" executes the file in the current shell so the variables become available
# The variables we need: RABBITMQ_USER, RABBITMQ_PASS, RABBITMQ_VHOST
source /etc/environment

# Create the DAWS admin user
# rabbitmqctl is RabbitMQ's command-line management tool
rabbitmqctl add_user "$RABBITMQ_USER" "$RABBITMQ_PASS"
echo "  Created user: $RABBITMQ_USER"

# Create the virtual host for DAWS_BAS
# Virtual hosts are isolated messaging environments within one RabbitMQ server
# Using "bas" as our vhost keeps DAWS_BAS data separate from anything else
rabbitmqctl add_vhost "$RABBITMQ_VHOST"
echo "  Created virtual host: $RABBITMQ_VHOST"

# Grant the user administrator privileges
# The "administrator" tag gives full access to the management UI and all operations
rabbitmqctl set_user_tags "$RABBITMQ_USER" administrator
echo "  Granted administrator role to: $RABBITMQ_USER"

# Set full permissions on the virtual host for our user
# rabbitmqctl set_permissions -p <vhost> <user> <configure> <write> <read>
# ".*" means "all resources" for each permission type
#   configure = can create/delete exchanges and queues
#   write     = can publish messages
#   read      = can consume messages
rabbitmqctl set_permissions -p "$RABBITMQ_VHOST" "$RABBITMQ_USER" ".*" ".*" ".*"
echo "  Set full permissions on /$RABBITMQ_VHOST for $RABBITMQ_USER"

# Delete the default "guest" user
# The guest user has full admin access and uses the well-known password "guest"
# It is a security risk to leave it enabled, especially on a network
# "|| true" means: if this command fails (e.g. guest already deleted), that's OK
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
echo "  Service status:"
# "--no-pager" prevents systemctl from opening a pager (like less)
# so the output just prints to the terminal normally
systemctl status rabbitmq-server --no-pager
