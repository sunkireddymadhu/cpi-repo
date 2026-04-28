#!/bin/bash
set -e

echo "⬇ Downloading artifact from Nexus..."

curl -f -u "$NEXUS_USER:$NEXUS_PASSWORD" \
  -O "$ARTIFACT_URL/$ARTIFACT_NAME"

echo "🚀 Deploying to CPI..."

curl -f -X POST \
"$CPI_URL/IntegrationDesigntimeArtifacts" \
-u "$CPI_USER:$CPI_PASSWORD" \
-H "Content-Type: application/zip" \
--data-binary @"$ARTIFACT_NAME"

echo "▶ Starting iFlow..."

curl -f -X POST \
"$CPI_URL/IntegrationRuntimeArtifacts('$IFLOW_NAME')/Start" \
-u "$CPI_USER:$CPI_PASSWORD"

echo "✅ Deployment successful"
