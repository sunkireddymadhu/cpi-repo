#!/bin/bash
set -euo pipefail
echo "Debugging env presence..."
env | grep -i nexus || true
env | grep -i cpi || true

get_env_value() {
  local var_name="$1"
  local lower_name
  lower_name="$(printf '%s' "$var_name" | tr '[:upper:]' '[:lower:]')"

  if [ -n "${!var_name:-}" ]; then
    printf '%s' "${!var_name}"
    return 0
  fi

  if [ -n "${!lower_name:-}" ]; then
    printf '%s' "${!lower_name}"
    return 0
  fi

  return 1
}

require_env() {
  local var_name="$1"
  local value

  if ! value="$(get_env_value "$var_name")"; then
    echo "Missing required environment variable: $var_name" >&2
    exit 1
  fi

  export "$var_name=$value"
}

extract_json_value() {
  local json_key="$1"
  node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(0,'utf8')); const value=data[process.argv[1]] || ''; if (!value) process.exit(1); process.stdout.write(String(value));" "$json_key"
}

extract_incident_state() {
  node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(0,'utf8')); const result=(data.result && data.result[0]) || null; if (!result) process.exit(1); process.stdout.write(String(result.state || ''));"
}

require_env NEXUS_REPOSITORY_URL
require_env NEXUS_USER
require_env NEXUS_PASSWORD
require_env CPI_TOKEN_URL
require_env CPI_CLIENT_ID
require_env CPI_CLIENT_SECRET
require_env CPI_RUNTIME_URL
require_env SNOW_INSTANCE_URL
require_env SNOW_USERNAME
require_env SNOW_PASSWORD

REQUEST_FILE="deploy-request.json"

[ -f "$REQUEST_FILE" ] || { echo "deploy-request.json not found"; exit 1; }

ARTIFACT_ID="$(cat "$REQUEST_FILE" | extract_json_value artifactId)"
ARTIFACT_VERSION="$(cat "$REQUEST_FILE" | extract_json_value version)"
CPI_PACKAGE_ID="$(cat "$REQUEST_FILE" | extract_json_value packageId)"
INCIDENT_ID="$(cat "$REQUEST_FILE" | extract_json_value incidentId)"

[ -n "$ARTIFACT_ID" ] || { echo "artifactId missing in deploy-request.json"; exit 1; }
[ -n "$ARTIFACT_VERSION" ] || { echo "version missing in deploy-request.json"; exit 1; }
[ -n "$CPI_PACKAGE_ID" ] || { echo "packageId missing in deploy-request.json"; exit 1; }
[ -n "$INCIDENT_ID" ] || { echo "incidentId missing in deploy-request.json"; exit 1; }

CPI_IFLOW_ID="$ARTIFACT_ID"
CPI_IFLOW_NAME="$ARTIFACT_ID"

SNOW_INCIDENT_TABLE="${SNOW_INCIDENT_TABLE:-incident}"
SNOW_REQUIRED_STATE="${SNOW_REQUIRED_STATE:-In Progress}"

ARTIFACT_NAME="${ARTIFACT_ID}_v${ARTIFACT_VERSION}.zip"
ARTIFACT_FILE="$ARTIFACT_NAME"
NEXUS_DOWNLOAD_URL="${NEXUS_REPOSITORY_URL%/}/$ARTIFACT_ID/$ARTIFACT_VERSION/$ARTIFACT_NAME"

echo "Resolved artifact id: $ARTIFACT_ID"
echo "Resolved artifact version: $ARTIFACT_VERSION"
echo "Resolved artifact name: $ARTIFACT_NAME"
echo "Resolved package id: $CPI_PACKAGE_ID"
echo "Resolved incident id: $INCIDENT_ID"
echo "Resolved iflow id: $CPI_IFLOW_ID"
echo "Resolved iflow name: $CPI_IFLOW_NAME"
echo "Nexus download URL: $NEXUS_DOWNLOAD_URL"

