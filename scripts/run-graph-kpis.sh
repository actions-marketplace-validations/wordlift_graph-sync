#!/usr/bin/env bash
set -euo pipefail

enabled="${INPUT_GRAPH_KPIS_ENABLED:-false}"
profile="${INPUT_PROFILE:-}"
config_path="${INPUT_CONFIG_PATH:-}"
working_directory="${INPUT_WORKING_DIRECTORY:-.}"
output_dir="${INPUT_OUTPUT_DIR:-${GITHUB_WORKSPACE}/output/${INPUT_PROFILE}}"
service_manager_url="${INPUT_GRAPH_KPIS_SERVICE_MANAGER_URL:-https://api.wordlift.io}"
allowed_hosts="${INPUT_GRAPH_KPIS_ALLOWED_HOSTS:-api.wordlift.io}"
snapshot_date="${INPUT_GRAPH_KPIS_SNAPSHOT_DATE:-}"
export_endpoint="${INPUT_GRAPH_KPIS_EXPORT_ENDPOINT:-}"
fail_on_error="${INPUT_GRAPH_KPIS_FAIL_ON_ERROR:-false}"
retry_attempts="${INPUT_GRAPH_KPIS_RETRY_ATTEMPTS:-3}"
log_level="${INPUT_LOG_LEVEL:-warning}"

enabled_lower="$(printf '%s' "$enabled" | tr '[:upper:]' '[:lower:]')"
fail_on_error_lower="$(printf '%s' "$fail_on_error" | tr '[:upper:]' '[:lower:]')"
log_level_lower="$(printf '%s' "$log_level" | tr '[:upper:]' '[:lower:]')"

handle_failure() {
  local message="$1"
  if [[ "$fail_on_error_lower" == "true" || "$fail_on_error_lower" == "1" || "$fail_on_error_lower" == "yes" ]]; then
    echo "error: $message" >&2
    exit 1
  fi
  echo "::warning::$message"
  exit 0
}

case "$enabled_lower" in
  true|1|yes)
    ;;
  false|0|no|'')
    echo "Graph KPI upload is disabled."
    exit 0
    ;;
  *)
    echo "error: input 'graph_kpis_enabled' must be true or false" >&2
    exit 1
    ;;
esac

case "$fail_on_error_lower" in
  true|1|yes|false|0|no|'')
    ;;
  *)
    echo "error: input 'graph_kpis_fail_on_error' must be true or false" >&2
    exit 1
    ;;
esac

if [[ -z "$profile" ]]; then
  echo "error: input 'profile' is required" >&2
  exit 1
fi

if [[ ! "$retry_attempts" =~ ^[0-9]+$ || "$retry_attempts" -lt 1 ]]; then
  echo "error: input 'graph_kpis_retry_attempts' must be a positive integer" >&2
  exit 1
fi

if [[ ! -d "$working_directory" ]]; then
  echo "error: working directory does not exist: $working_directory" >&2
  exit 1
fi

if ! command -v worai >/dev/null 2>&1; then
  echo "error: worai not found in PATH" >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "error: curl not found in PATH" >&2
  exit 1
fi

python_cmd=""
if command -v python3 >/dev/null 2>&1; then
  python_cmd="python3"
elif command -v python >/dev/null 2>&1; then
  python_cmd="python"
else
  echo "error: python3 or python is required" >&2
  exit 1
fi

if [[ -z "$snapshot_date" ]]; then
  snapshot_date="$(date -u +%F)"
fi
"$python_cmd" "$GITHUB_ACTION_PATH/scripts/graph-kpis.py" validate-date "$snapshot_date" || handle_failure "Graph KPI upload failed because snapshot date is invalid."

mkdir -p "$output_dir/graph-kpis"
temp_root="${RUNNER_TEMP:-/tmp}"
mkdir -p "$temp_root"
temp_dir="$(mktemp -d "$temp_root/graph-kpis.XXXXXX")"
trap 'rm -rf "$temp_dir"' EXIT

helper="$GITHUB_ACTION_PATH/scripts/graph-kpis.py"
audit_json="$output_dir/graph-kpis/graph_kpi_audit.json"
payload_json="$output_dir/graph-kpis/graph_kpi_payload.json"
report_md="$output_dir/graph-kpis/graph_kpi_report.md"
account_response="$temp_dir/account.json"
upload_response="$temp_dir/upload-response.json"
audit_json="$temp_dir/graph_kpi_audit.json"
export_file="$temp_dir/export-${profile}-${snapshot_date}.jsonld"

