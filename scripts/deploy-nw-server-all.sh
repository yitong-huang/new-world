#!/usr/bin/env bash
# 按 configs/servers 逐台部署 nw-server（每台调用 scripts/deploy-nw-server.sh）。
# 文件格式：每行「节点名 主机名」，空格分隔；空行与 # 开头行忽略。
# 登录凭据与单台脚本一致（脚本内 DEPLOY_SSH_PASSWORD / NW_SSH_PASSWORD / 公钥）。
#
# 用法（在仓库根目录）：
#   bash scripts/deploy-nw-server-all.sh
#
# 环境变量（可选）：
#   NW_SERVERS_FILE   节点列表路径，默认 <repo>/configs/servers
#   其余变量与 deploy-nw-server.sh 相同（NW_SSH_USER、NW_REMOTE_DIR、NW_LISTEN 等），
#   对每一台主机生效。
#
# 注意：不得用 `while read ...; do ... ssh/rsync ...; done <servers` 直连 stdin，
# 否则 ssh/rsync/sshpass 会读走剩余行，只会部署第一台。下面用 fd 3 读列表。
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SERVERS_FILE="${NW_SERVERS_FILE:-$ROOT/configs/servers}"
DEPLOY_ONE="$ROOT/scripts/deploy-nw-server.sh"

if [[ ! -f "$SERVERS_FILE" ]]; then
  echo "error: 未找到节点列表: $SERVERS_FILE" >&2
  exit 1
fi
if [[ ! -f "$DEPLOY_ONE" ]]; then
  echo "error: 未找到 $DEPLOY_ONE" >&2
  exit 1
fi

any=0
exec 3<"$SERVERS_FILE"
while IFS= read -r line <&3 || [[ -n "$line" ]]; do
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  [[ -z "$line" ]] && continue
  [[ "$line" == \#* ]] && continue

  read -r name host extra <<<"$line"
  if [[ -z "${host:-}" ]]; then
    echo "warn: 跳过无效行（需要「节点名 主机」两列）: $line" >&2
    continue
  fi
  if [[ -n "${extra:-}" ]]; then
    echo "warn: 行内存在第三列及以后内容，将忽略: $line" >&2
  fi

  any=1
  echo ""
  echo "##############################"
  echo "# 部署节点: ${name}  (${host})"
  echo "##############################"
  NW_DEPLOY_HOST="$host" bash "$DEPLOY_ONE"
done
exec 3<&-

if [[ "$any" -eq 0 ]]; then
  echo "error: $SERVERS_FILE 中无有效节点行" >&2
  exit 1
fi

echo ""
echo "==> 全部节点部署流程已结束。"