echo "Downloading artifact from Nexus..."
curl --fail --show-error --silent --location \
  -u "$NEXUS_USER:$NEXUS_PASSWORD" \
  "$NEXUS_DOWNLOAD_URL" \
  -o "$ARTIFACT_FILE"

echo "Validating artifact..."
unzip -t "$ARTIFACT_FILE" >/dev/null

echo "Encoding artifact..."
ARTIFACT_B64="$(base64 -w 0 "$ARTIFACT_FILE" 2>/dev/null || base64 "$ARTIFACT_FILE" | tr -d '\n')"

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

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
CSRF_HEADERS="$TMP_DIR/csrf-headers.txt"
CHECK_BODY="$TMP_DIR/check.json"
ACTION_BODY="$TMP_DIR/action.json"
ACTION_HEADERS="$TMP_DIR/action-headers.txt"
DEPLOY_BODY="$TMP_DIR/deploy.txt"
STATUS_BODY="$TMP_DIR/status.json"
COOKIE_JAR="$TMP_DIR/cookies.txt"
SNOW_BODY="$TMP_DIR/snow.json"

echo "Validating incident in ServiceNow..."
SNOW_URL="${SNOW_INSTANCE_URL%/}/api/now/table/${SNOW_INCIDENT_TABLE}?sysparm_query=number=${INCIDENT_ID}&sysparm_limit=1&sysparm_fields=number,state&sysparm_display_value=true"

HTTP_CODE="$(curl --silent --show-error --location \
  -u "$SNOW_USERNAME:$SNOW_PASSWORD" \
  -H "Accept: application/json" \
  -o "$SNOW_BODY" \
  -w "%{http_code}" \
  "$SNOW_URL" || true)"

echo "ServiceNow check HTTP code: $HTTP_CODE"

if [ "$HTTP_CODE" != "200" ]; then
  echo "Failed to query ServiceNow incident. HTTP $HTTP_CODE" >&2
  cat "$SNOW_BODY" >&2
  exit 1
fi

INC_STATE="$(cat "$SNOW_BODY" | extract_incident_state 2>/dev/null || true)"

if [ -z "$INC_STATE" ]; then
  echo "Incident not found: $INCIDENT_ID" >&2
  cat "$SNOW_BODY" >&2
  exit 1
fi

echo "Incident state: $INC_STATE"

if [ "$INC_STATE" != "$SNOW_REQUIRED_STATE" ]; then
  echo "Incident $INCIDENT_ID is not in required state '$SNOW_REQUIRED_STATE'." >&2
  exit 1
fi

echo "Incident validation passed."

echo "Fetching CSRF token..."
CSRF_URL="$BASE_URL/IntegrationDesigntimeArtifacts?\$top=1"

HTTP_CODE="$(curl --silent --show-error \
  -D "$CSRF_HEADERS" \
  -c "$COOKIE_JAR" \
  -b "$COOKIE_JAR" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-CSRF-Token: Fetch" \
  -H "Accept: application/json" \
  -o /dev/null \
  -w "%{http_code}" \
  "$CSRF_URL" || true)"

echo "CSRF fetch HTTP code: $HTTP_CODE"

CSRF_TOKEN="$(awk 'BEGIN{IGNORECASE=1} /^x-csrf-token:/ {sub(/\r$/, "", $2); print $2}' "$CSRF_HEADERS" | tail -1)"

if [ -z "$CSRF_TOKEN" ]; then
  echo "Failed to fetch CSRF token." >&2
  cat "$CSRF_HEADERS" >&2
  exit 1
fi

CHECK_URL="$BASE_URL/IntegrationDesigntimeArtifacts(Id='$CPI_IFLOW_ID',Version='$ARTIFACT_VERSION')"
CREATE_URL="$BASE_URL/IntegrationDesigntimeArtifacts"
DEPLOY_URL="$BASE_URL/DeployIntegrationDesigntimeArtifact?Id='$CPI_IFLOW_ID'&Version='$ARTIFACT_VERSION'"

