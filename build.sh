#!/bin/bash
set -e

echo "🔍 Selecting latest artifact..."

DIR=$(find iflows -mindepth 1 -maxdepth 1 -type d -printf "%T@ %p\n" | sort -n | tail -1 | cut -d" " -f2-)
[ -n "$DIR" ] || { echo "❌ No directory found"; exit 1; }

FILE=$(find "$DIR" -name "*.zip" | head -1)
[ -n "$FILE" ] || { echo "❌ No ZIP found"; exit 1; }

BASENAME=$(basename "$FILE")

echo "📦 Found artifact: $BASENAME"

echo "✅ Validating ZIP..."
unzip -t "$FILE"

mkdir -p dist
cp "$FILE" "dist/$BASENAME"

# Validate env variables
[ -n "$NEXUS_PASSWORD" ] || { echo "❌ NEXUS_PASSWORD missing"; exit 1; }
[ -n "$ARTIFACT_URL" ] || { echo "❌ ARTIFACT_URL missing"; exit 1; }

echo "⬆ Uploading to Nexus..."

curl --fail --show-error --silent \
  -u "admin:$NEXUS_PASSWORD" \
  -T "dist/$BASENAME" \
  "$ARTIFACT_URL/$BASENAME"

echo "✅ Build completed successfully"
