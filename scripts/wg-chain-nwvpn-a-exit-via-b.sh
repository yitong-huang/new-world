#!/usr/bin/env bash
# 方案一自动化：在 A、B 两台 Linux 上配置 WireGuard，使用户连 A 上 nw-server（源网段默认 10.77.0.0/24）
# 的 IPv4 流量经隧道从 B 的公网口 NAT 出口。
#
# 本机依赖：bash、ssh、scp；密码 SSH 需 sshpass。密钥在远程 A/B 上生成，本机无需安装 wg。
#   本机可选：brew install sshpass（macOS）或 apt install sshpass
#
# 必填：主机名（环境变量或见下方「凭据区」内联主机）
#   WG_CHAIN_NODE_A       SSH：用户连 nw 的入口机
#   WG_CHAIN_NODE_B       SSH：出口机；默认同 WG Endpoint（见 WG_CHAIN_ENDPOINT）
#
# 密码：可在下方「凭据区」填写 WG_CHAIN_PASSWORD（或分 A/B）；也可用环境变量
#   WG_CHAIN_SSH_PASSWORD / WG_CHAIN_A_PASSWORD / WG_CHAIN_B_PASSWORD
# 优先级：凭据区内联 > 对应环境变量（勿将含密码的脚本提交到公开仓库）
#
# 可选环境变量：
#   WG_CHAIN_SSH_USER         默认 root
#   WG_CHAIN_ENDPOINT         B 的 WG 对端地址（默认同 NODE_B）；B 在 NAT 后时请填公网 IP 或 DDNS
#   WG_CHAIN_LISTEN_PORT      B 上 WG UDP 端口，默认 51820
#   WG_CHAIN_USER_SUBNET      与 A 上 nw-server 用户源网段一致，默认 10.77.0.0/24
#                             注意：B 上若也有 nw-server 且 tun 为同网段，wg-quick 会与链式路由冲突；
#                             本脚本在 B 上使用 Table=off 并尽量补回程路由；仍冲突时请让 B 仅作出口或改 B 的 -tun-cidr
#   WG_CHAIN_LINK_SUBNET      隧道内网段，默认 10.200.0.0/24（A=.1，B=.2，仅支持 x.y.z.0/24）
#   WG_CHAIN_REMOVE_A_NW_NAT 默认 1：在 A 上删除 nft 表 ip nwvpn（deploy 脚本配的 MASQ），避免仍从 A 公网出
#   WG_CHAIN_POLICY_TABLE     策略路由表号，默认 200
#   WG_CHAIN_STOP_NW          默认 1：在改网络前于 A、B 上停止运行中的 nw-server（systemd nwvpn-nw-server + pkill）
#   WG_CHAIN_NW_REMOTE_DIR    nw-server 安装目录，与 deploy 一致，默认 /opt/nwvpn（用于匹配进程路径）
#   WG_CHAIN_RESTART_NW_A     默认 1：在 A 上 wg-quick up 后执行 systemctl start nwvpn-nw-server（客户端连 A 必需）
#   WG_CHAIN_AUTO_INSTALL_NW  默认 1：若 A/B 上既无 nwvpn-nw-server.service 又无 ${WG_CHAIN_NW_REMOTE_DIR}/bin/nw-server，则调用 deploy-nw-server.sh 安装
#   WG_CHAIN_DEPLOY_NAT_A      默认 0：链式出口经 B 时 A 上不配直连公网 NAT（与 WG_CHAIN_REMOVE_A_NW_NAT 一致）
#   WG_CHAIN_DEPLOY_NAT_B      默认 1：B 上 deploy 时保留 NAT（与 WG 出口常见需求一致）
#
# 用法示例：在「凭据区」填 NODE 与 PASSWORD，或仍用 export 环境变量后执行：
#   bash scripts/wg-chain-nwvpn-a-exit-via-b.sh
#
set -euo pipefail

# ========== 凭据（可在此填写；勿将含密码的脚本提交到公开仓库）==========
WG_CHAIN_NODE_A_INLINE='new-world-us-01.2fish.com.cn'
WG_CHAIN_NODE_B_INLINE='new-world-us-01-real.2fish.com.cn'
WG_CHAIN_PASSWORD='sDMkQ8ZnQFDTNFY4BeWK'
WG_CHAIN_PASSWORD_A=''
WG_CHAIN_PASSWORD_B=''
# ==============================================================

