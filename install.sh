#!/usr/bin/env bash

# ==============================================================================
# Dotfiles Installation Script
# 
# 1. Installs Niri window manager first
# 2. Installs additional applications: kitty, cava, vlc, mpd
# 3. Places all folders inside dotfiles/.config into ~/.config/
# 4. Places all folders inside dotfiles/.local into ~/.local/
# 5. Creates required runtime directories (MPD state/playlists, screenshots, etc.)
# ==============================================================================

set -euo pipefail

# ANSI color codes
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

log_success() {
    printf "${GREEN}[OK]${NC} %s\n" "$*"
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*"
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

# -----------------------------------------------------------------------------
# Pre-flight Checks
# -----------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    log_error "Please run this script as a normal user (without sudo)."
    log_error "The script will invoke 'sudo' only when installing packages."
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${SCRIPT_DIR}/dotfiles"
CONFIG_SRC="${DOTFILES_DIR}/.config"
LOCAL_SRC="${DOTFILES_DIR}/.local"

TARGET_CONFIG="${HOME}/.config"
TARGET_LOCAL="${HOME}/.local"

if [[ ! -d "${CONFIG_SRC}" ]]; then
    log_error "Config source directory '${CONFIG_SRC}' does not exist!"
    exit 1
fi

# Detect package manager
detect_pkg_manager() {
    if command -v dnf5 &>/dev/null; then
        echo "dnf5"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    elif command -v pacman &>/dev/null; then
        echo "pacman"
    elif command -v apt-get &>/dev/null; then
        echo "apt"
    elif command -v zypper &>/dev/null; then
        echo "zypper"
    else
        echo "unknown"
    fi
}

PKG_MGR="$(detect_pkg_manager)"

install_package() {
    local pkg_name="$1"
    local display_name="${2:-$pkg_name}"

    log_info "Installing ${display_name}..."
    case "${PKG_MGR}" in
        dnf5|dnf)
            sudo "${PKG_MGR}" install -y "${pkg_name}"
            ;;
        pacman)
            sudo pacman -S --noconfirm --needed "${pkg_name}"
            ;;
        apt)
            sudo apt-get update -qq && sudo apt-get install -y "${pkg_name}"
            ;;
        zypper)
            sudo zypper install -y "${pkg_name}"
            ;;
        *)
            log_error "Unsupported package manager. Please install '${display_name}' manually."
            return 1
            ;;
    esac
}

echo -e "${BOLD}${CYAN}==============================================${NC}"
echo -e "${BOLD}${CYAN}       Dotfiles & Packages Installer          ${NC}"
echo -e "${BOLD}${CYAN}==============================================${NC}\n"

log_info "Detected package manager: ${PKG_MGR}"

# -----------------------------------------------------------------------------
# Step 1: Install Niri Window Manager First
# -----------------------------------------------------------------------------
echo ""
log_info "${BOLD}Step 1: Installing Niri Window Manager...${NC}"

if command -v niri &>/dev/null; then
    log_success "Niri is already installed ($(niri --version 2>/dev/null || echo 'version detected'))."
else
    install_package "niri" "Niri Window Manager"
    log_success "Niri installed successfully."
fi

# -----------------------------------------------------------------------------
# Step 2: Install Additional Software (kitty, cava, vlc, mpd)
# -----------------------------------------------------------------------------
echo ""
log_info "${BOLD}Step 2: Installing kitty, cava, vlc, and mpd...${NC}"

PACKAGES=("kitty" "cava" "vlc" "mpd")

for pkg in "${PACKAGES[@]}"; do
    if command -v "${pkg}" &>/dev/null; then
        log_success "${pkg} is already installed."
    else
        install_package "${pkg}" "${pkg}"
        log_success "${pkg} installed successfully."
    fi
done

# -----------------------------------------------------------------------------
# Step 3: Deploy Configurations to ~/.config and ~/.local
# -----------------------------------------------------------------------------
echo ""
log_info "${BOLD}Step 3: Deploying configuration files...${NC}"

BACKUP_DIR="${HOME}/.config_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_CREATED=false

backup_target() {
    local target="$1"
    if [[ -e "${target}" ]]; then
        if [[ "${BACKUP_CREATED}" = false ]]; then
            mkdir -p "${BACKUP_DIR}"
            BACKUP_CREATED=true
            log_warn "Existing configurations detected. Backing up to: ${BACKUP_DIR}"
        fi
        local rel_path="${target#"${HOME}/"}"
        local dest_parent="${BACKUP_DIR}/$(dirname "${rel_path}")"
        mkdir -p "${dest_parent}"
        mv "${target}" "${dest_parent}/"
        log_info "Backed up: ${target} -> ${BACKUP_DIR}/${rel_path}"
    fi
}

