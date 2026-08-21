#!/usr/bin/env bash

# =========================================================
# hostctl - System Operations
# =========================================================

HOSTCTL_SWAP_FILE="/swapfile"
HOSTCTL_CLEANUP_CONF="${HOSTCTL_STATE_DIR}/cleanup.conf"
HOSTCTL_CLEANUP_LOG="${HOSTCTL_LOG_DIR}/cleanup.log"
HOSTCTL_CLEANUP_MARKER="# HOSTCTL:cleanup"

BACKUP_RETENTION_DAYS=7
JOURNAL_RETENTION_DAYS=7

# ---------------------------------------------------------
# System update
# ---------------------------------------------------------

cmd_update() {
    require_root
    require_debian_based

    echo
    echo "System Update"
    echo
    echo "This will run:"
    echo "- apt update"
    echo "- apt upgrade -y"
    echo "- apt autoremove -y"
    echo "- apt autoclean"
    echo

    if ! confirm "Continue?" "yes"; then
        warning "System update cancelled."
        return 0
    fi

    log_event "system update started"

    local exit_code=0
    run_system_update || exit_code=$?
    if (( exit_code != 0 )); then
        log_event "system update failed exit=${exit_code}"
        error "System update failed."
        return "$exit_code"
    fi

    log_event "system update completed"
    success "System update completed successfully."
}

run_system_update() {
    info "Updating package index..."
    apt update || return 1

    info "Upgrading installed packages..."
    apt upgrade -y || return 1

    info "Removing unused packages..."
    apt autoremove -y || return 1

    info "Cleaning package cache..."
    apt autoclean || return 1
}

# ---------------------------------------------------------
# Swap / virtual RAM
# ---------------------------------------------------------

get_total_ram_mb() {
    awk '/^MemTotal:/ { printf "%d\n", int($2 / 1024) }' /proc/meminfo
}

get_swap_mb() {
    awk '/^SwapTotal:/ { printf "%d\n", int($2 / 1024) }' /proc/meminfo
}

format_mb() {
    local mb="$1"

    if (( mb >= 1024 )); then
        awk -v mb="$mb" 'BEGIN { printf "%.1f GB", mb / 1024 }'
    else
        printf '%d MB' "$mb"
    fi
}

recommend_swap_size() {
    local ram_mb="$1"
    local existing_swap_mb="$2"
    local recommended_mb

    if (( ram_mb <= 2048 )); then
        recommended_mb=$((ram_mb * 2))
    elif (( ram_mb <= 4096 )); then
        recommended_mb=4096
    elif (( ram_mb <= 8192 )); then
        recommended_mb=4096
    else
        recommended_mb=2048
    fi

    if (( existing_swap_mb >= recommended_mb )); then
        printf '%d\n' "$existing_swap_mb"
    else
        printf '%d\n' "$recommended_mb"
    fi
}

mb_to_size_string() {
    local mb="$1"

    if (( mb % 1024 == 0 )); then
        printf '%dG\n' "$((mb / 1024))"
    else
        printf '%dM\n' "$mb"
    fi
}

validate_swap_size() {
    local size="$1"

    [[ "$size" =~ ^[1-9][0-9]*[MmGg]$ ]]
}

swap_size_to_mb() {
    local size="$1"
    local number="${size%[MmGg]}"
    local unit="${size: -1}"

    case "$unit" in
        M|m)
            printf '%d\n' "$number"
            ;;
        G|g)
            printf '%d\n' "$((number * 1024))"
            ;;
        *)
            return 1
            ;;
    esac
}

remove_hostctl_swap_fstab_entries() {
    local fstab_file="$1"
    local temp_file

    temp_file="$(mktemp)"

    awk -v swap_file="$HOSTCTL_SWAP_FILE" '
        $1 == swap_file && $2 == "none" && $3 == "swap" { next }
        $0 ~ /^[[:space:]]*#/ && $0 ~ /HOSTCTL:swap/ { next }
        { print }
    ' "$fstab_file" > "$temp_file"

    cp "$temp_file" "$fstab_file"
    rm -f "$temp_file"
}

