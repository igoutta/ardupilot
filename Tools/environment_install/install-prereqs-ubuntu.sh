#!/usr/bin/env bash
set -euo pipefail

# Ubuntu / Debian twin of install-prereqs-arch.sh: same options, same layout,
# same promises. The system part uses apt; everything else is identical.
#
# IMPORTANT, for whoever extends this: upstream's install-prereqs-ubuntu.sh
# does more than these twins, and each item was left out for a reason that
# was checked against the code, not assumed (sim project, 2026-09-29):
#   - SFML/CSFML: only used when SITL is configured with --enable-sfml
#     (OSD window, SFML joystick/audio); `sim compile` never passes it.
#   - g++-arm-linux-gnueabihf + pkg-config-arm-linux-gnueabihf: firmware for
#     Linux boards (Navio2, BBBmini...); ours are STM32/ChibiOS boards.
#   - lcov, gcovr: C++ coverage in CI (Tools/scripts/run_coverage.py).
#   - flake8, wsproto, tabulate: CI-only; nothing in Tools imports wsproto,
#     tabulate only feeds the firmware size comparison scripts.
#   - junitparser: only Tools/autotest/vehicle_test_suite.py. Add it the day
#     the autotest framework is used (e.g. a `sim scenario` built on it).
#   - valgrind, screen, astyle: debugging/formatting the firmware C++.
#   - python-is-python3, libpython3-stdlib: no script in Tools has a plain
#     `python` shebang any more; argparse is stdlib.
#   - ppp: autotest's PPP network tests.
#   - Bash/zsh completion (Tools/completion): cosmetic; add as a prompted
#     config entry if wanted.
#   - The Docker environment file and the SKIP_AP_*/DO_AP_* env toggles.
#   - Reinstalling Pillow on plucky/questing: upstream's commit a6420430f0
#     only says "somehow"; here Pillow is checked after pip and reinstalled
#     only if `import PIL.Image` really fails.
# Kept because the code needs it: psutil (sim_vehicle.py; optional, it falls
# back to pkill), pygame-ce + pyyaml (MAVProxy's joystick module; pygame-ce
# has wheels up to Python 3.15, pygame stops at 3.13), intelhex (waf checks
# it in configure and needs it for the .hex with bootloader), ccache first in
# PATH (waf only wires ccache by itself for QURT boards, boards.py:1527; for
# STM32 and SITL it finds the compilers through PATH).

# Configuration flags
ASSUME_YES=false
QUIET=false
SKIP_SYSTEM=false
TARGET_DIR=""

# Parse command-line options
#   -d DIR  set up another ArduPilot checkout (its .venv and submodules)
#           instead of the one this script lives in
#   -s      skip the system part (groups, apt, ccache, ARM toolchain,
#           shell config): only the checkout's .venv and submodules
OPTIND=1
while getopts "yqsd:" opt; do
    case "$opt" in
        y)  ASSUME_YES=true ;;
        q)  QUIET=true ;;
        s)  SKIP_SYSTEM=true ;;
        d)  TARGET_DIR="$OPTARG" ;;
        *)  exit 1 ;;
    esac
done

# Get configuration file with shell detection.
# An empty CONFIG_FILE means "unsupported shell": print the lines for the user
# instead of appending them somewhere they will never be read.
case "$(basename "${SHELL:-}")" in
    bash) CONFIG_FILE="$HOME/.bashrc" ;;
    zsh)  CONFIG_FILE="$HOME/.zshrc"  ;;
    *)    CONFIG_FILE=""              ;;
esac

