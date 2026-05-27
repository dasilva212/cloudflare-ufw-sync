#!/bin/bash
# =============================================================================
#  cloudflare-ufw-sync.sh
#  Fetches Cloudflare IP ranges and syncs them into UFW as allowed sources
#  for TCP ports 80 (HTTP) and 443 (HTTPS) only.
#
#  Repo   : https://github.com/dasilva212/cloudflare-ufw-sync
#  License: GPL v2 or later
# =============================================================================

set -euo pipefail

# =============================================================================
#  Configuration — edit these if needed
# =============================================================================
CF_V4_URL="https://www.cloudflare.com/ips-v4"
CF_V6_URL="https://www.cloudflare.com/ips-v6"
COMMENT="Cloudflare"
DIR="$(dirname "$(readlink -f "$0")")"
LOGFILE="/var/log/cloudflare-ufw-sync.log"
STATEFILE="/etc/cloudflare-ufw.state"
MIN_V4_EXPECTED=5        
MIN_V6_EXPECTED=3        

# =============================================================================
#  Logging — writes to terminal AND appends to $LOGFILE simultaneously
# =============================================================================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

# =============================================================================
#  Pre-flight checks
# =============================================================================
[ "$(id -u)" -eq 0 ] || {
  echo "ERROR: This script must be run as root (or via sudo)" >&2
  exit 1
}

command -v curl >/dev/null 2>&1 || {
  echo "ERROR: 'curl' is required but not installed. Run: apt install curl" >&2
  exit 1
}

command -v ufw >/dev/null 2>&1 || {
  echo "ERROR: 'ufw' is required but not installed. Run: apt install ufw" >&2
  exit 1
}

cd "$DIR"

log "===== Cloudflare UFW Sync Started ====="

# =============================================================================
#  Fetch IP ranges from Cloudflare
# =============================================================================
log "Fetching Cloudflare IPv4 ranges from $CF_V4_URL ..."
curl -sSf --max-time 15 --retry 3 "$CF_V4_URL" -o ips-v4.tmp || {
  log "ERROR: Failed to download IPv4 ranges — aborting with no changes made"
  rm -f ips-v4.tmp
  exit 1
}

log "Fetching Cloudflare IPv6 ranges from $CF_V6_URL ..."
curl -sSf --max-time 15 --retry 3 "$CF_V6_URL" -o ips-v6.tmp || {
  log "ERROR: Failed to download IPv6 ranges — aborting with no changes made"
  rm -f ips-v4.tmp ips-v6.tmp
  exit 1
}

# =============================================================================
#  Validate downloaded content
#  Ensures files contain only valid CIDR notation — nothing else.
#  Aborts and discards temp files if anything looks unexpected.
# =============================================================================
log "Validating downloaded IP range files..."

invalid_v4=$(grep -vE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' ips-v4.tmp \
  | grep -v '^[[:space:]]*$' || true)
if [ -n "$invalid_v4" ]; then
  log "ERROR: ips-v4.tmp contains unexpected content:"
  log "       $invalid_v4"
  log "       Aborting — no UFW rules have been changed"
  rm -f ips-v4.tmp ips-v6.tmp
  exit 1
fi

invalid_v6=$(grep -vE '^[0-9a-fA-F:]+/[0-9]{1,3}$' ips-v6.tmp \
  | grep -v '^[[:space:]]*$' || true)
if [ -n "$invalid_v6" ]; then
  log "ERROR: ips-v6.tmp contains unexpected content:"
  log "       $invalid_v6"
  log "       Aborting — no UFW rules have been changed"
  rm -f ips-v4.tmp ips-v6.tmp
  exit 1
fi

# Sanity-check minimum counts — guards against empty/truncated responses
v4_count=$(grep -cE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$' ips-v4.tmp)
v6_count=$(grep -cE '^[0-9a-fA-F:]+/[0-9]{1,3}$' ips-v6.tmp)

[ "$v4_count" -lt "$MIN_V4_EXPECTED" ] && {
  log "ERROR: Only $v4_count IPv4 ranges found — expected at least $MIN_V4_EXPECTED"
  log "       Response may be truncated or invalid. Aborting."
  rm -f ips-v4.tmp ips-v6.tmp
  exit 1
}

[ "$v6_count" -lt "$MIN_V6_EXPECTED" ] && {
  log "ERROR: Only $v6_count IPv6 ranges found — expected at least $MIN_V6_EXPECTED"
  log "       Response may be truncated or invalid. Aborting."
  rm -f ips-v4.tmp ips-v6.tmp
  exit 1
}

log "Validation passed: $v4_count IPv4 CIDRs and $v6_count IPv6 CIDRs look valid"

# =============================================================================
#  State Check — Avoid dropping rules if IPs haven't changed
# =============================================================================
cat ips-v4.tmp ips-v6.tmp | sort > new_state.tmp

if [ -f "$STATEFILE" ]; then
  sort "$STATEFILE" > old_state.tmp
else
  touch old_state.tmp
fi

if cmp -s new_state.tmp old_state.tmp; then
  log "Cloudflare IPs are unchanged since last run. No UFW updates required."
  rm -f ips-v4.tmp ips-v6.tmp new_state.tmp old_state.tmp
  log "===== Cloudflare UFW Sync Complete ====="
  exit 0
fi

# IPs have changed, proceed with update
rm -f new_state.tmp old_state.tmp
mv ips-v4.tmp ips-v4
mv ips-v6.tmp ips-v6
log "Changes detected (or first run). Proceeding with UFW updates..."

# =============================================================================
#  Flush previous Cloudflare rules using the state file
# =============================================================================
log "Removing previous Cloudflare UFW rules..."
removed=0

if [ -f "$STATEFILE" ]; then
  while IFS= read -r old_ip; do
    [[ -z "$old_ip" || "$old_ip" == \#* ]] && continue
    if ufw delete allow proto tcp from "$old_ip" to any port 80,443 >/dev/null 2>&1; then
      removed=$((removed + 1))
    else
      log "WARN: Could not remove rule for $old_ip — may have already been deleted"
    fi
  done < "$STATEFILE"
  rm -f "$STATEFILE"
  log "Removed $removed old Cloudflare rules"
else
  log "No state file found at $STATEFILE — assuming this is a first run"
fi

# =============================================================================
#  Add new rules and record each CIDR to the state file
# =============================================================================

# IPv4
log "Adding new IPv4 rules..."
ipv4_added=0
while IFS= read -r cfip; do
  [[ -z "$cfip" || "$cfip" == \#* ]] && continue
  ufw allow proto tcp from "$cfip" to any port 80,443 comment "$COMMENT" >/dev/null
  echo "$cfip" >> "$STATEFILE"
  ipv4_added=$((ipv4_added + 1))
done < ips-v4
log "Added $ipv4_added IPv4 rules"

# IPv6 — only if UFW has IPv6 support enabled
if grep -q '^IPV6=yes' /etc/default/ufw 2>/dev/null; then
  log "Adding new IPv6 rules..."
  ipv6_added=0
  while IFS= read -r cfip; do
    [[ -z "$cfip" || "$cfip" == \#* ]] && continue
    ufw allow proto tcp from "$cfip" to any port 80,443 comment "$COMMENT" >/dev/null
    echo "$cfip" >> "$STATEFILE"
    ipv6_added=$((ipv6_added + 1))
  done < ips-v6
  log "Added $ipv6_added IPv6 rules"
else
  log "WARNING: IPv6 is disabled in /etc/default/ufw — skipping IPv6 rules"
  log "         To enable: set IPV6=yes in /etc/default/ufw and re-run"
fi

log "===== Cloudflare UFW Sync Complete ====="
