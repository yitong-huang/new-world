#!/usr/bin/env bash
# NWVPN 鸿蒙：从仓库根一键构建 HAP 并 hdc 安装（可不打开 DevEco IDE）。
#
# 依赖（二选一即可，脚本会自动探测 PATH 与常见安装路径）：
#   1) HarmonyOS Command Line Tools（推荐，含 hdc / ohpm / hvigorw / SDK）
#   2) 已安装的 DevEco Studio（仅用其自带 CLI/SDK，不必开 IDE）
#
# 用法（在仓库根或任意目录）：
#   ./scripts/build_and_install_hap.sh
#   ./scripts/build_and_install_hap.sh --no-install          # 只构建
#   ./scripts/build_and_install_hap.sh --no-sync-servers     # 不覆盖 rawfile/servers
#   TARGET_SN=xxx ./scripts/build_and_install_hap.sh        # 指定设备
#   HAP_PATH=/path/to.hap ./scripts/build_and_install_hap.sh # 跳过构建，只安装
#
# 可选环境变量：
#   DEVECO_SDK_HOME / HARMONY_HOME / COMMANDLINE_TOOL_DIR / DEVECO_STUDIO_HOME
#   MODULE_NAME=entry   PRODUCT=default   SKIP_OHPM=1   SKIP_CLEAN=1

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NWVPN="${ROOT}/apps/harmonyos/NWVPN"
MODULE_NAME="${MODULE_NAME:-entry}"
PRODUCT="${PRODUCT:-default}"
HAP_PATH="${HAP_PATH:-}"
TARGET_SN="${TARGET_SN:-}"
DO_INSTALL=1
SYNC_SERVERS=1
SKIP_OHPM="${SKIP_OHPM:-0}"
SKIP_CLEAN="${SKIP_CLEAN:-0}"

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

while (($# > 0)); do
  case "$1" in
    -h|--help) usage 0 ;;
    --no-install) DO_INSTALL=0 ;;
    --no-sync-servers) SYNC_SERVERS=0 ;;
    --install-only)
      DO_INSTALL=1
      if [[ -z "${HAP_PATH}" ]]; then
        echo "error: --install-only 需要同时设置 HAP_PATH" >&2
        exit 1
      fi
      ;;
    *)
      echo "error: 未知参数: $1" >&2
      usage 1
      ;;
  esac
  shift
done

die() { echo "error: $*" >&2; exit 1; }
info() { echo "==> $*"; }

[[ -d "${NWVPN}" ]] || die "未找到工程目录 ${NWVPN}"

# --- 工具链探测 -------------------------------------------------------------

prepend_path() {
  local d="$1"
  [[ -d "$d" ]] || return 0
  case ":${PATH}:" in
    *":${d}:"*) ;;
    *) export PATH="${d}:${PATH}" ;;
  esac
}

resolve_sdk_home() {
  if [[ -n "${DEVECO_SDK_HOME:-}" && -d "${DEVECO_SDK_HOME}" ]]; then
    printf '%s\n' "${DEVECO_SDK_HOME}"
    return 0
  fi
  local c
  for c in \
    "${HARMONY_HOME:-}" \
    "${COMMANDLINE_TOOL_DIR:-}/sdk" \
    "${COMMANDLINE_TOOL_DIR:-}/command-line-tools/sdk" \
    "${HOME}/command-line-tools/sdk" \
    "${HOME}/Library/Huawei/Sdk" \
    "${HOME}/HarmonyOS/command-line-tools/sdk" \
    "/Applications/DevEco-Studio.app/Contents/sdk" \
    "${DEVECO_STUDIO_HOME:-}/sdk"
  do
    [[ -n "$c" && -d "$c" ]] || continue
    printf '%s\n' "$c"
    return 0
  done
  if [[ -f "${NWVPN}/local.properties" ]]; then
    local sdk_dir
    sdk_dir="$(sed -n 's/^[[:space:]]*sdk\.dir[[:space:]]*=[[:space:]]*//p' "${NWVPN}/local.properties" | tail -n1 | tr -d '\r')"
    # local.properties 里 Windows 路径可能带转义反斜杠；macOS/Linux 一般是普通路径
    sdk_dir="${sdk_dir//\\/}"
    if [[ -n "$sdk_dir" && -d "$sdk_dir" ]]; then
      printf '%s\n' "$sdk_dir"
      return 0
    fi
  fi
  return 1
}