# Development Packages.
# python3-* from apt are the system copies every .venv sees through
# --system-site-packages (wxPython above all: pip would build it for ~30 min).
BASE_PKGS=(build-essential ccache g++ gawk git make wget zip)
SITL_PKGS=(python3-dev python3-venv python3-pip python3-setuptools python3-wheel python3-numpy python3-scipy python3-opencv python3-wxgtk4.0 python3-tk libtool libtool-bin libxml2-dev libxslt1-dev xterm xfonts-base)
PX4_PKGS=(zlib1g-dev libncurses-dev)
# psutil: sim_vehicle.py uses it to kill its children (optional: it falls back to
# pkill). pygame-ce + pyyaml: MAVProxy's joystick module (pygame-ce, not pygame:
# it ships wheels up to Python 3.15, pygame stops at 3.13). intelhex: waf checks
# it in configure and needs it for the .hex with bootloader of board builds.
PYTHON_PKGS=(lxml pymavlink MAVProxy opencv-python pexpect argparse "matplotlib<3.11" pyparsing geocoder pyserial "empy==3.3.4" dronecan packaging setuptools wheel psutil pygame-ce pyyaml intelhex)

# Releases whose package names above are known to be right. Derivatives that
# set UBUNTU_CODENAME (Mint, Pop!_OS, elementary) are mapped through it.
SUPPORTED_CODENAMES=(jammy noble plucky questing resolute bookworm trixie forky)

# GNU Toolchain for ARM Embedded Processors (see https://launchpad.net/gcc-arm-embedded/).
# ArduPilot ships it for x86_64 and aarch64 (Raspberry Pi, WSL on ARM).
ARM_ROOT="gcc-arm-none-eabi-10-2020-q4-major"
case "$(uname -m)" in
    x86_64)
        ARM_TARBALL="$ARM_ROOT-x86_64-linux.tar.bz2"
        ARM_TARBALL_CHECKSUM="21134caa478bbf5352e239fbc6e2da3038f8d2207e089efc96c3b55f1edcd618"
        ;;
    aarch64)
        ARM_TARBALL="$ARM_ROOT-aarch64-linux.tar.bz2"
        ARM_TARBALL_CHECKSUM="343d8c812934fe5a904c73583a91edd812b1ac20636eb52de04135bb0f5cf36a"
        ;;
    *)
        ARM_TARBALL=""
        ARM_TARBALL_CHECKSUM=""
        ;;
esac
ARM_TARBALL_URL="https://firmware.ardupilot.org/Tools/STM32-tools/$ARM_TARBALL"

# Main directories
SCRIPT_DIR=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
if [[ -n "$TARGET_DIR" ]]; then
    ARDUPILOT_ROOT=$(realpath "$TARGET_DIR")
    if [[ ! -f "$ARDUPILOT_ROOT/Tools/autotest/sim_vehicle.py" ]]; then
        echo "FATAL: $ARDUPILOT_ROOT is not an ArduPilot checkout" >&2
        exit 1
    fi
else
    ARDUPILOT_ROOT="${SCRIPT_DIR%/Tools/environment_install}"
fi
ARDUPILOT_TOOLS_DIR="$ARDUPILOT_ROOT/Tools/autotest"
VENV_DIR="$ARDUPILOT_ROOT/.venv"
# OPT_DIR and OS_RELEASE are overridable so the script can be exercised
# without root and on another distro (see the tests in the sim project).
OPT_DIR="${OPT_DIR:-/opt}"
OS_RELEASE="${OS_RELEASE:-/etc/os-release}"
ARM_TOOLCHAIN_DIR="$OPT_DIR/$ARM_ROOT"
ARM_TARBALL_PATH="$OPT_DIR/${ARM_TARBALL:-none}"
CCACHE_DIR="/usr/lib/ccache"

# Helper functions
function log() {
    $QUIET || echo "$@"
}

function maybe_prompt_user() {
    if $ASSUME_YES; then
        return 0
    fi
    local reply=""
    # `read` returns non-zero on EOF (piped stdin, CI). Treat that as "no"
    # rather than letting it bubble up as a failure.
    read -rp "$1" reply || true
    [[ $reply =~ ^[Yy]$ ]]
}

