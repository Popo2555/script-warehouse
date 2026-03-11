#!/bin/bash

# ==============================================================================
# Grafana Alloy Deployment Script (Secured)
# ==============================================================================
# Usage direct: 
#   ./install-alloy-proxy-slave-hinet.sh --LOKI_SERVER=... --NGINX_USERNAME=... --NGINX_PASSWORD=...
#
# Usage CURL:
#   curl -sL <URL>/install-alloy-proxy-slave-hinet.sh | bash -s -- --LOKI_SERVER=... --NGINX_USERNAME=... --NGINX_PASSWORD=...
# ==============================================================================

set -e

# Default installation directory
INSTALL_DIR="${INSTALL_DIR:-${HOME}/alloyToLoki}"
DOCKER_COMPOSE_FILE="docker-compose.yml"
CONFIG_ALLOY_FILE="config.alloy"

# Parse command line arguments
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        --LOKI_SERVER=*) LOKI_SERVER="${1#*=}"; shift ;;
        --NGINX_USERNAME=*) NGINX_USERNAME="${1#*=}"; shift ;;
        --NGINX_PASSWORD=*) NGINX_PASSWORD="${1#*=}"; shift ;;
        --INSTALL_DIR=*) INSTALL_DIR="${1#*=}"; shift ;;
        *) echo "Unknown parameter: $1"; shift ;;
    esac
done

echo "Checking environment variables..."
: "${LOKI_SERVER:?Error: LOKI_SERVER environment variable is not set}"
: "${NGINX_USERNAME:?Error: NGINX_USERNAME environment variable is not set}"
: "${NGINX_PASSWORD:?Error: NGINX_PASSWORD environment variable is not set}"

echo "Checking dependencies..."
if ! command -v docker &> /dev/null; then
    echo "Error: docker is not installed. Please install docker first."
    exit 1
fi

if ! docker compose version &> /dev/null; then
    echo "Error: docker compose is not available. Please install docker compose first."
    exit 1
fi

echo "Creating installation directory: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"
cd "$INSTALL_DIR"

echo "Generating $DOCKER_COMPOSE_FILE..."
cat <<EOF > "$DOCKER_COMPOSE_FILE"
services:
  alloy-agent:
    image: grafana/alloy:latest
    container_name: alloy-agent
    network_mode: host
    environment:
      - TZ=Asia/Taipei
      - LOKI_SERVER=$LOKI_SERVER
      - NGINX_USERNAME=$NGINX_USERNAME
      - NGINX_PASSWORD=$NGINX_PASSWORD
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./config.alloy:/etc/alloy/config.alloy:ro
    restart: always
EOF

echo "Generating $CONFIG_ALLOY_FILE..."
cat <<'EOF' > "$CONFIG_ALLOY_FILE"
discovery.docker "local" {
  host = "unix:///var/run/docker.sock"
}

discovery.relabel "filter_proxyslave" {
  targets = discovery.docker.local.targets

  rule {
    source_labels = ["__meta_docker_container_name"]
    regex = "/(.*)"
    target_label = "container_name"
  }
  rule {
    source_labels = ["container_name"]
    regex         = "proxyslave-.*"
    action        = "keep"
  }

}

loki.process "filter_logs" {
  forward_to = [loki.write.centralloki.receiver]

  stage.drop {
    expression = ".*Received release message:.*"
  }

  stage.drop {
    expression = ".*RTNETLINK answers: No such process.*"
  }
}

loki.source.docker "default" {
  host = "unix:///var/run/docker.sock"
  targets = discovery.relabel.filter_proxyslave.output
  labels = { "platform" = "docker", "hostname" = env("HOSTNAME") }

  forward_to = [loki.process.filter_logs.receiver]
}

loki.write "centralloki" {
  endpoint {
    url = "http://" + env("LOKI_SERVER") + "/loki/api/v1/push"
    basic_auth {
      username = env("NGINX_USERNAME")
      password = env("NGINX_PASSWORD")
    }
  }
}
EOF

echo "Starting/Updating Alloy Agent..."
docker compose up -d --force-recreate --remove-orphans

echo "=============================================================================="
echo "Deployment successful!"
echo "Installation directory: $INSTALL_DIR"
echo "Check logs with: docker compose logs -f"
echo "=============================================================================="
