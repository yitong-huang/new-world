#!/usr/bin/env bash
# 使用国内 DNS 解析域名列表，并将 A 记录(/32)合并到 extra_direct_ipv4.txt
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOMAINS_FILE="${1:-${ROOT}/configs/direct_domains.txt}"
EXTRA_FILE="${2:-${ROOT}/configs/extra_direct_ipv4.txt}"
DNS_SERVERS="${DNS_SERVERS:-223.5.5.5 119.29.29.29 114.114.114.114}"

if [[ ! -f "$DOMAINS_FILE" ]]; then
  echo "domains file not found: $DOMAINS_FILE" >&2
  exit 1
fi

mkdir -p "$(dirname "$EXTRA_FILE")"
touch "$EXTRA_FILE"

TMP_IPS="$(mktemp)"
TMP_OUT="$(mktemp)"
trap 'rm -f "$TMP_IPS" "$TMP_OUT"' EXIT

while IFS= read -r domain; do
  domain="${domain%%#*}"
  domain="$(echo "$domain" | xargs)"
  [[ -z "$domain" ]] && continue
  for dns in $DNS_SERVERS; do
    dig +short A "$domain" @"$dns" 2>/dev/null | awk '/^[0-9.]+$/{print $0"/32"}' >> "$TMP_IPS" || true
  done
done < "$DOMAINS_FILE"

python3 - "$EXTRA_FILE" "$TMP_IPS" "$TMP_OUT" <<'PY'
import ipaddress
import sys
from pathlib import Path

extra_file = Path(sys.argv[1])
new_ips_file = Path(sys.argv[2])
out_file = Path(sys.argv[3])

nets = set()

if extra_file.exists():
    for line in extra_file.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        try:
            nets.add(str(ipaddress.ip_network(s, strict=False)))
        except ValueError:
            pass

for line in new_ips_file.read_text(encoding="utf-8", errors="ignore").splitlines():
    s = line.strip()
    if not s:
        continue
    try:
        nets.add(str(ipaddress.ip_network(s, strict=False)))
    except ValueError:
        pass

items = sorted(nets, key=lambda x: (int(ipaddress.ip_network(x).network_address), ipaddress.ip_network(x).prefixlen))

header = [
    "# 额外直连 IPv4 CIDR（补丁表）",
    "# 自动维护：scripts/update-extra-direct-from-domains.sh",
    "# 可与 fetch-china-routes.sh 生成内容合并使用",
    "",
]
out_file.write_text("\n".join(header + items) + "\n", encoding="utf-8")
print(f"merged_total={len(items)}")
PY

mv "$TMP_OUT" "$EXTRA_FILE"
echo "updated $EXTRA_FILE from $DOMAINS_FILE"
