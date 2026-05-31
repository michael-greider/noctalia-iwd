#!/usr/bin/env bash
# noctalia-iwd install script
# Replaces Noctalia Shell's NetworkManager backend with iwd
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NOCTALIA_DIR="/etc/xdg/quickshell/noctalia-shell"
SERVICE_PATH="${NOCTALIA_DIR}/Services/Networking/NetworkService.qml"
HELPER_DEST="/usr/local/bin/iwd-helper"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

# ─── Preflight ──────────────────────────────────────────────────────

# Check iwd is installed
command -v iwctl >/dev/null 2>&1 || error "iwd is not installed. Install it first: sudo pacman -S iwd"

# Check busctl (systemd)
command -v busctl >/dev/null 2>&1 || error "busctl not found. systemd is required."

# Check iw (for signal/rate info)
if ! command -v iw >/dev/null 2>&1; then
    warn "iw not installed. Signal strength/rate info will be unavailable."
    warn "Install it: sudo pacman -S iw"
fi

# Check curl (for connectivity check)
if ! command -v curl >/dev/null 2>&1; then
    warn "curl not installed. Connectivity checks will be unavailable."
fi

# Check Noctalia is installed
[[ -d "$NOCTALIA_DIR" ]] || error "Noctalia Shell not found at ${NOCTALIA_DIR}"
[[ -f "$SERVICE_PATH" ]] || error "NetworkService.qml not found at ${SERVICE_PATH}"

# Check source files exist
[[ -f "${SCRIPT_DIR}/iwd-helper" ]] || error "iwd-helper not found in repo"
[[ -f "${SCRIPT_DIR}/NetworkService.qml" ]] || error "NetworkService.qml not found in repo"

# ─── Install ────────────────────────────────────────────────────────

echo ""
echo "noctalia-iwd installer"
echo "======================"
echo ""
echo "This will:"
echo "  1. Install iwd-helper to ${HELPER_DEST}"
echo "  2. Back up the original NetworkService.qml"
echo "  3. Replace it with the iwd-compatible version"
echo ""

read -rp "Continue? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""

# Install helper
info "Installing iwd-helper to ${HELPER_DEST}"
sudo install -m755 "${SCRIPT_DIR}/iwd-helper" "$HELPER_DEST"

# Backup original
if [[ ! -f "${SERVICE_PATH}.nmcli.bak" ]]; then
    info "Backing up original NetworkService.qml"
    sudo cp "$SERVICE_PATH" "${SERVICE_PATH}.nmcli.bak"
else
    warn "Backup already exists at ${SERVICE_PATH}.nmcli.bak — skipping"
fi

# Install replacement
info "Installing iwd NetworkService.qml"
sudo cp "${SCRIPT_DIR}/NetworkService.qml" "$SERVICE_PATH"

# Verify
info "Verifying installation..."
if iwd-helper status >/dev/null 2>&1; then
    info "iwd-helper is working"
else
    warn "iwd-helper returned an error — is iwd running?"
    warn "Start it: sudo systemctl enable --now iwd"
fi

echo ""
info "Installation complete!"
echo ""
echo "Next steps:"
echo "  1. Make sure iwd is running: sudo systemctl enable --now iwd"
echo "  2. If using iwd standalone (no NetworkManager), configure /etc/iwd/main.conf:"
echo "     [General]"
echo "     EnableNetworkConfiguration=true"
echo "     [Network]"
echo "     NameResolvingService=systemd"
echo "  3. Restart Noctalia Shell"
echo ""
echo "To uninstall: ./uninstall.sh"