configure_swap() {
    local size="$1"
    local size_mb
    local fstab_backup=""
    local sysctl_backup=""

    size_mb="$(swap_size_to_mb "$size")" || return 1

    fstab_backup="$(backup_file /etc/fstab || true)"
    if [[ -z "$fstab_backup" ]]; then
        die "Unable to back up /etc/fstab."
    fi

    if [[ -f /etc/sysctl.conf ]]; then
        sysctl_backup="$(backup_file /etc/sysctl.conf || true)"
    fi

    if [[ -f "$HOSTCTL_SWAP_FILE" ]]; then
        info "Disabling existing ${HOSTCTL_SWAP_FILE} if active..."
        swapoff "$HOSTCTL_SWAP_FILE" 2>/dev/null || true
        rm -f "$HOSTCTL_SWAP_FILE"
    fi

    remove_hostctl_swap_fstab_entries /etc/fstab

    info "Creating ${HOSTCTL_SWAP_FILE} (${size})..."
    if ! fallocate -l "$size" "$HOSTCTL_SWAP_FILE" 2>/dev/null; then
        warning "fallocate failed; falling back to dd."
        rm -f "$HOSTCTL_SWAP_FILE"
        dd if=/dev/zero of="$HOSTCTL_SWAP_FILE" bs=1M count="$size_mb" status=progress || {
            rollback_file "$fstab_backup" /etc/fstab || true
            [[ -n "$sysctl_backup" ]] && rollback_file "$sysctl_backup" /etc/sysctl.conf || true
            rm -f "$HOSTCTL_SWAP_FILE"
            return 1
        }
    fi

    chmod 600 "$HOSTCTL_SWAP_FILE" || {
        rollback_file "$fstab_backup" /etc/fstab || true
        rm -f "$HOSTCTL_SWAP_FILE"
        return 1
    }

    mkswap "$HOSTCTL_SWAP_FILE" || {
        rollback_file "$fstab_backup" /etc/fstab || true
        rm -f "$HOSTCTL_SWAP_FILE"
        return 1
    }

    swapon "$HOSTCTL_SWAP_FILE" || {
        rollback_file "$fstab_backup" /etc/fstab || true
        rm -f "$HOSTCTL_SWAP_FILE"
        return 1
    }

    printf '%s none swap sw 0 0 # HOSTCTL:swap\n' "$HOSTCTL_SWAP_FILE" >> /etc/fstab

    if grep -qE '^[[:space:]]*vm\.swappiness[[:space:]]*=' /etc/sysctl.conf; then
        sed -i 's/^[[:space:]]*vm\.swappiness[[:space:]]*=.*/vm.swappiness=10/' /etc/sysctl.conf
    else
        printf '\n# HOSTCTL:swap\nvm.swappiness=10\n' >> /etc/sysctl.conf
    fi

    sysctl vm.swappiness=10 >/dev/null || true
}

cmd_vram() {
    require_root
    require_debian_based

    local ram_mb
    local swap_mb
    local recommended_mb
    local recommended_size
    local requested_size
    local existing_swap_prompt

    ram_mb="$(get_total_ram_mb)"
    swap_mb="$(get_swap_mb)"
    recommended_mb="$(recommend_swap_size "$ram_mb" "$swap_mb")"
    recommended_size="$(mb_to_size_string "$recommended_mb")"

    echo
    echo "Virtual RAM / Swap"
    echo
    printf 'Physical RAM: %s\n' "$(format_mb "$ram_mb")"
    printf 'Current swap: %s\n' "$(format_mb "$swap_mb")"
    printf 'Recommended swap target: %s\n' "$(format_mb "$recommended_mb")"
    echo

    if (( swap_mb > 0 )); then
        warning "Swap is already configured on this system."
        if swapon --show --noheadings --raw --output NAME 2>/dev/null | grep -Fxq "$HOSTCTL_SWAP_FILE" ||
           [[ -f "$HOSTCTL_SWAP_FILE" ]]; then
            existing_swap_prompt="Replace or resize ${HOSTCTL_SWAP_FILE}?"
        else
            existing_swap_prompt="Create ${HOSTCTL_SWAP_FILE} in addition to existing swap?"
        fi

        if ! confirm "$existing_swap_prompt" "no"; then
            warning "Swap configuration cancelled."
            return 0
        fi
    fi

    while true; do
        requested_size="$(ask_input "Swap size (examples: 2G, 4096M)" "$recommended_size")"
        if validate_swap_size "$requested_size"; then
            break
        fi
        warning "Invalid swap size. Use values like 2G, 4G, or 4096M."
    done

    echo
    warning "This will modify ${HOSTCTL_SWAP_FILE}, /etc/fstab, and vm.swappiness."
    if ! confirm "Continue?" "yes"; then
        warning "Swap configuration cancelled."
        return 0
    fi

    log_event "swap configuration started size=${requested_size}"

    local exit_code=0
    configure_swap "$requested_size" || exit_code=$?
    if (( exit_code != 0 )); then
        log_event "swap configuration failed exit=${exit_code}"
        error "Swap configuration failed."
        return "$exit_code"
    fi

    log_event "swap configuration completed size=${requested_size}"
    success "Swap configured successfully."
    echo
    swapon --show || true
    echo
    free -h || true
}

