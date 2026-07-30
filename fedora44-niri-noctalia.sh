#!/usr/bin/env bash
#
# Fedora 44 Everything (Minimal Install) -> Niri + Noctalia v5
#
# Validated against Fedora 44's official packages and upstream documentation
# on 2026-07-26. This script intentionally:
#   - uses the repositories already enabled on the host;
#   - does not enable or modify COPRs, RPM Fusion, or other repositories;
#   - does not install proprietary GPU drivers;
#   - does not enable autologin;
#   - does not remove GNOME or other desktop packages;
#   - uses Fedora's greetd + tuigreet packages instead of building the
#     currently-unpackaged Noctalia Greeter from source.
#
# Usage:
#   bash fedora44-niri-noctalia.sh --check
#   bash fedora44-niri-noctalia.sh --install
#   bash fedora44-niri-noctalia.sh --verify
#

set -Eeuo pipefail
IFS=$'\n\t'

readonly PROGRAM_NAME="fedora44-niri-noctalia"
readonly VALIDATED_FEDORA_VERSION="44"
readonly MANAGED_NIRI_INCLUDE='include "fedora-noctalia.kdl"'

MODE=""
ASSUME_YES=0
BACKUP_DIR=""

readonly -a PACKAGES=(
  NetworkManager
  NetworkManager-wifi
  adwaita-icon-theme
  adw-gtk3-theme
  bluez
  ddcutil
  firefox
  gnome-keyring
  google-noto-color-emoji-fonts
  google-noto-sans-fonts
  greetd
  greetd-selinux
  gvfs
  gvfs-mtp
  jetbrains-mono-fonts
  kitty
  mesa-dri-drivers
  mesa-vulkan-drivers
  nautilus
  niri
  noctalia
  pipewire
  pipewire-alsa
  pipewire-pulseaudio
  papirus-icon-theme
  polkit
  power-profiles-daemon
  qt6ct
  tuigreet
  upower
  wireplumber
  wl-clipboard
  xdg-desktop-portal
  xdg-desktop-portal-gnome
  xdg-desktop-portal-gtk
  xdg-user-dirs
  xwayland-satellite
)

info() {
  printf '\033[1;34m==>\033[0m %s\n' "$*"
}

warn() {
  printf '\033[1;33mWARNING:\033[0m %s\n' "$*" >&2
}

die() {
  printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Fedora 44 Everything -> Niri + Noctalia v5

Usage:
  fedora44-niri-noctalia.sh --check
      Confirm the OS, repositories, packages, GPU, and display-manager state.
      This refreshes DNF metadata but does not install packages or edit configs.

  fedora44-niri-noctalia.sh --install [--yes]
      Update Fedora, install the session, create backed-up configuration, and
      enable greetd for the next boot.

  fedora44-niri-noctalia.sh --verify
      Validate installed packages, Niri/Noctalia configuration, greetd, and
      the graphical boot target.

  --yes
      Skip the final confirmation. Intended for an already-reviewed invocation.

  -h, --help
      Show this help.
EOF
}

