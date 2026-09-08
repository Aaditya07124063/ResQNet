#!/usr/bin/env bash
set -euo pipefail

# ResQNet rollback script (Phase 18) — HOST-OPERATOR OWNED (reference copy;
# real copy lives at /opt/resqnet/docker/rollback.sh, same pattern as
# deploy.sh / docker-compose.reference.yml).
#
# Redeploys the previous api image — either the one deploy.sh recorded
# from its last run (.last_deployed_image), or an explicit tag you name.
# Reuses deploy.sh itself (recreates ONLY the api container, runs
# migrations, waits for health) rather than duplicating that logic.
#
# Usage:
#   ./rollback.sh                                          # uses .last_deployed_image
#   ./rollback.sh ghcr.io/org/repo/resqnet-api:<prior-sha>  # explicit target

cd "$(dirname "$0")"
LAST_IMAGE_FILE=".last_deployed_image"

TARGET="${1:-}"
if [ -z "$TARGET" ]; then
  if [ ! -f "$LAST_IMAGE_FILE" ]; then
    echo "ERROR: no $LAST_IMAGE_FILE recorded (no prior deploy.sh run on this host) and no image given explicitly." >&2
    echo "Usage: ./rollback.sh ghcr.io/org/repo/resqnet-api:<prior-commit-sha>" >&2
    exit 1
  fi
  TARGET="$(cat "$LAST_IMAGE_FILE")"
fi

echo "==> Rolling back to $TARGET ..."
RESQNET_API_IMAGE="$TARGET" ./deploy.sh
