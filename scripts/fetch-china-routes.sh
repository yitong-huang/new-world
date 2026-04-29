#!/usr/bin/env bash
# 更新直连 CIDR 列表：
# - CN 主表（多源合并） -> configs/china_ipv4.txt
# - HK+MO 补丁表 -> configs/extra_direct_ipv4.txt
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CN_OUT="${ROOT}/configs/china_ipv4.txt"
EXTRA_OUT="${ROOT}/configs/extra_direct_ipv4.txt"
mkdir -p "${ROOT}/configs"

CN_URL_IPDENY="https://www.ipdeny.com/ipblocks/data/countries/cn.zone"
CN_URL_17MON="https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt"
CN_URL_CLANG="https://ispip.clang.cn/all_cn_cidr.txt"
CN_URL_GAOYIFAN="https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt"
CN_URL_CHNROUTES2="https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt"
HK_URL="https://www.ipdeny.com/ipblocks/data/countries/hk.zone"
MO_URL="https://www.ipdeny.com/ipblocks/data/countries/mo.zone"

curl -fsSL --connect-timeout 20 --max-time 180 "$CN_URL_IPDENY" -o /tmp/cn_ipdeny.txt
curl -fsSL --connect-timeout 20 --max-time 180 "$CN_URL_17MON" -o /tmp/cn_17mon.txt
curl -fsSL --connect-timeout 20 --max-time 180 "$CN_URL_CLANG" -o /tmp/cn_clang.txt
curl -fsSL --connect-timeout 20 --max-time 180 "$CN_URL_GAOYIFAN" -o /tmp/cn_gaoyifan.txt
curl -fsSL --connect-timeout 20 --max-time 180 "$CN_URL_CHNROUTES2" -o /tmp/cn_chnroutes2.txt

python3 - "$CN_OUT" <<'PY'
import datetime
import ipaddress
import sys
from pathlib import Path

out = Path(sys.argv[1])
inputs = [
    ("ipdeny_cn", Path("/tmp/cn_ipdeny.txt")),
    ("17mon", Path("/tmp/cn_17mon.txt")),
    ("clang_all_cn", Path("/tmp/cn_clang.txt")),
    ("gaoyifan_china", Path("/tmp/cn_gaoyifan.txt")),
    ("chnroutes2", Path("/tmp/cn_chnroutes2.txt")),
]

all_nets = []
for _, p in inputs:
    for line in p.read_text(encoding="utf-8", errors="ignore").splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        try:
            n = ipaddress.ip_network(s, strict=False)
        except ValueError:
            continue
        if n.version == 4:
            all_nets.append(n)

collapsed = [n for n in ipaddress.collapse_addresses(all_nets) if n.version == 4]

header = [
    "# 中国大陆 IPv4 CIDR（自动更新，多源合并）",
    "# Sources:",
    "# - https://www.ipdeny.com/ipblocks/data/countries/cn.zone",
    "# - https://raw.githubusercontent.com/17mon/china_ip_list/master/china_ip_list.txt",
    "# - https://ispip.clang.cn/all_cn_cidr.txt",
    "# - https://raw.githubusercontent.com/gaoyifan/china-operator-ip/ip-lists/china.txt",
    "# - https://raw.githubusercontent.com/misakaio/chnroutes2/master/chnroutes.txt",
    f"# Updated: {datetime.date.today().isoformat()}",
    f"# Raw prefixes total: {len(all_nets)}",
    f"# Collapsed prefixes total: {len(collapsed)}",
    "# 说明：此主表偏“尽量覆盖”，可能含少量非大陆/争议段；可结合 extra_direct_ipv4.txt 做修正。",
    "",
]
out.write_text("\n".join(header + [str(n) for n in collapsed]) + "\n", encoding="utf-8")
print(len(collapsed))
PY

{
  curl -fsSL --connect-timeout 20 --max-time 180 "$HK_URL"
  curl -fsSL --connect-timeout 20 --max-time 180 "$MO_URL"
} > "${EXTRA_OUT}.tmp"
if [[ ! -s "${EXTRA_OUT}.tmp" ]]; then
  echo "Failed to download HK/MO lists" >&2
  exit 1
fi
{
  echo "# 额外直连 IPv4 CIDR（补丁表）"
  echo "# Sources:"
  echo "# - $HK_URL"
  echo "# - $MO_URL"
  echo "# Updated: $(date +%F)"
  echo
  awk 'NF && $1 !~ /^#/{print $1}' "${EXTRA_OUT}.tmp" | awk '!seen[$0]++'
} > "$EXTRA_OUT"
rm -f "${EXTRA_OUT}.tmp"

echo "Wrote $CN_OUT ($(wc -l < "$CN_OUT") lines)"
echo "Wrote $EXTRA_OUT ($(wc -l < "$EXTRA_OUT") lines)"
