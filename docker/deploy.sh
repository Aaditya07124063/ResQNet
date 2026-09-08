#!/usr/bin/env bash
set -euo pipefail

# ResQNet production deploy script (Phase 18) — HOST-OPERATOR OWNED.
# This is a REFERENCE copy checked into the repo for review — same
# pattern as docker-compose.reference.yml: the real copy that actually
# runs lives at /opt/resqnet/docker/deploy.sh on the VPS.
#
# What this does, and does NOT do:
#   1. Records the currently-running api image (for rollback.sh).
#   2. Pulls the image named by RESQNET_API_IMAGE from GHCR.
#   3. Recreates ONLY the api service container — `--no-deps` means db
#      and minio (and their volumes/data) are never touched.
#   4. Runs migrations against the already-running db.
#   5. Polls the container's own /health until it responds or times out.
#   It never runs a destructive database command, never touches
#   Orbyatravel (nothing here references anything outside this compose
#   file's resqnet-prefixed services), and never prints .env.prod's
#   contents or any secret.
#
# Requires: docker compose v2, .env.prod already present (chmod 600, real
# values — see .env.prod.example), and this host already authenticated to
# ghcr.io (`docker login ghcr.io`) if the image is private. This script
# does not manage that login — a login step reading a token would be one
# more place a secret could leak into a log, so it's kept out of scope
# here deliberately.
#
# Usage:
#   ./deploy.sh                                    # uses RESQNET_API_IMAGE from .env.prod
#   RESQNET_API_IMAGE=ghcr.io/org/repo/resqnet-api:<sha> ./deploy.sh   # explicit override

cd "$(dirname "$0")"

COMPOSE_FILE="docker-compose.prod.yml"
ENV_FILE=".env.prod"
LAST_IMAGE_FILE=".last_deployed_image"

if [ ! -f "$ENV_FILE" ]; then
  echo "ERROR: $ENV_FILE not found. Copy docker/.env.prod.example here, fill in real values, chmod 600." >&2
  exit 1
fi
if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: $COMPOSE_FILE not found. Copy docker-compose.reference.yml here as the real, host-owned compose file." >&2
  exit 1
fi

# Preserve an explicit RESQNET_API_IMAGE override (e.g. from rollback.sh)
# — sourcing .env.prod below would otherwise silently overwrite it with
# the file's own value.
_override_image="${RESQNET_API_IMAGE:-}"
set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
if [ -n "$_override_image" ]; then
  RESQNET_API_IMAGE="$_override_image"
fi

if [ -z "${RESQNET_API_IMAGE:-}" ]; then
  echo "ERROR: RESQNET_API_IMAGE is not set (in $ENV_FILE or the environment)." >&2
  exit 1
fi
if [[ "$RESQNET_API_IMAGE" == *:latest ]]; then
  echo "ERROR: RESQNET_API_IMAGE resolves to a :latest tag — deploy an immutable commit-SHA tag instead." >&2
  exit 1
fi

echo "==> Recording the currently-running api image (for rollback.sh)..."
if docker inspect --format '{{.Config.Image}}' resqnet-api > "$LAST_IMAGE_FILE" 2>/dev/null; then
  echo "    previous image: $(cat "$LAST_IMAGE_FILE")"
else
  rm -f "$LAST_IMAGE_FILE"
  echo "    (no currently-running resqnet-api container — first deploy, nothing to roll back to yet)"
fi

echo "==> Pulling $RESQNET_API_IMAGE ..."
docker pull "$RESQNET_API_IMAGE"

echo "==> Recreating ONLY the api service (db/minio and their volumes are untouched)..."
RESQNET_API_IMAGE="$RESQNET_API_IMAGE" docker compose -f "$COMPOSE_FILE" up -d --no-deps api

echo "==> Running migrations against the live database (additive-only migrations, per project convention)..."
docker compose -f "$COMPOSE_FILE" exec -T api node dist/src/database/migrate.js

echo "==> Waiting for the api container's own /health endpoint..."
for _ in $(seq 1 30); do
  if docker compose -f "$COMPOSE_FILE" exec -T api node -e \
    "fetch('http://127.0.0.1:3000/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" >/dev/null 2>&1; then
    echo "==> Healthy. Deploy complete: $RESQNET_API_IMAGE"
    exit 0
  fi
  sleep 2
done

echo "ERROR: api did not become healthy within 60s. Check 'docker compose -f $COMPOSE_FILE logs api'. Consider ./rollback.sh." >&2
exit 1
