#!/usr/bin/env bash
# ==============================================================================
# Fedora (Everything/minimal) + Niri + Noctalia + Dotfiles Installer  (v4)
#
# Order of work:
#   1. System upgrade (+ git/curl/COPR plugin prerequisites)
#   2. Wi-Fi and Bluetooth packages, firmware, NetworkManager
#   3. Repositories: RPM Fusion Free, Noctalia COPR, Helium COPR (+ fail-fast check)
#   4. Graphical session dependencies (audio, portals, polkit, ...) + greetd/Noctalia greeter
#   5. Essential applications, media tools, fonts, Luciole file manager
#   6. Niri and Noctalia
#   7. Services (Bluetooth, login manager = Noctalia greeter) and graphical boot
#   8. Dotfiles from github.com/sahulhustles/dotfiles-backup
#   9. Verification
#
# Usage:
#   chmod +x install.sh
#   ./install.sh                       # Full install
#   ./install.sh --greeter-only        # Existing install: switch to the Noctalia greeter + add Luciole
#   ./install.sh --gdm                 # Full install, but keep GDM instead of the Noctalia greeter
#   ./install.sh --dotfiles-only       # Only (re)deploy dotfiles + runtime dirs
#   ./install.sh --verify              # Post-reboot verification checks
#   ./install.sh --help
#
# Overrides (flags or environment variables):
#   --noctalia-copr OWNER/PROJECT   NOCTALIA_COPR   (default: lionheartp/Hyprland)
#   --noctalia-pkg  NAME            NOCTALIA_PKG    (default: noctalia-git)
#   HELIUM_COPR (default: imput/helium)   HELIUM_PKG (default: helium-bin)
#   DOTFILES_REPO_URL, DOTFILES_CLONE_DIR (default: ~/dotfiles-backup)
#
# Tip: on a fresh Fedora Everything install, connect to the internet FIRST:
#   nmcli device wifi connect "SSID" password "PASSWORD"
# ==============================================================================

set -euo pipefail

# ------------------------------------------------------------------------------
# Colors & logging
# ------------------------------------------------------------------------------
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log_header() {
    printf "\n${BOLD}${CYAN}======================================================================${NC}\n"
    printf "${BOLD}${CYAN} %s${NC}\n" "$*"
    printf "${BOLD}${CYAN}======================================================================${NC}\n"
}
log_info()    { printf "${BLUE}[INFO]${NC} %s\n" "$*"; }
log_success() { printf "${GREEN}[OK]${NC} %s\n" "$*"; }
log_warn()    { printf "${YELLOW}[WARN]${NC} %s\n" "$*"; }
log_error()   { printf "${RED}[ERROR]${NC} %s\n" "$*" >&2; }

# ------------------------------------------------------------------------------
# Configuration
# ------------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NOCTALIA_COPR="${NOCTALIA_COPR:-lionheartp/Hyprland}"
NOCTALIA_PKG="${NOCTALIA_PKG:-noctalia-git}"
HELIUM_COPR="${HELIUM_COPR:-imput/helium}"
HELIUM_PKG="${HELIUM_PKG:-helium-bin}"

# Luciole (Noctalia file manager): Terra's build if Terra is already enabled, else this COPR
LUCIOLE_TERRA_PKG="luciole-nightly"
LUCIOLE_COPR="lemmy/favorites"
LUCIOLE_COPR_PKG="luciole-git"

# Login manager: "greeter" = Noctalia greeter on greetd (default), "gdm" = GNOME's GDM
LOGIN_MANAGER="${LOGIN_MANAGER:-greeter}"
GREETER_PKG=""
GREETD_CONFIG="${GREETD_CONFIG:-/etc/greetd/config.toml}"
GREETER_TMPFILES="${GREETER_TMPFILES:-/etc/tmpfiles.d/noctalia-greeter.conf}"
GREETER_STATE_DIR="${GREETER_STATE_DIR:-/var/lib/noctalia-greeter}"

DOTFILES_REPO_URL="${DOTFILES_REPO_URL:-https://github.com/sahulhustles/dotfiles-backup.git}"
DOTFILES_CLONE_DIR="${DOTFILES_CLONE_DIR:-${HOME}/dotfiles-backup}"

# Resolved later by resolve_dotfiles_source()
REPO_ROOT=""
CONFIG_SRC=""
LOCAL_SRC=""
WALLS_SRC=""

TARGET_CONFIG="${HOME}/.config"
TARGET_LOCAL="${HOME}/.local"
NIRI_CONFIG_DIR="${TARGET_CONFIG}/niri"
NIRI_CONFIG_FILE="${NIRI_CONFIG_DIR}/config.kdl"

# Username baked into the repo's settings.toml (wallpaper/avatar paths)
ORIGINAL_HOME="/home/steve"

BACKUP_DIR="${HOME}/.config_backup_$(date +%Y%m%d_%H%M%S)"
BACKUP_CREATED=false
SUDO_KEEPALIVE_PID=""
HELIUM_OK=false