function add_config_entry() {
    local line="$1" prompt="$2"

    if [[ -z "$CONFIG_FILE" ]]; then
        echo "Unsupported shell. Please add this line to your shell config yourself:"
        echo "    $line"
        return 0
    fi

    if grep -Fxq "$line" "$CONFIG_FILE" 2>/dev/null; then
        log "Already configured: $prompt"
        return 0
    fi

    if maybe_prompt_user "$prompt [N/y]?"; then
        echo "$line" >> "$CONFIG_FILE"
        log "Added to $CONFIG_FILE: $prompt"
    else
        log "Skipped: $prompt"
    fi
}

# The Ubuntu codename this system is based on: UBUNTU_CODENAME on Ubuntu and
# its derivatives, VERSION_CODENAME on Debian. Empty when unknown.
function release_codename() {
    local UBUNTU_CODENAME="" VERSION_CODENAME=""
    if [[ -r "$OS_RELEASE" ]]; then
        # shellcheck source=/dev/null
        source "$OS_RELEASE"
    fi
    echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}"
}

# Privilege escalation.
# Nothing is hardcoded to `sudo`: run as root and no escalation is used at all,
# otherwise take whichever tool the system actually has.
if [[ $EUID -eq 0 && -n "${SUDO_USER:-}" ]]; then
    echo "FATAL: do not run this script with sudo." >&2
    echo "Run it as your normal user. It elevates only the steps that need root," >&2
    echo "so the venv, the git checkout and your shell config stay yours." >&2
    exit 1
fi

if $SKIP_SYSTEM; then
    SUDO=()
elif [[ $EUID -eq 0 ]]; then
    SUDO=()
elif command -v sudo >/dev/null 2>&1; then
    SUDO=(sudo)
elif command -v doas >/dev/null 2>&1; then
    SUDO=(doas)
elif command -v run0 >/dev/null 2>&1; then
    SUDO=(run0)
else
    echo "FATAL: root privileges are required, but no sudo, doas or run0 was found." >&2
    exit 1
fi

# Ask for the password once, up front, instead of at a random point mid-install.
if [[ "${SUDO[0]-}" == "sudo" ]]; then
    sudo -v
fi

# Main execution
log "=== ArduPilot Development Environment Setup ==="
log "Checkout: $ARDUPILOT_ROOT"

if ! $SKIP_SYSTEM; then
# Release check: only the package names depend on it.
CODENAME=$(release_codename)
if [[ " ${SUPPORTED_CODENAMES[*]} " != *" $CODENAME "* ]]; then
    echo "FATAL: release '${CODENAME:-unknown}' is not handled (end of life, or not Ubuntu/Debian)." >&2
    echo "Supported: ${SUPPORTED_CODENAMES[*]}. Install the packages by hand and rerun with -s." >&2
    exit 1
fi
log "Release: $CODENAME"

# User group setup.
# $USER is not exported in every context (cron, CI, `env -i`), which would be
# fatal under `set -u`. `id -nG` avoids a pipeline that `pipefail` can trip on.
CURRENT_USER="${USER:-$(id -un)}"
if [[ " $(id -nG "$CURRENT_USER") " != *" dialout "* ]]; then
    log "Adding user to dialout group..."
    "${SUDO[@]}" usermod -aG dialout "$CURRENT_USER"
fi

# System packages installation
log "Installing system packages..."
APT_OPTS=()
APT_ENV=()
# -y and -q both mean "do not stop to ask me anything".
if $ASSUME_YES || $QUIET; then
    APT_OPTS+=(--assume-yes)
    APT_ENV=(env DEBIAN_FRONTEND=noninteractive)
fi
if $QUIET; then
    APT_OPTS+=(-qq)
fi
"${SUDO[@]}" "${APT_ENV[@]}" apt-get update "${APT_OPTS[@]}"
"${SUDO[@]}" "${APT_ENV[@]}" apt-get install "${APT_OPTS[@]}" "${BASE_PKGS[@]}" "${SITL_PKGS[@]}" "${PX4_PKGS[@]}"
# xfonts-base needs the font cache rebuilt to be seen by xterm.
if command -v fc-cache >/dev/null 2>&1; then
    fc-cache >/dev/null 2>&1 || true