# ---------------------------------------------------------
# Cleanup
# ---------------------------------------------------------

get_disk_usage() {
    df -h / | awk 'NR == 2 { printf "%s used of %s (%s available)", $3, $2, $4 }'
}

load_cleanup_config() {
    BACKUP_RETENTION_DAYS=7
    JOURNAL_RETENTION_DAYS=7

    if [[ -f "$HOSTCTL_CLEANUP_CONF" ]]; then
        local key
        local value

        while IFS='=' read -r key value; do
            case "$key" in
                BACKUP_RETENTION_DAYS)
                    [[ "$value" =~ ^[1-9][0-9]*$ ]] && BACKUP_RETENTION_DAYS="$value"
                    ;;
                JOURNAL_RETENTION_DAYS)
                    [[ "$value" =~ ^[1-9][0-9]*$ ]] && JOURNAL_RETENTION_DAYS="$value"
                    ;;
            esac
        done < "$HOSTCTL_CLEANUP_CONF"
    fi

    if ! is_positive_integer "$BACKUP_RETENTION_DAYS"; then
        BACKUP_RETENTION_DAYS=7
    fi

    if ! is_positive_integer "$JOURNAL_RETENTION_DAYS"; then
        JOURNAL_RETENTION_DAYS=7
    fi
}

save_cleanup_config() {
    local backup_retention_days="$1"
    local journal_retention_days="${2:-7}"

    mkdir -p "$HOSTCTL_STATE_DIR"

    cat > "$HOSTCTL_CLEANUP_CONF" <<EOF
BACKUP_RETENTION_DAYS=${backup_retention_days}
JOURNAL_RETENTION_DAYS=${journal_retention_days}
EOF
}

cleanup_apt() {
    info "Cleaning apt cache and unused packages..."
    apt autoremove -y || return 1
    apt autoclean || return 1
    apt clean || return 1
}

cleanup_journal() {
    local retention_days="${1:-7}"

    if ! command_exists journalctl; then
        warning "journalctl not found; skipping journal cleanup."
        return 0
    fi

    info "Vacuuming systemd journal older than ${retention_days} days..."
    journalctl "--vacuum-time=${retention_days}d" || return 1
}

cleanup_temp() {
    info "Cleaning safe temporary files older than 7 days..."

    if command_exists systemd-tmpfiles; then
        systemd-tmpfiles --clean || return 1
        return 0
    fi

    local temp_root
    for temp_root in /tmp /var/tmp; do
        [[ -d "$temp_root" ]] || continue
        find "$temp_root" -xdev -mindepth 1 -maxdepth 1 -type f -mtime +7 -print0 |
            while IFS= read -r -d '' temp_file; do
                rm -f "$temp_file"
            done
    done
}

cleanup_old_backups() {
    local retention_days="${1:-7}"

    if [[ ! -d "$HOSTCTL_BACKUP_DIR" ]]; then
        warning "Backup directory not found; skipping backup cleanup."
        return 0
    fi

    info "Removing hostctl backup files older than ${retention_days} days..."

    find "$HOSTCTL_BACKUP_DIR" -xdev -type f -mtime "+${retention_days}" \
        \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.dump' -o -name '*.bak' -o -name '*.backup' -o -name '*.tar' -o -name '*.tar.gz' -o -name '*.tgz' -o -name '*.zip' \) \
        -print0 |
        while IFS= read -r -d '' backup_file_path; do
            rm -f "$backup_file_path"
        done
}

