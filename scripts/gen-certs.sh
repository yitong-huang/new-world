#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${ROOT}/certs"
mkdir -p "$OUT"

# subjectAltName：本机调试名 + configs/servers 中全部节点 host（第二列），多机共用一份 server 证书；
# 增删节点后请重新执行本脚本并 rsync/部署 certs 到每台 nw-server。
# 可按 IP 连接时在环境变量里追加，例如：
#   NW_CERT_SAN_EXTRA=IP:43.108.59.224 bash scripts/gen-certs.sh
SAN="DNS:localhost,IP:127.0.0.1"
SERVERS_FILE="${NW_SERVERS_FILE:-$ROOT/configs/servers}"
if [[ -f "$SERVERS_FILE" ]]; then
  exec 3<"$SERVERS_FILE"
  while IFS= read -r line <&3 || [[ -n "$line" ]]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" || "$line" == \#* ]] && continue
    read -r _name host _extra <<<"$line"
    [[ -z "${host:-}" ]] && continue
    host="${host//$'\r'/}"
    host="${host#"${host%%[![:space:]]*}"}"
    host="${host%"${host##*[![:space:]]}"}"
    [[ -z "$host" ]] && continue
    SAN="${SAN},DNS:${host}"
  done
  exec 3<&-
fi
# 未配置 servers 或解析不到 host 时保留历史默认
if [[ "$SAN" == "DNS:localhost,IP:127.0.0.1" ]]; then
  SAN="${SAN},DNS:new-world-kr-01.2fish.com.cn"
fi
if [[ -n "${NW_CERT_SAN_EXTRA:-}" ]]; then
  SAN="${SAN},${NW_CERT_SAN_EXTRA}"
fi

# Dev-only self-signed server + client for mutual TLS tests (optional client auth).
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
  -days 825 -nodes \
  -keyout "$OUT/server.key" -out "$OUT/server.crt" \
  -subj "/CN=nw-server.dev/O=newworld" \
  -addext "subjectAltName=${SAN}"

openssl req -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes \
  -keyout "$OUT/client.key" -out "$OUT/client.csr" \
  -subj "/CN=nw-client.dev/O=newworld"

openssl x509 -req -in "$OUT/client.csr" -days 825 \
  -CA "$OUT/server.crt" -CAkey "$OUT/server.key" -CAcreateserial \
  -out "$OUT/client.crt"

openssl x509 -in "$OUT/client.crt" -out "$OUT/client-ca-chain.crt"

rm -f "$OUT/client.csr" "$OUT/server.crt.srl"

echo "Wrote $OUT/server.{crt,key} client.{crt,key} client-ca-chain.crt"
