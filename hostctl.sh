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
DOCKER_LIB="${SCRIPT_DIR}/lib/docker.sh"
NGINX_LIB="${SCRIPT_DIR}/lib/nginx.sh"

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

if [[ ! -f "$DOCKER_LIB" ]]; then
    die "Missing required library: $DOCKER_LIB"
fi

# shellcheck source=lib/docker.sh
source "$DOCKER_LIB"

if [[ ! -f "$NGINX_LIB" ]]; then
    die "Missing required library: $NGINX_LIB"
fi

# shellcheck source=lib/nginx.sh
source "$NGINX_LIB"

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
  --nginx-rate-limit-list  List rate limits
  --nginx-rate-limit-edit  Edit rate limit
  --nginx-rate-limit-remove Remove rate limit
  --nginx-block-ip         Block IP/CIDR
  --nginx-block-ip-list    List blocked IP rules
  --nginx-block-ip-edit    Edit blocked IP rule
  --nginx-block-ip-remove  Remove blocked IP rule
  --nginx-whitelist-ip     Whitelist IP/CIDR
  --nginx-whitelist-ip-list List whitelist rules
  --nginx-whitelist-ip-edit Edit whitelist rule
  --nginx-whitelist-ip-remove Remove whitelist rule
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

HOSTCTL_ERROR_HANDLED=0

on_error() {
    local exit_code=$?

    if [[ "${HOSTCTL_ERROR_HANDLED:-0}" -eq 1 ]]; then
        return "$exit_code"
    fi

    HOSTCTL_ERROR_HANDLED=1

    local line_no="${BASH_LINENO[0]:-unknown}"
    local failed_command="${1:-unknown}"

    error "Command failed: ${failed_command}"
    error "Location: line ${line_no}, exit code ${exit_code}"
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
    --docker)
        cmd_docker "$@"
        ;;

    --docker-status)
        cmd_docker_status "$@"
        ;;

    --docker-build)
        cmd_docker_build "$@"
        ;;

    --docker-start)
        cmd_docker_start "$@"
        ;;

    --docker-stop)
        cmd_docker_stop "$@"
        ;;

    --docker-restart)
        cmd_docker_restart "$@"
        ;;

    --docker-rebuild)
        cmd_docker_rebuild "$@"
        ;;

    --docker-down)
        cmd_docker_down "$@"
        ;;

    --docker-pull)
        cmd_docker_pull "$@"
        ;;

    --docker-logs)
        cmd_docker_logs "$@"
        ;;

    --docker-logs-clear)
        cmd_docker_logs_clear "$@"
        ;;

    --docker-ps)
        cmd_docker_ps "$@"
        ;;

    # Nginx
    --nginx)
        cmd_nginx "$@"
        ;;

    --domain)
        cmd_domain "$@"
        ;;

    --nginx-security)
        cmd_nginx_security "$@"
        ;;

    --nginx-rate-limit)
        cmd_nginx_rate_limit "$@"
        ;;

    --nginx-rate-limit-list)
        cmd_nginx_rate_limit_list "$@"
        ;;

    --nginx-rate-limit-edit)
        cmd_nginx_rate_limit_edit "$@"
        ;;

    --nginx-rate-limit-remove)
        cmd_nginx_rate_limit_remove "$@"
        ;;

    --nginx-block-ip)
        cmd_nginx_block_ip "$@"
        ;;

    --nginx-block-ip-list)
        cmd_nginx_block_ip_list "$@"
        ;;

    --nginx-block-ip-edit)
        cmd_nginx_block_ip_edit "$@"
        ;;

    --nginx-block-ip-remove)
        cmd_nginx_block_ip_remove "$@"
        ;;

    --nginx-whitelist-ip)
        cmd_nginx_whitelist_ip "$@"
        ;;

    --nginx-whitelist-ip-list)
        cmd_nginx_whitelist_ip_list "$@"
        ;;

    --nginx-whitelist-ip-edit)
        cmd_nginx_whitelist_ip_edit "$@"
        ;;

    --nginx-whitelist-ip-remove)
        cmd_nginx_whitelist_ip_remove "$@"
        ;;

    --nginx-logs)
        cmd_nginx_logs "$@"
        ;;

    --nginx-logs-clear)
        cmd_nginx_logs_clear "$@"
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
