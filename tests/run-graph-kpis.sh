#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/run-graph-kpis.sh"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

pass_count=0
fail_count=0

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" == "$actual" ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $message"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $message"
    echo "  expected to contain: $needle"
    echo "  actual:              $haystack"
  fi
}

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    pass_count=$((pass_count + 1))
  else
    fail_count=$((fail_count + 1))
    echo "FAIL: $message"
    echo "  expected not to contain: $needle"
    echo "  actual:                  $haystack"
  fi
}

run_case() {
  local name="$1"
  shift
  local out_file="$TMP_DIR/${name}.out"
  local err_file="$TMP_DIR/${name}.err"
  set +e
  "$@" >"$out_file" 2>"$err_file"
  local code=$?
  set -e
  echo "$code"
}

FAKE_BIN="$TMP_DIR/bin"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/worai" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$WORAI_ARGS_FILE"
if [[ "$*" == *" graph export "* ]]; then
  output="${@: -1}"
  printf '{"@graph":[]}\n' > "$output"
  exit 0
fi
if [[ "$*" == *" graph audit "* ]]; then
  cat <<'JSON'
{
  "total_entities": 10,
  "total_properties": 25,
  "total_triples": 40,
  "edges": 7,
  "entity_types": {"schema:Article": 3},
  "properties": {"schema:name": 10},
  "unique_urls": {"count": 4, "urls": ["https://example.com/a"]},
  "orphans": {"count": 2, "iris": ["urn:orphan"]},
  "broken_links": {"count": 1, "iris": ["urn:missing"]},
  "isolated_graphs": {"component_count": 1, "components": [["urn:a"]]},
  "edge_node_ratio": {"ratio": 0.7, "edges": 7, "nodes": 10},
  "duplicates": {"count": 1, "groups": [["urn:a", "urn:b"]]},
  "rich_snippets": {
    "eligible_valid": {"Article": 2},
    "eligible_invalid": {"Article": 1}
  },
  "schema_compliance": [
    {"error_count": 2, "warning_count": 3, "url": "https://example.com/a"}
  ],
  "account_id": 999,
  "dataset_id": "forbidden"
}
JSON
  exit 0
fi
exit 0
EOS
chmod +x "$FAKE_BIN/worai"

cat > "$FAKE_BIN/curl" <<'EOS'
#!/usr/bin/env bash
method="GET"
output=""
write_out=false
data_file=""
url=""
args=("$@")
printf '%s\n' "$*" >> "$CURL_ARGS_FILE"
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --request)
      i=$((i + 1))
      method="${args[$i]}"
      ;;
    --output)
      i=$((i + 1))
      output="${args[$i]}"
      ;;
    --write-out)
      i=$((i + 1))
      write_out=true
      ;;
    --data-binary)
      i=$((i + 1))
      data_file="${args[$i]#@}"
      ;;
    http*)
      url="${args[$i]}"
      ;;
  esac
done

printf '%s %s\n' "$method" "$url" >> "$CURL_CALLS_FILE"

if [[ "$method" == "GET" ]]; then
  printf '%s\n' "${CURL_ACCOUNT_RESPONSE:-{\"account_id\":1506805}}" > "$output"
  exit 0
fi

if [[ -n "$data_file" ]]; then
  cp "$data_file" "$CURL_LAST_PAYLOAD_FILE"
fi

count=0
if [[ -f "$CURL_COUNT_FILE" ]]; then
  count="$(cat "$CURL_COUNT_FILE")"
fi
count=$((count + 1))
printf '%s' "$count" > "$CURL_COUNT_FILE"

