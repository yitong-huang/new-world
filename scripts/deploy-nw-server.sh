#!/usr/bin/env bash
# 通过 SSH 将 nw-server 部署到远程 Linux，检查/安装 Go、同步代码与证书、编译并后台启动。
#
# 适配说明（含 Ubuntu 24.04 LTS）：
#   - 远程：须为 Linux x86_64 或 arm64/aarch64；使用官方 Go linux tarball 安装到 /usr/local/go。
#   - 远程编译使用 CGO_ENABLED=0，无需安装 build-essential（nw-server 依赖纯 Go TUN，已在 linux/amd64 + CGO=0 下验证可编译）。
#   - 远程需：openssh-server、rsync、curl 或 wget、tar；缺 rsync 时脚本会尝试 sudo apt update && sudo apt install -y rsync（Debian/Ubuntu）
#   - 执行本脚本的机器：需 bash、ssh、rsync（在 Ubuntu 24.04 上：sudo apt install -y openssh-client rsync）
#
# 证书：本机 `bash scripts/gen-certs.sh` 生成的整个 certs/ 目录原样 rsync 到远程（含 client 等）；nw-server 仅用 server.crt + server.key。
#
# 用法（在仓库根目录执行）：
#   bash scripts/deploy-nw-server.sh
# SSH 密码：NW_DEPLOY_FORCE_PASSWORD（若设）> 脚本内 DEPLOY_SSH_PASSWORD > 环境变量 NW_SSH_PASSWORD；
# 都未设则走 SSH 公钥免密。密码模式需本机安装 sshpass（brew / apt）。
#
# 环境变量（可选）：
#   NW_DEPLOY_HOST   默认 new-world-kr-01.2fish.com.cn
#   NW_SSH_USER      默认 root
#   NW_SSH_PASSWORD  与脚本内密码二选一；勿将含密码的脚本提交到 git
#   NW_DEPLOY_FORCE_PASSWORD  若设置，优先于脚本内 DEPLOY_SSH_PASSWORD（供 wg-chain 等对多主机分别传密）
#   NW_REMOTE_DIR    远程安装目录，默认 /opt/nwvpn
#   NW_LISTEN        监听地址，默认 0.0.0.0:8443
#   NW_GO_VERSION    自动安装 Go 的版本，默认 1.22.10（须 >= go.mod 的 1.22）
#   GOPROXY          传给远程 go build，默认 https://goproxy.cn,direct
#   NW_DEPLOY_NAT    默认 1：在远程启用 net.ipv4.ip_forward + MASQUERADE（10.77.0.0/24）；设 0 跳过
#   NW_TUN_CIDR      与 nw-server 虚拟网段一致，默认 10.77.0.0/24（NAT 源地址段）
#   NW_SKIP_SYSTEMD  默认 0：远程为 root 且存在 systemctl 时，安装 systemd 单元并 enable（开机自启）；
#                    设为 1 则仍用 nohup，不写 systemd。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

# ========== 凭据（勿将填好密码的脚本提交到公开仓库）==========
# 在此填写 root（或 NW_SSH_USER）的 SSH 登录密码；留空则尝试 NW_SSH_PASSWORD 环境变量，再留空则公钥登录。
DEPLOY_SSH_PASSWORD='sDMkQ8ZnQFDTNFY4BeWK'
# ==============================================================

NW_DEPLOY_HOST="${NW_DEPLOY_HOST:-new-world-kr-01.2fish.com.cn}"
NW_SSH_USER="${NW_SSH_USER:-root}"
NW_REMOTE_DIR="${NW_REMOTE_DIR:-/opt/nwvpn}"
NW_LISTEN="${NW_LISTEN:-0.0.0.0:8443}"
NW_GO_VERSION="${NW_GO_VERSION:-1.22.10}"
GOPROXY="${GOPROXY:-https://goproxy.cn,direct}"
NW_DEPLOY_NAT="${NW_DEPLOY_NAT:-1}"
NW_TUN_CIDR="${NW_TUN_CIDR:-10.77.0.0/24}"
NW_SKIP_SYSTEMD="${NW_SKIP_SYSTEMD:-0}"

SSH_TARGET="${NW_SSH_USER}@${NW_DEPLOY_HOST}"

# NW_DEPLOY_FORCE_PASSWORD：供 wg-chain 等脚本覆盖内联密码（每主机不同密码时必设）
NW_SSH_PASSWORD_EFFECTIVE="${NW_DEPLOY_FORCE_PASSWORD:-${DEPLOY_SSH_PASSWORD:-${NW_SSH_PASSWORD:-}}}"