api_key="$("$python_cmd" "$helper" resolve-key \
  --profile "$profile" \
  --config-path "$config_path" \
  --working-directory "$working_directory")" || handle_failure "Graph KPI upload failed while resolving the WordLift key."
echo "::add-mask::$api_key"

base_url="${service_manager_url%/}"
"$python_cmd" "$helper" validate-url \
  --url "$base_url" \
  --allowed-hosts "$allowed_hosts" \
  --base-url || handle_failure "Graph KPI upload failed because the service-manager URL is not allowed."

if [[ -n "$export_endpoint" ]]; then
  "$python_cmd" "$helper" validate-url \
    --url "$export_endpoint" \
    --allowed-hosts "$allowed_hosts" || handle_failure "Graph KPI upload failed because the export endpoint is not allowed."
fi

auth_config="$temp_dir/curl-auth.conf"
old_umask="$(umask)"
umask 077
printf 'header = "Authorization: Key %s"\n' "$api_key" > "$auth_config"
umask "$old_umask"

if ! curl --silent --show-error --fail \
  --config "$auth_config" \
  --header "Accept: application/vnd.wordlift.account-info.v2+json, application/json" \
  --connect-timeout 10 \
  --max-time 60 \
  --output "$account_response" \
  "$base_url/accounts/me"; then
  handle_failure "Graph KPI upload failed while resolving /accounts/me."
fi

account_id="$("$python_cmd" "$helper" account-id "$(cat "$account_response")")" || handle_failure "Graph KPI upload failed because /accounts/me did not return an account id."

cmd=("worai")
if [[ -n "$config_path" ]]; then
  cmd+=("--config" "$config_path")
fi
cmd+=("--profile" "$profile" "graph" "export")
if [[ -n "$export_endpoint" ]]; then
  cmd+=("--endpoint" "$export_endpoint")
fi
cmd+=("$export_file")

cd "$working_directory"
printf 'Running graph export for KPI calculation.\n'
if [[ -n "$log_level_lower" ]]; then
  WORAI_LOG_LEVEL="$log_level_lower" "${cmd[@]}" || handle_failure "Graph KPI export failed."
else
  "${cmd[@]}" || handle_failure "Graph KPI export failed."
fi

audit_cmd=("worai")
if [[ -n "$config_path" ]]; then
  audit_cmd+=("--config" "$config_path")
fi
audit_cmd+=("--profile" "$profile" "graph" "audit" "--format" "json" "$export_file")

printf 'Running graph audit for KPI calculation.\n'
if [[ -n "$log_level_lower" ]]; then
  WORAI_LOG_LEVEL="$log_level_lower" "${audit_cmd[@]}" > "$audit_json" || handle_failure "Graph KPI audit failed."
else
  "${audit_cmd[@]}" > "$audit_json" || handle_failure "Graph KPI audit failed."
fi

"$python_cmd" "$helper" build-payload \
  --audit-json "$audit_json" \
  --payload-json "$payload_json" \
  --report-md "$report_md" \
  --snapshot-date "$snapshot_date" || handle_failure "Graph KPI payload generation failed."

upload_url="$base_url/accounts/$account_id/graph-kpis/$snapshot_date"
attempt=1
while [[ "$attempt" -le "$retry_attempts" ]]; do
  http_code="$(curl --silent --show-error \
    --request PUT \
    --config "$auth_config" \
    --header "Content-Type: application/json" \
    --header "Accept: application/json" \
    --connect-timeout 10 \
    --max-time 60 \
    --data-binary "@$payload_json" \
    --output "$upload_response" \
    --write-out "%{http_code}" \
    "$upload_url")" || http_code="000"

  case "$http_code" in
    200|201|204)
      echo "Graph KPI snapshot uploaded for account $account_id on $snapshot_date."
      exit 0
      ;;
    408|429|5??|000)
      if [[ "$attempt" -lt "$retry_attempts" ]]; then
        sleep "$attempt"
        attempt=$((attempt + 1))
        continue
      fi
      handle_failure "Graph KPI upload failed with transient HTTP status $http_code after $retry_attempts attempt(s)."
      ;;
    *)
      handle_failure "Graph KPI upload failed with HTTP status $http_code."
      ;;
  esac
done
