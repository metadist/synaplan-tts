#!/usr/bin/env bash
# Synaplan TTS watchguard.
#
# Polls GHCR for the latest synaplan-tts image. If the digest differs from the
# image the running container was started from, recreates the stack via
# `docker compose up -d` (picking up the freshly pulled image). This is the
# auto-update mechanism referenced in deploy/README.md and mirrors the
# synaplan-website watchguard.
#
# Install (see deploy/README.md for the full flow):
#   sudo install -m 0755 deploy/watchguard.sh /usr/local/bin/synaplan-tts-watchguard.sh
#   sudo install -m 0644 deploy/synaplan-tts-watchguard.service /etc/systemd/system/
#   sudo install -m 0644 deploy/synaplan-tts-watchguard.timer /etc/systemd/system/
#   sudo systemctl daemon-reload
#   sudo systemctl enable --now synaplan-tts-watchguard.timer
#
# Logs:
#   journalctl -u synaplan-tts-watchguard.service -f
#
# Configuration (override via /etc/default/synaplan-tts-watchguard if present):
#   COMPOSE_DIR   directory holding the compose file        (default /netroot/synaplan-tts)
#   COMPOSE_FILE  compose file name within COMPOSE_DIR       (default docker-compose.yml)
#   SERVICE_IMAGE image to track                             (default ghcr.io/metadist/synaplan-tts:latest)
#   CONTAINER     running container name                     (default synaplan-piper-tts)
set -euo pipefail

# Optional host-specific overrides.
[ -f /etc/default/synaplan-tts-watchguard ] && . /etc/default/synaplan-tts-watchguard

COMPOSE_DIR="${COMPOSE_DIR:-/netroot/synaplan-tts}"
COMPOSE_FILE="${COMPOSE_FILE:-docker-compose.yml}"
SERVICE_IMAGE="${SERVICE_IMAGE:-ghcr.io/metadist/synaplan-tts:latest}"
CONTAINER="${CONTAINER:-synaplan-piper-tts}"

COMPOSE="docker compose -f ${COMPOSE_DIR}/${COMPOSE_FILE}"

cd "$COMPOSE_DIR"

# Image the running container was created from (empty if not running yet).
running_digest="$(docker inspect "$CONTAINER" --format "{{index .Image}}" 2>/dev/null || echo none)"

# Pull silently; read back the digest of whatever is now :latest in GHCR.
docker pull --quiet "$SERVICE_IMAGE" >/dev/null
latest_digest="$(docker image inspect "$SERVICE_IMAGE" --format "{{.Id}}")"

if [ "$running_digest" = "$latest_digest" ]; then
  echo "watchguard: up to date ($latest_digest), no action"
  exit 0
fi

echo "watchguard: new image detected"
echo "  running: $running_digest"
echo "  latest : $latest_digest"
echo "watchguard: recreating stack via docker compose up -d"
$COMPOSE up -d --remove-orphans

# Keep disk usage bounded — drop the now-unreferenced previous image.
docker image prune -f >/dev/null || true
echo "watchguard: redeploy complete"
