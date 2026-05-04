#!/usr/bin/env bash
# 将 apps/macos/NewWorldVPN 打成 Release .app，并生成可双击安装的 .pkg（安装到 /Applications）。
#
# 用法：
#   ./scripts/package-newworld-macos.sh              # 默认无代码签名，输出到 archives/macos/
#   OUT=~/Desktop ./scripts/package-newworld-macos.sh
#   VERSION=1.0.1 ./scripts/package-newworld-macos.sh
#
# 可选环境变量：
#   OUT              输出目录（默认：仓库根 archives/macos）
#   VERSION          包版本号（默认从 apps/macos/NewWorldVPN/project.yml 读 MARKETING_VERSION）
#   CODE_SIGN_IDENTITY  传给 xcodebuild，默认 "-"（ad hoc）；分发请改为 "Developer ID Application: …" 等
#   CODE_SIGNING_ALLOWED 默认 NO；需 Apple 开发/分发证书时请设 YES（与 Xcode 自动签名一致）
#   SKIP_ADHOC_CODESIGN  若设为 1，在 CODE_SIGNING_ALLOWED=NO 时跳过对 .app 的 ad-hoc 签名（不推荐：安装后 SMAppService 会报 -67056）
#   SKIP_GO_BUILD    若设为 1，不在打包前尝试编译 go/nw-client
#   DEVELOPER_INSTALLER_ID  若设置，在 .pkg 生成后用 productsign 用「Developer ID Installer」再签安装包
#
# 依赖：Xcode 命令行工具、xcodegen（brew install xcodegen）、可选 go（嵌入 nw-client）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MAC="$ROOT/apps/macos/NewWorldVPN"
SCHEME="NewWorldVPN"
OUT="${OUT:-$ROOT/archives/macos}"
PKG_ID="com.newworld.NewWorldVPN.installer"

die() { echo "error: $*" >&2; exit 1; }

VERSION="${VERSION:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(grep -E '^[[:space:]]*MARKETING_VERSION:' "$MAC/project.yml" | head -1 | sed -E 's/[^"]*"([^"]+)".*/\1/')"
fi
[[ -n "$VERSION" ]] || die "无法从 project.yml 解析 MARKETING_VERSION，请设置 VERSION=…"

command -v xcodegen >/dev/null 2>&1 || die "未找到 xcodegen，请先: brew install xcodegen"
command -v xcodebuild >/dev/null 2>&1 || die "未找到 xcodebuild，请安装 Xcode 命令行工具"

mkdir -p "$OUT"
DD="$MAC/build/package-derived-data"
rm -rf "$DD"

if [[ "${SKIP_GO_BUILD:-0}" != "1" ]] && command -v go >/dev/null 2>&1; then
  if [[ ! -f "$ROOT/go/nw-client" ]]; then
    echo "==> 编译 go/nw-client（供嵌入 App）…"
    (cd "$ROOT/go" && go build -o nw-client ./cmd/nw-client)
  fi
else
  echo "==> 跳过 go 编译（SKIP_GO_BUILD=1 或未安装 go）；若 go/nw-client 不存在，安装包内可能无客户端二进制"
fi

echo "==> xcodegen …"
( cd "$MAC" && xcodegen generate )

echo "==> xcodebuild Release …"
CODE_SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
CODE_SIGNING_ALLOWED="${CODE_SIGNING_ALLOWED:-NO}"
( cd "$MAC" && xcodebuild \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "platform=macOS" \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="$CODE_SIGN_IDENTITY" \
  CODE_SIGNING_ALLOWED="$CODE_SIGNING_ALLOWED" \
  build )

APP="$DD/Build/Products/Release/NewWorldVPN.app"
[[ -d "$APP" ]] || die "未找到构建产物: $APP"

# 未启用 Xcode 签名时，产物为「未签名」；SMAppService 加载内嵌 LaunchDaemon plist 会校验签名并报 Codesigning failure（-67056）。
# 对整包做 ad-hoc（codesign -）可满足本机/拷贝安装；对外分发仍请使用 CODE_SIGNING_ALLOWED=YES + Developer ID + 公证。
if [[ "${CODE_SIGNING_ALLOWED}" == "NO" ]] && [[ "${SKIP_ADHOC_CODESIGN:-0}" != "1" ]]; then
  echo "==> ad-hoc 签名 NewWorldVPN.app（codesign -，含 Hardened Runtime + entitlements）…"
  ENT="$MAC/App/NewWorldVPN.entitlements"
  [[ -f "$ENT" ]] || die "缺少 $ENT"
  codesign --force --deep --sign - --timestamp=none --options runtime --entitlements "$ENT" "$APP" \
    || die "codesign 失败。请安装 Xcode 命令行工具，或改用 CODE_SIGNING_ALLOWED=YES 在 Xcode 侧签名后再打包。"
  codesign --verify --verbose=2 "$APP" 2>/dev/null || true
fi

STAGE="$(mktemp -d "${TMPDIR:-/tmp}/nwvpn-pkg-stage.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

mkdir -p "$STAGE/Applications"
echo "==> 拷贝 NewWorldVPN.app …"
ditto "$APP" "$STAGE/Applications/NewWorldVPN.app"

PKG_UNSIGNED="$OUT/NewWorldVPN-${VERSION}-unsigned.pkg"
PKG_FINAL="$OUT/NewWorldVPN-${VERSION}.pkg"
rm -f "$PKG_UNSIGNED" "$PKG_FINAL"

echo "==> pkgbuild → $PKG_FINAL …"
pkgbuild \
  --root "$STAGE" \
  --identifier "$PKG_ID" \
  --version "$VERSION" \
  --install-location / \
  "$PKG_UNSIGNED"

if [[ -n "${DEVELOPER_INSTALLER_ID:-}" ]]; then
  echo "==> productsign（安装包签名）…"
  productsign --sign "$DEVELOPER_INSTALLER_ID" "$PKG_UNSIGNED" "$PKG_FINAL"
  rm -f "$PKG_UNSIGNED"
else
  mv "$PKG_UNSIGNED" "$PKG_FINAL"
fi

echo "==> 完成: $PKG_FINAL"
echo "    安装: 双击 .pkg，按向导将 NewWorldVPN 安装到「应用程序」。"