IFS=',' read -r -a codes <<< "${CURL_UPLOAD_CODES:-201}"
index=$((count - 1))
if [[ "$index" -ge "${#codes[@]}" ]]; then
  index=$((${#codes[@]} - 1))
fi
code="${codes[$index]}"
printf '{"status":%s}\n' "$code" > "$output"
if [[ "$write_out" == true ]]; then
  printf '%s' "$code"
fi
exit 0
EOS
chmod +x "$FAKE_BIN/curl"

WORK_DIR="$TMP_DIR/work"
mkdir -p "$WORK_DIR"
cat > "$WORK_DIR/worai.toml" <<'EOF_TOML'
[profiles._base]
api_key = "${WORDLIFT_API_KEY}"

[profiles.prod]
EOF_TOML
cat > "$WORK_DIR/custom.toml" <<'EOF_TOML'
[profiles.custom]
api_key = "${WORDLIFT_API_KEY}"
EOF_TOML

BASE_ENV=(
  env
  PATH="$FAKE_BIN:$PATH"
  GITHUB_ACTION_PATH="$ROOT_DIR"
  GITHUB_WORKSPACE="$TMP_DIR/workspace"
  RUNNER_TEMP="$TMP_DIR/runner"
  WORAI_ARGS_FILE="$TMP_DIR/worai-args.txt"
  CURL_CALLS_FILE="$TMP_DIR/curl-calls.txt"
  CURL_ARGS_FILE="$TMP_DIR/curl-args.txt"
  CURL_COUNT_FILE="$TMP_DIR/curl-count.txt"
  CURL_LAST_PAYLOAD_FILE="$TMP_DIR/payload.json"
  WORDLIFT_API_KEY="secret-key-123"
)
mkdir -p "$TMP_DIR/runner"

# Case 1: disabled is a no-op.
code=$(run_case disabled "${BASE_ENV[@]}" INPUT_GRAPH_KPIS_ENABLED="false" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" "$SCRIPT")
assert_eq "0" "$code" "disabled graph KPIs should succeed"
assert_eq "0" "$(test ! -f "$TMP_DIR/worai-args.txt"; echo $?)" "disabled graph KPIs should not run worai"

# Case 2: enabled resolves profile key, exports, audits, resolves account, and uploads sanitized payload.
rm -f "$TMP_DIR/worai-args.txt" "$TMP_DIR/curl-calls.txt" "$TMP_DIR/curl-args.txt" "$TMP_DIR/curl-count.txt" "$TMP_DIR/payload.json"
code=$(run_case enabled "${BASE_ENV[@]}" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_CONFIG_PATH="./worai.toml" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out" INPUT_GRAPH_KPIS_SNAPSHOT_DATE="2026-06-23" INPUT_GRAPH_KPIS_SERVICE_MANAGER_URL="https://api.wordlift.io/" "$SCRIPT")
assert_eq "0" "$code" "enabled graph KPIs should succeed"
calls="$(cat "$TMP_DIR/curl-calls.txt")"
assert_contains "GET https://api.wordlift.io/accounts/me" "$calls" "should resolve account from /accounts/me"
assert_contains "PUT https://api.wordlift.io/accounts/1506805/graph-kpis/2026-06-23" "$calls" "should PUT KPI snapshot by account/date"
args="$(cat "$TMP_DIR/worai-args.txt")"
assert_contains "--config ./worai.toml --profile prod graph export" "$args" "should run graph export"
assert_contains "--config ./worai.toml --profile prod graph audit --format json" "$args" "should run graph audit json"
payload_check="$(python3 - "$TMP_DIR/payload.json" <<'PY'
import json, sys
payload = json.load(open(sys.argv[1]))
checks = [
    payload["snapshot_date"] == "2026-06-23",
    payload["snapshot_origin"] == "calculated",
    payload["all_total_entities"] == 10,
    payload["all_unique_urls_count"] == 4,
    payload["all_edge_node_ratio"] == 0.7,
    payload["rich_snippets_valid_count"] == 2,
    payload["rich_snippets_invalid_count"] == 1,
    payload["schema_compliance_errors"] == 2,
    "account_id" not in payload,
    "dataset_id" not in payload,
    '"urls"' not in json.dumps(payload),
    '"iris"' not in json.dumps(payload),
]
print("ok" if all(checks) else payload)
PY
)"
assert_eq "ok" "$payload_check" "payload should map and sanitize audit metrics"
stdout_logs="$(cat "$TMP_DIR/enabled.out")"
stderr_logs="$(cat "$TMP_DIR/enabled.err")"
assert_not_contains "secret-key-123" "$stderr_logs" "stderr should not print the resolved key"
assert_contains "::add-mask::secret-key-123" "$stdout_logs" "resolved key should be masked"
curl_args="$(cat "$TMP_DIR/curl-args.txt")"
assert_not_contains "secret-key-123" "$curl_args" "curl argv should not contain the resolved key"
assert_eq "0" "$(test ! -f "$TMP_DIR/out/graph-kpis/graph_kpi_audit.json"; echo $?)" "raw audit JSON should not be stored in uploaded output"

# Case 3: transient upload failures retry.
rm -f "$TMP_DIR/curl-calls.txt" "$TMP_DIR/curl-count.txt" "$TMP_DIR/payload.json"
code=$(run_case retry "${BASE_ENV[@]}" CURL_UPLOAD_CODES="500,201" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-retry" INPUT_GRAPH_KPIS_SNAPSHOT_DATE="2026-06-23" "$SCRIPT")
assert_eq "0" "$code" "transient upload failure should retry and succeed"
assert_eq "2" "$(cat "$TMP_DIR/curl-count.txt")" "upload should be attempted twice"

# Case 4: missing key is warning-only by default.
code=$(run_case missing_key "${BASE_ENV[@]}" WORDLIFT_API_KEY="" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-missing" "$SCRIPT")
assert_eq "0" "$code" "missing key should be non-blocking by default"
missing_out="$(cat "$TMP_DIR/missing_key.out")"
assert_contains "::warning::Graph KPI upload failed while resolving the WordLift key." "$missing_out" "missing key should emit warning"

# Case 5: strict mode fails on missing key.
code=$(run_case strict_missing_key "${BASE_ENV[@]}" WORDLIFT_API_KEY="" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_GRAPH_KPIS_FAIL_ON_ERROR="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-strict" "$SCRIPT")
assert_eq "1" "$code" "missing key should fail in strict mode"

# Case 6: untrusted non-HTTPS URL is rejected before curl sends the key.
rm -f "$TMP_DIR/curl-calls.txt" "$TMP_DIR/curl-args.txt"
code=$(run_case http_url "${BASE_ENV[@]}" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-http" INPUT_GRAPH_KPIS_SERVICE_MANAGER_URL="http://api.wordlift.io" "$SCRIPT")
assert_eq "0" "$code" "non-HTTPS service-manager URL should be warning-only by default"
http_out="$(cat "$TMP_DIR/http_url.out")"
assert_contains "service-manager URL is not allowed" "$http_out" "non-HTTPS URL should warn"
assert_eq "0" "$(test ! -f "$TMP_DIR/curl-calls.txt"; echo $?)" "non-HTTPS URL should be rejected before curl"

# Case 7: account id from /accounts/me must be numeric.
code=$(run_case bad_account_id "${BASE_ENV[@]}" CURL_ACCOUNT_RESPONSE='{"account_id":"../1506805"}' INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-bad-account" "$SCRIPT")
assert_eq "0" "$code" "malformed account id should be warning-only by default"
bad_account_out="$(cat "$TMP_DIR/bad_account_id.out")"
assert_contains "/accounts/me did not return an account id" "$bad_account_out" "malformed account id should warn"

# Case 8: snapshot date must be a strict calendar date before it reaches the URL path.
code=$(run_case bad_snapshot_date "${BASE_ENV[@]}" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-bad-date" INPUT_GRAPH_KPIS_SNAPSHOT_DATE="2026-06-23/extra" "$SCRIPT")
assert_eq "0" "$code" "malformed snapshot date should be warning-only by default"
bad_date_out="$(cat "$TMP_DIR/bad_snapshot_date.out")"
assert_contains "snapshot date is invalid" "$bad_date_out" "malformed snapshot date should warn"

# Case 9: service-manager base URL must be an origin, not a URL with query/path content.
code=$(run_case base_url_query "${BASE_ENV[@]}" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="prod" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-base-query" INPUT_GRAPH_KPIS_SERVICE_MANAGER_URL="https://api.wordlift.io?debug=true" "$SCRIPT")
assert_eq "0" "$code" "base URL with query should be warning-only by default"
base_query_out="$(cat "$TMP_DIR/base_url_query.out")"
assert_contains "service-manager URL is not allowed" "$base_query_out" "base URL with query should warn"

# Case 10: relative WORAI_CONFIG is resolved from working_directory, matching worai execution.
rm -f "$TMP_DIR/curl-calls.txt" "$TMP_DIR/curl-count.txt" "$TMP_DIR/payload.json"
code=$(run_case worai_config_relative "${BASE_ENV[@]}" WORAI_CONFIG="./custom.toml" INPUT_GRAPH_KPIS_ENABLED="true" INPUT_PROFILE="custom" INPUT_WORKING_DIRECTORY="$WORK_DIR" INPUT_OUTPUT_DIR="$TMP_DIR/out-worai-config" INPUT_GRAPH_KPIS_SNAPSHOT_DATE="2026-06-23" "$SCRIPT")
assert_eq "0" "$code" "relative WORAI_CONFIG should resolve from working_directory"

if [[ "$fail_count" -ne 0 ]]; then
  echo "\n$fail_count test(s) failed, $pass_count passed"
  exit 1
fi

echo "$pass_count test(s) passed"
