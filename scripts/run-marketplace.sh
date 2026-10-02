#!/usr/bin/env bash
#
# Downloads, installs and activates every plugin of the GLPI Marketplace catalog,
# one after another, without resetting state between them, to detect plugins that
# break the GLPI core once combined with others (not just standalone breakage,
# already covered by each plugin's own CI).
#
# Usage: run-marketplace.sh <priority-plugins-file>
# Must be run from the GLPI root directory (where bin/console lives).

set -uo pipefail

PRIORITY_FILE="${1:?Usage: run-marketplace.sh <priority-plugins-file>}"
LOG_FILE="files/_log/php-errors.log"
CATALOG_FILE="/tmp/marketplace-catalog.txt"
ORDERED_FILE="/tmp/marketplace-order.txt"
RESULTS_FILE="/tmp/marketplace-results.tsv"
REPORT_MD="/tmp/marketplace-report.md"
REPORT_JSON="/tmp/marketplace-report.json"

echo "Fetching marketplace catalog..."
php bin/console marketplace:search --no-ansi --no-interaction \
  | awk -F'|' 'NR > 3 { gsub(/^[ \t]+|[ \t]+$/, "", $2); if ($2 != "") print $2 }' \
  | grep -E '^[a-z0-9_]+$' \
  | sort -u > "$CATALOG_FILE"

if [[ ! -s "$CATALOG_FILE" ]]; then
  echo "No plugin found in the marketplace catalog (missing/invalid registration key, or network issue)." >&2
  exit 1
fi
echo "Found $(wc -l < "$CATALOG_FILE") plugins in the catalog."

