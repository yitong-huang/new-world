#!/usr/bin/env bash
# Stream idevicesyslog from USB iPhone, grep NWVPN-related lines, append to repo .cursor/debug-2902a2.log
#
# Requires: brew install libimobiledevice
#
# Usage (from repo root):
#   ./scripts/ios_device_logs_to_cursor.sh
#   ./scripts/ios_device_logs_to_cursor.sh fresh
#
# Env:
#   IOS_DEVICE_UDID   idevicesyslog -u
#   IOS_LOG_FILTER    grep -E pattern (default below)

set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/.cursor/debug-2902a2.log"
mkdir -p "$(dirname "$OUT")"

# Default grep pattern (ASCII only; avoid CRLF / fancy quotes in this file)
DEFAULT_FILTER='NWVPN|nwvpn|PacketTunnel|NWVPNiOSPacketTunnel|2902a2|com\.newworld\.nwvpn|nwvpn\.ios\.debug|VPNManager|lastDisconnectError|NWTunnel|NEVPN|NESMVPNSession|nesessionmanager|neagent|NetworkExtension|provider|plugin'
if [[ -n "${IOS_LOG_FILTER:-}" ]]; then
  FILTER="${IOS_LOG_FILTER}"
else
  FILTER="${DEFAULT_FILTER}"
fi

if [[ "${1:-}" == "fresh" ]]; then
  : >"$OUT"
  echo "Cleared: $OUT"
  shift || true
fi

if ! command -v idevicesyslog >/dev/null 2>&1; then
  echo "idevicesyslog not found. Install: brew install libimobiledevice" >&2
  echo "Or use Console.app on Mac, select iPhone, filter com.newworld.nwvpn.ios.debug, paste into:" >&2
  echo "  $OUT" >&2
  exit 1
fi

echo "Appending to: $OUT (Ctrl+C to stop); filter: $FILTER"
{
  echo ""
  echo "# idevicesyslog $(date "+%Y-%m-%dT%H:%M:%S%z") filter=${FILTER}"
} >>"$OUT"

# Bash 3.2 + set -u: empty "${ARGS[@]}" can be "unbound"; branch instead.
if [[ -n "${IOS_DEVICE_UDID:-}" ]]; then
  idevicesyslog -u "${IOS_DEVICE_UDID}" 2>/dev/null | grep -E --line-buffered "${FILTER}" | tee -a "$OUT"
else
  idevicesyslog 2>/dev/null | grep -E --line-buffered "${FILTER}" | tee -a "$OUT"
fi