echo "Checking whether exact iFlow version exists..."
HTTP_CODE="$(curl --silent --show-error \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "Accept: application/json" \
  -o "$CHECK_BODY" \
  -w "%{http_code}" \
  "$CHECK_URL" || true)"

echo "Check HTTP code: $HTTP_CODE"
echo "Check response body:"
cat "$CHECK_BODY"
echo

if [ "$HTTP_CODE" = "200" ]; then
  echo "Exact iFlow version already exists. Skipping update and deploying existing artifact."
elif [ "$HTTP_CODE" = "404" ]; then
  echo "Exact iFlow version does not exist. Creating design-time artifact..."
  HTTP_CODE="$(curl --silent --show-error \
    -X POST \
    -D "$ACTION_HEADERS" \
    -c "$COOKIE_JAR" \
    -b "$COOKIE_JAR" \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "X-CSRF-Token: $CSRF_TOKEN" \
    -H "Accept: application/json" \
    -H "Content-Type: application/json" \
    -d "{\"Id\":\"$CPI_IFLOW_ID\",\"Name\":\"$CPI_IFLOW_NAME\",\"PackageId\":\"$CPI_PACKAGE_ID\",\"ArtifactContent\":\"$ARTIFACT_B64\"}" \
    -o "$ACTION_BODY" \
    -w "%{http_code}" \
    "$CREATE_URL" || true)"

  if [ "$HTTP_CODE" -lt 200 ] || [ "$HTTP_CODE" -ge 300 ]; then
    echo "Create failed. HTTP $HTTP_CODE" >&2
    echo "Create response headers:" >&2
    cat "$ACTION_HEADERS" >&2
    echo >&2
    echo "Create response body:" >&2
    cat "$ACTION_BODY" >&2
    exit 1
  fi
else
  echo "Failed to check exact iFlow version. HTTP $HTTP_CODE" >&2
  cat "$CHECK_BODY" >&2
  exit 1
fi

echo "Triggering deployment..."
curl --fail --show-error --silent \
  -X POST \
  -c "$COOKIE_JAR" \
  -b "$COOKIE_JAR" \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  -H "X-CSRF-Token: $CSRF_TOKEN" \
  -H "Accept: application/json" \
  "$DEPLOY_URL" \
  -o "$DEPLOY_BODY"

TASK_ID="$(tr -d '\r\n\"' < "$DEPLOY_BODY")"

if [ -z "$TASK_ID" ]; then
  echo "Failed to read deployment task id." >&2
  cat "$DEPLOY_BODY" >&2
  exit 1
fi

STATUS_URL="$BASE_URL/BuildAndDeployStatus(TaskId='$TASK_ID')"
echo "Polling deployment task: $TASK_ID"

attempt=1
while [ "$attempt" -le 30 ]; do
  curl --fail --show-error --silent \
    -H "Authorization: Bearer $ACCESS_TOKEN" \
    -H "Accept: application/json" \
    "$STATUS_URL" \
    -o "$STATUS_BODY"

  STATUS="$(printf '%s' "$(cat "$STATUS_BODY")" | node -e "const fs=require('fs'); const data=JSON.parse(fs.readFileSync(0,'utf8')); const status=data.Status || (data.d && data.d.Status) || ''; process.stdout.write(String(status));")"

  if [ "$STATUS" = "SUCCESS" ]; then
    echo "Deployment successful"
    exit 0
  fi

  if [ "$STATUS" = "ERROR" ] || [ "$STATUS" = "FAIL" ] || [ "$STATUS" = "FAILED" ]; then
    echo "Deployment failed with status: $STATUS" >&2
    cat "$STATUS_BODY" >&2
    exit 1
  fi

  echo "Deployment status attempt $attempt/30: ${STATUS:-pending}"
  attempt=$((attempt + 1))
  sleep 10
done

echo "Deployment timed out." >&2
cat "$STATUS_BODY" >&2
exit 1