WG_CHAIN_NODE_A="${WG_CHAIN_NODE_A:-}"
WG_CHAIN_NODE_B="${WG_CHAIN_NODE_B:-}"
[[ -n "${WG_CHAIN_NODE_A_INLINE}" ]] && WG_CHAIN_NODE_A="${WG_CHAIN_NODE_A_INLINE}"
[[ -n "${WG_CHAIN_NODE_B_INLINE}" ]] && WG_CHAIN_NODE_B="${WG_CHAIN_NODE_B_INLINE}"

WG_CHAIN_SSH_USER="${WG_CHAIN_SSH_USER:-root}"
WG_CHAIN_ENDPOINT="${WG_CHAIN_ENDPOINT:-$WG_CHAIN_NODE_B}"
WG_CHAIN_LISTEN_PORT="${WG_CHAIN_LISTEN_PORT:-51820}"
WG_CHAIN_USER_SUBNET="${WG_CHAIN_USER_SUBNET:-10.77.0.0/24}"
WG_CHAIN_LINK_SUBNET="${WG_CHAIN_LINK_SUBNET:-10.200.0.0/24}"
WG_CHAIN_REMOVE_A_NW_NAT="${WG_CHAIN_REMOVE_A_NW_NAT:-1}"
WG_CHAIN_POLICY_TABLE="${WG_CHAIN_POLICY_TABLE:-200}"
WG_CHAIN_STOP_NW="${WG_CHAIN_STOP_NW:-1}"
WG_CHAIN_NW_REMOTE_DIR="${WG_CHAIN_NW_REMOTE_DIR:-/opt/nwvpn}"
WG_CHAIN_RESTART_NW_A="${WG_CHAIN_RESTART_NW_A:-1}"
WG_CHAIN_AUTO_INSTALL_NW="${WG_CHAIN_AUTO_INSTALL_NW:-1}"
WG_CHAIN_DEPLOY_NAT_A="${WG_CHAIN_DEPLOY_NAT_A:-0}"
WG_CHAIN_DEPLOY_NAT_B="${WG_CHAIN_DEPLOY_NAT_B:-1}"

PW_A="${WG_CHAIN_PASSWORD_A:-${WG_CHAIN_PASSWORD:-${WG_CHAIN_A_PASSWORD:-${WG_CHAIN_SSH_PASSWORD:-}}}}"
PW_B="${WG_CHAIN_PASSWORD_B:-${WG_CHAIN_PASSWORD:-${WG_CHAIN_B_PASSWORD:-${WG_CHAIN_SSH_PASSWORD:-}}}}"

SSH_OPTS=( -o BatchMode=no -o StrictHostKeyChecking=accept-new )

die() { echo "error: $*" >&2; exit 1; }

[[ -n "$WG_CHAIN_NODE_A" ]] || die "请设置 WG_CHAIN_NODE_A"
[[ -n "$WG_CHAIN_NODE_B" ]] || die "请设置 WG_CHAIN_NODE_B"
[[ -n "$PW_A" && -n "$PW_B" ]] || die "请在本脚本「凭据区」填写 WG_CHAIN_PASSWORD（或 A/B 分填），或设置环境变量 WG_CHAIN_SSH_PASSWORD 等"

if ! command -v sshpass >/dev/null 2>&1; then
  die "未找到 sshpass（密码 SSH 需要）"
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -d "$ROOT/go" ]] || die "缺少 $ROOT/go；自动安装 nw-server 需在仓库根执行"
[[ -f "$ROOT/certs/server.crt" && -f "$ROOT/certs/server.key" ]] || die "缺少 certs/server.crt 或 server.key，请先: bash scripts/gen-certs.sh"

if [[ ! "$WG_CHAIN_LINK_SUBNET" =~ ^([0-9.]+)\.0/24$ ]]; then
  die "WG_CHAIN_LINK_SUBNET 暂仅支持 x.y.z.0/24，当前: $WG_CHAIN_LINK_SUBNET"
fi
LINK_BASE="${BASH_REMATCH[1]}"
ADDR_A="${LINK_BASE}.1"
ADDR_B="${LINK_BASE}.2"

ssh_a() { SSHPASS="$PW_A" sshpass -e ssh "${SSH_OPTS[@]}" "${WG_CHAIN_SSH_USER}@${WG_CHAIN_NODE_A}" "$@"; }
ssh_b() { SSHPASS="$PW_B" sshpass -e ssh "${SSH_OPTS[@]}" "${WG_CHAIN_SSH_USER}@${WG_CHAIN_NODE_B}" "$@"; }
scp_a() { SSHPASS="$PW_A" sshpass -e scp "${SSH_OPTS[@]}" "$@"; }
scp_b() { SSHPASS="$PW_B" sshpass -e scp "${SSH_OPTS[@]}" "$@"; }