cleanup() {
    if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
        kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------
detect_dnf() {
    if command -v dnf5 &>/dev/null; then
        echo "dnf5"
    elif command -v dnf &>/dev/null; then
        echo "dnf"
    else
        echo ""
    fi
}

# Packages that MUST install (script stops if one fails)
pkg_install() {
    sudo "${DNF_CMD}" install -y "$@"
}

# Nice-to-have packages (a failure only prints a warning)
pkg_install_optional() {
    local pkg
    for pkg in "$@"; do
        if sudo "${DNF_CMD}" install -y "${pkg}"; then
            log_success "Installed optional package: ${pkg}"
        else
            log_warn "Optional package not available, skipped: ${pkg}"
        fi
    done
}

# True if a package can be found in the enabled repos (or is already installed)
pkg_available() {
    rpm -q "$1" &>/dev/null || "${DNF_CMD}" info "$1" &>/dev/null
}

check_internet() {
    getent hosts mirrors.fedoraproject.org &>/dev/null
}

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

tilde_path() {
    local p="$1"
    if [[ "${p}" == "${HOME}"* ]]; then
        printf '~%s' "${p#"${HOME}"}"
    else
        printf '%s' "${p}"
    fi
}

# True if an ACTIVE (not commented, not slashdashed) line matching the pattern
# exists in any .kdl file under ~/.config/niri.
has_active_kdl_line() {
    local pattern="$1"
    local hits
    hits="$(grep -RhsE --include='*.kdl' -- "${pattern}" "${NIRI_CONFIG_DIR}" 2>/dev/null \
        | grep -vE '^[[:space:]]*(//|/-)' || true)"
    [[ -n "${hits}" ]]
}

# ------------------------------------------------------------------------------
# Login manager: Noctalia greeter (runs on greetd) or GDM
# ------------------------------------------------------------------------------

# Finds which package provides the greeter: the Noctalia COPR first (same source
# as Noctalia itself), then the Terra repo as a fallback. Sets GREETER_PKG.
resolve_greeter_package() {
    local cand
    for cand in noctalia-greeter-git noctalia-greeter; do
        if pkg_available "${cand}"; then
            GREETER_PKG="${cand}"
            log_success "Greeter package available: ${GREETER_PKG}"
            return 0
        fi
    done

    log_warn "Greeter not found in the Noctalia COPR; adding the Terra repository (documented by Noctalia)."
    log_warn "Terra's release package is installed with --nogpgcheck, as in Noctalia's own instructions."
    if sudo "${DNF_CMD}" install -y --nogpgcheck \
        --repofrompath 'terra,https://repos.fyralabs.com/terra$releasever' terra-release; then
        for cand in noctalia-greeter noctalia-greeter-git; do
            if pkg_available "${cand}"; then
                GREETER_PKG="${cand}"
                log_success "Greeter package available from Terra: ${GREETER_PKG}"
                return 0
            fi
        done
    fi
    return 1
}

install_greeter_packages() {
    pkg_install greetd "${GREETER_PKG}"
    # SELinux policy for greetd, and user avatars on the greeter; both optional
    pkg_install_optional greetd-selinux accountsservice
}

# Prints the account greetd runs the greeter as ("greetd" on Fedora, "greeter" elsewhere)
detect_greeter_account() {
    local acct=""
    if [[ -r "${GREETD_CONFIG}" ]]; then
        acct="$(awk '
            /^\[default_session\]/ {s=1; next}
            /^\[/ {s=0}
            s && /^[[:space:]]*user[[:space:]]*=/ {
                gsub(/.*=[[:space:]]*"|"[[:space:]]*$/, ""); print; exit
            }' "${GREETD_CONFIG}")"
    fi
    if [[ -z "${acct}" ]] || ! getent passwd "${acct}" &>/dev/null; then
        for acct in greetd greeter; do
            if getent passwd "${acct}" &>/dev/null; then
                break
            fi
            acct=""
        done
    fi
    printf '%s' "${acct}"
}

# Disables every other display manager, enables the chosen one (no --now: starting
# it immediately would end the current session) and sets the graphical boot target.
enable_display_manager() {
    local chosen="$1" dm
    for dm in gdm greetd sddm lightdm lxdm; do
        [[ "${dm}" == "${chosen}" ]] && continue
        if systemctl list-unit-files "${dm}.service" --no-legend 2>/dev/null | grep -q "^${dm}\.service"; then
            log_info "Disabling ${dm}..."
            sudo systemctl disable "${dm}.service" || true
        fi
    done
    sudo systemctl enable -f "${chosen}.service" || return 1
    sudo systemctl set-default graphical.target || return 1
}

# Writes greetd's config, prepares the greeter's state directory, enables greetd.
# Every step is checked with "|| return 1": this runs inside "if", where set -e is off.
configure_greeter() {
    local session_cmd acct group cmd

    session_cmd="$(command -v noctalia-greeter-session || true)"
    if [[ -z "${session_cmd}" ]]; then
        log_error "noctalia-greeter-session not found; is ${GREETER_PKG:-the greeter package} installed?"
        return 1
    fi

    acct="$(detect_greeter_account)"
    if [[ -z "${acct}" ]]; then
        log_error "No 'greetd' or 'greeter' system account exists for the greeter."
        return 1
    fi
    group="$(id -gn "${acct}")" || return 1
    log_info "Greeter runs as: ${acct}:${group}; session wrapper: ${session_cmd}"

    cmd="${session_cmd}"
    if systemd-detect-virt --vm --quiet 2>/dev/null; then
        log_warn "Virtual machine detected: asking the greeter for software rendering (WLR_RENDERER=pixman)."
        cmd="env WLR_RENDERER=pixman WLR_NO_HARDWARE_CURSORS=1 ${session_cmd}"
    fi

    sudo mkdir -p "$(dirname "${GREETD_CONFIG}")" || return 1
    if [[ -f "${GREETD_CONFIG}" ]]; then
        sudo cp -a "${GREETD_CONFIG}" "${GREETD_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)" || return 1
        log_info "Backed up the old greetd config next to ${GREETD_CONFIG}"
    fi
    sudo tee "${GREETD_CONFIG}" >/dev/null <<EOF || return 1
[terminal]
vt = 1

[default_session]
command = "${cmd}"
user = "${acct}"
EOF
    log_success "Wrote ${GREETD_CONFIG}"

    # The greeter keeps its state in ${GREETER_STATE_DIR}; it must belong to the greeter account
    if [[ "${acct}" != "greeter" ]]; then
        printf 'd %s 0750 %s %s -\n' "${GREETER_STATE_DIR}" "${acct}" "${group}" \
            | sudo tee "${GREETER_TMPFILES}" >/dev/null || return 1
    fi
    sudo systemd-tmpfiles --create noctalia-greeter.conf \
        || log_warn "systemd-tmpfiles could not apply noctalia-greeter.conf"
    sudo env GREETER_USER="${acct}" noctalia-greeter-apply-appearance --setup-system || return 1

    if [[ ! -d "${GREETER_STATE_DIR}" ]]; then
        log_error "${GREETER_STATE_DIR} was not created."
        return 1
    fi
    log_info "Greeter state dir: $(stat -c '%U:%G %a' "${GREETER_STATE_DIR}")"

    enable_display_manager greetd || return 1
}

# Uses the Noctalia greeter if asked; if its setup fails, falls back to GDM so the
# machine never ends up without a graphical login.
setup_login_manager() {
    if [[ "${LOGIN_MANAGER}" == "greeter" ]]; then
        if configure_greeter; then
            log_success "Noctalia greeter configured; greetd enabled for the next boot."
            return 0
        fi
        log_warn "Noctalia greeter setup failed; falling back to GDM so you still get a graphical login."
        LOGIN_MANAGER="gdm"
        pkg_install gdm
    fi
    enable_display_manager gdm
    log_success "GDM enabled and graphical boot target set."
}

print_login_notes() {
    if [[ "${LOGIN_MANAGER}" == "greeter" ]]; then
        cat <<'EOF'

After rebooting you will see the Noctalia greeter:
  1. Select your user and the Niri session.
  2. Log in; Noctalia and your dotfiles load automatically.
  3. To make the greeter match your wallpaper and theme, open
     Noctalia Settings -> Security -> Noctalia Greeter -> Sync Now.

If the login screen is blank or never appears:
  - Press Ctrl+Alt+F3 for a text console and log in there.
  - Logs:  journalctl -u greetd -b | grep noctalia-greeter
  - To go back to GDM:
      sudo systemctl disable greetd
      sudo dnf install -y gdm
      sudo systemctl enable -f gdm
      sudo reboot
EOF
    else
        cat <<'EOF'

After rebooting, at the GDM login screen:
  1. Select your user.
  2. Click the session selector (gear icon) and choose Niri.
  3. Log in; Noctalia and your dotfiles load automatically.
EOF
    fi
}

prompt_reboot() {
    echo ""
    read -r -p "Reboot now? [y/N]: " REBOOT_CHOICE
    if [[ "${REBOOT_CHOICE}" =~ ^[Yy]$ ]]; then
        sudo reboot
    else
        log_info "Reboot skipped. Run 'sudo reboot' when you are ready."
    fi
}

# ------------------------------------------------------------------------------
# Luciole: Noctalia's native Wayland file manager
# ------------------------------------------------------------------------------
install_luciole() {
    log_info "Installing Luciole (Noctalia file manager)..."
    local lpkg=""
    if pkg_available "${LUCIOLE_TERRA_PKG}"; then
        lpkg="${LUCIOLE_TERRA_PKG}"
    else
        log_info "Not in Terra; trying COPR ${LUCIOLE_COPR}..."
        if sudo "${DNF_CMD}" copr enable -y "${LUCIOLE_COPR}" && pkg_available "${LUCIOLE_COPR_PKG}"; then
            lpkg="${LUCIOLE_COPR_PKG}"
        fi
    fi

    if [[ -z "${lpkg}" ]]; then
        log_warn "Luciole not found in Terra or COPR; skipping."
        return 0
    fi

    if sudo "${DNF_CMD}" install -y "${lpkg}"; then
        log_success "Installed Luciole (${lpkg})."
    else
        log_warn "Luciole install failed; skipping."
        return 0
    fi

    # Helpers recommended by Luciole's docs: trash/network, thumbnails, archives, images
    pkg_install_optional \
        gvfs gvfs-smb glycin-loaders ffmpegthumbnailer poppler-utils 7zip \
        shared-mime-info xdg-terminal-exec
}

# ------------------------------------------------------------------------------
# Dotfiles source: local repo next to this script, otherwise clone from GitHub
# ------------------------------------------------------------------------------
resolve_dotfiles_source() {
    if [[ -d "${SCRIPT_DIR}/dotfiles/.config" ]]; then
        REPO_ROOT="${SCRIPT_DIR}"
        log_info "Using dotfiles next to this script: ${REPO_ROOT}"
    else
        if ! command -v git &>/dev/null; then
            log_error "git is not installed, so the dotfiles repo cannot be cloned."
            exit 1
        fi
        if [[ -d "${DOTFILES_CLONE_DIR}/.git" ]]; then
            log_info "Updating existing clone: ${DOTFILES_CLONE_DIR}"
            git -C "${DOTFILES_CLONE_DIR}" pull --ff-only \
                || log_warn "git pull failed; using the existing copy as it is."
        else
            log_info "Cloning ${DOTFILES_REPO_URL} -> ${DOTFILES_CLONE_DIR}"
            git clone --depth 1 "${DOTFILES_REPO_URL}" "${DOTFILES_CLONE_DIR}"
        fi
        REPO_ROOT="${DOTFILES_CLONE_DIR}"
    fi

    CONFIG_SRC="${REPO_ROOT}/dotfiles/.config"
    LOCAL_SRC="${REPO_ROOT}/dotfiles/.local"
    WALLS_SRC="${REPO_ROOT}/walls"
}

# ------------------------------------------------------------------------------
# Fonts: kitty config needs JetBrainsMono Nerd Font + Symbols Nerd Font Mono
# ------------------------------------------------------------------------------
install_nerd_fonts() {
    local font_dir="${HOME}/.local/share/fonts/NerdFonts"
    local base="https://github.com/ryanoasis/nerd-fonts/releases/latest/download"
    local have_jb="" have_sym=""

    have_jb="$(fc-list 2>/dev/null | grep -i 'JetBrainsMono Nerd Font' || true)"
    have_sym="$(fc-list 2>/dev/null | grep -i 'Symbols Nerd Font' || true)"

    if [[ -n "${have_jb}" && -n "${have_sym}" ]]; then
        log_success "Nerd Fonts already installed."
        return 0
    fi

    mkdir -p "${font_dir}"
    local archive tmp
    for archive in JetBrainsMono NerdFontsSymbolsOnly; do
        tmp="$(mktemp --suffix=.tar.xz)"
        log_info "Downloading ${archive} Nerd Font..."
        if curl -fL --retry 3 -o "${tmp}" "${base}/${archive}.tar.xz" \
            && tar -xJf "${tmp}" -C "${font_dir}"; then
            log_success "Installed ${archive}"
        else
            log_warn "Could not install ${archive}; kitty icons/glyphs may look wrong."
        fi
        rm -f "${tmp}"
    done
    fc-cache -f "${HOME}/.local/share/fonts" >/dev/null 2>&1 || true
}

# ------------------------------------------------------------------------------
# Step 8 pieces: deploy dotfiles, wallpapers, runtime dirs, niri config
# ------------------------------------------------------------------------------
deploy_dotfiles() {
    log_header "Step 8: Deploying Dotfiles (~/.config & ~/.local)"

    resolve_dotfiles_source
    mkdir -p "${TARGET_CONFIG}" "${TARGET_LOCAL}"

    if [[ ! -d "${CONFIG_SRC}" ]]; then
        log_warn "Dotfiles source '${CONFIG_SRC}' not found; skipping dotfiles deployment."
        return 0
    fi

    log_info "Placing folders from ${CONFIG_SRC} into ${TARGET_CONFIG}/..."
    local item folder_name dest
    for item in "${CONFIG_SRC}"/*; do
        [[ -e "${item}" ]] || continue
        folder_name="$(basename "${item}")"

        # README screenshots are not a real config; keep them out of ~/.config
        if [[ "${folder_name}" == "screenshots" ]]; then
            log_info "Skipping README screenshots folder."
            continue
        fi

        dest="${TARGET_CONFIG}/${folder_name}"
        backup_target "${dest}"
        cp -a "${item}" "${TARGET_CONFIG}/"
        log_success "Installed: ~/.config/${folder_name}"
    done

    if [[ -d "${LOCAL_SRC}" ]]; then
        log_info "Merging folders from ${LOCAL_SRC} into ${TARGET_LOCAL}/..."
        for item in "${LOCAL_SRC}"/*; do
            [[ -e "${item}" ]] || continue
            folder_name="$(basename "${item}")"
            dest="${TARGET_LOCAL}/${folder_name}"

            mkdir -p "${dest}"
            cp -a "${item}/." "${dest}/"
            log_success "Installed: ~/.local/${folder_name}"
        done
    fi

    # Noctalia settings.toml must exist in both locations
    log_info "Ensuring Noctalia settings.toml is placed in required locations..."
    mkdir -p "${TARGET_CONFIG}/noctalia" "${TARGET_LOCAL}/state/noctalia"

    local settings_src=""
    if [[ -f "${CONFIG_SRC}/noctalia/settings.toml" ]]; then
        settings_src="${CONFIG_SRC}/noctalia/settings.toml"
    elif [[ -f "${LOCAL_SRC}/state/noctalia/settings.toml" ]]; then
        settings_src="${LOCAL_SRC}/state/noctalia/settings.toml"
    fi

    local dest_file
    if [[ -n "${settings_src}" ]]; then
        local target_paths=(
            "${TARGET_CONFIG}/noctalia/settings.toml"
            "${TARGET_LOCAL}/state/noctalia/settings.toml"
        )
        for dest_file in "${target_paths[@]}"; do
            if [[ -f "${dest_file}" ]] && cmp -s "${settings_src}" "${dest_file}"; then
                log_success "Verified: $(tilde_path "${dest_file}")"
            else
                backup_target "${dest_file}"
                cp -a "${settings_src}" "${dest_file}"
                log_success "Placed: $(tilde_path "${dest_file}")"
            fi
        done
    else
        log_warn "settings.toml not found in source dotfiles."
    fi

    deploy_wallpapers
    fix_hardcoded_home_paths
}

# settings.toml points at ~/Downloads/walls/walls1, so wallpapers go there
deploy_wallpapers() {
    if [[ -d "${WALLS_SRC}" ]]; then
        mkdir -p "${HOME}/Downloads/walls"
        cp -a "${WALLS_SRC}/." "${HOME}/Downloads/walls/"
        log_success "Wallpapers placed in ~/Downloads/walls"
    else
        log_warn "No walls/ folder in the repo; wallpaper paths in settings.toml may be empty."
    fi
}

# The repo's Noctalia settings contain /home/steve/... paths. If this machine's
# username differs, rewrite them (deployed copies only, never the repo).
fix_hardcoded_home_paths() {
    if [[ "${HOME}" == "${ORIGINAL_HOME}" ]]; then
        return 0
    fi
    local f
    for f in \
        "${TARGET_CONFIG}/noctalia/settings.toml" \
        "${TARGET_LOCAL}/state/noctalia/settings.toml" \
        "${TARGET_LOCAL}/state/noctalia/state.toml"; do
        if [[ -f "${f}" ]] && grep -q "${ORIGINAL_HOME}/" "${f}"; then
            sed -i "s#${ORIGINAL_HOME}/#${HOME}/#g" "${f}"
            log_success "Rewrote ${ORIGINAL_HOME}/ -> ${HOME}/ in $(tilde_path "${f}")"
        fi
    done
}

setup_runtime_dirs() {
    log_header "Runtime Directories"

    mkdir -p "${HOME}/.local/share/mpd/playlists"
    mkdir -p "${HOME}/Music"
    mkdir -p "${HOME}/Pictures/Screenshots"

    log_success "Ready: ~/Music, ~/Pictures/Screenshots, ~/.local/share/mpd/playlists"
}

configure_niri() {
    log_header "Configuring & Validating Niri"

    mkdir -p "${NIRI_CONFIG_DIR}"

    if [[ ! -f "${NIRI_CONFIG_FILE}" ]]; then
        if [[ -f "/etc/niri/config.kdl" ]]; then
            log_info "Copying default Niri config from /etc/niri/config.kdl..."
            cp /etc/niri/config.kdl "${NIRI_CONFIG_FILE}"
        elif [[ -f "/usr/share/doc/niri/default-config.kdl" ]]; then
            log_info "Copying default Niri config from /usr/share/doc/niri/default-config.kdl..."
            cp /usr/share/doc/niri/default-config.kdl "${NIRI_CONFIG_FILE}"
        else
            log_warn "No default Niri config found; one will be created on first Niri launch."
        fi
    else
        log_info "Using existing ${NIRI_CONFIG_FILE}."
    fi

    append_startup_if_missing() {
        local pattern="$1"
        local line="$2"

        if has_active_kdl_line "${pattern}"; then
            log_success "Startup entry already active: ${line}"
        else
            [[ -s "${NIRI_CONFIG_FILE}" && -n "$(tail -c 1 "${NIRI_CONFIG_FILE}")" ]] && echo "" >> "${NIRI_CONFIG_FILE}"
            echo "${line}" >> "${NIRI_CONFIG_FILE}"
            log_success "Added to config.kdl: ${line}"
        fi
    }

    if [[ -f "${NIRI_CONFIG_FILE}" ]]; then
        append_startup_if_missing \
            'spawn(-sh)?-at-startup[[:space:]]+"noctalia' \
            'spawn-at-startup "noctalia"'

        append_startup_if_missing \
            'polkit-mate-authentication-agent-1' \
            'spawn-at-startup "/usr/libexec/polkit-mate-authentication-agent-1"'

        log_info "Validating Niri configuration..."
        if command -v niri &>/dev/null; then
            if niri validate; then
                log_success "Niri configuration is valid."
            else
                log_warn "niri validate reported problems. Fix them in ${NIRI_CONFIG_DIR} before logging in."
            fi
        else
            log_warn "niri binary not found; skipped 'niri validate'."
        fi
    else
        log_warn "Could not find ${NIRI_CONFIG_FILE}."
        echo "       Launch Niri once after reboot, exit it (Super+Shift+E), and add:"
        echo '         spawn-at-startup "noctalia"'
        echo '         spawn-at-startup "/usr/libexec/polkit-mate-authentication-agent-1"'
        echo "       Then run: niri validate"
    fi
}

# Warn about programs the Niri/Noctalia configs call that are not installed
check_config_programs() {
    local prog
    for prog in brave-browser qimgv; do
        if grep -RqsE "(spawn|pinned).*${prog}" "${TARGET_CONFIG}/niri" "${TARGET_CONFIG}/noctalia" 2>/dev/null \
            && ! command -v "${prog}" &>/dev/null; then
            log_warn "Your config references '${prog}' but it is not installed."
            case "${prog}" in
                brave-browser)
                    echo "       Mod+B (conf/binds/apps.kdl) and Noctalia's pinned apps still point at Brave."
                    echo "       Change them to the Helium command (see 'rpm -ql ${HELIUM_PKG} | grep /bin/')."
                    ;;
                qimgv)
                    echo "       Mod+Shift+Period opens a guide image with qimgv. Install it or remove that bind."
                    ;;
            esac
        fi
    done

    if grep -RqsE 'spawn[[:space:]]+"nautilus"' "${TARGET_CONFIG}/niri" 2>/dev/null \
        && command -v luciole &>/dev/null; then
        log_info "Mod+E still opens Nautilus. To use Luciole, change spawn \"nautilus\" to spawn \"luciole\" in ~/.config/niri/conf/binds/apps.kdl."
    fi
}

# ------------------------------------------------------------------------------
# Verification
# ------------------------------------------------------------------------------
run_verification() {
    log_header "Step 9: Verifying Installed Components"

    log_info "Niri version:"
    niri --version || log_warn "Could not retrieve niri version."

    log_info "Noctalia version:"
    noctalia --version || log_warn "Could not retrieve noctalia version."

    log_info "Validating Niri config:"
    if [[ -f "${NIRI_CONFIG_FILE}" ]]; then
        niri validate || log_warn "Niri config has problems."
    else
        log_warn "${NIRI_CONFIG_FILE} not found yet."
    fi

    log_info "Installed packages:"
    local pkg
    for pkg in niri "${NOCTALIA_PKG}" "${HELIUM_PKG}" kitty cava mpd vlc nautilus; do
        if rpm -q "${pkg}" &>/dev/null; then
            log_success "${pkg}: $(rpm -q "${pkg}")"
        else
            log_warn "${pkg}: NOT installed"
        fi
    done

    log_info "Luciole file manager:"
    local lu
    lu="$(rpm -qa 'luciole*' 2>/dev/null | head -n1 || true)"
    if [[ -n "${lu}" ]]; then
        log_success "${lu}"
    else
        log_warn "Luciole: NOT installed"
    fi

    log_info "Helium commands:"
    if rpm -q "${HELIUM_PKG}" &>/dev/null; then
        rpm -ql "${HELIUM_PKG}" | grep -E '/bin/' || log_warn "No /bin/ entries found for ${HELIUM_PKG}."
    fi

    log_info "Nerd Fonts:"
    if [[ -n "$(fc-list 2>/dev/null | grep -i 'JetBrainsMono Nerd Font' || true)" ]]; then
        log_success "JetBrainsMono Nerd Font found."
    else
        log_warn "JetBrainsMono Nerd Font NOT found (kitty will fall back)."
    fi
    if [[ -n "$(fc-list 2>/dev/null | grep -i 'Symbols Nerd Font' || true)" ]]; then
        log_success "Symbols Nerd Font found."
    else
        log_warn "Symbols Nerd Font NOT found."
    fi

    log_info "Dotfiles in place:"
    local f
    for f in \
        "${NIRI_CONFIG_FILE}" \
        "${TARGET_CONFIG}/kitty/kitty.conf" \
        "${TARGET_CONFIG}/mpd/mpd.conf" \
        "${TARGET_CONFIG}/cava/config" \
        "${TARGET_CONFIG}/noctalia/settings.toml" \
        "${TARGET_LOCAL}/state/noctalia/settings.toml"; do
        if [[ -e "${f}" ]]; then
            log_success "$(tilde_path "${f}")"
        else
            log_warn "Missing: $(tilde_path "${f}")"
        fi
    done

    check_config_programs

    log_info "NetworkManager status:"
    systemctl is-active NetworkManager || log_warn "NetworkManager is not running."

    log_info "Network devices:"
    nmcli device status || log_warn "nmcli failed."

    log_info "Wi-Fi radio:"
    nmcli radio wifi || log_warn "Could not read Wi-Fi radio state."

    log_info "Bluetooth service status:"
    systemctl is-active bluetooth || log_warn "bluetooth.service is not running."

    log_info "Bluetooth controller:"
    if command -v bluetoothctl &>/dev/null; then
        bluetoothctl list || log_warn "No Bluetooth controller found."
    fi

    log_info "rfkill (look for 'blocked: yes'):"
    rfkill list || true

    log_info "Login manager:"
    local dm_unit=""
    if [[ -L /etc/systemd/system/display-manager.service ]]; then
        dm_unit="$(basename "$(readlink -f /etc/systemd/system/display-manager.service)")"
    fi
    if [[ -z "${dm_unit}" ]]; then
        log_warn "No display manager is enabled; you will boot to a text console."
    else
        log_success "Enabled display manager: ${dm_unit}"
    fi

    if [[ "${dm_unit}" == "greetd.service" ]]; then
        local gp
        for gp in greetd noctalia-greeter-git noctalia-greeter; do
            if rpm -q "${gp}" &>/dev/null; then
                log_success "${gp}: $(rpm -q "${gp}")"
            fi
        done
        if [[ -r "${GREETD_CONFIG}" ]]; then
            grep -E '^(command|user)' "${GREETD_CONFIG}" || log_warn "greetd config has no command/user lines."
        else
            log_warn "${GREETD_CONFIG} is missing."
        fi
        if [[ -d "${GREETER_STATE_DIR}" ]]; then
            log_success "Greeter state dir: $(stat -c '%U:%G %a' "${GREETER_STATE_DIR}")"
        else
            log_warn "${GREETER_STATE_DIR} is missing (the greeter may show a blank screen)."
        fi
        if command -v noctalia-greeter &>/dev/null; then
            log_info "Sessions the greeter detects:"
            noctalia-greeter sessions || log_warn "Could not list sessions."
        fi
    fi

    systemctl get-default || true
    systemctl status "${dm_unit:-display-manager.service}" --no-pager || true
}

# ------------------------------------------------------------------------------
# CLI arguments
# ------------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

  (no options)                    Full install, in the 9-step order
  --noctalia-copr OWNER/PROJECT   COPR providing Noctalia (default: ${NOCTALIA_COPR})
  --noctalia-pkg NAME             Noctalia package name   (default: ${NOCTALIA_PKG})
  --greeter-only                  Existing install: switch to the Noctalia greeter + add Luciole
  --gdm                           Full install, but use GDM instead of the Noctalia greeter
  --dotfiles-only                 (Re)deploy dotfiles, wallpapers, runtime dirs, Niri check
  --verify                        Run verification checks only
  -h, --help                      Show this help
EOF
}

MODE="full"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --verify)         MODE="verify"; shift ;;
        --dotfiles-only)  MODE="dotfiles"; shift ;;
        --greeter-only)   MODE="greeter"; shift ;;
        --gdm)            LOGIN_MANAGER="gdm"; shift ;;
        --noctalia-copr|--copr)
            if [[ -z "${2:-}" ]]; then
                log_error "$1 needs a value like OWNER/PROJECT"
                exit 1
            fi
            NOCTALIA_COPR="$2"; shift 2 ;;
        --noctalia-copr=*|--copr=*)
            NOCTALIA_COPR="${1#*=}"; shift ;;
        --noctalia-pkg)
            if [[ -z "${2:-}" ]]; then
                log_error "--noctalia-pkg needs a package name"
                exit 1
            fi
            NOCTALIA_PKG="$2"; shift 2 ;;
        --noctalia-pkg=*)
            NOCTALIA_PKG="${1#*=}"; shift ;;
        -h|--help)        usage; exit 0 ;;
        *)
            log_error "Unknown option: $1 (use --help for usage)"
            exit 1 ;;
    esac
done

# ------------------------------------------------------------------------------
# Pre-flight checks
# ------------------------------------------------------------------------------
if [[ "${EUID}" -eq 0 ]]; then
    log_error "Please run this script as your normal user (without sudo)."
    log_error "The script will ask for sudo only when installing packages or configuring services."
    exit 1
fi

if [[ "${MODE}" == "verify" ]]; then
    run_verification
    exit 0
fi

if [[ "${MODE}" == "dotfiles" ]]; then
    deploy_dotfiles
    setup_runtime_dirs
    configure_niri
    check_config_programs
    log_success "Dotfiles sync completed."
    exit 0
fi

# ---- Full install only below this line ----

if [[ -r /etc/os-release ]] && ! grep -qiE '^ID=fedora' /etc/os-release; then
    log_error "This installer is built for Fedora Linux only."
    exit 1
fi

DNF_CMD="$(detect_dnf)"
if [[ -z "${DNF_CMD}" ]]; then
    log_error "dnf/dnf5 not found. This full installer is built for Fedora Linux."
    exit 1
fi

if [[ "${DNF_CMD}" == "dnf5" ]]; then
    COPR_PLUGIN_PKG="dnf5-plugins"
else
    COPR_PLUGIN_PKG="dnf-plugins-core"
fi

if ! check_internet; then
    log_error "No internet connection detected."
    echo "       Connect first, then re-run this script. For Wi-Fi:"
    echo '         nmcli device wifi list'
    echo '         nmcli device wifi connect "SSID" password "PASSWORD"'
    echo "       Or use the text UI:  nmtui"
    exit 1
fi

printf "\n${BOLD}${CYAN}======================================================================${NC}\n"
printf "${BOLD}${CYAN}         Fedora + Niri + Noctalia + Dotfiles Full Installer           ${NC}\n"
printf "${BOLD}${CYAN}======================================================================${NC}\n"
log_info "Detected package manager: ${DNF_CMD}"
log_info "Noctalia: ${NOCTALIA_PKG} from COPR ${NOCTALIA_COPR}"
log_info "Helium:   ${HELIUM_PKG} from COPR ${HELIUM_COPR}"

log_info "Requesting sudo privileges..."
sudo -v
( while true; do sudo -n true; sleep 50; done ) 2>/dev/null &
SUDO_KEEPALIVE_PID=$!

# ------------------------------------------------------------------------------
# --greeter-only: switch an existing install from GDM to the Noctalia greeter
# ------------------------------------------------------------------------------
if [[ "${MODE}" == "greeter" ]]; then
    log_header "Switching the login screen to the Noctalia greeter"
    LOGIN_MANAGER="greeter"
    if [[ "${DNF_CMD}" == "dnf5" ]]; then
        pkg_install dnf5-plugins
    else
        pkg_install dnf-plugins-core
    fi
    log_info "Making sure the Noctalia COPR is enabled: ${NOCTALIA_COPR}"
    sudo "${DNF_CMD}" copr enable -y "${NOCTALIA_COPR}"
    if ! resolve_greeter_package; then
        log_error "Could not find a Noctalia greeter package (COPR or Terra). No changes were made."
        exit 1
    fi
    install_greeter_packages
    install_luciole
    setup_login_manager
    print_login_notes
    prompt_reboot
    exit 0
fi

# ------------------------------------------------------------------------------
# Step 1: System upgrade + prerequisites
# ------------------------------------------------------------------------------
log_header "Step 1: System Upgrade & Prerequisites"
sudo "${DNF_CMD}" upgrade --refresh -y

pkg_install git curl tar xz fontconfig "${COPR_PLUGIN_PKG}"
log_success "System upgraded; git, curl and the COPR plugin are ready."

# ------------------------------------------------------------------------------
# Step 2: Wi-Fi and Bluetooth
# ------------------------------------------------------------------------------
log_header "Step 2: Wi-Fi & Bluetooth"
pkg_install \
    NetworkManager \
    NetworkManager-wifi \
    NetworkManager-tui \
    wpa_supplicant \
    linux-firmware \
    bluez \
    rfkill

# NetworkManager now, so Wi-Fi keeps working; Bluetooth is enabled in Step 7
sudo systemctl enable --now NetworkManager
sudo rfkill unblock all || true
log_success "Wi-Fi and Bluetooth packages installed; NetworkManager running."

# ------------------------------------------------------------------------------
# Step 3: Repositories (RPM Fusion Free, Noctalia COPR, Helium COPR)
# ------------------------------------------------------------------------------
log_header "Step 3: Enabling Repositories"

if ! rpm -q rpmfusion-free-release &>/dev/null; then
    log_info "Enabling RPM Fusion Free (needed for vlc)..."
    pkg_install \
        "https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-$(rpm -E %fedora).noarch.rpm"
    log_success "RPM Fusion Free enabled."
else
    log_success "RPM Fusion Free already enabled."
fi

log_info "Enabling Noctalia COPR: ${NOCTALIA_COPR}"
sudo "${DNF_CMD}" copr enable -y "${NOCTALIA_COPR}"
log_success "COPR enabled: ${NOCTALIA_COPR}"

log_info "Enabling Helium COPR: ${HELIUM_COPR}"
if sudo "${DNF_CMD}" copr enable -y "${HELIUM_COPR}"; then
    log_success "COPR enabled: ${HELIUM_COPR}"
else
    log_warn "Could not enable ${HELIUM_COPR}; Helium will be skipped."
fi

# Fail fast: confirm the key packages resolve BEFORE the long installs start
log_info "Checking that key packages are available..."
for pkg in niri "${NOCTALIA_PKG}" vlc mpd; do
    if pkg_available "${pkg}"; then
        log_success "Available: ${pkg}"
    else
        log_error "Package '${pkg}' was not found in any enabled repository."
        if [[ "${pkg}" == "${NOCTALIA_PKG}" ]]; then
            echo "       Check the COPR / package name:  ./install.sh --noctalia-copr OWNER/PROJECT --noctalia-pkg NAME"
        fi
        exit 1
    fi
done
if pkg_available "${HELIUM_PKG}"; then
    HELIUM_OK=true
    log_success "Available: ${HELIUM_PKG}"
else
    log_warn "Package '${HELIUM_PKG}' not found; Helium will be skipped."
fi

if [[ "${LOGIN_MANAGER}" == "greeter" ]]; then
    if ! resolve_greeter_package; then
        log_warn "Noctalia greeter package not found anywhere; falling back to GDM."
        LOGIN_MANAGER="gdm"
    fi
fi

# ------------------------------------------------------------------------------
# Step 4: Graphical session dependencies
# ------------------------------------------------------------------------------
log_header "Step 4: Graphical Session Dependencies"
pkg_install \
    pipewire \
    pipewire-pulseaudio \
    pipewire-alsa \
    wireplumber \
    alsa-utils \
    xdg-desktop-portal \
    xdg-desktop-portal-gtk \
    xdg-desktop-portal-gnome \
    polkit \
    mate-polkit \
    gnome-keyring \
    xwayland-satellite \
    qt6-qtwayland
# Speakers/mic on many modern Intel laptops; skipped if unavailable
pkg_install_optional alsa-sof-firmware

# Login manager packages (GDM is NOT installed when the Noctalia greeter is used)
if [[ "${LOGIN_MANAGER}" == "greeter" ]]; then
    install_greeter_packages
else
    pkg_install gdm
fi
log_success "Graphical session dependencies installed."

# ------------------------------------------------------------------------------
# Step 5: Essential applications, media tools & fonts
# ------------------------------------------------------------------------------
log_header "Step 5: Essential Applications, Media Tools & Fonts"
pkg_install \
    kitty \
    nautilus \
    gvfs \
    gvfs-mtp \
    gvfs-smb \
    pavucontrol \
    blueman \
    brightnessctl \
    playerctl \
    wl-clipboard \
    grim \
    slurp \
    unzip \
    fastfetch \
    cava \
    vlc \
    mpd

if [[ "${HELIUM_OK}" == true ]]; then
    pkg_install_optional "${HELIUM_PKG}"
fi

pkg_install_optional \
    google-noto-sans-fonts \
    google-noto-emoji-fonts \
    google-noto-sans-cjk-fonts \
    fontawesome-fonts-all \
    jetbrains-mono-fonts
install_nerd_fonts
install_luciole
log_success "Applications, media tools and fonts installed."

# ------------------------------------------------------------------------------
# Step 6: Niri and Noctalia
# ------------------------------------------------------------------------------
log_header "Step 6: Niri & Noctalia"
pkg_install niri "${NOCTALIA_PKG}"
log_success "Niri and Noctalia installed."

# ------------------------------------------------------------------------------
# Step 7: Services & graphical boot
# ------------------------------------------------------------------------------
log_header "Step 7: Services & Graphical Boot"
sudo systemctl enable --now bluetooth
log_success "Bluetooth enabled."

# Noctalia greeter (greetd) or GDM, with automatic fallback to GDM if the greeter fails
setup_login_manager

# ------------------------------------------------------------------------------
# Step 8: Dotfiles (+ wallpapers, runtime dirs, Niri config)
# ------------------------------------------------------------------------------
deploy_dotfiles
setup_runtime_dirs
configure_niri

# ------------------------------------------------------------------------------
# Step 9: Verification
# ------------------------------------------------------------------------------
run_verification
log_info "The login manager becomes 'active (running)' after reboot. Run './install.sh --verify' after logging in."

# ------------------------------------------------------------------------------
# Completion summary & reboot prompt
# ------------------------------------------------------------------------------
printf "\n${BOLD}${GREEN}======================================================================${NC}\n"
printf "${BOLD}${GREEN}                     Installation Completed!                          ${NC}\n"
printf "${BOLD}${GREEN}======================================================================${NC}\n"

if [[ "${BACKUP_CREATED}" = true ]]; then
    printf "${YELLOW}Notice:${NC} Previous configs were backed up to: ${BOLD}%s${NC}\n" "${BACKUP_DIR}"
fi

print_login_notes

cat <<'EOF'

Wi-Fi after login:  nmtui   (or: nmcli device wifi connect "SSID" password "PASS")
Bluetooth:          blueman-manager  (or: bluetoothctl)

Check the [WARN] lines above for anything that still needs a manual fix
(for example Mod+B still launching brave-browser).
EOF

prompt_reboot