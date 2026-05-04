#!/usr/bin/env bash
# NWVPN Android 打包：在仓库根目录执行，或任意目录执行（脚本会定位到 apps/android/NWVPN）。
#
# 依赖：JDK 17+、Android SDK（设置 ANDROID_HOME 或写入 apps/android/NWVPN/local.properties 的 sdk.dir）。
#
# 用法:
#   ./scripts/package_android_nwvpn.sh              # 默认 assembleDebug
#   ./scripts/package_android_nwvpn.sh debug        # Debug APK
#   ./scripts/package_android_nwvpn.sh release      # Release APK（未配置签名时为 unsigned）
#   ./scripts/package_android_nwvpn.sh bundle       # Release AAB（应用上架）
#   ./scripts/package_android_nwvpn.sh clean        # ./gradlew clean
#
# 产物默认复制到仓库根下 archives/android-nwvpn/（目录在 .gitignore 中）。
#
# 可选环境变量:
#   GRADLE_EXTRA_ARGS   追加到 gradlew 的参数，例如: '--warning-mode all'
#   COPY_OUT_DIR        覆盖默认产物目录（仍会 mkdir -p）

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NWVPN="${ROOT}/apps/android/NWVPN"
ARCHIVES_DEFAULT="${ROOT}/archives/android-nwvpn"
OUT_DIR="${COPY_OUT_DIR:-${ARCHIVES_DEFAULT}}"
GRADLEW="${NWVPN}/gradlew"

if [[ ! -d "${NWVPN}" ]]; then
  echo "error: 未找到 ${NWVPN}" >&2
  exit 1
fi

if [[ ! -x "${GRADLEW}" ]]; then
  echo "error: 未找到可执行的 ${GRADLEW}（请确认已提交 Gradle Wrapper）。" >&2
  exit 1
fi

if [[ -n "${ANDROID_HOME:-}" ]] && [[ ! -d "${ANDROID_HOME}" ]]; then
  echo "error: ANDROID_HOME 指向不存在的目录: ${ANDROID_HOME}" >&2
  exit 1
fi

TASK="${1:-debug}"
if (($# >= 1)); then
  shift
fi

extra=()
if [[ -n "${GRADLE_EXTRA_ARGS:-}" ]]; then
  # shellcheck disable=SC2206
  extra=( ${GRADLE_EXTRA_ARGS} )
fi

# macOS /bin/bash 3.2 + set -u：空数组 "${extra[@]}" 会报 unbound variable，须分支展开。
run_gradle() {
  if ((${#extra[@]} > 0)); then
    ./gradlew "$@" "${extra[@]}"
  else
    ./gradlew "$@"
  fi
}

cd "${NWVPN}"

case "${TASK}" in
  debug)
    run_gradle :app:assembleDebug "$@"
    echo ""
    echo "Debug APK:"
    find app/build/outputs/apk/debug -name '*.apk' -type f 2>/dev/null || true
    ;;
  release)
    run_gradle :app:assembleRelease "$@"
    echo ""
    echo "Release APK:"
    find app/build/outputs/apk/release -name '*.apk' -type f 2>/dev/null || true
    ;;
  bundle)
    run_gradle :app:bundleRelease "$@"
    echo ""
    echo "Release bundle:"
    find app/build/outputs/bundle/release -name '*.aab' -type f 2>/dev/null || true
    ;;
  clean)
    run_gradle clean "$@"
    ;;
  all)
    run_gradle :app:assembleDebug :app:assembleRelease "$@"
    echo ""
    find app/build/outputs/apk -name '*.apk' -type f 2>/dev/null || true
    ;;
  *)
    echo "用法: $0 [debug|release|bundle|clean|all] [额外 gradle 参数...]" >&2
    echo "当前未知子命令: ${TASK}" >&2
    exit 2
    ;;
esac

if [[ "${TASK}" != "clean" ]]; then
  mkdir -p "${OUT_DIR}"
  copied=0
  while IFS= read -r -d '' f; do
    cp -f "${f}" "${OUT_DIR}/"
    echo "已复制: $(basename "${f}") -> ${OUT_DIR}/"
    copied=$((copied + 1))
  done < <(find app/build/outputs -type f \( -name '*.apk' -o -name '*.aab' \) -print0 2>/dev/null || true)
  if [[ "${copied}" -eq 0 ]]; then
    echo "提示: 未找到 apk/aab 可复制（检查构建是否成功）。" >&2
  else
    echo ""
    echo "产物目录: ${OUT_DIR}"
  fi
fi