if [[ ! -d "$ROOT/go" ]]; then
  echo "error: 未找到 $ROOT/go，请在仓库根目录执行本脚本" >&2
  exit 1
fi

if [[ ! -d "$ROOT/certs" ]]; then
  echo "error: 缺少目录 certs/，请先在本机执行: bash scripts/gen-certs.sh" >&2
  exit 1
fi
if [[ ! -f "$ROOT/certs/server.crt" || ! -f "$ROOT/certs/server.key" ]]; then
  echo "error: 本机 certs/ 中缺少 server.crt 或 server.key（nw-server 启动必需），请先执行: bash scripts/gen-certs.sh" >&2
  exit 1
fi

if [[ -n "${NW_SSH_PASSWORD_EFFECTIVE}" ]]; then
  if ! command -v sshpass >/dev/null 2>&1; then
    echo "error: 已配置 SSH 密码但未找到 sshpass。请: brew install sshpass（macOS）或 sudo apt install -y sshpass（Ubuntu/Debian，universe），或改用 SSH 公钥并清空密码" >&2
    exit 1
  fi
  export SSHPASS="$NW_SSH_PASSWORD_EFFECTIVE"
fi

remote() {
  if [[ -n "${NW_SSH_PASSWORD_EFFECTIVE}" ]]; then
    sshpass -e ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
  else
    ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
  fi
}

SSH_RSH="ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new"
if [[ -n "${NW_SSH_PASSWORD_EFFECTIVE}" ]]; then
  SSH_RSH="sshpass -e ssh -o BatchMode=no -o StrictHostKeyChecking=accept-new"
fi

echo "==> 目标: $SSH_TARGET"
echo "==> 远程目录: $NW_REMOTE_DIR"

if ! remote 'command -v rsync >/dev/null 2>&1'; then
  echo "==> 远程未检测到 rsync，尝试: sudo apt update && sudo apt install -y rsync ..."
  if ! remote 'sudo apt update && sudo apt install -y rsync'; then
    echo "error: 远程安装 rsync 失败（可能非 Debian/Ubuntu 或未配置 sudo）。请在本机可 SSH 登录后手动安装 rsync 再重试。" >&2
    exit 1
  fi
fi
if ! remote 'command -v rsync >/dev/null 2>&1'; then
  echo "error: 远程仍未找到 rsync（apt 安装后仍不可用）。请检查 PATH 或换用发行版对应包管理器手动安装。" >&2
  exit 1
fi

echo "==> 确保远程安装目录存在: $NW_REMOTE_DIR"
remote mkdir -p "$NW_REMOTE_DIR"

echo "==> 同步 go/ 与本机 certs/（整目录，与 gen-certs.sh 产出一致）..."
rsync -az --delete -e "$SSH_RSH" \
  "$ROOT/go/" "$SSH_TARGET:$NW_REMOTE_DIR/go/"
rsync -az --delete -e "$SSH_RSH" \
  "$ROOT/certs/" "$SSH_TARGET:$NW_REMOTE_DIR/certs/"

echo "==> 远程: 检查 Go、必要时安装、编译并启动 nw-server ..."
remote \
  env \
  "REMOTE_DIR=$NW_REMOTE_DIR" \
  "REMOTE_GO_VERSION=$NW_GO_VERSION" \
  "REMOTE_GOPROXY=$GOPROXY" \
  "REMOTE_LISTEN=$NW_LISTEN" \
  "REMOTE_DEPLOY_NAT=$NW_DEPLOY_NAT" \
  "REMOTE_TUN_CIDR=$NW_TUN_CIDR" \
  "REMOTE_SKIP_SYSTEMD=$NW_SKIP_SYSTEMD" \
  bash -s <<'REMOTE_SCRIPT'
set -euo pipefail
export PATH="/usr/local/go/bin:${PATH}"

if [[ "$(uname -s)" != "Linux" ]]; then
  echo "error: 本脚本仅支持远程系统为 Linux（当前: $(uname -s)）。Ubuntu 24.04 等 glibc 发行版均可。" >&2
  exit 1
fi

