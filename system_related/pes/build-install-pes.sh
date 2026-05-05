#!/bin/bash
set -euo pipefail

ROOTFS="${1:?usage: build-install-pes.sh ROOTFS}"
SRCROOT="${SRCROOT:?SRCROOT must point at gateway-image}"
PES_SRC="${SRCROOT}/../../../gateway_softwares/processing_engine_software_PES/PES"

if [ ! -d "${PES_SRC}" ]; then
  echo "PES source not found: ${PES_SRC}" >&2
  exit 1
fi

BUILD_ROOT="${ROOTFS}/tmp/gateway-build/pes"
SRC_COPY="${BUILD_ROOT}/src"

cleanup() {
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT

rm -rf "${BUILD_ROOT}"
install -d -m 0755 "${SRC_COPY}"

rsync -a --delete \
  --exclude '.git' \
  --exclude 'build' \
  --exclude 'cmake-build-*' \
  --exclude '.cache' \
  "${PES_SRC}/" "${SRC_COPY}/"

find "${BUILD_ROOT}" -type d -exec chmod 0777 {} +

uchroot "${ROOTFS}" bash <<'EOCHROOT'
set -euo pipefail

cmake \
  -S /tmp/gateway-build/pes/src \
  -B /tmp/gateway-build/pes/build \
  -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DPES_BUILD_TESTS=OFF

cmake --build /tmp/gateway-build/pes/build --target pes_main --parallel

strip /tmp/gateway-build/pes/build/apps/pes_main/pes_main || true
EOCHROOT

install -D -m 0755 \
  "${ROOTFS}/tmp/gateway-build/pes/build/apps/pes_main/pes_main" \
  "${ROOTFS}/opt/gateway/pes_bin/pes_main"