run_deploy_nw_to() {
  local label=$1 host=$2 pass=$3 nat=$4
  (
    cd "$ROOT"
    export NW_DEPLOY_HOST="$host"
    export NW_SSH_USER="${WG_CHAIN_SSH_USER}"
    export NW_REMOTE_DIR="${WG_CHAIN_NW_REMOTE_DIR}"
    export NW_DEPLOY_NAT="$nat"
    export NW_DEPLOY_FORCE_PASSWORD="$pass"
    export NW_TUN_CIDR="${WG_CHAIN_USER_SUBNET}"
    bash "$ROOT/scripts/deploy-nw-server.sh"
  ) || die "${label}：deploy-nw-server.sh 失败"
}

maybe_auto_install_nw() {
  [[ "${WG_CHAIN_AUTO_INSTALL_NW}" == "1" ]] || return 0
  command -v rsync >/dev/null 2>&1 || die "自动安装 nw-server 需要本机已安装 rsync"

  if ssh_b env "REMOTE_DIR=${WG_CHAIN_NW_REMOTE_DIR}" bash -s <<'EOS'
[[ -f /etc/systemd/system/nwvpn-nw-server.service ]] && [[ -x "${REMOTE_DIR}/bin/nw-server" ]] && exit 1
exit 0
EOS
  then
    echo "==> B: 未检测到完整 nw-server（无单元或无可执行 bin），正在 deploy-nw-server.sh（NW_DEPLOY_NAT=${WG_CHAIN_DEPLOY_NAT_B}）..."
    run_deploy_nw_to "B" "$WG_CHAIN_NODE_B" "$PW_B" "${WG_CHAIN_DEPLOY_NAT_B}"
  fi

  if ssh_a env "REMOTE_DIR=${WG_CHAIN_NW_REMOTE_DIR}" bash -s <<'EOS'
[[ -f /etc/systemd/system/nwvpn-nw-server.service ]] && [[ -x "${REMOTE_DIR}/bin/nw-server" ]] && exit 1
exit 0
EOS
  then
    echo "==> A: 未检测到完整 nw-server（无单元或无可执行 bin），正在 deploy-nw-server.sh（NW_DEPLOY_NAT=${WG_CHAIN_DEPLOY_NAT_A}）..."
    run_deploy_nw_to "A" "$WG_CHAIN_NODE_A" "$PW_A" "${WG_CHAIN_DEPLOY_NAT_A}"
  fi
}

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
umask 077

# B：PostUp 用独立脚本；B 侧 Table=off 避免 wg-quick 自动 ip route add 用户网段与 nw TUN 冲突（RTNETLINK File exists）
cat >"$TMP/wg-chain-b-postup.sh" <<EOF
#!/bin/bash
set -euo pipefail
IF="\${INTERFACE:-wg0}"
USER_SUBNET="${WG_CHAIN_USER_SUBNET}"
sysctl -w net.ipv4.ip_forward=1
PUB=\$(ip -4 route show default | head -1 | sed -n 's/.* dev \\([^ ]*\\) .*/\\1/p')
[[ -n "\$PUB" ]]
if ! command -v nft >/dev/null 2>&1; then
  echo "error: 未找到 nft，请安装 nftables 或使用手工 iptables NAT" >&2
  exit 1
fi
nft delete table ip wg_chain_exit 2>/dev/null || true
nft add table ip wg_chain_exit
nft add chain ip wg_chain_exit postrouting '{ type nat hook postrouting priority 100; policy accept; }'
nft add rule ip wg_chain_exit postrouting "iifname \${IF}" "oifname \${PUB}" masquerade
# 回程：若内核尚无该前缀路由，则经 wg0 指向 A；若已有（多为 B 本机 nw TUN），仅告警
if ! ip -4 route show "\${USER_SUBNET}" 2>/dev/null | grep -q .
then
  ip -4 route add "\${USER_SUBNET}" dev "\${IF}" || true
else
  echo "warn: 本机已有 \${USER_SUBNET} 路由，未再添加 dev \${IF}。若 B 同时跑 nw-server 同网段，链式回程需改 B 的 tun 网段或策略路由。" >&2
fi
EOF

cat >"$TMP/wg-chain-b-postdown.sh" <<EOF
#!/bin/bash
IF="\${INTERFACE:-wg0}"
USER_SUBNET="${WG_CHAIN_USER_SUBNET}"
nft delete table ip wg_chain_exit 2>/dev/null || true
ip route del "\${USER_SUBNET}" dev "\${IF}" 2>/dev/null || true
EOF
chmod +x "$TMP/wg-chain-b-postup.sh" "$TMP/wg-chain-b-postdown.sh"