seed_tool_paths() {
  local roots=()
  [[ -n "${COMMANDLINE_TOOL_DIR:-}" ]] && roots+=("${COMMANDLINE_TOOL_DIR}" "${COMMANDLINE_TOOL_DIR}/command-line-tools")
  [[ -n "${HARMONY_HOME:-}" ]] && roots+=("${HARMONY_HOME}")
  [[ -n "${DEVECO_STUDIO_HOME:-}" ]] && roots+=("${DEVECO_STUDIO_HOME}" "${DEVECO_STUDIO_HOME}/tools")
  roots+=(
    "${HOME}/HarmonyOS/command-line-tools"
    "${HOME}/command-line-tools"
    "${HOME}/command-line-tools/command-line-tools"
    "/Applications/DevEco-Studio.app/Contents"
    "/Applications/DevEco-Studio.app/Contents/tools"
  )

  local r
  for r in "${roots[@]}"; do
    [[ -d "$r" ]] || continue
    prepend_path "${r}/bin"
    # hdc 有时只在 SDK toolchains 下
    local tc
    for tc in \
      "${r}/sdk/default/openharmony/toolchains" \
      "${r}/sdk/default/hms/toolchains" \
      "${r}/sdk/openharmony/toolchains"
    do
      prepend_path "$tc"
    done
  done

  local sdk
  if sdk="$(resolve_sdk_home)"; then
    export DEVECO_SDK_HOME="${sdk}"
    prepend_path "${sdk}/default/openharmony/toolchains"
    prepend_path "${sdk}/default/hms/toolchains"
    prepend_path "${sdk}/openharmony/toolchains"
  fi
}

find_cmd() {
  local name="$1"
  if command -v "$name" >/dev/null 2>&1; then
    command -v "$name"
    return 0
  fi
  return 1
}

seed_tool_paths

info "1) Check tools"
HDC="$(find_cmd hdc || true)"
OHPM="$(find_cmd ohpm || true)"
HVIGOR="$(find_cmd hvigorw || true)"
if [[ -z "${HVIGOR}" && -x "${NWVPN}/hvigorw" ]]; then
  HVIGOR="${NWVPN}/hvigorw"
fi

