#!/usr/bin/env bash

# =========================================================
# hostctl - Common Utilities
# =========================================================

HOSTCTL_NAME="hostctl"
HOSTCTL_VERSION="0.1.0"

HOSTCTL_HOME="/etc/hostctl"
HOSTCTL_LOG_DIR="${HOSTCTL_HOME}/logs"
HOSTCTL_STATE_DIR="${HOSTCTL_HOME}/state"
HOSTCTL_BACKUP_DIR="${HOSTCTL_HOME}/backups"

HOSTCTL_LOG_FILE="${HOSTCTL_LOG_DIR}/hostctl.log"

PROJECT_DIR="$(pwd)"

# ---------------------------------------------------------
# Colors
# ---------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---------------------------------------------------------
# Output helpers
# ---------------------------------------------------------

info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$*"
}

success() {
    printf "${GREEN}[OK]${NC} %s\n" "$*"
}

warning() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$*" >&2
}

error() {
    printf "${RED}[ERROR]${NC} %s\n" "$*" >&2
}

die() {
    error "$*"
    exit 1
}

# ---------------------------------------------------------
# Logging
# ---------------------------------------------------------

ensure_hostctl_dirs() {
    mkdir -p \
        "$HOSTCTL_LOG_DIR" \
        "$HOSTCTL_STATE_DIR" \
        "$HOSTCTL_BACKUP_DIR"
}

log_event() {
    local message="$*"

    # Logging should not break the main operation.
    if [[ -d "$HOSTCTL_LOG_DIR" ]] || mkdir -p "$HOSTCTL_LOG_DIR" 2>/dev/null; then
        printf '[%s] %s\n' \
            "$(date '+%Y-%m-%d %H:%M:%S')" \
            "$message" >> "$HOSTCTL_LOG_FILE" 2>/dev/null || true
    fi
}

# ---------------------------------------------------------
# Privilege / OS checks
# ---------------------------------------------------------

require_root() {
    if [[ "${EUID}" -ne 0 ]]; then
        die "This command requires sudo/root privileges."
    fi
}

is_debian_based() {
    [[ -f /etc/debian_version ]]
}

require_debian_based() {
    if ! is_debian_based; then
        die "Unsupported operating system. hostctl requires a Debian-based system."
    fi
}

# ---------------------------------------------------------
# Command helpers
# ---------------------------------------------------------

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

require_command() {
    local command_name="$1"

    if ! command_exists "$command_name"; then
        die "Required command not found: $command_name"
    fi
}

# ---------------------------------------------------------
# Input helpers
# ---------------------------------------------------------

ask_input() {
    local prompt="$1"
    local default_value="${2:-}"
    local value

    if [[ -n "$default_value" ]]; then
        read -r -p "$prompt [$default_value]: " value
        printf '%s\n' "${value:-$default_value}"
    else
        read -r -p "$prompt: " value
        printf '%s\n' "$value"
    fi
}

confirm() {
    local prompt="$1"
    local default="${2:-yes}"
    local answer

    while true; do
        if [[ "$default" == "yes" ]]; then
            read -r -p "$prompt [Y/n]: " answer
            answer="${answer:-y}"
        else
            read -r -p "$prompt [y/N]: " answer
            answer="${answer:-n}"
        fi

        case "${answer,,}" in
            y|yes)
                return 0
                ;;
            n|no)
                return 1
                ;;
            *)
                warning "Please answer yes or no."
                ;;
        esac
    done
}

select_option() {
    local prompt="$1"
    shift

    local options=("$@")
    local choice

    if [[ "${#options[@]}" -eq 0 ]]; then
        return 1
    fi

    printf '%s\n' "$prompt" >&2

    local i
    for i in "${!options[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${options[$i]}" >&2
    done

    while true; do
        read -r -p "Select [1-${#options[@]}]: " choice

        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#options[@]} )); then
            printf '%s\n' "${options[$((choice - 1))]}"
            return 0
        fi

        warning "Invalid selection."
    done
}

# ---------------------------------------------------------
# File helpers
# ---------------------------------------------------------

backup_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        return 0
    fi

    local backup="${file}.hostctl.$(date '+%Y%m%d%H%M%S').bak"

    cp -a "$file" "$backup" || return 1

    printf '%s\n' "$backup"
}

rollback_file() {
    local backup="$1"
    local target="$2"

    if [[ ! -f "$backup" ]]; then
        error "Rollback backup not found: $backup"
        return 1
    fi

    cp -a "$backup" "$target"
}

# ---------------------------------------------------------
# Project helpers
# ---------------------------------------------------------

get_project_dir() {
    printf '%s\n' "$PROJECT_DIR"
}

require_project_dir() {
    if [[ ! -d "$PROJECT_DIR" ]]; then
        die "Current project directory does not exist: $PROJECT_DIR"
    fi
}

# ---------------------------------------------------------
# Generic validation
# ---------------------------------------------------------

is_valid_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] &&
    (( port >= 1 && port <= 65535 ))
}

is_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

# ---------------------------------------------------------
# Initialization
# ---------------------------------------------------------

common_init() {
    require_root
    require_debian_based
    ensure_hostctl_dirs
}