go_major_minor_ok() {
  if ! command -v go >/dev/null 2>&1; then
    return 1
  fi
  local ver major minor
  ver=$(go env GOVERSION 2>/dev/null | sed 's/^go//;s/rc.*//')
  if [[ -z "${ver}" ]]; then
    return 1
  fi
  major=$(echo "${ver}" | cut -d. -f1)
  minor=$(echo "${ver}" | cut -d. -f2)
  if [[ "${major:-0}" -gt 1 ]]; then return 0; fi
  if [[ "${major:-0}" -eq 1 && "${minor:-0}" -ge 22 ]]; then return 0; fi
  return 1
}

install_go_linux() {
  local arch tarname url tmp
  case "$(uname -m)" in
    x86_64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *)
      echo "error: 不支持的架构: $(uname -m)" >&2
      exit 1
      ;;
  esac
  tarname="go${REMOTE_GO_VERSION}.linux-${arch}.tar.gz"
  url="https://go.dev/dl/${tarname}"
  echo "==> 下载 Go ${REMOTE_GO_VERSION} (${arch}) ..."
  tmp="/tmp/${tarname}"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "${url}" -o "${tmp}"
  elif command -v wget >/dev/null 2>&1; then
    wget -q -O "${tmp}" "${url}"
  else
    echo "error: 需要 curl 或 wget 以下载 Go" >&2
    exit 1
  fi
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "${tmp}"
  rm -f "${tmp}"
  echo "==> Go 已安装到 /usr/local/go"
}

if ! go_major_minor_ok; then
  echo "==> 未检测到满足要求的 Go（需 >= 1.22），正在安装..."
  if [[ $(id -u) -ne 0 ]]; then
    echo "error: 安装 Go 到 /usr/local/go 需要 root。请使用 NW_SSH_USER=root 或配置无密码 sudo。" >&2
    exit 1
  fi
  install_go_linux
fi

echo "==> $(go version)"

export GOPROXY="${REMOTE_GOPROXY}"
export GO111MODULE=on
export CGO_ENABLED=0

mkdir -p "${REMOTE_DIR}/bin" "${REMOTE_DIR}/certs"
cd "${REMOTE_DIR}/go"
go mod download
go build -trimpath -ldflags="-s -w" -o "${REMOTE_DIR}/bin/nw-server" ./cmd/nw-server
chmod +x "${REMOTE_DIR}/bin/nw-server"

# IPv4 转发 + NAT：客户端带 -split-default 上网依赖此项（需 root；出网网卡自动取 default 路由）
setup_forward_and_nat() {
  if [[ "${REMOTE_DEPLOY_NAT:-1}" != "1" ]]; then
    echo "==> 已跳过 NAT（REMOTE_DEPLOY_NAT!=1）"
    return 0
  fi
  if [[ "$(id -u)" -ne 0 ]]; then
    echo "warn: 非 root，跳过 ip_forward / NAT；客户端全流量可能无法出公网" >&2
    return 0
  fi

  echo "==> 启用 net.ipv4.ip_forward=1 ..."
  sysctl -w net.ipv4.ip_forward=1
  mkdir -p /etc/sysctl.d
  printf '%s\n' "net.ipv4.ip_forward=1" >/etc/sysctl.d/99-nwvpn-forward.conf
  sysctl -p /etc/sysctl.d/99-nwvpn-forward.conf 2>/dev/null || true

  local pub_if
  pub_if=$(ip -4 route show default 2>/dev/null | head -1 | sed -n 's/.* dev \([^ ]*\) .*/\1/p')
  if [[ -z "${pub_if}" ]]; then
    echo "warn: 无法从 default 路由解析出网网卡，已跳过 MASQUERADE；请手工执行 docs/server-deploy.md" >&2
    return 0
  fi
  echo "==> NAT: ${REMOTE_TUN_CIDR} -> masquerade (oif ${pub_if})"

  if command -v nft >/dev/null 2>&1; then
    nft delete table ip nwvpn 2>/dev/null || true
    nft add table ip nwvpn
    nft add chain ip nwvpn postrouting '{ type nat hook postrouting priority 100 ; policy accept; }'
    nft add rule ip nwvpn postrouting oifname "${pub_if}" ip saddr "${REMOTE_TUN_CIDR}" masquerade
    echo "==> 已配置 nftables（table ip nwvpn）"
    return 0
  fi

  if command -v iptables >/dev/null 2>&1; then
    if iptables -t nat -C POSTROUTING -s "${REMOTE_TUN_CIDR}" -o "${pub_if}" -j MASQUERADE 2>/dev/null; then
      echo "==> iptables MASQUERADE 已存在，未重复添加"
    else
      iptables -t nat -A POSTROUTING -s "${REMOTE_TUN_CIDR}" -o "${pub_if}" -j MASQUERADE
      echo "==> 已追加 iptables NAT POSTROUTING MASQUERADE"
    fi
    return 0
  fi

  echo "warn: 未找到 nft 与 iptables，已跳过 NAT" >&2
}
setup_forward_and_nat

