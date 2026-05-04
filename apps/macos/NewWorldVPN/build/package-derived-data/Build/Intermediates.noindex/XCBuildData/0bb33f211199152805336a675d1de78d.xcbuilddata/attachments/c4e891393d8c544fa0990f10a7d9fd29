#!/bin/sh
set -e
RES="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Resources"
mkdir -p "${RES}"
NW="${SRCROOT}/../../../go/nw-client"
if [ -f "$NW" ]; then
  cp -f "$NW" "${RES}/nw-client"
  chmod +x "${RES}/nw-client"
fi
CRT="${SRCROOT}/../../../certs/server.crt"
if [ -f "$CRT" ]; then
  cp -f "$CRT" "${RES}/server.crt"
fi
CHINA="${SRCROOT}/../../../configs/china_ipv4.txt"
if [ -f "$CHINA" ]; then
  cp -f "$CHINA" "${RES}/china_ipv4.txt"
fi
EXTRA="${SRCROOT}/../../../configs/extra_direct_ipv4.txt"
if [ -f "$EXTRA" ]; then
  cp -f "$EXTRA" "${RES}/extra_direct_ipv4.txt"
fi
# SMAppService.daemon(plistName:) 要求 plist 位于 Contents/Library/LaunchDaemons/
LD="${TARGET_BUILD_DIR}/${CONTENTS_FOLDER_PATH}/Library/LaunchDaemons"
mkdir -p "${LD}"
cp -f "${SRCROOT}/LaunchDaemons/com.newworld.NewWorldVPN.helper.plist" "${LD}/"