missing=()
[[ -n "${HDC}" ]] || missing+=("hdc")
[[ -n "${HVIGOR}" ]] || missing+=("hvigorw")
if ((${#missing[@]} > 0)); then
  cat >&2 <<EOF
error: 缺少工具: ${missing[*]}

请安装 HarmonyOS Command Line Tools（或 DevEco Studio），并任选其一：
  export COMMANDLINE_TOOL_DIR=~/command-line-tools
  export PATH="\$COMMANDLINE_TOOL_DIR/bin:\$PATH"
  export DEVECO_SDK_HOME="\$COMMANDLINE_TOOL_DIR/sdk"

下载: https://developer.huawei.com/consumer/cn/download/
工程说明: apps/harmonyos/NWVPN/README.md
EOF
  exit 1
fi

if ! SDK_HOME="$(resolve_sdk_home)"; then
  die "未找到 HarmonyOS SDK。请设置 DEVECO_SDK_HOME，或复制 local.properties.example 为 local.properties 并填写 sdk.dir"
fi
export DEVECO_SDK_HOME="${SDK_HOME}"

echo "  hdc:            ${HDC}"
echo "  hvigorw:        ${HVIGOR}"
echo "  ohpm:           ${OHPM:-（未找到，将跳过 ohpm install）}"
echo "  DEVECO_SDK_HOME:${DEVECO_SDK_HOME}"

# --- 签名材料（hap-sign-tool 本地签名）--------------------------------------

SIGN_DIR="${NWVPN}/signing/material"
SIGN_ENV="${SIGN_DIR}/local.env"
SIGN_CER="${SIGN_DIR}/nwvpn-debug.cer"
SIGN_P7B="${SIGN_DIR}/nwvpn-debug.p7b"
SIGN_P12="${SIGN_DIR}/nwvpn-debug.p12"
SIGN_JAR="${DEVECO_SDK_HOME}/default/openharmony/toolchains/lib/hap-sign-tool.jar"

if [[ ! -f "${SIGN_CER}" || ! -f "${SIGN_P7B}" || ! -f "${SIGN_P12}" ]]; then
  cat >&2 <<EOF
error: 调试签名材料不齐全（需要 .p12 + .cer + .p7b）。

已有本地密钥/CSR 时，请到 AppGallery Connect 下载证书与 Profile，放到:
  ${SIGN_CER}
  ${SIGN_P7B}

一键指引:
  ./scripts/harmonyos_setup_signing.sh
EOF
  exit 1
fi
[[ -f "${SIGN_JAR}" ]] || die "找不到 hap-sign-tool.jar: ${SIGN_JAR}"
[[ -f "${SIGN_ENV}" ]] || die "缺少 ${SIGN_ENV}，请先跑 ./scripts/harmonyos_setup_signing.sh"

# shellcheck disable=SC1090
source "${SIGN_ENV}"
KEY_ALIAS="${KEY_ALIAS:-nwvpnDebugKey}"
KEY_PASSWORD="${KEY_PASSWORD:?local.env 缺 KEY_PASSWORD}"
STORE_PASSWORD="${STORE_PASSWORD:?local.env 缺 STORE_PASSWORD}"

cd "${NWVPN}"

# --- 同步节点列表 -----------------------------------------------------------

if [[ "${SYNC_SERVERS}" == "1" ]]; then
  info "2) Sync configs/servers → entry rawfile"
  mkdir -p entry/src/main/resources/rawfile
  cp -f "${ROOT}/configs/servers" entry/src/main/resources/rawfile/servers
else
  info "2) Skip sync servers"
fi

# --- 依赖 / 构建 ------------------------------------------------------------

if [[ -n "${HAP_PATH}" ]]; then
  info "3) Skip build (HAP_PATH set)"
  [[ -f "${HAP_PATH}" ]] || die "HAP_PATH 不是文件: ${HAP_PATH}"
else
  if [[ -n "${OHPM}" && "${SKIP_OHPM}" != "1" ]]; then
    info "3) ohpm install"
    "${OHPM}" install --all
  else
    info "3) Skip ohpm install"
  fi

  info "4) Build HAP (product=${PRODUCT})"
  if [[ "${SKIP_CLEAN}" != "1" ]]; then
    "${HVIGOR}" --stop-daemon >/dev/null 2>&1 || true
    "${HVIGOR}" clean --no-daemon || true
  fi
  "${HVIGOR}" --mode module -p "product=${PRODUCT}" -p "module=${MODULE_NAME}@${PRODUCT}" assembleHap --no-daemon

  info "5) Resolve unsigned HAP"
  HAP_PATH="$(find "${MODULE_NAME}/build" -name '*.hap' -type f ! -name '*signed*' 2>/dev/null | head -n 1 || true)"
  if [[ -z "${HAP_PATH}" ]]; then
    HAP_PATH="$(find "${MODULE_NAME}/build" -name '*.hap' -type f 2>/dev/null | head -n 1 || true)"
  fi
  [[ -n "${HAP_PATH}" && -f "${HAP_PATH}" ]] || die "未找到 HAP。可手动: HAP_PATH=... $0 --install-only"

  if [[ "${HAP_PATH}" != /* ]]; then
    HAP_PATH="${NWVPN}/${HAP_PATH}"
  fi

  info "5b) Sign HAP with hap-sign-tool"
  SIGNED_HAP="${NWVPN}/${MODULE_NAME}/build/outputs/nwvpn-signed.hap"
  mkdir -p "$(dirname "${SIGNED_HAP}")"
  command -v java >/dev/null || die "需要 java 才能签名"
  java -jar "${SIGN_JAR}" sign-app \
    -keyAlias "${KEY_ALIAS}" \
    -signAlg "SHA256withECDSA" \
    -mode "localSign" \
    -appCertFile "${SIGN_CER}" \
    -profileFile "${SIGN_P7B}" \
    -inFile "${HAP_PATH}" \
    -keystoreFile "${SIGN_P12}" \
    -outFile "${SIGNED_HAP}" \
    -keyPwd "${KEY_PASSWORD}" \
    -keystorePwd "${STORE_PASSWORD}" \
    -signCode "1"
  HAP_PATH="${SIGNED_HAP}"
fi

# 相对路径转绝对，便于后面打印
if [[ "${HAP_PATH}" != /* ]]; then
  HAP_PATH="${NWVPN}/${HAP_PATH}"
fi
echo "HAP: ${HAP_PATH}"

if [[ "${DO_INSTALL}" != "1" ]]; then
  info "Skip install (--no-install)"
  echo "Done."
  exit 0
fi

info "6) Check devices"
if [[ -n "${TARGET_SN}" ]]; then
  "${HDC}" -t "${TARGET_SN}" shell "echo device_ok" >/dev/null
else
  "${HDC}" list targets
  target_count="$("${HDC}" list targets 2>/dev/null | grep -cvE '^\[Empty\]$' || true)"
  if [[ "${target_count}" == "0" ]]; then
    die "hdc 未发现设备。请用 USB 连接并开启调试，或启动模拟器后再试"
  fi
fi

info "7) Install (replace)"
if [[ -n "${TARGET_SN}" ]]; then
  "${HDC}" -t "${TARGET_SN}" install -r "${HAP_PATH}"
else
  "${HDC}" install -r "${HAP_PATH}"
fi

BUNDLE="$(python3 - <<'PY' "${NWVPN}/AppScope/app.json5"
import re, sys
text = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'"bundleName"\s*:\s*"([^"]+)"', text)
print(m.group(1) if m else "")
PY
)"
ABILITY="EntryAbility"
if [[ -n "${BUNDLE}" ]]; then
  info "8) Launch ${BUNDLE}/${ABILITY}"
  if [[ -n "${TARGET_SN}" ]]; then
    "${HDC}" -t "${TARGET_SN}" shell aa start -a "${ABILITY}" -b "${BUNDLE}" || true
  else
    "${HDC}" shell aa start -a "${ABILITY}" -b "${BUNDLE}" || true
  fi
fi

echo "Done."