echo "==> 停止旧 nw-server（systemd / 手工进程）..."
if command -v systemctl >/dev/null 2>&1 && [[ -f /etc/systemd/system/nwvpn-nw-server.service ]]; then
  systemctl disable --now nwvpn-nw-server.service 2>/dev/null || true
fi
pkill -f "${REMOTE_DIR}/bin/nw-server" 2>/dev/null || true
sleep 1

start_nw_server_nohup() {
  echo "==> 启动 nw-server 监听 ${REMOTE_LISTEN} （nohup，无开机自启）..."
  nohup "${REMOTE_DIR}/bin/nw-server" \
    -listen "${REMOTE_LISTEN}" \
    -cert "${REMOTE_DIR}/certs/server.crt" \
    -key "${REMOTE_DIR}/certs/server.key" \
    >>"${REMOTE_DIR}/nw-server.log" 2>&1 &
  echo $! >"${REMOTE_DIR}/nw-server.pid"
  sleep 1
  if kill -0 "$(cat "${REMOTE_DIR}/nw-server.pid")" 2>/dev/null; then
    echo "==> nw-server 已启动 PID=$(cat "${REMOTE_DIR}/nw-server.pid")"
  else
    echo "error: 进程未存活，请查看 ${REMOTE_DIR}/nw-server.log" >&2
    tail -n 80 "${REMOTE_DIR}/nw-server.log" >&2 || true
    exit 1
  fi
}

install_nw_server_systemd() {
  local unit=nwvpn-nw-server.service
  local unit_path="/etc/systemd/system/${unit}"
  echo "==> 安装 systemd 单元 ${unit}（开机自启）..."
  cat >"${unit_path}" <<UNIT
[Unit]
Description=NewWorld nw-server (VPN)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=${REMOTE_DIR}
ExecStart=${REMOTE_DIR}/bin/nw-server -listen ${REMOTE_LISTEN} -cert ${REMOTE_DIR}/certs/server.crt -key ${REMOTE_DIR}/certs/server.key
Restart=on-failure
RestartSec=3
StandardOutput=append:${REMOTE_DIR}/nw-server.log
StandardError=append:${REMOTE_DIR}/nw-server.log

[Install]
WantedBy=multi-user.target
UNIT
  chmod 644 "${unit_path}"
  systemctl daemon-reload
  systemctl enable --now "${unit}"
  sleep 1
  if systemctl is-active --quiet "${unit}"; then
    echo "==> systemd: ${unit} 已运行（enabled，重启后自动拉起）"
  else
    echo "error: systemd 启动失败，请执行: journalctl -u ${unit} -n 50 --no-pager" >&2
    systemctl status "${unit}" --no-pager -l >&2 || true
    exit 1
  fi
}

if [[ $(id -u) -eq 0 ]] && command -v systemctl >/dev/null 2>&1 && [[ "${REMOTE_SKIP_SYSTEMD:-0}" != "1" ]]; then
  install_nw_server_systemd
else
  if [[ "${REMOTE_SKIP_SYSTEMD:-0}" == "1" ]]; then
    echo "==> 已设 REMOTE_SKIP_SYSTEMD=1，跳过 systemd"
  elif [[ $(id -u) -ne 0 ]]; then
    echo "warn: 非 root，无法安装 systemd 单元，改用 nohup（无开机自启）" >&2
  else
    echo "warn: 未找到 systemctl，改用 nohup（无开机自启）" >&2
  fi
  start_nw_server_nohup
fi
REMOTE_SCRIPT

echo ""
echo "完成。客户端示例:"
echo "  cd go && sudo ./nw-client -server ${NW_DEPLOY_HOST}:8443 -cacert ../certs/server.crt -split-default"
echo "远程日志: ssh ${SSH_TARGET} 'tail -f ${NW_REMOTE_DIR}/nw-server.log'"
echo "（若已用 systemd）状态: ssh ${SSH_TARGET} 'systemctl status nwvpn-nw-server --no-pager'"
echo "（若已用 systemd）开机自启: systemctl is-enabled nwvpn-nw-server"
