#!/bin/bash
set -e

echo "⬇ Downloading artifact from Nexus..."

[ -n "$NEXUS_USER" ] || { echo "❌ NEXUS_USER missing"; exit 1; }
[ -n "$NEXUS_PASSWORD" ] || { echo "❌ NEXUS_PASSWORD missing"; exit 1; }
[ -n "$ARTIFACT_URL" ] || { echo "❌ ARTIFACT_URL missing"; exit 1; }
[ -n "$ARTIFACT_NAME" ] || { echo "❌ ARTIFACT_NAME missing"; exit 1; }

curl -f -u "$NEXUS_USER:$NEXUS_PASSWORD" \
  -O "$ARTIFACT_URL/$ARTIFACT_NAME"

echo "🚀 Deploying to CPI..."

[ -n "$CPI_URL" ] || { echo "❌ CPI_URL missing"; exit 1; }
[ -n "$CPI_USER" ] || { echo "❌ CPI_USER missing"; exit 1; }
[ -n "$CPI_PASSWORD" ] || { echo "❌ CPI_PASSWORD missing"; exit 1; }
[ -n "$IFLOW_NAME" ] || { echo "❌ IFLOW_NAME missing"; exit 1; }

curl -f -X POST \
"$CPI_URL/IntegrationDesigntimeArtifacts(Id='$IFLOW_NAME',Version='active')/\$value" \
-u "$CPI_USER:$CPI_PASSWORD" \
-H "Content-Type: application/octet-stream" \
--data-binary @"$ARTIFACT_NAME"

echo "▶ Starting iFlow..."

curl -f -X POST \
"$CPI_URL/IntegrationRuntimeArtifacts('$IFLOW_NAME')/Start" \
-u "$CPI_USER:$CPI_PASSWORD"

echo "✅ Deployment successful"