remote_install_wg_a() {
  ssh_a bash -s <<'EOS'
export DEBIAN_FRONTEND=noninteractive
if command -v wg >/dev/null 2>&1; then exit 0; fi
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools
  exit 0
fi
echo "error: 未找到 apt-get，请手工安装 wireguard-tools" >&2
exit 1
EOS
}

remote_install_wg_b() {
  ssh_b bash -s <<'EOS'
export DEBIAN_FRONTEND=noninteractive
if command -v wg >/dev/null 2>&1; then exit 0; fi
if command -v apt-get >/dev/null 2>&1; then
  apt-get update -qq && apt-get install -y -qq wireguard wireguard-tools
  exit 0
fi
echo "error: 未找到 apt-get，请手工安装 wireguard-tools" >&2
exit 1
EOS
}

stop_nw_b() {
  ssh_b env "REMOTE_DIR=${WG_CHAIN_NW_REMOTE_DIR}" bash -s <<'EOS'
set -euo pipefail
unit=nwvpn-nw-server.service
had=0
if command -v systemctl >/dev/null 2>&1 && [[ -f "/etc/systemd/system/${unit}" ]]; then
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    echo "==> B: 停止 systemd ${unit}"
    systemctl stop "${unit}" || true
    had=1
  fi
fi
if pgrep -af "${REMOTE_DIR}/bin/nw-server" >/dev/null 2>&1; then
  echo "==> B: 结束 nw-server 进程 (${REMOTE_DIR}/bin/nw-server)"
  pkill -f "${REMOTE_DIR}/bin/nw-server" 2>/dev/null || true
  had=1
fi
if [[ "$had" -eq 1 ]]; then
  sleep 1
else
  echo "==> B: 未检测到运行中的 nw-server"
fi
EOS
}

stop_nw_a() {
  ssh_a env "REMOTE_DIR=${WG_CHAIN_NW_REMOTE_DIR}" bash -s <<'EOS'
set -euo pipefail
unit=nwvpn-nw-server.service
had=0
if command -v systemctl >/dev/null 2>&1 && [[ -f "/etc/systemd/system/${unit}" ]]; then
  if systemctl is-active --quiet "${unit}" 2>/dev/null; then
    echo "==> A: 停止 systemd ${unit}"
    systemctl stop "${unit}" || true
    had=1
  fi
fi
if pgrep -af "${REMOTE_DIR}/bin/nw-server" >/dev/null 2>&1; then
  echo "==> A: 结束 nw-server 进程 (${REMOTE_DIR}/bin/nw-server)"
  pkill -f "${REMOTE_DIR}/bin/nw-server" 2>/dev/null || true
  had=1
fi
if [[ "$had" -eq 1 ]]; then
  sleep 1
else
  echo "==> A: 未检测到运行中的 nw-server"
fi
EOS
}

maybe_auto_install_nw

echo "==> 在 B、A 上安装 wireguard（若尚未安装）..."
remote_install_wg_b
remote_install_wg_a

if [[ "${WG_CHAIN_STOP_NW}" == "1" ]]; then
  echo "==> 检查并停止 B、A 上已运行的 nw-server（释放 TUN / 避免与 WG 路由冲突）..."
  stop_nw_b
  stop_nw_a
fi

echo "==> 在远程生成 WireGuard 密钥（本机无需 wg）..."
SK_B=$(ssh_b wg genkey | tr -d '\r\n')
PK_B=$(printf '%s\n' "$SK_B" | ssh_b wg pubkey | tr -d '\r\n')
SK_A=$(ssh_a wg genkey | tr -d '\r\n')
PK_A=$(printf '%s\n' "$SK_A" | ssh_a wg pubkey | tr -d '\r\n')
[[ -n "$SK_B" && -n "$PK_B" && -n "$SK_A" && -n "$PK_A" ]] || die "远程 wg genkey/pubkey 失败，请确认 A/B 已安装 wireguard-tools"

cat >"$TMP/wg0.b.conf" <<EOF
[Interface]
Address = ${ADDR_B}/24
ListenPort = ${WG_CHAIN_LISTEN_PORT}
PrivateKey = ${SK_B}
Table = off
PostUp = /etc/wireguard/wg-chain-b-postup.sh
PostDown = /etc/wireguard/wg-chain-b-postdown.sh

[Peer]
PublicKey = ${PK_A}
AllowedIPs = ${ADDR_A}/32, ${WG_CHAIN_USER_SUBNET}
EOF

