#!/bin/sh
set -eu

require_env() {
  var_name="$1"
  eval "value=\${$var_name:-}"
  if [ -z "$value" ]; then
    echo "Missing required environment variable: $var_name" >&2
    exit 1
  fi
}

extract_json_value() {
  key="$1"
  node -e "const fs = require('fs'); const payload = fs.readFileSync(0, 'utf8'); const data = JSON.parse(payload); const value = data[key]; if (!value) process.exit(1); process.stdout.write(String(value));"
}

require_env NEXUS_REPOSITORY_URL
require_env NEXUS_ARTIFACT_NAME
require_env NEXUS_USER
require_env NEXUS_PASSWORD
require_env CPI_TOKEN_URL
require_env CPI_CLIENT_ID
require_env CPI_CLIENT_SECRET
require_env CPI_RUNTIME_URL
require_env CPI_IFLOW_ID

ARTIFACT_FILE="$NEXUS_ARTIFACT_NAME"
NEXUS_DOWNLOAD_URL="${NEXUS_REPOSITORY_URL%/}/$NEXUS_ARTIFACT_NAME"

echo "Downloading artifact from Nexus..."
curl --fail --show-error --silent --location \
  -u "$NEXUS_USER:$NEXUS_PASSWORD" \
  "$NEXUS_DOWNLOAD_URL" \
  -o "$ARTIFACT_FILE"

echo "Validating artifact..."
unzip -t "$ARTIFACT_FILE" >/dev/null

echo "Requesting CPI access token..."
TOKEN_RESPONSE="$(curl --fail --show-error --silent \
  -u "$CPI_CLIENT_ID:$CPI_CLIENT_SECRET" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=client_credentials" \
  "$CPI_TOKEN_URL")"

ACCESS_TOKEN="$(printf '%s' "$TOKEN_RESPONSE" | extract_json_value access_token)"

BASE_URL="${CPI_RUNTIME_URL%/}"
case "$BASE_URL" in
  */api/v1) ;;
  */api) BASE_URL="$BASE_URL/v1" ;;
  *) BASE_URL="$BASE_URL/api/v1" ;;
esac

UPLOAD_URL="$BASE_URL/IntegrationDesigntimeArtifacts"
DEPLOY_URL="$BASE_URL/IntegrationRuntimeArtifacts('$CPI_IFLOW_ID')/Start"

echo "Resolved upload URL: $UPLOAD_URL"
echo "Resolved deploy URL: $DEPLOY_URL"

echo "Uploading artifact to CPI..."
curl --fail --show-error --silent \
  -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  -H "Content-Type: application/zip" \
  --data-binary "@$ARTIFACT_FILE" \
  "$UPLOAD_URL"

echo "Starting iFlow..."
curl --fail --show-error --silent \
  -X POST \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  "$DEPLOY_URL"

echo "Deployment successful"