fi

# ModemManager and brltty probe every new serial device and can grab the flight
# controller's USB port in the middle of a firmware upload. Upstream removes them
# outright; here it asks (and -y means yes).
for pkg in modemmanager brltty; do
    if dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then
        if maybe_prompt_user "Remove $pkg (it can grab the flight controller's USB serial port) [N/y]?"; then
            "${SUDO[@]}" "${APT_ENV[@]}" apt-get remove "${APT_OPTS[@]}" "$pkg"
        fi
    fi
done
fi

# Python virtual environment setup
if [[ ! -d "$VENV_DIR" ]]; then
    log "Creating Python virtual environment..."
    if ! python3 -m venv --system-site-packages "$VENV_DIR"; then
        echo "FATAL: Failed to create virtual environment" >&2
        echo "On Debian/Ubuntu this needs python3-venv: run this script once without -s." >&2
        exit 1
    fi
fi

# Keep the venv out of `git status` without touching the tracked .gitignore.
if [[ -d "$ARDUPILOT_ROOT/.git" ]]; then
    GIT_EXCLUDE="$ARDUPILOT_ROOT/.git/info/exclude"
    mkdir -p "$(dirname "$GIT_EXCLUDE")"
    if ! grep -Fxq '.venv/' "$GIT_EXCLUDE" 2>/dev/null; then
        echo '.venv/' >> "$GIT_EXCLUDE"
    fi
fi

# Install Python packages within the virtual environment
log "Installing Python packages..."
PIP_OPTS=(-U --no-warn-script-location)
if $QUIET; then
    PIP_OPTS+=(-q)
fi
"$VENV_DIR"/bin/python3 -m pip install "${PIP_OPTS[@]}" --upgrade pip
"$VENV_DIR"/bin/python3 -m pip install "${PIP_OPTS[@]}" "${PYTHON_PKGS[@]}"

# Pillow sanity check. The distro's PIL and pip's can end up mixed through
# --system-site-packages ("_imaging" from one, the package from the other:
# "Core version ... Pillow version" mismatch). Reinstall only if it really fails.
if ! "$VENV_DIR"/bin/python3 -c "import PIL.Image" >/dev/null 2>&1; then
    log "Pillow does not import in the venv; reinstalling it..."
    "$VENV_DIR"/bin/python3 -m pip install "${PIP_OPTS[@]}" --force-reinstall pillow
    "$VENV_DIR"/bin/python3 -c "import PIL.Image"
fi

if ! $SKIP_SYSTEM; then
# CCache setup
log "Configuring ccache symlinks for build optimizations..."
for compiler in arm-none-eabi-g++ arm-none-eabi-gcc; do
    if [[ ! -e "$CCACHE_DIR/$compiler" ]]; then
        "${SUDO[@]}" ln -sf /usr/bin/ccache "$CCACHE_DIR/$compiler"
    fi
done

# ARM toolchain installation.
# The whole block is skipped when the toolchain is already in place, so a
# re-run does not re-download ~130-170 MB.
if [[ -z "$ARM_TARBALL" ]]; then
    log "ARM toolchain: no tarball for $(uname -m); skipping."
    log "See https://firmware.ardupilot.org/Tools/STM32-tools/ for what is available."
