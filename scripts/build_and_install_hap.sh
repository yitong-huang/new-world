#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   bash scripts/build_and_install_hap.sh
#   TARGET_SN=xxx bash scripts/build_and_install_hap.sh
#   HAP_PATH=entry/build/default/outputs/default/entry-default-signed.hap bash scripts/build_and_install_hap.sh

MODULE_NAME="${MODULE_NAME:-entry}"
BUILD_MODE="${BUILD_MODE:-debug}"
HAP_PATH="${HAP_PATH:-}"
TARGET_SN="${TARGET_SN:-}"

echo "==> 1) Check tools"
command -v hdc >/dev/null 2>&1 || {
  echo "ERROR: hdc not found in PATH"
  exit 1
}

if [[ -x "./hvigorw" ]]; then
  HVIGOR="./hvigorw"
elif [[ -x "./hvigorw.bat" ]]; then
  HVIGOR="./hvigorw.bat"
else
  echo "ERROR: hvigorw not found. Run this script in HarmonyOS project root."
  exit 1
fi

echo "==> 2) Build HAP ($BUILD_MODE)"
"$HVIGOR" clean
"$HVIGOR" assembleHap

echo "==> 3) Resolve HAP path"
if [[ -z "$HAP_PATH" ]]; then
  if command -v rg >/dev/null 2>&1; then
    HAP_PATH="$(rg --files "${MODULE_NAME}/build" -g '*.hap' | head -n 1 || true)"
  fi
fi

if [[ -z "$HAP_PATH" || ! -f "$HAP_PATH" ]]; then
  echo "ERROR: HAP not found automatically."
  echo "Set HAP_PATH manually, e.g.:"
  echo "  HAP_PATH=entry/build/default/outputs/default/entry-default-signed.hap bash scripts/build_and_install_hap.sh"
  exit 1
fi

echo "HAP: $HAP_PATH"

echo "==> 4) Check devices"
if [[ -n "$TARGET_SN" ]]; then
  hdc -t "$TARGET_SN" shell "echo device_ok" >/dev/null
else
  hdc list targets
fi

echo "==> 5) Install (replace)"
if [[ -n "$TARGET_SN" ]]; then
  hdc -t "$TARGET_SN" install -r "$HAP_PATH"
else
  hdc install -r "$HAP_PATH"
fi

echo "Done."