docker_is_available() {
    command_exists docker && docker info >/dev/null 2>&1
}

cleanup_docker_safe() {
    if ! docker_is_available; then
        warning "Docker is not installed or not running; skipping Docker cleanup."
        return 0
    fi

    info "Pruning dangling Docker images..."
    docker image prune -f || return 1

    info "Pruning Docker build cache..."
    docker builder prune -f || return 1
}

cleanup_docker_optional() {
    if ! docker_is_available; then
        warning "Docker is not installed or not running; skipping optional Docker cleanup."
        return 0
    fi

    if confirm "Also remove stopped containers?" "no"; then
        info "Removing stopped Docker containers..."
        docker container prune -f || return 1
    fi

    if confirm "Also remove unused Docker volumes?" "no"; then
        info "Removing unused Docker volumes..."
        docker volume prune -f || return 1
    fi
}

run_safe_cleanup() {
    local backup_retention_days="${1:-7}"
    local journal_retention_days="${2:-7}"

    cleanup_apt || return 1
    cleanup_journal "$journal_retention_days" || return 1
    cleanup_temp || return 1
    cleanup_old_backups "$backup_retention_days" || return 1
    cleanup_docker_safe || return 1
}

validate_cron_expression() {
    local expression="$1"
    local field_count

    field_count="$(awk '{ print NF }' <<< "$expression")"
    [[ "$field_count" -eq 5 ]]
}

validate_hour() {
    local hour="$1"

    [[ "$hour" =~ ^[0-9]+$ ]] && (( hour >= 0 && hour <= 23 ))
}

validate_minute() {
    local minute="$1"

    [[ "$minute" =~ ^[0-9]+$ ]] && (( minute >= 0 && minute <= 59 ))
}

validate_weekday() {
    local day="$1"

    [[ "$day" =~ ^[0-7]$ ]]
}

read_time_fields() {
    local default_hour="$1"
    local default_minute="$2"
    local hour
    local minute

    while true; do
        hour="$(ask_input "Hour (0-23)" "$default_hour")"
        minute="$(ask_input "Minute (0-59)" "$default_minute")"

        if validate_hour "$hour" && validate_minute "$minute"; then
            printf '%s %s\n' "$hour" "$minute"
            return 0
        fi

        warning "Invalid time. Use hour 0-23 and minute 0-59."
    done
}

