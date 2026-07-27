#!/usr/bin/env bash
# 鸿蒙调试签名：生成本地密钥 / 在拿到 AGC 证书后写入工程配置并可用 hap-sign-tool 签名。
#
# 用法:
#   ./scripts/harmonyos_setup_signing.sh              # 确保 p12/csr 存在，打印 AGC 下一步
#   ./scripts/harmonyos_setup_signing.sh status        # 检查材料是否齐全
#   ./scripts/harmonyos_setup_signing.sh apply         # 检测到 .cer+.p7b 后写入签名就绪标记
#   ./scripts/harmonyos_setup_signing.sh device-udid   # 读取已授权设备 UDID（配 Profile 用）
#
# AGC 流程（需华为开发者账号）:
#   1) 手机弹出「是否允许 USB 调试」→ 点允许
#   2) 本脚本 device-udid 拿到 UDID
#   3) https://developer.huawei.com/consumer/cn/console
#      → 用户与访问 / 证书管理：上传 CSR，下载调试证书 .cer
#      → 调测 Profile：绑定 bundleName + 设备 UDID + 调试证书，下载 .p7b
#   4) 把文件放到 signing/material/ 并命名为:
#        nwvpn-debug.cer
#        nwvpn-debug.p7b
#   5) ./scripts/harmonyos_setup_signing.sh apply
#   6) ./scripts/build_and_install_hap.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NWVPN="${ROOT}/apps/harmonyos/NWVPN"
SIGN_DIR="${NWVPN}/signing/material"
ENV_FILE="${SIGN_DIR}/local.env"
READY_FILE="${SIGN_DIR}/.ready"
JAR="${DEVECO_SDK_HOME:-$HOME/HarmonyOS/command-line-tools/sdk}/default/openharmony/toolchains/lib/hap-sign-tool.jar"
BUNDLE_NAME="com.newworld.nwvpn.harmonyos"
ALIAS="nwvpnDebugKey"
PASS="NwVpnDebug_2026!"
P12="${SIGN_DIR}/nwvpn-debug.p12"
CSR="${SIGN_DIR}/nwvpn-debug.csr"
CER="${SIGN_DIR}/nwvpn-debug.cer"
P7B="${SIGN_DIR}/nwvpn-debug.p7b"

CMD="${1:-ensure}"

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

ensure_tools() {
  export PATH="${HOME}/HarmonyOS/command-line-tools/bin:${HOME}/HarmonyOS/command-line-tools/sdk/default/openharmony/toolchains:${PATH:-}"
  export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$HOME/HarmonyOS/command-line-tools/sdk}"
  JAR="${DEVECO_SDK_HOME}/default/openharmony/toolchains/lib/hap-sign-tool.jar"
  [[ -f "$JAR" ]] || die "找不到 hap-sign-tool.jar（请先装好 Command Line Tools）"
  command -v java >/dev/null || die "需要 java（建议 JDK 17/21）"
}

ensure_keypair() {
  mkdir -p "$SIGN_DIR"
  if [[ ! -f "$P12" ]]; then
    info "生成密钥库 $P12"
    java -jar "$JAR" generate-keypair \
      -keyAlias "$ALIAS" -keyPwd "$PASS" \
      -keyAlg ECC -keySize NIST-P-256 \
      -keystoreFile "$P12" -keystorePwd "$PASS"
  fi
  if [[ ! -f "$CSR" ]]; then
    info "生成 CSR $CSR"
    java -jar "$JAR" generate-csr \
      -keyAlias "$ALIAS" -keyPwd "$PASS" \
      -subject "C=CN,O=NewWorld,OU=NWVPN,CN=NWVPN Debug" \
      -signAlg SHA256withECDSA \
      -keystoreFile "$P12" -keystorePwd "$PASS" \
      -outFile "$CSR"
  fi
  cat > "$ENV_FILE" <<EOF
KEY_ALIAS=$ALIAS
KEY_PASSWORD=$PASS
STORE_PASSWORD=$PASS
STORE_FILE=$P12
CSR_FILE=$CSR
CERT_FILE=$CER
PROFILE_FILE=$P7B
BUNDLE_NAME=$BUNDLE_NAME
EOF
}

