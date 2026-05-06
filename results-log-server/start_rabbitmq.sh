#!/bin/bash

# Results Log Server RabbitMQ Startup Script (User Mode)
# This script starts a dedicated RabbitMQ instance for the results log server as the current user

set -e  # Exit on error

# Server-specific configuration
SERVER_NAME="results-log-server"
INSTANCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NODE_NAME="results-log-server"
COOKIE_FILE="$INSTANCE_DIR/.erlang.cookie"

# Port configuration (matching rabbitmq.conf)
DIST_PORT=35673
AMQP_PORT=5673
MANAGEMENT_PORT=15673
STREAM_PORT=5553

echo "========================================="
echo "Starting RabbitMQ Server: $SERVER_NAME"
echo "Instance directory: $INSTANCE_DIR"
echo "Node name: $NODE_NAME@$(hostname -s)"
echo "Distribution port: $DIST_PORT"
echo "AMQP port: $AMQP_PORT"
echo "Management port: $MANAGEMENT_PORT"
echo "Stream port: $STREAM_PORT"
echo "========================================="

# Create required directories with user permissions
mkdir -p "$INSTANCE_DIR/rabbitmq-conf"
mkdir -p "$INSTANCE_DIR/mnesia"
mkdir -p "$INSTANCE_DIR/logs"

# Create a consistent cookie if it doesn't exist
if [ ! -f "$COOKIE_FILE" ]; then
    echo "Creating Erlang cookie for $SERVER_NAME..."
    # Generate a random cookie
    COOKIE=$(openssl rand -base64 16 | tr -d '/+=' | cut -c1-20)
    echo "$COOKIE" > "$COOKIE_FILE"
    # CRITICAL: Set correct permissions - owner read/write only, no group/other access
    chmod 400 "$COOKIE_FILE"
    echo "Cookie created at $COOKIE_FILE with correct permissions (400)"
else
    # Ensure existing cookie has correct permissions
    echo "Checking cookie file permissions..."
    CURRENT_PERMS=$(stat -f "%Lp" "$COOKIE_FILE" 2>/dev/null || stat -c "%a" "$COOKIE_FILE" 2>/dev/null)
    if [ "$CURRENT_PERMS" != "400" ] && [ "$CURRENT_PERMS" != "600" ]; then
        echo "Fixing cookie file permissions (was: $CURRENT_PERMS, should be: 400)"
        chmod 400 "$COOKIE_FILE"
    else
        echo "Cookie file permissions OK: $CURRENT_PERMS"
    fi
fi

# Export environment for this server
export RABBITMQ_CONFIG_FILE="$INSTANCE_DIR/rabbitmq-conf/rabbitmq.conf"
export RABBITMQ_ENABLED_PLUGINS_FILE="$INSTANCE_DIR/rabbitmq-conf/enabled_plugins"
export RABBITMQ_MNESIA_BASE="$INSTANCE_DIR/mnesia"
export RABBITMQ_LOG_BASE="$INSTANCE_DIR/logs"
export RABBITMQ_NODENAME="$NODE_NAME"
export RABBITMQ_DIST_PORT="$DIST_PORT"
export RABBITMQ_USE_LONGNAME="false"
export HOME="$INSTANCE_DIR"

# Define definitions file path
DEFINITIONS_FILE="$INSTANCE_DIR/rabbitmq-conf/definitions.json"

# Check if config file exists, create default if not
if [ ! -f "$RABBITMQ_CONFIG_FILE" ]; then
    echo "Creating default configuration file..."
    cat > "$RABBITMQ_CONFIG_FILE" << EOF
# Configuration for results-log-server
listeners.tcp.default = $AMQP_PORT
management.tcp.port = $MANAGEMENT_PORT
stream.listeners.tcp.1 = $STREAM_PORT
stomp.listeners.tcp = none
mqtt.listeners.tcp = none

# Other configurations
disk_free_limit.absolute = 1GB
load_definitions = $DEFINITIONS_FILE
EOF
    chmod 644 "$RABBITMQ_CONFIG_FILE"
    echo "Configuration file created: $RABBITMQ_CONFIG_FILE"
else
    # Update existing config to use correct definitions file path
    echo "Updating configuration file with correct definitions path..."
    # Create a backup
    cp "$RABBITMQ_CONFIG_FILE" "$RABBITMQ_CONFIG_FILE.bak"
    # Update or add the load_definitions line
    if grep -q "load_definitions" "$RABBITMQ_CONFIG_FILE"; then
        sed -i '' "s|load_definitions.*|load_definitions = $DEFINITIONS_FILE|" "$RABBITMQ_CONFIG_FILE"
    else
        echo "load_definitions = $DEFINITIONS_FILE" >> "$RABBITMQ_CONFIG_FILE"
    fi
fi

# Check if enabled_plugins file exists, create default if not
if [ ! -f "$RABBITMQ_ENABLED_PLUGINS_FILE" ]; then
    echo "Creating enabled_plugins file..."
    echo "[rabbitmq_management,rabbitmq_stream]." > "$RABBITMQ_ENABLED_PLUGINS_FILE"
    chmod 644 "$RABBITMQ_ENABLED_PLUGINS_FILE"
    echo "Plugins file created: $RABBITMQ_ENABLED_PLUGINS_FILE"
fi

# Check if definitions file exists, create default if not
if [ ! -f "$DEFINITIONS_FILE" ]; then
    echo "Creating default definitions.json..."
    cat > "$DEFINITIONS_FILE" << EOF
{
  "vhosts": [
    {"name": "/"}
  ],
  "users": [{
    "name": "guest",
    "password": "guest",
    "tags": "administrator"
  }],
  "permissions": [{
    "user": "guest",
    "vhost": "/",
    "configure": ".*",
    "write": ".*",
    "read": ".*"
  }]
}
EOF
    chmod 644 "$DEFINITIONS_FILE"
    echo "Definitions file created: $DEFINITIONS_FILE"
fi

# Verify the definitions file exists and has correct permissions
if [ ! -f "$DEFINITIONS_FILE" ]; then
    echo "ERROR: Definitions file still not found after creation attempt!"
    exit 1
fi

echo "Definitions file verified: $DEFINITIONS_FILE"

# Enable plugins offline before starting
echo "Enabling plugins offline..."
# Note: No sudo needed for plugin management when running as user
RABBITMQ_ENABLED_PLUGINS_FILE="$RABBITMQ_ENABLED_PLUGINS_FILE" \
    rabbitmq-plugins --offline --node "$NODE_NAME" enable rabbitmq_management rabbitmq_stream

# Final cookie permission check before starting
echo "Final cookie permission check:"
ls -la "$COOKIE_FILE"

echo "========================================="
echo "Starting RabbitMQ server for $SERVER_NAME..."
echo "Press Ctrl+C to stop"
echo "========================================="

# Test write permissions
touch "$INSTANCE_DIR/logs/test_write" 2>/dev/null && echo "Log directory is writable" || echo "Log directory is NOT writable"
rm -f "$INSTANCE_DIR/logs/test_write"

# Start the server (no sudo)
rabbitmq-server
