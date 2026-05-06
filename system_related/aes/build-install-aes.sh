#!/bin/bash
set -euo pipefail

ROOTFS="${1:?usage: build-install-aes.sh ROOTFS}"
SRCROOT="${SRCROOT:?SRCROOT must point at gateway-image}"
AES_SRC="${SRCROOT}/../../../gateway_softwares/analytics_engine_software_aes/AES"

if [ ! -d "${AES_SRC}" ]; then
  echo "AES source not found: ${AES_SRC}" >&2
  exit 1
fi

BUILD_ROOT="${ROOTFS}/tmp/gateway-build/aes"
SRC_COPY="${BUILD_ROOT}/src"

cleanup() {
  rm -rf "${BUILD_ROOT}"
}
trap cleanup EXIT

rm -rf "${BUILD_ROOT}"
install -d -m 0755 "${SRC_COPY}"

rsync -a --delete \
  --exclude '.git' \
  --exclude '__pycache__' \
  --exclude '*.pyc' \
  --exclude '.venv' \
  --exclude 'venv' \
  "${AES_SRC}/" "${SRC_COPY}/"

find "${BUILD_ROOT}" -type d -exec chmod 0777 {} +

uchroot "${ROOTFS}" bash <<'EOCHROOT'
set -euo pipefail

cd /tmp/gateway-build/aes/src
rm -rf /tmp/gateway-build/aes/nuitka
python3 -m venv --system-site-packages /tmp/gateway-build/aes/venv
. /tmp/gateway-build/aes/venv/bin/activate

python -m pip install --upgrade pip wheel
python -m pip install 'nuitka>=2.6,<3'

python -m nuitka \
  --assume-yes-for-downloads \
  --output-dir=/tmp/gateway-build/aes/nuitka \
  --output-filename=gateway-aes \
  --include-package=analytics_engine \
  --include-package=utils \
  --include-package=webpage \
  --include-data-dir=/tmp/gateway-build/aes/src/webpage/templates=webpage/templates \
  --include-data-dir=/tmp/gateway-build/aes/src/webpage/static=webpage/static \
  /tmp/gateway-build/aes/src/main.py

if [ ! -x /tmp/gateway-build/aes/nuitka/gateway-aes ]; then
  echo "Nuitka did not produce the AES executable" >&2
  exit 1
fi
EOCHROOT

EXE="${ROOTFS}/tmp/gateway-build/aes/nuitka/gateway-aes"
if [ ! -x "${EXE}" ]; then
  echo "Nuitka did not produce the AES executable" >&2
  exit 1
fi

rm -rf "${ROOTFS}/opt/gateway/aes_bin"
install -d -m 0755 "${ROOTFS}/opt/gateway/aes_bin"
install -D -m 0755 "${EXE}" "${ROOTFS}/opt/gateway/aes_bin/gateway-aes"
install -d -m 0755 "${ROOTFS}/opt/gateway/aes_bin/webpage"
rsync -a --delete "${AES_SRC}/webpage/templates" "${ROOTFS}/opt/gateway/aes_bin/webpage/"
rsync -a --delete "${AES_SRC}/webpage/static" "${ROOTFS}/opt/gateway/aes_bin/webpage/"
chmod 0755 "${ROOTFS}/opt/gateway/aes_bin/gateway-aes"
