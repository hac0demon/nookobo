#!/bin/sh
# /opt/scripts/update_plato.sh - Download & install latest Plato release
set -eu

PLATO_DIR="/opt/plato"
TMP_DIR="/tmp/plato_update"
TMP_ZIP="/tmp/plato-latest.zip"
API_URL="https://api.github.com/repos/baskerville/plato/releases/latest"

echo "Checking network connectivity..."
if ! ping -c 1 -W 2 1.1.1.1 >/dev/null 2>&1 && ! ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "ERROR: No internet connection. Turn on Wi-Fi first."
    exit 1
fi

echo "Fetching latest Plato release info..."
# Plato's official release asset is named plato-<version>.zip (not
# plato-kobo-<version>.zip).  Select only the release archive, not source
# archives or checksums.
RELEASE_JSON=$(curl -fsSL --connect-timeout 10 --max-time 30 "${API_URL}")
DL_URL=$(printf '%s\n' "${RELEASE_JSON}" \
    | grep '"browser_download_url"' \
    | sed -n 's/.*"browser_download_url": "\(https:[^"]*\/plato-[^"]*\.zip\)".*/\1/p' \
    | head -n 1 || true)

if [ -z "${DL_URL}" ]; then
    echo "ERROR: Failed to retrieve download link from GitHub API."
    exit 2
fi

echo "Downloading ${DL_URL}..."
curl -fL --connect-timeout 10 --max-time 300 "${DL_URL}" -o "${TMP_ZIP}"

echo "Verifying archive..."
unzip -tq "${TMP_ZIP}"

echo "Extracting archive..."
rm -rf "${TMP_DIR}"
mkdir -p "${TMP_DIR}"
unzip -o -q "${TMP_ZIP}" -d "${TMP_DIR}"
rm -f "${TMP_ZIP}"

# Keep the user's Plato settings even if a future release starts shipping a
# default Settings.toml in its archive.
SETTINGS_BACKUP="${TMP_DIR}.Settings.toml"
if [ -f "${PLATO_DIR}/Settings.toml" ]; then
    cp -p "${PLATO_DIR}/Settings.toml" "${SETTINGS_BACKUP}"
fi

mkdir -p "${PLATO_DIR}"
if [ -d "${TMP_DIR}/plato" ]; then
    cp -rf "${TMP_DIR}/plato/"* "${PLATO_DIR}/"
else
    cp -rf "${TMP_DIR}/"* "${PLATO_DIR}/"
fi
if [ -f "${SETTINGS_BACKUP}" ]; then
    cp -p "${SETTINGS_BACKUP}" "${PLATO_DIR}/Settings.toml"
fi
rm -rf "${TMP_DIR}"
rm -f "${SETTINGS_BACKUP}"

# Preserve custom Settings.toml if not present
if [ ! -f "${PLATO_DIR}/Settings.toml" ] && [ -f "${PLATO_DIR}/Settings-sample.toml" ]; then
    cp "${PLATO_DIR}/Settings-sample.toml" "${PLATO_DIR}/Settings.toml"
fi

# Ensure binaries and scripts have execution bits
chmod +x "${PLATO_DIR}/plato" "${PLATO_DIR}"/*.sh 2>/dev/null || true

echo "SUCCESS: Plato updated successfully!"
exit 0