configure_cleanup_schedule() {
    require_command crontab

    local choice
    local cron_expression
    local backup_retention_days
    local time_fields
    local hour
    local minute
    local weekday
    local current_cron
    local next_cron
    local cron_command

    echo
    echo "Cleanup Schedule"
    echo

    choice="$(
        select_option \
            "Choose schedule:" \
            "Daily once" \
            "Weekly once" \
            "Daily at specific time" \
            "Weekly at specific day/time" \
            "Custom cron expression"
    )"

    case "$choice" in
        "Daily once")
            cron_expression="0 1 * * *"
            ;;
        "Weekly once")
            cron_expression="0 1 * * 0"
            ;;
        "Daily at specific time")
            time_fields="$(read_time_fields 1 0)"
            hour="${time_fields%% *}"
            minute="${time_fields##* }"
            cron_expression="${minute} ${hour} * * *"
            ;;
        "Weekly at specific day/time")
            time_fields="$(read_time_fields 1 0)"
            hour="${time_fields%% *}"
            minute="${time_fields##* }"
            while true; do
                weekday="$(ask_input "Weekday (0-7, Sunday is 0 or 7)" "0")"
                if validate_weekday "$weekday"; then
                    break
                fi
                warning "Invalid weekday. Use 0-7."
            done
            cron_expression="${minute} ${hour} * * ${weekday}"
            ;;
        "Custom cron expression")
            while true; do
                cron_expression="$(ask_input "Cron expression (5 fields)")"
                if validate_cron_expression "$cron_expression"; then
                    break
                fi
                warning "Invalid cron expression. Expected 5 fields."
            done
            ;;
        *)
            die "Invalid cleanup schedule selection."
            ;;
    esac

    while true; do
        backup_retention_days="$(ask_input "Backup retention days" "7")"
        if is_positive_integer "$backup_retention_days"; then
            break
        fi
        warning "Retention days must be a positive integer."
    done

    echo
    printf 'Schedule: %s\n' "$cron_expression"
    printf 'Backup retention: %s days\n' "$backup_retention_days"
    echo

    if ! confirm "Create or update cleanup cron job?" "yes"; then
        warning "Cleanup schedule cancelled."
        return 0
    fi

    save_cleanup_config "$backup_retention_days" "7"

    mkdir -p "$HOSTCTL_LOG_DIR"

    cron_command="${cron_expression} /usr/local/bin/hostctl --cleanup --cron >> ${HOSTCTL_CLEANUP_LOG} 2>&1 ${HOSTCTL_CLEANUP_MARKER}"
    current_cron="$(mktemp)"
    next_cron="$(mktemp)"

    crontab -l > "$current_cron" 2>/dev/null || true
    grep -Fv "$HOSTCTL_CLEANUP_MARKER" "$current_cron" > "$next_cron" || true
    printf '%s\n' "$cron_command" >> "$next_cron"
    crontab "$next_cron"

    rm -f "$current_cron" "$next_cron"

    log_event "cleanup schedule configured expression=${cron_expression} retention_days=${backup_retention_days}"
    success "Cleanup schedule configured."
}

cmd_cleanup() {
    require_root
    require_debian_based

    case "${1:-}" in
        --schedule)
            configure_cleanup_schedule
            return
            ;;
        --cron)
            load_cleanup_config
            log_event "scheduled cleanup started"
            local cron_exit_code=0
            run_safe_cleanup "$BACKUP_RETENTION_DAYS" "$JOURNAL_RETENTION_DAYS" || cron_exit_code=$?
            if (( cron_exit_code == 0 )); then
                log_event "scheduled cleanup completed"
                success "Scheduled cleanup completed."
                return 0
            fi

            log_event "scheduled cleanup failed exit=${cron_exit_code}"
            error "Scheduled cleanup failed."
            return "$cron_exit_code"
            ;;
        "")
            ;;
        *)
            die "Unknown --cleanup option: $1"
            ;;
    esac

    local backup_retention_days
    local disk_before
    local disk_after

    load_cleanup_config

    echo
    echo "System Cleanup"
    echo
    echo "Planned cleanup:"
    echo "- apt cache"
    echo "- unused apt packages"
    echo "- systemd journal logs older than ${JOURNAL_RETENTION_DAYS} days"
    echo "- safe temporary files"
    echo "- hostctl local database backups"
    echo "- dangling Docker images"
    echo "- Docker build cache"
    echo

    while true; do
        backup_retention_days="$(ask_input "Backup retention days" "$BACKUP_RETENTION_DAYS")"
        if is_positive_integer "$backup_retention_days"; then
            break
        fi
        warning "Retention days must be a positive integer."
    done

    disk_before="$(get_disk_usage || true)"
    [[ -n "$disk_before" ]] && printf 'Disk before: %s\n' "$disk_before"
    echo

    if ! confirm "Continue with safe cleanup?" "yes"; then
        warning "Cleanup cancelled."
        return 0
    fi

    save_cleanup_config "$backup_retention_days" "$JOURNAL_RETENTION_DAYS"
    log_event "manual cleanup started backup_retention_days=${backup_retention_days}"

    local exit_code=0
    run_safe_cleanup "$backup_retention_days" "$JOURNAL_RETENTION_DAYS" || exit_code=$?
    if (( exit_code != 0 )); then
        log_event "manual cleanup failed exit=${exit_code}"
        error "Cleanup failed."
        return "$exit_code"
    fi

    cleanup_docker_optional || return 1

    disk_after="$(get_disk_usage || true)"
    [[ -n "$disk_after" ]] && printf 'Disk after: %s\n' "$disk_after"

    log_event "manual cleanup completed"
    success "Cleanup completed successfully."
}
