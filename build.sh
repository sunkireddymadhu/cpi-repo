#!/bin/bash
set -euo pipefail

echo "Reading latest artifact pointer..."

LATEST_FILE="latest-artifact.txt"

[ -f "$LATEST_FILE" ] || { echo "latest-artifact.txt not found"; exit 1; }

FILE=$(tr -d '\r' < "$LATEST_FILE")
[ -n "$FILE" ] || { echo "latest-artifact.txt is empty"; exit 1; }
[ -f "$FILE" ] || { echo "Artifact file not found: $FILE"; exit 1; }

BASENAME=$(basename "$FILE")

echo "Found artifact from pointer: $BASENAME"
echo "Artifact path: $FILE"

echo "Validating ZIP..."
unzip -t "$FILE" >/dev/null

mkdir -p dist
cp "$FILE" "dist/$BASENAME"

[ -n "${NEXUS_PASSWORD:-}" ] || { echo "NEXUS_PASSWORD missing"; exit 1; }
[ -n "${ARTIFACT_URL:-}" ] || { echo "ARTIFACT_URL missing"; exit 1; }

echo "Uploading to Nexus..."

curl --fail --show-error --silent \
  -u "admin:$NEXUS_PASSWORD" \
  -T "dist/$BASENAME" \
  "$ARTIFACT_URL/$BASENAME"

echo "Build completed successfully"
