#!/usr/bin/env bash
# noctalia-iwd uninstall script
# Restores original NetworkManager-based NetworkService
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

NOCTALIA_DIR="/etc/xdg/quickshell/noctalia-shell"
SERVICE_PATH="${NOCTALIA_DIR}/Services/Networking/NetworkService.qml"
HELPER_DEST="/usr/local/bin/iwd-helper"

info()  { echo -e "${GREEN}[+]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[x]${NC} $1"; exit 1; }

echo ""
echo "noctalia-iwd uninstaller"
echo "========================"
echo ""

read -rp "Restore original NetworkManager backend? [y/N] " confirm
[[ "$confirm" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

echo ""

# Restore backup
if [[ -f "${SERVICE_PATH}.nmcli.bak" ]]; then
    info "Restoring original NetworkService.qml"
    sudo cp "${SERVICE_PATH}.nmcli.bak" "$SERVICE_PATH"
else
    warn "No backup found at ${SERVICE_PATH}.nmcli.bak"
    warn "You may need to reinstall Noctalia Shell to restore the original"
fi

# Remove helper
if [[ -f "$HELPER_DEST" ]]; then
    info "Removing iwd-helper"
    sudo rm "$HELPER_DEST"
else
    warn "iwd-helper not found at ${HELPER_DEST}"
fi

echo ""
info "Uninstall complete. Restart Noctalia Shell to apply."
echo ""
echo "Don't forget to re-enable NetworkManager if needed:"
echo "  sudo systemctl enable --now NetworkManager"
