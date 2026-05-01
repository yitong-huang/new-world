#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_PATH="$SCRIPT_DIR/NWVPN.xcodeproj"
SCHEME="NWVPN"
CONFIGURATION="Debug"
DERIVED_DATA_PATH="${1:-$SCRIPT_DIR/.derivedData}"
SOURCE_APP="$DERIVED_DATA_PATH/Build/Products/$CONFIGURATION/NWVPN.app"
TARGET_APP="/Applications/NWVPN.app"

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "错误: 找不到工程文件: $PROJECT_PATH"
  exit 1
fi

echo "清理旧构建缓存: $DERIVED_DATA_PATH"
rm -rf "$DERIVED_DATA_PATH"

echo "开始构建: scheme=$SCHEME, configuration=$CONFIGURATION"
xcodebuild \
  -project "$PROJECT_PATH" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -allowProvisioningUpdates \
  clean build

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "错误: 构建完成但未找到产物: $SOURCE_APP"
  echo "可尝试先在 Xcode 里手动 Build 一次后重试。"
  exit 1
fi

echo "删除旧版本: $TARGET_APP"
osascript -e 'quit app "NWVPN"' >/dev/null 2>&1 || true
pkill -x "NWVPN" >/dev/null 2>&1 || true
sleep 1
rm -rf "$TARGET_APP"

echo "拷贝新版本: $SOURCE_APP -> $TARGET_APP"
ditto "$SOURCE_APP" "$TARGET_APP"

echo "启动应用: $TARGET_APP"
open "$TARGET_APP"

echo "完成。"