on_error() {
  local exit_code=$?
  local line_number=${1:-unknown}
  printf '\n\033[1;31mInstallation stopped at line %s (exit %s).\033[0m\n' \
    "$line_number" "$exit_code" >&2
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    printf 'Backups made during this run are in: %s\n' "$BACKUP_DIR" >&2
  fi
  exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

parse_args() {
  while (($#)); do
    case "$1" in
      --check|--install|--verify)
        [[ -z "$MODE" ]] || die "Choose only one mode."
        MODE=$1
        ;;
      --yes)
        ASSUME_YES=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        usage >&2
        die "Unknown argument: $1"
        ;;
    esac
    shift
  done

  [[ -n "$MODE" ]] || {
    usage >&2
    exit 2
  }
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

check_host() {
  ((EUID != 0)) || die "Run this script as your regular admin user, not as root."
  [[ -r /etc/os-release ]] || die "Cannot read /etc/os-release."

  # shellcheck disable=SC1091
  source /etc/os-release
  [[ ${ID:-} == "fedora" ]] || die "This script supports Fedora only; detected ${ID:-unknown}."
  [[ ${VERSION_ID:-} == "$VALIDATED_FEDORA_VERSION" ]] ||
    die "This script is pinned to Fedora 44; detected Fedora ${VERSION_ID:-unknown}."

  require_command dnf
  require_command grep
  require_command rpm
  require_command sudo
  require_command systemctl

  local uid
  uid=$(id -u)
  ((uid >= 1000)) || warn "The current account has UID $uid; a normal desktop user usually has UID 1000 or higher."
}

display_manager_target() {
  local link="/etc/systemd/system/display-manager.service"
  if [[ -L "$link" ]]; then
    readlink -f "$link"
  fi
}

check_display_manager() {
  local target
  target=$(display_manager_target || true)
  if [[ -n "$target" && ${target##*/} != "greetd.service" ]]; then
    die "Another display manager is enabled (${target##*/}). Disable it deliberately before using this script; the script will not replace it automatically."
  fi
}

show_gpu() {
  info "Detected graphics hardware"
  if command -v lspci >/dev/null 2>&1; then
    local gpu_lines
    gpu_lines=$(lspci | grep -Ei 'VGA compatible controller|3D controller|Display controller' || true)
    if [[ -n "$gpu_lines" ]]; then
      printf '%s\n' "$gpu_lines"
    else
      printf 'No PCI graphics controller was reported.\n'
    fi

    if grep -qi nvidia <<<"$gpu_lines"; then
      warn "NVIDIA detected. This script leaves the existing driver unchanged. Niri may need a separate, hardware-specific proprietary-driver setup if Nouveau is not suitable."
    fi
  else
    printf 'lspci is not installed; GPU detection skipped.\n'
  fi
}

refresh_and_check_packages() {
  info "Refreshing Fedora repository metadata"
  sudo dnf --refresh -q makecache

  info "Confirming every requested package exists in the enabled Fedora repositories"
  local package
  local -a missing=()
  for package in "${PACKAGES[@]}"; do
    if ! dnf -q repoquery --available --qf '%{name}' "$package" 2>/dev/null |
      grep -Fxq "$package"; then
      missing+=("$package")
    fi
  done

  if ((${#missing[@]})); then
    printf 'Missing packages:\n' >&2
    printf '  - %s\n' "${missing[@]}" >&2
    die "Package validation failed. No installation was attempted."
  fi
}

print_plan() {
  cat <<'EOF'

Planned changes:
  - Upgrade installed Fedora 44 packages.
  - Install Niri, Noctalia v5, portals, Xwayland compatibility, PipeWire,
    NetworkManager Wi-Fi support, a terminal, file manager, browser, and fonts.
  - Install greetd + tuigreet as the password-based login screen.
  - Add a small Niri include that starts Noctalia and supplies upstream
    Noctalia keybindings.
  - Enable Noctalia's notification and polkit agents.
  - Disable Noctalia telemetry in the declarative user configuration.
  - Enable graphical boot and greetd on the next boot.

Not changed:
  - SELinux, Secure Boot, kernel parameters, firmware, and GPU drivers.
  - Existing repository configuration, codecs, and Flatpak.
  - Existing desktop packages.
  - Password requirements or autologin.
EOF
}

confirm_install() {
  ((ASSUME_YES == 1)) && return
  printf '\nType INSTALL to continue: '
  local answer
  read -r answer
  [[ "$answer" == "INSTALL" ]] || die "Cancelled; no packages or configurations were changed."
}

make_backup_dir() {
  local timestamp
  timestamp=$(date +'%Y%m%d-%H%M%S')
  BACKUP_DIR="$HOME/.local/state/$PROGRAM_NAME/backups/$timestamp"
  mkdir -p "$BACKUP_DIR"
}

backup_user_file() {
  local source_path=$1
  local backup_name=$2
  if [[ -e "$source_path" || -L "$source_path" ]]; then
    cp -a -- "$source_path" "$BACKUP_DIR/$backup_name"
  fi
}

backup_system_file() {
  local source_path=$1
  local backup_name=$2
  if sudo test -e "$source_path"; then
    sudo cp -a -- "$source_path" "$BACKUP_DIR/$backup_name"
    sudo chown "$(id -u):$(id -g)" "$BACKUP_DIR/$backup_name"
  fi
}

write_user_file() {
  local target=$1
  local mode=${2:-0644}
  local temporary
  temporary=$(mktemp)
  tee "$temporary" >/dev/null
  install -m "$mode" "$temporary" "$target"
  rm -f -- "$temporary"
}

write_system_file() {
  local target=$1
  local mode=${2:-0644}
  local temporary
  temporary=$(mktemp)
  tee "$temporary" >/dev/null
  sudo install -m "$mode" "$temporary" "$target"
  rm -f -- "$temporary"
}

install_packages() {
  info "Upgrading Fedora 44"
  sudo dnf --refresh upgrade -y

  info "Installing the validated package set"
  sudo dnf install -y --exclude=fuzzel --exclude=swaylock --exclude=waybar "${PACKAGES[@]}"
}

configure_niri() {
  local niri_dir="$HOME/.config/niri"
  local main_config="$niri_dir/config.kdl"
  local managed_config="$niri_dir/fedora-noctalia.kdl"
  local packaged_default="/usr/share/doc/niri/default-config.kdl"

  [[ -r "$packaged_default" ]] ||
    die "The Fedora Niri package did not install $packaged_default."

  mkdir -p "$niri_dir"
  backup_user_file "$main_config" "niri-config.kdl"
  backup_user_file "$managed_config" "fedora-noctalia.kdl"

  if [[ ! -e "$main_config" ]]; then
    install -m 0644 "$packaged_default" "$main_config"
    sed -i \
      -e '/spawn "alacritty"/d' \
      -e '/spawn "fuzzel"/d' \
      -e '/spawn "swaylock"/d' \
      -e '/wpctl set-volume/d' \
       -e '/wpctl set-mute/d' \
       -e '/playerctl /d' \
       -e '/spawn "brightnessctl"/d' \
       -e '/Mod+Comma  { consume-window-into-column; }/d' \
       -e '/^    mouse {/,/^    }/ s@^        // accel-profile "flat"@        accel-profile "flat"@' \
       "$main_config"
    sed -i '/Mod+Shift+Slash { show-hotkey-overlay; }/a\    Mod+T hotkey-overlay-title="Open a Terminal: kitty" { spawn "kitty"; }' "$main_config"
  fi

  if ! grep -Fqx "$MANAGED_NIRI_INCLUDE" "$main_config"; then
    printf '\n// Added by fedora44-niri-noctalia.sh.\n%s\n' \
      "$MANAGED_NIRI_INCLUDE" >>"$main_config"
  fi

  write_user_file "$managed_config" <<'EOF'
// Managed Noctalia v5 integration.
// Source: https://docs.noctalia.dev/v5/compositor-settings/niri/

spawn-at-startup "noctalia"

window-rule {
    match app-id="dev.noctalia.Noctalia"
    open-floating true
    default-column-width { fixed 1080; }
    default-window-height { fixed 920; }
}

debug {
    // Allows notification actions and app activation from Noctalia.
    honor-xdg-activation-with-invalid-serial
}

binds {
    Mod+Space hotkey-overlay-title="Noctalia Launcher" {
        spawn "noctalia" "msg" "panel-toggle" "launcher"
    }
    Mod+S hotkey-overlay-title="Noctalia Control Center" {
        spawn "noctalia" "msg" "panel-toggle" "control-center"
    }
    Mod+Shift+Comma hotkey-overlay-title="Noctalia Settings" {
        spawn "noctalia" "msg" "settings-toggle"
    }
    Super+Alt+L hotkey-overlay-title="Noctalia Lock Screen" {
        spawn "noctalia" "msg" "session" "lock"
    }
    Alt+Tab hotkey-overlay-title="Noctalia Window Switcher" {
        spawn "noctalia" "msg" "window-switcher"
    }
    Ctrl+Shift+Y hotkey-overlay-title="Noctalia Clipboard" {
        spawn "noctalia" "msg" "panel-toggle" "clipboard"
    }
    Mod+Ctrl+Space hotkey-overlay-title="Noctalia Wallpaper" {
        spawn "noctalia" "msg" "panel-toggle" "wallpaper"
    }
    Mod+Shift+N hotkey-overlay-title="Noctalia Region Screenshot" {
        spawn "noctalia" "msg" "screenshot-region"
    }
    Mod+N hotkey-overlay-title="Noctalia Notifications" {
        spawn "noctalia" "msg" "panel-toggle" "control-center" "notifications"
    }

    XF86AudioRaiseVolume {
        spawn "noctalia" "msg" "volume-up"
    }
    XF86AudioLowerVolume {
        spawn "noctalia" "msg" "volume-down"
    }
    XF86AudioMute {
        spawn "noctalia" "msg" "volume-mute"
    }
    XF86AudioMicMute {
        spawn "noctalia" "msg" "mic-mute"
    }
    XF86AudioPlay {
        spawn "noctalia" "msg" "media" "toggle"
    }
    XF86AudioStop {
        spawn "noctalia" "msg" "media" "stop"
    }
    XF86AudioPrev {
        spawn "noctalia" "msg" "media" "previous"
    }
    XF86AudioNext {
        spawn "noctalia" "msg" "media" "next"
    }
    XF86MonBrightnessUp {
        spawn "noctalia" "msg" "brightness-up"
    }
    XF86MonBrightnessDown {
        spawn "noctalia" "msg" "brightness-down"
    }
}
EOF

  info "Validating Niri configuration"
  niri validate
}

configure_noctalia() {
  local noctalia_dir="$HOME/.config/noctalia"
  local managed_config="$noctalia_dir/10-fedora-session.toml"

  mkdir -p "$noctalia_dir"
  backup_user_file "$managed_config" "noctalia-10-fedora-session.toml"

  write_user_file "$managed_config" <<'EOF'
# Managed Fedora session integration.
# GUI settings may override these values later through
# ~/.local/state/noctalia/settings.toml.

[shell]
polkit_agent = true
telemetry_enabled = false

[notification]
enable_daemon = true

[brightness]
enable_ddcutil = true
EOF

  info "Validating Noctalia configuration"
  noctalia config validate "$managed_config"
}

configure_greetd() {
  local config="/etc/greetd/config.toml"
  backup_system_file "$config" "greetd-config.toml"

  write_system_file "$config" <<'EOF'
# Managed by fedora44-niri-noctalia.sh.
# Password authentication is required; this is not an autologin configuration.

[terminal]
vt = 1

[default_session]
command = "/usr/bin/tuigreet --time --remember --remember-session --asterisks --user-menu --sessions /usr/share/wayland-sessions --cmd niri-session"
user = "greetd"
EOF

  getent passwd greetd >/dev/null ||
    die "The Fedora greetd package did not create its greetd account."
}

enable_services() {
  info "Enabling NetworkManager, Bluetooth, greetd, and graphical boot"
  sudo systemctl enable NetworkManager.service
  sudo systemctl enable bluetooth.service
  sudo systemctl enable greetd.service
  sudo systemctl set-default graphical.target
}

initialize_user_dirs() {
  xdg-user-dirs-update
}

verify_installation() {
  local failed=0
  local item

  info "Installed package versions"
  rpm -q niri noctalia greetd tuigreet xwayland-satellite ddcutil qt6ct ||
    failed=1

  info "Required commands"
  for item in niri niri-session noctalia tuigreet xwayland-satellite ddcutil qt6ct; do
    if command -v "$item" >/dev/null 2>&1; then
      printf '  OK  %s -> %s\n' "$item" "$(command -v "$item")"
    else
      printf '  MISSING  %s\n' "$item" >&2
      failed=1
    fi
  done

  if [[ -f /usr/share/wayland-sessions/niri.desktop ]]; then
    printf '  OK  Niri Wayland session entry\n'
  else
    printf '  MISSING  /usr/share/wayland-sessions/niri.desktop\n' >&2
    failed=1
  fi

  info "Configuration validation"
  if niri validate; then
    printf '  OK  Niri configuration\n'
  else
    failed=1
  fi
  if noctalia config validate; then
    printf '  OK  Noctalia merged configuration\n'
  else
    failed=1
  fi

  info "Boot configuration"
  if systemctl is-enabled --quiet greetd.service; then
    printf '  OK  greetd is enabled\n'
  else
    printf '  NOT ENABLED  greetd.service\n' >&2
    failed=1
  fi

  if [[ $(systemctl get-default) == "graphical.target" ]]; then
    printf '  OK  default target is graphical.target\n'
  else
    printf '  WRONG TARGET  %s\n' "$(systemctl get-default)" >&2
    failed=1
  fi

  if ((failed)); then
    die "One or more verification checks failed. Do not reboot until they are resolved."
  fi

  info "All static and installed-system checks passed"
}

run_check() {
  check_host
  sudo -v
  check_display_manager
  show_gpu
  refresh_and_check_packages
  print_plan
  info "Pre-installation checks passed; no packages or configurations were changed."
}

run_install() {
  check_host
  sudo -v
  check_display_manager
  show_gpu
  refresh_and_check_packages
  print_plan
  confirm_install

  make_backup_dir
  install_packages
  configure_niri
  configure_noctalia
  configure_greetd
  enable_services
  initialize_user_dirs
  verify_installation

  cat <<EOF

Installation completed successfully.

Backups:
  $BACKUP_DIR

Next:
  1. Reboot: sudo systemctl reboot
  2. At tuigreet, leave/select the Niri session and sign in with your password.
  3. Complete Noctalia's first-run setup.

Useful keys:
  Super+T       terminal
  Super+Space   Noctalia launcher
  Super+S       Noctalia control center
  Super+Shift+, Noctalia settings
  Super+N       Noctalia notifications
  Super+Shift+N region screenshot
  Super+Shift+E exit Niri
EOF
}

run_verify() {
  check_host
  verify_installation
}

main() {
  parse_args "$@"
  case "$MODE" in
    --check) run_check ;;
    --install) run_install ;;
    --verify) run_verify ;;
  esac
}

main "$@"