print_agc_steps() {
  cat <<EOF

本地材料已就绪:
  密钥库: $P12
  CSR:    $CSR
  证书:   $CER   $([ -f "$CER" ] && echo OK || echo '← 还需从 AGC 下载')
  Profile:$P7B   $([ -f "$P7B" ] && echo OK || echo '← 还需从 AGC 下载')

请在 AppGallery Connect 完成（华为账号）:
  打开: https://developer.huawei.com/consumer/cn/console
  1. 证书管理 → 申请调试证书 → 上传上述 CSR → 下载为:
       $CER
  2. Profile 管理 → 申请调试 Profile
       - 包名: $BUNDLE_NAME
       - 选择刚下的调试证书
       - 添加设备 UDID（先: $0 device-udid）
       - 下载为: $P7B
  3. 然后执行: $0 apply

EOF
}

status() {
  ensure_keypair
  local ok=1
  [[ -f "$P12" ]] && echo "OK  p12" || { echo "MISS p12"; ok=0; }
  [[ -f "$CSR" ]] && echo "OK  csr" || { echo "MISS csr"; ok=0; }
  [[ -f "$CER" ]] && echo "OK  cer" || { echo "MISS cer"; ok=0; }
  [[ -f "$P7B" ]] && echo "OK  p7b" || { echo "MISS p7b"; ok=0; }
  [[ -f "$READY_FILE" ]] && echo "OK  ready marker" || echo "—   ready marker"
  [[ "$ok" == "1" ]]
}

apply() {
  ensure_keypair
  [[ -f "$CER" ]] || die "缺少 $CER（从 AGC 下载调试证书后放到该路径）"
  [[ -f "$P7B" ]] || die "缺少 $P7B（从 AGC 下载调试 Profile 后放到该路径）"
  # 写入 ready 标记；构建脚本会用 hap-sign-tool 签名（不必改 build-profile 加密口令）
  date > "$READY_FILE"
  # 同步一份明文说明到 example（不含密码）
  cat > "${NWVPN}/signing/material.example.json5" <<'EOF'
// 本工程采用「hvigor 出未签名 HAP + hap-sign-tool 本地签名」。
// 材料目录 signing/material/（已 gitignore）需要:
//   nwvpn-debug.p12 / nwvpn-debug.csr  — scripts/harmonyos_setup_signing.sh 生成
//   nwvpn-debug.cer / nwvpn-debug.p7b  — 从 AppGallery Connect 下载后放入
// 配齐后执行: ./scripts/harmonyos_setup_signing.sh apply
{}
EOF
  info "签名材料齐全，已写入 $READY_FILE"
  echo "下一步: ./scripts/build_and_install_hap.sh"
}

device_udid() {
  ensure_tools
  command -v hdc >/dev/null || die "hdc 不在 PATH"
  info "hdc list targets"
  hdc list targets
  local out
  if ! out="$(hdc shell bm get --udid 2>&1)"; then
    die "读 UDID 失败。若显示 Unauthorized：请在手机上点「允许 USB 调试」后重试。原始输出: $out"
  fi
  echo "$out"
  # 有的系统输出多行，尽量抽出像 hex 的一行
  echo "$out" | awk '/^[0-9A-Fa-f]{16,}$/ {print; found=1} END{if(!found) exit 0}'
}

case "$CMD" in
  ensure|"")
    ensure_tools
    ensure_keypair
    print_agc_steps
    ;;
  status)
    ensure_tools
    status
    ;;
  apply)
    ensure_tools
    apply
    ;;
  device-udid)
    device_udid
    ;;
  *)
    die "未知命令: $CMD（ensure|status|apply|device-udid）"
    ;;
esac
