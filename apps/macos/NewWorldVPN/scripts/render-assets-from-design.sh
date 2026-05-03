#!/usr/bin/env bash
# App Icon / BrickWallMark / MenuBarBrick 统一由仓库根目录 scripts/gen_nwvpn_app_icons.py 生成（Pillow，与 design 几何一致）。
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../../.." && pwd)"
exec python3 "$ROOT/scripts/gen_nwvpn_app_icons.py"