cat >"$TMP/wg0.a.conf" <<EOF
[Interface]
Address = ${ADDR_A}/24
PrivateKey = ${SK_A}
Table = off
PostUp = sysctl -w net.ipv4.ip_forward=1; ip route replace default via ${ADDR_B} dev %i table ${WG_CHAIN_POLICY_TABLE}; ip rule add from ${WG_CHAIN_USER_SUBNET} lookup ${WG_CHAIN_POLICY_TABLE} priority 100 || true
PostDown = ip rule del from ${WG_CHAIN_USER_SUBNET} lookup ${WG_CHAIN_POLICY_TABLE} priority 100 2>/dev/null || true; ip route flush table ${WG_CHAIN_POLICY_TABLE} 2>/dev/null || true

[Peer]
PublicKey = ${PK_B}
Endpoint = ${WG_CHAIN_ENDPOINT}:${WG_CHAIN_LISTEN_PORT}
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

if [[ "$WG_CHAIN_REMOVE_A_NW_NAT" == "1" ]]; then
  echo "==> A: 删除 nft 表 ip nwvpn（避免 10.77 仍从本机公网 NAT）..."
  ssh_a 'nft delete table ip nwvpn 2>/dev/null || true'
fi

echo "==> B: 安装 wg 配置与 NAT 脚本..."
scp_b "$TMP/wg0.b.conf" "$TMP/wg-chain-b-postup.sh" "$TMP/wg-chain-b-postdown.sh" \
  "${WG_CHAIN_SSH_USER}@${WG_CHAIN_NODE_B}:/tmp/"
ssh_b bash -s <<'EOS'
set -euo pipefail
install -m 0600 /tmp/wg0.b.conf /etc/wireguard/wg0.conf
install -m 0755 /tmp/wg-chain-b-postup.sh /etc/wireguard/wg-chain-b-postup.sh
install -m 0755 /tmp/wg-chain-b-postdown.sh /etc/wireguard/wg-chain-b-postdown.sh
rm -f /tmp/wg0.b.conf /tmp/wg-chain-b-postup.sh /tmp/wg-chain-b-postdown.sh
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable wg-quick@wg0 2>/dev/null || true
fi
EOS

if ssh_b 'command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qF "Status: active"'; then
  echo "==> B: ufw 放行 WG 端口 ..."
  ssh_b "ufw allow ${WG_CHAIN_LISTEN_PORT}/udp comment 'wg-chain' || true"
fi

echo "==> A: 安装 wg0（策略路由仅影响 ${WG_CHAIN_USER_SUBNET}）..."
scp_a "$TMP/wg0.a.conf" "${WG_CHAIN_SSH_USER}@${WG_CHAIN_NODE_A}:/tmp/wg0.a.conf"
ssh_a bash -s <<'EOS'
set -euo pipefail
install -m 0600 /tmp/wg0.a.conf /etc/wireguard/wg0.conf
rm -f /tmp/wg0.a.conf
wg-quick down wg0 2>/dev/null || true
wg-quick up wg0
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable wg-quick@wg0 2>/dev/null || true
fi
EOS

if [[ "${WG_CHAIN_RESTART_NW_A}" == "1" ]]; then
  echo "==> A: 启动 nw-server（否则客户端会一直「连接中」）..."
  ssh_a bash -s <<'EOS'
set -euo pipefail
unit=nwvpn-nw-server.service
if [[ -f "/etc/systemd/system/${unit}" ]]; then
  systemctl start "${unit}" || true
  sleep 1
  if systemctl is-active --quiet "${unit}"; then
    echo "==> A: ${unit} 已运行"
  else
    echo "warn: A: ${unit} 未 active，请执行: journalctl -u ${unit} -n 40 --no-pager" >&2
  fi
else
  echo "warn: A: 未找到 ${unit}；若为 nohup 部署请在本机手工启动 nw-server" >&2
fi
EOS
fi

echo ""
echo "完成。校验：连 A 上 VPN 的客户端执行 curl -4 https://ifconfig.me 应显示 B 的公网 IP。"
echo "若需跳过自动拉起 nw：设 WG_CHAIN_RESTART_NW_A=0；B 上 nw 请按需手工 systemctl start。"
echo "若 A 丢失 deploy 的 NAT 表后仍需本机其它网段 NAT，请手工 nft 或设 WG_CHAIN_REMOVE_A_NW_NAT=0 后重跑本脚本并自行处理冲突。"
echo "密钥仅存在于两台机 /etc/wireguard/ 与本机临时目录（已删）；请勿将密码写入 git。"
