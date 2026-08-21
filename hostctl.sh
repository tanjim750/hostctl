#!/usr/bin/env bash

set -Eeuo pipefail

# =========================================================
# hostctl - Main CLI Router
# =========================================================

SCRIPT_PATH="$(readlink -f "${BASH_SOURCE[0]}")"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

COMMON_LIB="${SCRIPT_DIR}/lib/common.sh"
INIT_LIB="${SCRIPT_DIR}/lib/init.sh"
SYSTEM_LIB="${SCRIPT_DIR}/lib/system.sh"

# ---------------------------------------------------------
# Load required libraries
# ---------------------------------------------------------

if [[ ! -f "$COMMON_LIB" ]]; then
    echo "[ERROR] Missing required library: $COMMON_LIB" >&2
    exit 1
fi

# shellcheck source=lib/common.sh
source "$COMMON_LIB"

if [[ ! -f "$INIT_LIB" ]]; then
    die "Missing required library: $INIT_LIB"
fi

# shellcheck source=lib/init.sh
source "$INIT_LIB"

if [[ ! -f "$SYSTEM_LIB" ]]; then
    die "Missing required library: $SYSTEM_LIB"
fi

# shellcheck source=lib/system.sh
source "$SYSTEM_LIB"

# ---------------------------------------------------------
# Help
# ---------------------------------------------------------

show_help() {
    cat <<EOF
hostctl ${HOSTCTL_VERSION}

Usage:
  sudo hostctl <command>

Core:
  --init                  Install dependencies and register hostctl
  --status                Show global server status
  --health                Run server health checks
  --help                  Show this help
  --version               Show version

System:
  --update                Update system packages
  --vram                  Configure swap / virtual RAM
  --cleanup               Run safe cleanup
  --security              Configure server security

Docker:
  --docker                 Install/check Docker
  --docker-status          Show Docker health
  --docker-build           Build current project
  --docker-start           Start current project
  --docker-stop            Stop current project
  --docker-restart         Restart current project
  --docker-rebuild         Rebuild current project
  --docker-down            Bring current project down
  --docker-pull            Pull project images
  --docker-logs            Show project logs
  --docker-logs-clear      Clear project container logs
  --docker-ps              Show project containers

Nginx / SSL:
  --nginx                  Install/check Nginx
  --domain                 Configure reverse proxy domain
  --nginx-security         Configure Nginx security
  --nginx-rate-limit       Configure rate limiting
  --nginx-block-ip         Block IP/CIDR
  --nginx-whitelist-ip     Whitelist IP/CIDR
  --nginx-logs             Show Nginx logs
  --nginx-logs-clear       Clear/rotate Nginx logs
  --ssl                    Configure Certbot SSL
  --ssl-status             Show SSL status

Firewall:
  --firewall               Configure UFW
  --allow-port             Allow port
  --deny-port              Deny port
  --firewall-status        Show firewall rules
  --firewall-reset         Reset firewall

Database / Backup:
  --db-backup              Backup project database
  --db-restore             Restore project database
  --backup-now             Run backup now
  --backup-schedule        Configure backup cron
  --backup-status          Show backup status
  --rclone                 Install/run rclone config

Cron:
  --cronjob                Create cron job
  --cron-list              List hostctl cron jobs
  --cron-remove            Remove cron job

Security:
  --fail2ban               Configure Fail2Ban
  --ssh-security           Configure SSH security
  --security-status        Show security status

Monitoring:
  --monitor                Show resource monitor
  --service-status         Show service status

Logs:
  --logs                   Interactive log viewer
  --logs-clear             Clear selected logs
  --log-status             Show log usage
  --system-logs            Show system journal logs

EOF
}

# ---------------------------------------------------------
# Error handling
# ---------------------------------------------------------

on_error() {
    local exit_code=$?
    local line_no="${BASH_LINENO[0]:-unknown}"
    local failed_command="${1:-unknown}"

    error "Command failed at line ${line_no} with exit code ${exit_code}."
    log_event "ERROR exit=${exit_code} line=${line_no} command=${failed_command}"

    exit "$exit_code"
}

trap 'on_error "$BASH_COMMAND"' ERR

# ---------------------------------------------------------
# Basic validation
# ---------------------------------------------------------

if [[ $# -eq 0 ]]; then
    show_help
    exit 0
fi

COMMAND="$1"
shift || true

# Help and version do not require root.
case "$COMMAND" in
    --help|-h)
        show_help
        exit 0
        ;;

    --version|-v)
        printf 'hostctl %s\n' "$HOSTCTL_VERSION"
        exit 0
        ;;
esac

require_root
require_debian_based
ensure_hostctl_dirs

log_event "COMMAND ${COMMAND} args=$* cwd=$(pwd)"

# ---------------------------------------------------------
# Command routing
# ---------------------------------------------------------

case "$COMMAND" in

    # Core
    --init)
        cmd_init "$@"
        ;;

    --status)
        die "--status is not implemented yet."
        ;;

    --health)
        die "--health is not implemented yet."
        ;;

    # System
    --update)
        cmd_update "$@"
        ;;

    --vram)
        cmd_vram "$@"
        ;;

    --cleanup)
        cmd_cleanup "$@"
        ;;

    --security)
        die "--security is not implemented yet."
        ;;

    # Docker
    --docker|\
    --docker-status|\
    --docker-build|\
    --docker-start|\
    --docker-stop|\
    --docker-restart|\
    --docker-rebuild|\
    --docker-down|\
    --docker-pull|\
    --docker-logs|\
    --docker-logs-clear|\
    --docker-ps)
        die "${COMMAND} is not implemented yet."
        ;;

    # Nginx
    --nginx|\
    --domain|\
    --nginx-security|\
    --nginx-rate-limit|\
    --nginx-block-ip|\
    --nginx-whitelist-ip|\
    --nginx-logs|\
    --nginx-logs-clear)
        die "${COMMAND} is not implemented yet."
        ;;

    # SSL
    --ssl|--ssl-status)
        die "${COMMAND} is not implemented yet."
        ;;

    # Firewall
    --firewall|\
    --allow-port|\
    --deny-port|\
    --firewall-status|\
    --firewall-reset)
        die "${COMMAND} is not implemented yet."
        ;;

    # Database / Backup
    --db-backup|\
    --db-restore|\
    --backup-now|\
    --backup-schedule|\
    --backup-status)
        die "${COMMAND} is not implemented yet."
        ;;

    # rclone
    --rclone)
        die "--rclone is not implemented yet."
        ;;

    # Cron
    --cronjob|\
    --cron-list|\
    --cron-remove)
        die "${COMMAND} is not implemented yet."
        ;;

    # Security
    --fail2ban|\
    --ssh-security|\
    --security-status)
        die "${COMMAND} is not implemented yet."
        ;;

    # Monitoring
    --monitor|\
    --service-status)
        die "${COMMAND} is not implemented yet."
        ;;

    # Logs
    --logs|\
    --logs-clear|\
    --log-status|\
    --system-logs)
        die "${COMMAND} is not implemented yet."
        ;;

    # Unknown
    *)
        error "Unknown command: $COMMAND"
        echo
        show_help
        exit 2
        ;;
esac