: > "$ORDERED_FILE"
if [[ -f "$PRIORITY_FILE" ]]; then
  while IFS= read -r key; do
    [[ -z "$key" || "$key" == \#* ]] && continue
    if grep -qxF "$key" "$CATALOG_FILE"; then
      echo "$key" >> "$ORDERED_FILE"
    fi
  done < "$PRIORITY_FILE"
fi
comm -23 "$CATALOG_FILE" <(sort -u "$ORDERED_FILE") >> "$ORDERED_FILE"

: > "$RESULTS_FILE"
ACTIVE_PLUGINS=()
LAST_LOG_LINES=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
HEALTH_STATUS=""

# Scans php-errors.log for lines appended since the last call; always advances
# the read pointer so a failed step's errors aren't misattributed to the next plugin.
scan_new_log_errors() {
  NEW_LOG_ERRORS=""

  local current_lines
  current_lines=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
  if [[ "$current_lines" -gt "$LAST_LOG_LINES" ]]; then
    if tail -n "+$((LAST_LOG_LINES + 1))" "$LOG_FILE" | grep -qiE 'fatal error|uncaught exception'; then
      NEW_LOG_ERRORS="php_fatal_error"
    fi
  fi
  LAST_LOG_LINES="$current_lines"
}

healthcheck() {
  HEALTH_STATUS=""

  local http_code
  http_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://localhost/" || echo "000")
  if [[ "$http_code" -ge 500 || "$http_code" == "000" ]]; then
    HEALTH_STATUS="http_${http_code}"
  fi

  scan_new_log_errors
  if [[ -n "$NEW_LOG_ERRORS" ]]; then
    HEALTH_STATUS="${HEALTH_STATUS:+$HEALTH_STATUS,}$NEW_LOG_ERRORS"
  fi
}

# Strips Symfony error box padding/blank border lines, keeps the last few meaningful lines.
clean_detail() {
  sed -E 's/[[:space:]]+$//' "$1" | sed '/^[[:space:]]*$/d' | tail -n 5
}

record() {
  local key="$1" status="$2" detail="$3"
  local active_csv
  active_csv=$(IFS=,; echo "${ACTIVE_PLUGINS[*]:-}")
  active_csv="${active_csv//,/, }"
  detail="${detail//$'\t'/ }"
  detail="${detail//$'\n'/ }"
  printf '%s\t%s\t%s\t%s\n' "$key" "$status" "$detail" "$active_csv" >> "$RESULTS_FILE"
}

# Versions already on disk (downloaded by a previous run, restored from cache),
# keyed by plugin, fetched once instead of per-plugin to avoid extra API calls.
declare -A LOCAL_VERSIONS
while IFS=$'\t' read -r local_key local_version; do
  [[ -z "$local_key" ]] && continue
  LOCAL_VERSIONS["$local_key"]="$local_version"
done < <(php bin/console plugin:list --no-ansi --no-interaction --format=json 2>/dev/null \
  | jq -r '.[] | "\(.key)\t\(.version)"')

# Fetches marketplace:info once per plugin, exposing the latest compatible version as
# REMOTE_VERSION, reused for the version pre-filter and the stale-cache check.
fetch_marketplace_info() {
  local key="$1"
  REMOTE_VERSION=""
  local info
  if ! info=$(php bin/console marketplace:info --no-ansi --no-interaction "$key" 2>/dev/null); then
    # Info lookup failed: don't pre-filter, let the download attempt decide.
    return 0
  fi
  # Non-empty 'versions' array starts with a '0 =>' entry right after it.
  if ! echo "$info" | grep -A3 "'versions' =>" | grep -q "0 =>"; then
    return 1
  fi
  REMOTE_VERSION=$(echo "$info" | grep -oP "^  'version' => '\K[^']*")
  return 0
}

while IFS= read -r key; do
  [[ -z "$key" ]] && continue
  echo "::group::$key"

  if ! fetch_marketplace_info "$key"; then
    record "$key" "incompatible_version" "No version available for this GLPI instance"
    echo "Plugin \"$key\" has no compatible version for this GLPI instance, skipping."
    echo "::endgroup::"
    continue
  fi

  # Only force a re-download when a cached copy exists but is not the latest
  # compatible version; an up-to-date cache hit costs no download API call.
  DOWNLOAD_FLAGS=()
  if [[ -n "${LOCAL_VERSIONS[$key]+set}" && "${LOCAL_VERSIONS[$key]}" != "$REMOTE_VERSION" ]]; then
    DOWNLOAD_FLAGS+=(--force)
  fi

  if ! php bin/console marketplace:download --no-ansi --no-interaction "${DOWNLOAD_FLAGS[@]}" "$key" > /tmp/step.log 2>&1; then
    scan_new_log_errors
    record "$key" "download_failed" "$(clean_detail /tmp/step.log)${NEW_LOG_ERRORS:+ [$NEW_LOG_ERRORS]}"
    cat /tmp/step.log
    echo "::endgroup::"
    continue
  fi

  # marketplace:download can exit 0 without actually fetching/extracting anything
  # (just a warning); verify the plugin directory is there before plugin:install.
  if [[ ! -f "marketplace/$key/setup.php" ]]; then
    record "$key" "download_failed" "Archive was not downloaded/extracted (marketplace:download reported success but marketplace/$key/setup.php is missing)"
    cat /tmp/step.log
    echo "::endgroup::"
    continue
  fi

  if ! php bin/console plugin:install --no-ansi --no-interaction --username=glpi "$key" > /tmp/step.log 2>&1; then
    scan_new_log_errors
    record "$key" "install_failed" "$(clean_detail /tmp/step.log)${NEW_LOG_ERRORS:+ [$NEW_LOG_ERRORS]}"
    cat /tmp/step.log
    echo "::endgroup::"
    continue
  fi

  if ! php bin/console plugin:activate --no-ansi --no-interaction "$key" > /tmp/step.log 2>&1; then
    scan_new_log_errors
    record "$key" "activate_failed" "$(clean_detail /tmp/step.log)${NEW_LOG_ERRORS:+ [$NEW_LOG_ERRORS]}"
    cat /tmp/step.log
    php bin/console plugin:uninstall --no-ansi --no-interaction "$key" > /dev/null 2>&1 || true
    echo "::endgroup::"
    continue
  fi

  healthcheck
  if [[ -n "$HEALTH_STATUS" ]]; then
    record "$key" "broke_core" "$HEALTH_STATUS"
    echo "Plugin broke the core ($HEALTH_STATUS), rolling it back."
    php bin/console plugin:deactivate --no-ansi --no-interaction "$key" > /dev/null 2>&1 || true
    php bin/console plugin:uninstall --no-ansi --no-interaction "$key" > /dev/null 2>&1 || true
    echo "::endgroup::"
    continue
  fi

  ACTIVE_PLUGINS+=("$key")
  record "$key" "ok" ""
  echo "::endgroup::"
done < "$ORDERED_FILE"

# Wraps a comma-separated plugin list in a collapsible block so table rows
# stay short; the count alone is visible without expanding.
active_cell() {
  local active="$1"
  [[ -z "$active" ]] && { echo ""; return; }
  local count
  count=$(( $(grep -o ', ' <<< "$active" | wc -l) + 1 ))
  echo "<details><summary>$count active</summary>$active</details>"
}

INCOMPATIBLE_COUNT=$(awk -F'\t' '$2 == "incompatible_version"' "$RESULTS_FILE" | wc -l)
ISSUES_COUNT=$(awk -F'\t' '$2 != "ok" && $2 != "incompatible_version"' "$RESULTS_FILE" | wc -l)

{
  echo "# Marketplace compatibility scan (GLPI ${GLPI_VERSION:-unknown})"
  echo
  echo "| 🧪 Tested | ✅ OK | ⚠️ Issues | ⏭️ Not available for this GLPI version |"
  echo "|---|---|---|---|"
  echo "| $(wc -l < "$ORDERED_FILE") | ${#ACTIVE_PLUGINS[@]} | $ISSUES_COUNT | $INCOMPATIBLE_COUNT |"
  echo
  echo "**Status legend:** 💥 \`broke_core\` = plugin broke GLPI once combined with the others already active, the actionable signal this scan exists for &middot; ❌ \`install_failed\`/\`activate_failed\`/\`download_failed\` = plugin itself failed (bug, missing prerequisite, unmet system requirement), usually not a cross-plugin conflict &middot; ⏭️ \`incompatible_version\` = no version published for this GLPI release, expected noise."
  echo
  if [[ "$ISSUES_COUNT" -gt 0 ]]; then
    echo "## ⚠️ Issues (actionable signal)"
    echo
    echo "| Plugin | Status | Detail | Active plugins at the time |"
    echo "|---|---|---|---|"
    while IFS=$'\t' read -r key status detail active; do
      [[ "$status" == "ok" || "$status" == "incompatible_version" ]] && continue
      # Escape pipes: raw '|' in detail would otherwise break the table row.
      echo "| $key | $status | ${detail//|/\\|} | $(active_cell "$active") |"
    done < "$RESULTS_FILE"
    echo
  fi
  if [[ "$INCOMPATIBLE_COUNT" -gt 0 ]]; then
    echo "<details><summary>⏭️ Not available for this GLPI version ($INCOMPATIBLE_COUNT, expected noise)</summary>"
    echo
    while IFS=$'\t' read -r key status _detail _active; do
      [[ "$status" == "incompatible_version" ]] || continue
      echo "- $key"
    done < "$RESULTS_FILE"
    echo
    echo "</details>"
  fi
} > "$REPORT_MD"

jq -R -s -c '
  split("\n") | map(select(length > 0) | split("\t"))
  | map({key: .[0], status: .[1], detail: .[2], active_plugins: ((.[3] // "") | split(",") | map(select(length > 0)))})
' "$RESULTS_FILE" > "$REPORT_JSON"

cat "$REPORT_MD"

# Zero `ok` with compatible candidates means the scan environment itself is broken
# (disk/rights/network); fail the job instead of staying green.
ATTEMPTED_COUNT=$(( $(wc -l < "$ORDERED_FILE") - INCOMPATIBLE_COUNT ))
if [[ "$ATTEMPTED_COUNT" -gt 0 && "${#ACTIVE_PLUGINS[@]}" -eq 0 ]]; then
  echo "No plugin could be installed out of $ATTEMPTED_COUNT compatible candidate(s): failing the job." >&2
  exit 1
fi