mkdir -p "${TARGET_CONFIG}"
mkdir -p "${TARGET_LOCAL}"

# Deploy each folder from dotfiles/.config into ~/.config/
log_info "Placing folders from ${CONFIG_SRC} into ${TARGET_CONFIG}/:"
for item in "${CONFIG_SRC}"/*; do
    [[ -e "${item}" ]] || continue
    folder_name="$(basename "${item}")"
    dest="${TARGET_CONFIG}/${folder_name}"

    backup_target "${dest}"
    cp -r "${item}" "${TARGET_CONFIG}/"
    log_success "Installed: ~/.config/${folder_name}"
done

# Deploy dotfiles/.local into ~/.local/ (if present)
if [[ -d "${LOCAL_SRC}" ]]; then
    log_info "Placing folders from ${LOCAL_SRC} into ${TARGET_LOCAL}/:"
    for item in "${LOCAL_SRC}"/*; do
        [[ -e "${item}" ]] || continue
        folder_name="$(basename "${item}")"
        dest="${TARGET_LOCAL}/${folder_name}"

        # Recursively merge without destroying non-conflicting user state
        mkdir -p "${dest}"
        cp -r "${item}/." "${dest}/"
        log_success "Installed: ~/.local/${folder_name}"
    done
fi

# Ensure settings.toml is placed in both ~/.config/noctalia and ~/.local/state/noctalia
log_info "Ensuring Noctalia settings.toml is placed in required locations..."
mkdir -p "${TARGET_CONFIG}/noctalia"
mkdir -p "${TARGET_LOCAL}/state/noctalia"

SETTINGS_SRC=""
if [[ -f "${CONFIG_SRC}/noctalia/settings.toml" ]]; then
    SETTINGS_SRC="${CONFIG_SRC}/noctalia/settings.toml"
elif [[ -f "${LOCAL_SRC}/state/noctalia/settings.toml" ]]; then
    SETTINGS_SRC="${LOCAL_SRC}/state/noctalia/settings.toml"
fi

if [[ -n "${SETTINGS_SRC}" ]]; then
    backup_target "${TARGET_CONFIG}/noctalia/settings.toml"
    cp "${SETTINGS_SRC}" "${TARGET_CONFIG}/noctalia/settings.toml"
    log_success "Placed: ~/.config/noctalia/settings.toml"

    backup_target "${TARGET_LOCAL}/state/noctalia/settings.toml"
    cp "${SETTINGS_SRC}" "${TARGET_LOCAL}/state/noctalia/settings.toml"
    log_success "Placed: ~/.local/state/noctalia/settings.toml"
else
    log_warn "settings.toml not found in source dotfiles!"
fi

# -----------------------------------------------------------------------------
# Step 4: Setup Runtime Directories
# -----------------------------------------------------------------------------
echo ""
log_info "${BOLD}Step 4: Ensuring runtime directories exist...${NC}"

# MPD playlists and state directories (required by mpd.conf)
mkdir -p "${HOME}/.local/share/mpd/playlists"
mkdir -p "${HOME}/Music"

# Screenshot storage path (configured in niri conf/startup.kdl)
mkdir -p "${HOME}/Pictures/Screenshots"

log_success "Runtime directories verified: ~/Music, ~/Pictures/Screenshots, ~/.local/share/mpd/playlists"

# -----------------------------------------------------------------------------
# Completion Summary
# -----------------------------------------------------------------------------
echo ""
echo -e "${BOLD}${GREEN}==============================================${NC}"
echo -e "${BOLD}${GREEN}        Installation Completed!               ${NC}"
echo -e "${BOLD}${GREEN}==============================================${NC}"
if [[ "${BACKUP_CREATED}" = true ]]; then
    echo -e "${YELLOW}Notice:${NC} Previous configs were safely backed up in: ${BOLD}${BACKUP_DIR}${NC}"
fi
echo -e "\nTo start your desktop session:"
echo -e "  1. Log out of your current session."
echo -e "  2. Select '${BOLD}Niri${NC}' from your display manager (GDM/SDDM) session menu."
echo -e "  3. Log in to start your newly configured desktop!\n"