elif [[ ! -d "$ARM_TOOLCHAIN_DIR/bin" ]]; then
    log "Setting up ARM toolchain..."

    # Download with verification
    if [[ ! -f "$ARM_TARBALL_PATH" ]] || \
       [[ $(sha256sum "$ARM_TARBALL_PATH" | awk '{print $1}') != "$ARM_TARBALL_CHECKSUM" ]]; then
        log "Downloading ARM toolchain..."
        WGET_OPTS=(-O "$ARM_TARBALL_PATH")
        if $QUIET; then
            WGET_OPTS+=(--quiet)
        else
            WGET_OPTS+=(--progress=dot:giga)
        fi
        if ! "${SUDO[@]}" wget "${WGET_OPTS[@]}" "$ARM_TARBALL_URL"; then
            echo "FATAL: Unable to download the toolchain tarball!" >&2
            "${SUDO[@]}" rm -f "$ARM_TARBALL_PATH"
            exit 1
        fi
    fi

    # Post-download verification
    ACTUAL_CHECKSUM=$(sha256sum "$ARM_TARBALL_PATH" | awk '{print $1}')
    if [[ "$ACTUAL_CHECKSUM" != "$ARM_TARBALL_CHECKSUM" ]]; then
        echo "FATAL: Checksum mismatch after download!" >&2
        "${SUDO[@]}" rm -f "$ARM_TARBALL_PATH"
        exit 1
    fi

    # Extraction. --checkpoint counts 512-byte records, so 2048 is one dot
    # per MiB extracted.
    log "Extracting toolchain..."
    TAR_OPTS=(--extract --file="$ARM_TARBALL_PATH" --directory="$OPT_DIR")
    if ! $QUIET; then
        TAR_OPTS+=(--checkpoint=2048 --checkpoint-action=dot)
    fi
    "${SUDO[@]}" tar "${TAR_OPTS[@]}"
    $QUIET || echo

    # Extraction validation
    if [[ ! -d "$ARM_TOOLCHAIN_DIR/bin" ]]; then
        echo "FATAL: Extraction failed - invalid tarball structure" >&2
        exit 1
    fi

    # Validate ARM toolchain functionality.
    # a+rX sets execute on directories and on files that are already
    # executable, unlike a blanket 755.
    "${SUDO[@]}" chmod -R a+rX "$ARM_TOOLCHAIN_DIR"
    if ! "$ARM_TOOLCHAIN_DIR/bin/arm-none-eabi-gcc" --version &>/dev/null; then
        echo "FATAL: ARM toolchain failed to run" >&2
        exit 1
    fi
    log "ARM toolchain installed!"
    "${SUDO[@]}" rm -f "$ARM_TARBALL_PATH"
else
    log "ARM toolchain already present at $ARM_TOOLCHAIN_DIR"
fi

# Environment configuration. /usr/lib/ccache first in PATH is what makes the
# ccache symlinks above (and Debian's own gcc/g++ ones) take effect.
CONFIG_ENTRIES=("export PATH=$CCACHE_DIR:\$PATH|Put ccache first in PATH")
if [[ -d "$ARM_TOOLCHAIN_DIR/bin" ]]; then
    CONFIG_ENTRIES+=("export PATH=$ARM_TOOLCHAIN_DIR/bin:\$PATH|Add ARM toolchain to PATH")
fi
CONFIG_ENTRIES+=(
    "export PATH=$ARDUPILOT_TOOLS_DIR:\$PATH|Add ArduPilot test tools to PATH"
    "source $VENV_DIR/bin/activate|Auto-activate Python virtual environment"
)

for entry in "${CONFIG_ENTRIES[@]}"; do
    IFS='|' read -r line prompt <<< "$entry"
    add_config_entry "$line" "$prompt"
done
fi

# Repository submodules initialization
log "Initializing repository submodules..."
GIT_OPTS=(--init --recursive)
if $QUIET; then
    GIT_OPTS+=(--quiet)
fi
git -C "$ARDUPILOT_ROOT" submodule update "${GIT_OPTS[@]}"

# Final instructions
log ""
log "=== Setup complete ==="
if $SKIP_SYSTEM; then
    log "Python virtual environment: $VENV_DIR"
    exit 0
fi
log "Recommended actions:"
if [[ -n "$CONFIG_FILE" ]]; then
    log "1. Reload your shell config: source $CONFIG_FILE"
else
    log "1. Add the lines printed above to your shell config"
fi
log "2. Verify ARM toolchain in environment: which arm-none-eabi-gcc"
log "3. Activate Python virtual environment: source $VENV_DIR/bin/activate"
log "4. Log out and back in for group changes to take effect"
