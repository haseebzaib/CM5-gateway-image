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
python3 -m venv /tmp/gateway-build/aes/venv
. /tmp/gateway-build/aes/venv/bin/activate

python -m pip install --upgrade pip wheel
python -m pip install \
  'nuitka>=2.6,<3' \
  'fastapi>=0.115,<1.0' \
  'itsdangerous>=2.2,<3.0' \
  'jinja2>=3.1,<4.0' \
  'uvicorn[standard]>=0.30,<1.0' \
  'paho-mqtt>=2,<3' \
  'python-multipart>=0.0.9,<1.0'

python -m nuitka \
  --standalone \
  --follow-imports \
  --assume-yes-for-downloads \
  --output-dir=/tmp/gateway-build/aes/nuitka \
  --include-package=analytics_engine \
  --include-package=utils \
  --include-package=webpage \
  --include-data-dir=/tmp/gateway-build/aes/src/webpage/templates=webpage/templates \
  --include-data-dir=/tmp/gateway-build/aes/src/webpage/static=webpage/static \
  /tmp/gateway-build/aes/src/main.py

dist_dir="$(find /tmp/gateway-build/aes/nuitka -maxdepth 1 -type d -name '*.dist' | head -n1)"
if [ -z "${dist_dir}" ]; then
  echo "Nuitka did not produce a .dist directory" >&2
  exit 1
fi
EOCHROOT

DIST_DIR="$(find "${ROOTFS}/tmp/gateway-build/aes/nuitka" -maxdepth 1 -type d -name '*.dist' | head -n1)"
if [ -z "${DIST_DIR}" ]; then
  echo "Nuitka did not produce a .dist directory" >&2
  exit 1
fi

rm -rf "${ROOTFS}/opt/gateway/aes_bin"
install -d -m 0755 "${ROOTFS}/opt/gateway/aes_bin"
cp -a "${DIST_DIR}/." "${ROOTFS}/opt/gateway/aes_bin/"

exe=""
for candidate in \
  "${ROOTFS}/opt/gateway/aes_bin/main.bin" \
  "${ROOTFS}/opt/gateway/aes_bin/main" \
  "${ROOTFS}/opt/gateway/aes_bin/gateway-aes"
do
  if [ -x "${candidate}" ]; then
    exe="${candidate}"
    break
  fi
done

if [ -z "${exe}" ]; then
  exe="$(find "${ROOTFS}/opt/gateway/aes_bin" -maxdepth 1 -type f -perm /111 | head -n1)"
fi

if [ -z "${exe}" ]; then
  echo "Unable to locate Nuitka AES executable" >&2
  exit 1
fi

if [ "${exe}" != "${ROOTFS}/opt/gateway/aes_bin/gateway-aes" ]; then
  mv "${exe}" "${ROOTFS}/opt/gateway/aes_bin/gateway-aes"
fi

chmod 0755 "${ROOTFS}/opt/gateway/aes_bin/gateway-aes"
find "${ROOTFS}/opt/gateway/aes_bin" -name '*.py' -delete
