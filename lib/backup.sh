#!/usr/bin/env bash

# =========================================================
# hostctl - Database Backup / Restore Operations
# =========================================================

BACKUP_STATE_DIR="${HOSTCTL_STATE_DIR}/backups"
BACKUP_RUN_STATE_DIR="${BACKUP_STATE_DIR}/runs"
BACKUP_DATABASE_DIR="${HOSTCTL_BACKUP_DIR}/databases"
BACKUP_RESTORE_TMP_DIR="${HOSTCTL_HOME}/tmp/restore"
BACKUP_LOW_SPACE_KB="${BACKUP_LOW_SPACE_KB:-524288}"

BACKUP_PROFILE_NAME=""
BACKUP_SOURCE_MODE=""
BACKUP_DB_TYPE=""
BACKUP_PROJECT_DIR=""
BACKUP_COMPOSE_FILE=""
BACKUP_ENV_FILE=""
BACKUP_DB_SERVICE=""
BACKUP_DB_HOST=""
BACKUP_DB_PORT=""
BACKUP_DB_NAME=""
BACKUP_DB_USER=""
BACKUP_DB_NAME_VAR=""
BACKUP_DB_USER_VAR=""
BACKUP_DB_PASSWORD_VAR=""
BACKUP_CREDENTIAL_SOURCE=""
BACKUP_DESTINATION=""
BACKUP_LOCAL_PATH=""
BACKUP_LOCAL_RETENTION_DAYS=""
BACKUP_RCLONE_REMOTE=""
BACKUP_RCLONE_PATH=""
BACKUP_CRON_MODE=0
BACKUP_RUNTIME_PASSWORD=""
BACKUP_LAST_LOCAL_FILE=""
BACKUP_LAST_SIZE=""
BACKUP_LAST_REMOTE_RESULT=""
BACKUP_LAST_RESULT=""
BACKUP_LAST_ERROR=""

# ---------------------------------------------------------
# Common helpers
# ---------------------------------------------------------

ensure_backup_dirs() {
    mkdir -p \
        "$BACKUP_STATE_DIR" \
        "$BACKUP_RUN_STATE_DIR" \
        "$BACKUP_DATABASE_DIR" \
        "$BACKUP_RESTORE_TMP_DIR" \
        "$HOSTCTL_LOG_DIR"

    chmod 700 "$BACKUP_STATE_DIR" "$BACKUP_RUN_STATE_DIR" "$BACKUP_DATABASE_DIR" "$BACKUP_RESTORE_TMP_DIR" 2>/dev/null || true
}

sanitize_backup_name() {
    local value="$1"

    value="$(tr '[:upper:]' '[:lower:]' <<< "$value")"
    value="${value//[^a-z0-9._-]/-}"
    value="${value##-}"
    value="${value%%-}"
    printf '%s\n' "${value:-database}"
}

human_size() {
    local file="$1"

    if command_exists du; then
        du -h "$file" 2>/dev/null | awk '{print $1}'
    else
        wc -c < "$file" | awk '{print $1 " bytes"}'
    fi
}

backup_profile_path() {
    valid_profile_name "$1" || {
        error "Invalid backup profile name: $1"
        return 1
    }
    printf '%s/%s.conf\n' "$BACKUP_STATE_DIR" "$1"
}

backup_run_state_path() {
    valid_profile_name "$1" || {
        error "Invalid backup profile name: $1"
        return 1
    }
    printf '%s/%s.state\n' "$BACKUP_RUN_STATE_DIR" "$1"
}

reset_backup_config() {
    BACKUP_PROFILE_NAME=""
    BACKUP_SOURCE_MODE=""
    BACKUP_DB_TYPE=""
    BACKUP_PROJECT_DIR=""
    BACKUP_COMPOSE_FILE=""
    BACKUP_ENV_FILE=""
    BACKUP_DB_SERVICE=""
    BACKUP_DB_HOST=""
    BACKUP_DB_PORT=""
    BACKUP_DB_NAME=""
    BACKUP_DB_USER=""
    BACKUP_DB_NAME_VAR=""
    BACKUP_DB_USER_VAR=""
    BACKUP_DB_PASSWORD_VAR=""
    BACKUP_CREDENTIAL_SOURCE=""
    BACKUP_DESTINATION=""
    BACKUP_LOCAL_PATH=""
    BACKUP_LOCAL_RETENTION_DAYS=""
    BACKUP_RCLONE_REMOTE=""
    BACKUP_RCLONE_PATH=""
    BACKUP_RUNTIME_PASSWORD=""
    BACKUP_LAST_LOCAL_FILE=""
    BACKUP_LAST_SIZE=""
    BACKUP_LAST_REMOTE_RESULT=""
    BACKUP_LAST_RESULT=""
    BACKUP_LAST_ERROR=""
}

backup_config_default_profile_name() {
    local db_name="${BACKUP_DB_NAME:-database}"

    if [[ -z "$db_name" && -n "$BACKUP_DB_NAME_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        db_name="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_NAME_VAR" || true)"
    fi

    printf '%s-db\n' "$(sanitize_backup_name "${db_name:-database}")"
}

valid_profile_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[A-Za-z0-9]$ || "$1" =~ ^[A-Za-z0-9]$ ]]
}

list_backup_profiles() {
    local file

    ensure_backup_dirs
    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        local profile_name
        profile_name="$(basename "$file" .conf)"
        valid_profile_name "$profile_name" && printf '%s\n' "$profile_name"
    done < <(find "$BACKUP_STATE_DIR" -maxdepth 1 -type f -name '*.conf' -print | sort)
}

select_backup_profile() {
    local profiles=()
    local profile
    local choice

    while IFS= read -r profile; do
        [[ -n "$profile" ]] && profiles+=("$profile")
    done < <(list_backup_profiles)

    if [[ "${#profiles[@]}" -eq 0 ]]; then
        warning "No backup profiles configured."
        echo "Create one with:"
        echo "hostctl --db-backup"
        return 1
    fi

    echo "Select backup profile:" >&2
    echo >&2
    local i
    for i in "${!profiles[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${profiles[$i]}" >&2
    done

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${#profiles[@]}]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-${#profiles[@]}]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#profiles[@]} )); then
            printf '%s\n' "${profiles[$((choice - 1))]}"
            return 0
        fi
        warning "Invalid selection."
    done
}

env_file_value() {
    local file="$1"
    local key="$2"
    local line
    local value

    [[ -f "$file" ]] || return 1
    line="$(awk -F= -v key="$key" '$1 == key { print substr($0, index($0, "=") + 1); exit }' "$file")"
    [[ -n "$line" ]] || return 1
    value="$line"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"
    printf '%s\n' "$value"
}

read_secret() {
    local prompt="$1"
    local value

    if [[ -r /dev/tty ]]; then
        read -r -s -p "$prompt: " value </dev/tty || return 1
        echo >/dev/tty
    else
        read -r -s -p "$prompt: " value || return 1
        echo
    fi

    printf '%s\n' "$value"
}

backup_disk_space_check() {
    local target_dir="$1"
    local available

    mkdir -p "$target_dir"
    available="$(df -Pk "$target_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    [[ "$available" =~ ^[0-9]+$ ]] || return 0

    info "Available backup storage: $(df -Ph "$target_dir" 2>/dev/null | awk 'NR == 2 { print $4 }')"
    if (( available < BACKUP_LOW_SPACE_KB )); then
        warning "Available disk space is low."
        if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
            error "Cron backup aborted because available disk space is below threshold."
            return 1
        fi
        confirm "Continue?" "no"
    fi
}

profile_key_allowed() {
    case "$1" in
        PROFILE_NAME|SOURCE_MODE|DB_TYPE|PROJECT_DIR|COMPOSE_FILE|ENV_FILE|DB_SERVICE|DB_HOST|DB_PORT|DB_NAME|DB_USER|DB_NAME_VAR|DB_USER_VAR|DB_PASSWORD_VAR|CREDENTIAL_SOURCE|DESTINATION|LOCAL_PATH|LOCAL_RETENTION_DAYS|RCLONE_REMOTE|RCLONE_PATH)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

set_backup_config_value() {
    local key="$1"
    local value="$2"

    case "$key" in
        PROFILE_NAME) BACKUP_PROFILE_NAME="$value" ;;
        SOURCE_MODE) BACKUP_SOURCE_MODE="$value" ;;
        DB_TYPE) BACKUP_DB_TYPE="$value" ;;
        PROJECT_DIR) BACKUP_PROJECT_DIR="$value" ;;
        COMPOSE_FILE) BACKUP_COMPOSE_FILE="$value" ;;
        ENV_FILE) BACKUP_ENV_FILE="$value" ;;
        DB_SERVICE) BACKUP_DB_SERVICE="$value" ;;
        DB_HOST) BACKUP_DB_HOST="$value" ;;
        DB_PORT) BACKUP_DB_PORT="$value" ;;
        DB_NAME) BACKUP_DB_NAME="$value" ;;
        DB_USER) BACKUP_DB_USER="$value" ;;
        DB_NAME_VAR) BACKUP_DB_NAME_VAR="$value" ;;
        DB_USER_VAR) BACKUP_DB_USER_VAR="$value" ;;
        DB_PASSWORD_VAR) BACKUP_DB_PASSWORD_VAR="$value" ;;
        CREDENTIAL_SOURCE) BACKUP_CREDENTIAL_SOURCE="$value" ;;
        DESTINATION) BACKUP_DESTINATION="$value" ;;
        LOCAL_PATH) BACKUP_LOCAL_PATH="$value" ;;
        LOCAL_RETENTION_DAYS) BACKUP_LOCAL_RETENTION_DAYS="$value" ;;
        RCLONE_REMOTE) BACKUP_RCLONE_REMOTE="$value" ;;
        RCLONE_PATH) BACKUP_RCLONE_PATH="$value" ;;
    esac
}

write_backup_profile() {
    local profile="$1"
    local path

    ensure_backup_dirs
    path="$(backup_profile_path "$profile")"

    {
        printf 'PROFILE_NAME=%s\n' "$profile"
        printf 'SOURCE_MODE=%s\n' "$BACKUP_SOURCE_MODE"
        printf 'DB_TYPE=%s\n' "$BACKUP_DB_TYPE"
        printf 'PROJECT_DIR=%s\n' "$BACKUP_PROJECT_DIR"
        printf 'COMPOSE_FILE=%s\n' "$BACKUP_COMPOSE_FILE"
        printf 'ENV_FILE=%s\n' "$BACKUP_ENV_FILE"
        printf 'DB_SERVICE=%s\n' "$BACKUP_DB_SERVICE"
        printf 'DB_HOST=%s\n' "$BACKUP_DB_HOST"
        printf 'DB_PORT=%s\n' "$BACKUP_DB_PORT"
        printf 'DB_NAME=%s\n' "$BACKUP_DB_NAME"
        printf 'DB_USER=%s\n' "$BACKUP_DB_USER"
        printf 'DB_NAME_VAR=%s\n' "$BACKUP_DB_NAME_VAR"
        printf 'DB_USER_VAR=%s\n' "$BACKUP_DB_USER_VAR"
        printf 'DB_PASSWORD_VAR=%s\n' "$BACKUP_DB_PASSWORD_VAR"
        printf 'CREDENTIAL_SOURCE=%s\n' "$BACKUP_CREDENTIAL_SOURCE"
        printf 'DESTINATION=%s\n' "$BACKUP_DESTINATION"
        printf 'LOCAL_PATH=%s\n' "$BACKUP_LOCAL_PATH"
        printf 'LOCAL_RETENTION_DAYS=%s\n' "$BACKUP_LOCAL_RETENTION_DAYS"
        printf 'RCLONE_REMOTE=%s\n' "$BACKUP_RCLONE_REMOTE"
        printf 'RCLONE_PATH=%s\n' "$BACKUP_RCLONE_PATH"
    } > "$path"

    chmod 600 "$path"
}

load_backup_profile() {
    local profile="$1"
    local path
    local line
    local key
    local value

    reset_backup_config
    valid_profile_name "$profile" || {
        error "Invalid backup profile name: ${profile}"
        return 1
    }
    path="$(backup_profile_path "$profile")"
    [[ -f "$path" ]] || {
        error "Backup profile not found: ${profile}"
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ -n "$line" && "$line" != \#* && "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        profile_key_allowed "$key" || continue
        set_backup_config_value "$key" "$value"
    done < "$path"

    BACKUP_PROFILE_NAME="${BACKUP_PROFILE_NAME:-$profile}"
    validate_loaded_backup_profile
}

backup_profile_value() {
    local profile="$1"
    local wanted_key="$2"
    local path
    local line
    local key
    local value

    valid_profile_name "$profile" || return 1
    path="$(backup_profile_path "$profile")"
    [[ -f "$path" ]] || return 1
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *=* ]] || continue
        key="${line%%=*}"
        value="${line#*=}"
        if [[ "$key" == "$wanted_key" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$path"
    return 1
}

validate_loaded_backup_profile() {
    case "$BACKUP_SOURCE_MODE" in docker|native) ;; *) error "Invalid profile source mode."; return 1 ;; esac
    case "$BACKUP_DB_TYPE" in postgres|mysql|mariadb) ;; *) error "Invalid profile database type."; return 1 ;; esac
    case "$BACKUP_DESTINATION" in local|remote|both) ;; *) error "Invalid profile destination."; return 1 ;; esac
    [[ -n "$BACKUP_LOCAL_RETENTION_DAYS" ]] || BACKUP_LOCAL_RETENTION_DAYS=7
    [[ "$BACKUP_LOCAL_RETENTION_DAYS" =~ ^[0-9]+$ ]] || BACKUP_LOCAL_RETENTION_DAYS=7
}

write_backup_run_state() {
    local profile="${1:-one-time}"
    local path

    ensure_backup_dirs
    path="$(backup_run_state_path "$profile")"
    {
        printf 'LAST_RUN=%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
        printf 'LAST_RESULT=%s\n' "$BACKUP_LAST_RESULT"
        printf 'LAST_LOCAL_FILE=%s\n' "$BACKUP_LAST_LOCAL_FILE"
        printf 'LAST_SIZE=%s\n' "$BACKUP_LAST_SIZE"
        printf 'LAST_REMOTE_RESULT=%s\n' "$BACKUP_LAST_REMOTE_RESULT"
        printf 'LAST_ERROR=%s\n' "$BACKUP_LAST_ERROR"
    } > "$path"
    chmod 600 "$path"
}

# ---------------------------------------------------------
# Configuration collection
# ---------------------------------------------------------

select_db_type() {
    local choice

    choice="$(
        select_option \
            "Database type:" \
            "PostgreSQL" \
            "MySQL" \
            "MariaDB"
    )" || return 1

    case "$choice" in
        "PostgreSQL") printf 'postgres\n' ;;
        "MySQL") printf 'mysql\n' ;;
        "MariaDB") printf 'mariadb\n' ;;
    esac
}

detect_docker_db_type_for_service() {
    local service="$1"
    local image
    local lowered

    image="$(compose_exec config 2>/dev/null | awk -v service="$service" '
        $1 == service ":" { in_service = 1; next }
        in_service && /^[[:space:]]{2}[A-Za-z0-9_.-]+:/ { exit }
        in_service && $1 == "image:" { print $2; exit }
    ' || true)"
    lowered="$(tr '[:upper:]' '[:lower:]' <<< "${service} ${image}")"

    case "$lowered" in
        *postgres*) printf 'postgres\n' ;;
        *mariadb*) printf 'mariadb\n' ;;
        *mysql*) printf 'mysql\n' ;;
        *) return 1 ;;
    esac
}

select_docker_db_service() {
    local candidates=()
    local service
    local db_type
    local choice

    while IFS= read -r service; do
        [[ -n "$service" ]] || continue
        if db_type="$(detect_docker_db_type_for_service "$service" 2>/dev/null)"; then
            candidates+=("${service}|${db_type}")
        elif [[ "$service" =~ (db|database|postgres|mysql|mariadb) ]]; then
            candidates+=("${service}|")
        fi
    done < <(get_compose_services || true)

    if [[ "${#candidates[@]}" -eq 1 ]]; then
        BACKUP_DB_SERVICE="${candidates[0]%%|*}"
        BACKUP_DB_TYPE="${candidates[0]#*|}"
        [[ -n "$BACKUP_DB_TYPE" ]] || BACKUP_DB_TYPE="$(select_db_type)"
        return 0
    fi

    if [[ "${#candidates[@]}" -gt 1 ]]; then
        echo "Detected database services:" >&2
        echo >&2
        local i
        for i in "${!candidates[@]}"; do
            printf '%d. %s\n' "$((i + 1))" "${candidates[$i]%%|*}" >&2
        done
        while true; do
            if [[ -r /dev/tty ]]; then
                read -r -p "Select [1-${#candidates[@]}]: " choice </dev/tty || return 1
            else
                read -r -p "Select [1-${#candidates[@]}]: " choice || return 1
            fi
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#candidates[@]} )); then
                BACKUP_DB_SERVICE="${candidates[$((choice - 1))]%%|*}"
                BACKUP_DB_TYPE="${candidates[$((choice - 1))]#*|}"
                [[ -n "$BACKUP_DB_TYPE" ]] || BACKUP_DB_TYPE="$(select_db_type)"
                return 0
            fi
            warning "Invalid selection."
        done
    fi

    BACKUP_DB_SERVICE="$(select_compose_service)" || return 1
    BACKUP_DB_TYPE="$(select_db_type)" || return 1
}

collect_docker_database_config() {
    BACKUP_SOURCE_MODE="docker"

    prepare_docker_project_command || return 1
    BACKUP_PROJECT_DIR="$DOCKER_PROJECT_DIR"
    BACKUP_COMPOSE_FILE="$COMPOSE_FILE"
    BACKUP_ENV_FILE="${ENV_FILE:-}"

    select_docker_db_service || return 1

    BACKUP_DB_NAME_VAR="$(ask_input "Database name env var" "DB_NAME")" || return 1
    BACKUP_DB_USER_VAR="$(ask_input "Database user env var" "DB_USER")" || return 1
    BACKUP_DB_PASSWORD_VAR="$(ask_input "Database password env var" "DB_PASSWORD")" || return 1
    BACKUP_CREDENTIAL_SOURCE="env"

    if [[ -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_DB_NAME="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_NAME_VAR" || true)"
        BACKUP_DB_USER="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_USER_VAR" || true)"
    fi

    [[ -n "$BACKUP_DB_NAME" ]] || BACKUP_DB_NAME="$(ask_input "Database name")" || return 1
    [[ -n "$BACKUP_DB_USER" ]] || BACKUP_DB_USER="$(ask_input "Database user")" || return 1
}

detect_native_db_types() {
    command_exists pg_dump && printf 'postgres\n'
    { command_exists mysqldump || command_exists mariadb-dump; } && printf 'mysql\n'
}

collect_native_database_config() {
    local detected=()
    local type

    BACKUP_SOURCE_MODE="native"
    while IFS= read -r type; do
        [[ -n "$type" ]] && detected+=("$type")
    done < <(detect_native_db_types | awk '!seen[$0]++')

    if [[ "${#detected[@]}" -eq 1 ]]; then
        BACKUP_DB_TYPE="${detected[0]}"
        echo "Detected database engine: ${BACKUP_DB_TYPE}"
        if ! confirm "Use this database engine?" "yes"; then
            BACKUP_DB_TYPE="$(select_db_type)"
        fi
    else
        BACKUP_DB_TYPE="$(select_db_type)"
    fi

    case "$BACKUP_DB_TYPE" in
        postgres) BACKUP_DB_PORT="$(ask_input "Port" "5432")" ;;
        mysql|mariadb) BACKUP_DB_PORT="$(ask_input "Port" "3306")" ;;
    esac
    BACKUP_DB_HOST="$(ask_input "Host" "127.0.0.1")" || return 1
    BACKUP_DB_NAME="$(ask_input "Database")" || return 1
    BACKUP_DB_USER="$(ask_input "Username")" || return 1

    local cred_choice
    cred_choice="$(
        select_option \
            "Credential source:" \
            "Existing environment/config" \
            "Environment file" \
            "Prompt securely now"
    )" || return 1

    case "$cred_choice" in
        "Existing environment/config")
            BACKUP_CREDENTIAL_SOURCE="existing"
            ;;
        "Environment file")
            BACKUP_ENV_FILE="$(prompt_manual_env_file "$(pwd)")" || return 1
            BACKUP_DB_PASSWORD_VAR="$(ask_input "Database password env var" "DB_PASSWORD")" || return 1
            BACKUP_CREDENTIAL_SOURCE="env"
            ;;
        "Prompt securely now")
            BACKUP_RUNTIME_PASSWORD="$(read_secret "Database password")" || return 1
            BACKUP_CREDENTIAL_SOURCE="prompt"
            ;;
    esac
}

ensure_rclone_available_for_backup() {
    if command_exists rclone; then
        return 0
    fi

    echo
    echo "rclone is required for remote backups."
    if ! confirm "Install rclone now?" "yes"; then
        warning "Remote backup cancelled."
        return 1
    fi

    if declare -F install_rclone >/dev/null 2>&1; then
        install_rclone
    else
        apt update
        apt install -y rclone
    fi
}

select_rclone_remote() {
    local remotes=()
    local remote
    local choice

    ensure_rclone_available_for_backup || return 1
    while IFS= read -r remote; do
        [[ -n "$remote" ]] && remotes+=("$remote")
    done < <(rclone listremotes 2>/dev/null || true)

    if [[ "${#remotes[@]}" -eq 0 ]]; then
        if confirm "Configure rclone now?" "yes"; then
            rclone config
        else
            return 1
        fi
        while IFS= read -r remote; do
            [[ -n "$remote" ]] && remotes+=("$remote")
        done < <(rclone listremotes 2>/dev/null || true)
    fi

    echo "Remote destination:" >&2
    echo >&2
    local i
    for i in "${!remotes[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${remotes[$i]}" >&2
    done
    printf '%d. Configure a new rclone remote\n' "$(( ${#remotes[@]} + 1 ))" >&2
    printf '%d. Cancel\n' "$(( ${#remotes[@]} + 2 ))" >&2

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-$(( ${#remotes[@]} + 2 ))]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-$(( ${#remotes[@]} + 2 ))]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#remotes[@]} )); then
                printf '%s\n' "${remotes[$((choice - 1))]}"
                return 0
            elif (( choice == ${#remotes[@]} + 1 )); then
                rclone config
                select_rclone_remote
                return
            elif (( choice == ${#remotes[@]} + 2 )); then
                return 1
            fi
        fi
        warning "Invalid selection."
    done
}

collect_destination_config() {
    local choice
    local default_profile

    choice="$(
        select_option \
            "Backup destination:" \
            "Local" \
            "Remote" \
            "Both"
    )" || return 1

    case "$choice" in
        "Local") BACKUP_DESTINATION="local" ;;
        "Remote") BACKUP_DESTINATION="remote" ;;
        "Both") BACKUP_DESTINATION="both" ;;
    esac

    default_profile="$(backup_config_default_profile_name)"
    if [[ "$BACKUP_DESTINATION" == "local" || "$BACKUP_DESTINATION" == "both" ]]; then
        BACKUP_LOCAL_PATH="$(ask_input "Local backup path" "${BACKUP_DATABASE_DIR}/${default_profile}")" || return 1
        BACKUP_LOCAL_RETENTION_DAYS="$(ask_input "Local retention days" "7")" || return 1
    else
        BACKUP_LOCAL_PATH="${BACKUP_DATABASE_DIR}/${default_profile}"
        BACKUP_LOCAL_RETENTION_DAYS=7
    fi

    if [[ "$BACKUP_DESTINATION" == "remote" || "$BACKUP_DESTINATION" == "both" ]]; then
        BACKUP_RCLONE_REMOTE="$(select_rclone_remote)" || return 1
        BACKUP_RCLONE_PATH="$(ask_input "Remote backup path" "hostctl/backups/${default_profile}")" || return 1
    fi
}

collect_backup_config() {
    local source

    reset_backup_config
    source="$(
        select_option \
            "Database source:" \
            "Docker" \
            "Native / OS"
    )" || return 1

    case "$source" in
        "Docker") collect_docker_database_config ;;
        "Native / OS") collect_native_database_config ;;
    esac

    collect_destination_config
}

# ---------------------------------------------------------
# Backup engine
# ---------------------------------------------------------

backup_resolve_runtime_values() {
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        COMPOSE_FILE="$BACKUP_COMPOSE_FILE"
        ENV_FILE="$BACKUP_ENV_FILE"
        DOCKER_PROJECT_DIR="$BACKUP_PROJECT_DIR"

        if [[ ! -f "$COMPOSE_FILE" ]]; then
            if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
                error "Saved compose file does not exist: ${COMPOSE_FILE}"
                return 1
            fi
            warning "Saved compose file no longer exists: ${COMPOSE_FILE}"
            COMPOSE_FILE="$(prompt_manual_compose_file)" || return 1
            BACKUP_COMPOSE_FILE="$COMPOSE_FILE"
            DOCKER_PROJECT_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd -P)" || return 1
            BACKUP_PROJECT_DIR="$DOCKER_PROJECT_DIR"
            if confirm "Update saved profile with new path?" "yes"; then
                write_backup_profile "$BACKUP_PROFILE_NAME"
            fi
        fi
    fi

    if [[ -z "$BACKUP_DB_NAME" && -n "$BACKUP_DB_NAME_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_DB_NAME="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_NAME_VAR" || true)"
    fi
    if [[ -z "$BACKUP_DB_USER" && -n "$BACKUP_DB_USER_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_DB_USER="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_USER_VAR" || true)"
    fi

    [[ -n "$BACKUP_DB_NAME" ]] || { error "Database name is missing."; return 1; }
    [[ -n "$BACKUP_DB_USER" ]] || { error "Database user is missing."; return 1; }

    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "env" ]]; then
        if [[ -z "$BACKUP_ENV_FILE" || ! -f "$BACKUP_ENV_FILE" ]]; then
            error "Configured environment file is missing: ${BACKUP_ENV_FILE:-none}"
            return 1
        fi
        if [[ -n "$BACKUP_DB_PASSWORD_VAR" ]] &&
           ! env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_PASSWORD_VAR" >/dev/null 2>&1; then
            error "Database password variable not found in environment file: ${BACKUP_DB_PASSWORD_VAR}"
            return 1
        fi
    fi

    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "prompt" && "$BACKUP_CRON_MODE" -eq 1 ]]; then
        error "Scheduled profiles require a non-interactive credential source."
        return 1
    fi

    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "prompt" && -z "$BACKUP_RUNTIME_PASSWORD" ]]; then
        BACKUP_RUNTIME_PASSWORD="$(read_secret "Database password")" || return 1
    fi
}

backup_password_env_prefix() {
    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "env" && -n "$BACKUP_ENV_FILE" && -n "$BACKUP_DB_PASSWORD_VAR" ]]; then
        env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_PASSWORD_VAR" || true
    elif [[ "$BACKUP_CREDENTIAL_SOURCE" == "prompt" ]]; then
        printf '%s\n' "$BACKUP_RUNTIME_PASSWORD"
    fi
}

docker_dump_database_to_sql() {
    local sql_file="$1"
    local password

    case "$BACKUP_DB_TYPE" in
        postgres)
            info "Creating PostgreSQL dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                compose_exec exec -T -e "PGPASSWORD=${password}" "$BACKUP_DB_SERVICE" \
                    pg_dump -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            else
                compose_exec exec -T "$BACKUP_DB_SERVICE" \
                    pg_dump -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            fi
            ;;
        mysql|mariadb)
            info "Creating MySQL/MariaDB dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                compose_exec exec -T -e "MYSQL_PWD=${password}" "$BACKUP_DB_SERVICE" \
                    sh -c "command -v mariadb-dump >/dev/null 2>&1 && exec mariadb-dump --no-tablespaces -u \"\$1\" \"\$2\" || exec mysqldump --no-tablespaces -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            else
                compose_exec exec -T "$BACKUP_DB_SERVICE" \
                    sh -c "command -v mariadb-dump >/dev/null 2>&1 && exec mariadb-dump --no-tablespaces -u \"\$1\" \"\$2\" || exec mysqldump --no-tablespaces -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            fi
            ;;
    esac
}

native_dump_database_to_sql() {
    local sql_file="$1"
    local password
    local dump_cmd

    case "$BACKUP_DB_TYPE" in
        postgres)
            command_exists pg_dump || { error "pg_dump not found."; return 1; }
            info "Creating PostgreSQL dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                PGPASSWORD="$password" pg_dump -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            else
                pg_dump -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            fi
            ;;
        mysql|mariadb)
            if command_exists mariadb-dump; then
                dump_cmd="mariadb-dump"
            elif command_exists mysqldump; then
                dump_cmd="mysqldump"
            else
                error "mysqldump/mariadb-dump not found."
                return 1
            fi
            info "Creating MySQL/MariaDB dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                MYSQL_PWD="$password" "$dump_cmd" --no-tablespaces -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            else
                "$dump_cmd" --no-tablespaces -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" > "$sql_file"
            fi
            ;;
    esac
}

dump_database_to_sql() {
    local sql_file="$1"

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        docker_dump_database_to_sql "$sql_file"
    else
        native_dump_database_to_sql "$sql_file"
    fi
}

validate_backup_file() {
    local file="$1"
    local preview

    [[ -f "$file" && -s "$file" ]] || {
        error "Backup file is missing or empty: ${file}"
        return 1
    }

    gzip -t "$file" || {
        error "Backup gzip integrity check failed: ${file}"
        return 1
    }

    preview="$(gzip -dc "$file" 2>/dev/null | awk 'NR <= 40 { print }' || true)"
    if ! grep -Eq 'PostgreSQL database dump|MySQL dump|MariaDB dump|CREATE|INSERT|SET' <<< "$preview"; then
        warning "Backup content did not match common SQL dump markers."
    fi
}

create_database_dump() {
    local output_file="$1"
    local tmp_sql
    local tmp_gz

    tmp_sql="${output_file}.sql.tmp"
    tmp_gz="${output_file}.tmp"
    rm -f "$tmp_sql" "$tmp_gz"

    if ! dump_database_to_sql "$tmp_sql"; then
        rm -f "$tmp_sql" "$tmp_gz"
        return 1
    fi

    [[ -s "$tmp_sql" ]] || {
        rm -f "$tmp_sql" "$tmp_gz"
        error "Database dump produced an empty file."
        return 1
    }

    gzip -c "$tmp_sql" > "$tmp_gz" || {
        rm -f "$tmp_sql" "$tmp_gz"
        return 1
    }
    rm -f "$tmp_sql"

    validate_backup_file "$tmp_gz" || {
        rm -f "$tmp_gz"
        return 1
    }

    mv "$tmp_gz" "$output_file"
    success "Database dump created."
    success "Backup integrity verified."
}

backup_filename() {
    local prefix="${1:-}"
    local db

    db="$(sanitize_backup_name "${BACKUP_DB_NAME:-database}")"
    [[ -n "$prefix" ]] && db="${prefix}_${db}"
    printf '%s_%s.sql.gz\n' "$db" "$(date '+%Y%m%d_%H%M%S')"
}

rclone_remote_target() {
    printf '%s%s\n' "$BACKUP_RCLONE_REMOTE" "$BACKUP_RCLONE_PATH"
}

upload_backup_remote() {
    local file="$1"

    ensure_rclone_available_for_backup || return 1
    info "Uploading backup via rclone..."
    rclone copy "$file" "$(rclone_remote_target)" || return 1
    success "Remote backup completed."
}

apply_local_retention() {
    local path="$1"
    local days="$2"

    [[ "$days" =~ ^[0-9]+$ ]] || days=7
    case "$path" in
        "$HOSTCTL_BACKUP_DIR"|"$HOSTCTL_BACKUP_DIR"/*) ;;
        *)
            warning "Skipping retention outside hostctl backup directory: ${path}"
            return 0
            ;;
    esac

    find "$path" -maxdepth 1 -type f -name '*.sql.gz' -mtime "+${days}" -print |
        while IFS= read -r old_file; do
            rm -f "$old_file"
        done
}

run_database_backup() {
    local profile="${1:-one-time}"
    local prefix="${2:-}"
    local local_required="no"
    local remote_required="no"
    local output_dir
    local output_file
    local exit_code=0

    ensure_backup_dirs
    backup_resolve_runtime_values || return 1

    case "$BACKUP_DESTINATION" in
        local) local_required="yes" ;;
        remote) remote_required="yes" ;;
        both) local_required="yes"; remote_required="yes" ;;
    esac

    output_dir="$BACKUP_LOCAL_PATH"
    [[ -n "$output_dir" ]] || output_dir="${BACKUP_DATABASE_DIR}/$(sanitize_backup_name "$profile")"
    mkdir -p "$output_dir"
    chmod 700 "$output_dir" 2>/dev/null || true
    backup_disk_space_check "$output_dir" || return 1

    output_file="${output_dir}/$(backup_filename "$prefix")"

    if ! create_database_dump "$output_file"; then
        BACKUP_LAST_RESULT="Failed"
        BACKUP_LAST_ERROR="BACKUP FAILED"
        [[ "$profile" != "one-time" ]] && write_backup_run_state "$profile"
        return 1
    fi

    BACKUP_LAST_LOCAL_FILE="$output_file"
    BACKUP_LAST_SIZE="$(human_size "$output_file")"
    BACKUP_LAST_REMOTE_RESULT="Skipped"
    success "Local backup completed."

    if [[ "$remote_required" == "yes" ]]; then
        if upload_backup_remote "$output_file"; then
            BACKUP_LAST_REMOTE_RESULT="Success"
            if [[ "$BACKUP_DESTINATION" == "remote" ]]; then
                rm -f "$output_file"
                BACKUP_LAST_LOCAL_FILE="removed after remote upload"
            fi
        else
            BACKUP_LAST_REMOTE_RESULT="Failed"
            BACKUP_LAST_ERROR="REMOTE UPLOAD FAILED"
            error "Remote upload failed."
            echo
            echo "Local backup preserved:"
            printf '%s\n' "$output_file"
            exit_code=2
        fi
    fi

    if [[ "$local_required" == "yes" ]]; then
        apply_local_retention "$output_dir" "$BACKUP_LOCAL_RETENTION_DAYS" || warning "Retention cleanup failed."
    fi

    if [[ "$exit_code" -eq 0 ]]; then
        BACKUP_LAST_RESULT="Success"
        BACKUP_LAST_ERROR=""
        success "Backup completed successfully."
    else
        BACKUP_LAST_RESULT="Partial"
    fi

    echo
    echo "Backup:"
    printf '%s\n' "$BACKUP_LAST_LOCAL_FILE"
    echo
    echo "Size:"
    printf '%s\n' "$BACKUP_LAST_SIZE"

    [[ "$profile" != "one-time" ]] && write_backup_run_state "$profile"
    return "$exit_code"
}

with_backup_lock() {
    local profile="$1"
    shift
    local lock_name
    local lock_path

    lock_name="$(sanitize_backup_name "$profile")"
    lock_path="/tmp/hostctl-backup-${lock_name}.lock"

    if command_exists flock; then
        (
            flock -n 9 || {
                warning "Backup already running for profile: ${profile}"
                exit 0
            }
            "$@"
        ) 9>"$lock_path"
    else
        "$@"
    fi
}

# ---------------------------------------------------------
# Profiles / scheduling / status
# ---------------------------------------------------------

save_profile_interactive() {
    local default_name
    local profile
    local existing_action

    default_name="$(backup_config_default_profile_name)"

    while true; do
        profile="$(ask_input "Profile name" "$default_name")" || return 1
        profile="$(sanitize_backup_name "$profile")"
        valid_profile_name "$profile" || {
            warning "Invalid profile name."
            continue
        }

        if [[ -f "$(backup_profile_path "$profile")" ]]; then
            echo
            echo "Profile already exists."
            echo
            existing_action="$(
                select_option \
                    "Profile action:" \
                    "Update existing profile" \
                    "Choose another name" \
                    "Cancel profile creation"
            )" || return 1
            case "$existing_action" in
                "Update existing profile")
                    backup_file "$(backup_profile_path "$profile")" >/dev/null 2>&1 || true
                    ;;
                "Choose another name")
                    continue
                    ;;
                "Cancel profile creation")
                    warning "Profile creation cancelled."
                    return 0
                    ;;
            esac
        fi

        BACKUP_PROFILE_NAME="$profile"
        write_backup_profile "$profile" || return 1
        success "Backup profile created: ${profile}"
        log_event "BACKUP_PROFILE_SAVE profile=${profile} result=success"
        if confirm "Schedule this backup profile now?" "no"; then
            schedule_backup_profile "$profile"
        fi
        return 0
    done
}

inspect_backup_profile() {
    local profile="$1"

    load_backup_profile "$profile" || return 1
    echo
    printf 'Profile: %s\n' "$BACKUP_PROFILE_NAME"
    printf 'Source: %s / %s\n' "$BACKUP_SOURCE_MODE" "$BACKUP_DB_TYPE"
    printf 'Database: %s\n' "$BACKUP_DB_NAME"
    printf 'User: %s\n' "$BACKUP_DB_USER"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        printf 'Project: %s\n' "$BACKUP_PROJECT_DIR"
        printf 'Compose: %s\n' "$BACKUP_COMPOSE_FILE"
        printf 'Environment: %s\n' "${BACKUP_ENV_FILE:-none}"
        printf 'Service: %s\n' "$BACKUP_DB_SERVICE"
    else
        printf 'Host: %s\n' "$BACKUP_DB_HOST"
        printf 'Port: %s\n' "$BACKUP_DB_PORT"
        printf 'Credential source: %s\n' "$BACKUP_CREDENTIAL_SOURCE"
    fi
    printf 'Destination: %s\n' "$BACKUP_DESTINATION"
    printf 'Local path: %s\n' "$BACKUP_LOCAL_PATH"
    printf 'Retention: %s days\n' "$BACKUP_LOCAL_RETENTION_DAYS"
    if [[ -n "$BACKUP_RCLONE_REMOTE" ]]; then
        printf 'Remote: %s%s\n' "$BACKUP_RCLONE_REMOTE" "$BACKUP_RCLONE_PATH"
    fi
}

delete_backup_profile() {
    local profile="$1"
    local path

    path="$(backup_profile_path "$profile")"
    [[ -f "$path" ]] || {
        warning "Profile not found: ${profile}"
        return 0
    }

    if ! confirm "Delete backup profile \"${profile}\"?" "no"; then
        warning "Profile deletion cancelled."
        return 0
    fi

    if crontab -l 2>/dev/null | grep -Fq "# HOSTCTL:backup:${profile}"; then
        warning "Profile has an active backup schedule."
        if confirm "Remove its cron schedule too?" "yes"; then
            remove_backup_schedule "$profile"
        fi
    fi

    backup_file "$path" >/dev/null 2>&1 || true
    rm -f "$path"
    log_event "BACKUP_PROFILE_DELETE profile=${profile} result=success"
    success "Backup profile deleted: ${profile}"
}

cron_expression_valid() {
    local expr="$1"
    local fields

    fields="$(awk '{ print NF }' <<< "$expr")"
    [[ "$fields" -eq 5 ]] || return 1
    [[ "$expr" != *[\'\"\`\\]* ]]
}

schedule_expression_interactive() {
    local choice
    local time
    local day
    local expr
    local hour
    local minute

    choice="$(
        select_option \
            "Backup Schedule" \
            "Daily once" \
            "Weekly once" \
            "Daily at specific time" \
            "Weekly at specific day/time" \
            "Custom cron expression" \
            "Remove existing schedule" \
            "Cancel"
    )" || return 1

    case "$choice" in
        "Daily once")
            printf '0 2 * * *\n'
            ;;
        "Weekly once")
            printf '0 3 * * 0\n'
            ;;
        "Daily at specific time")
            time="$(ask_input "Time (HH:MM)" "02:00")" || return 1
            hour="${time%%:*}"
            minute="${time#*:}"
            [[ "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ && "$hour" -le 23 && "$minute" -le 59 ]] || {
                error "Invalid time."
                return 1
            }
            printf '%d %d * * *\n' "$minute" "$hour"
            ;;
        "Weekly at specific day/time")
            day="$(ask_input "Day of week (0-6, Sunday=0)" "0")" || return 1
            time="$(ask_input "Time (HH:MM)" "03:00")" || return 1
            hour="${time%%:*}"
            minute="${time#*:}"
            [[ "$day" =~ ^[0-6]$ && "$hour" =~ ^[0-9]+$ && "$minute" =~ ^[0-9]+$ && "$hour" -le 23 && "$minute" -le 59 ]] || {
                error "Invalid day/time."
                return 1
            }
            printf '%d %d * * %d\n' "$minute" "$hour" "$day"
            ;;
        "Custom cron expression")
            expr="$(ask_input "Cron expression")" || return 1
            cron_expression_valid "$expr" || {
                error "Invalid cron expression."
                return 1
            }
            printf '%s\n' "$expr"
            ;;
        "Remove existing schedule")
            printf 'REMOVE\n'
            ;;
        "Cancel")
            printf 'CANCEL\n'
            ;;
    esac
}

remove_backup_schedule() {
    local profile="$1"
    local temp

    temp="$(mktemp)"
    crontab -l 2>/dev/null | grep -Fv "# HOSTCTL:backup:${profile}" > "$temp" || true
    crontab "$temp"
    rm -f "$temp"
    log_event "BACKUP_SCHEDULE_REMOVE profile=${profile} result=success"
    success "Backup schedule removed: ${profile}"
}

schedule_backup_profile() {
    local profile="$1"
    local expr
    local temp
    local command

    load_backup_profile "$profile" || return 1
    expr="$(schedule_expression_interactive)" || return 1

    case "$expr" in
        REMOVE) remove_backup_schedule "$profile"; return ;;
        CANCEL) warning "Backup schedule cancelled."; return 0 ;;
    esac

    echo
    printf 'Profile: %s\n' "$profile"
    printf 'Schedule: %s\n' "$expr"
    printf 'Destination: %s\n' "$BACKUP_DESTINATION"
    echo

    if ! confirm "Create/update schedule?" "yes"; then
        warning "Backup schedule cancelled."
        return 0
    fi

    command="/usr/local/bin/hostctl --backup-now --profile ${profile} --cron >> ${HOSTCTL_LOG_DIR}/backup-${profile}.log 2>&1 # HOSTCTL:backup:${profile}"
    temp="$(mktemp)"
    crontab -l 2>/dev/null | grep -Fv "# HOSTCTL:backup:${profile}" > "$temp" || true
    printf '%s %s\n' "$expr" "$command" >> "$temp"
    crontab "$temp"
    rm -f "$temp"
    log_event "BACKUP_SCHEDULE profile=${profile} expression=${expr} result=success"
    success "Backup schedule configured: ${profile}"
}

run_profile_now() {
    local profile="$1"

    load_backup_profile "$profile" || return 1
    with_backup_lock "$profile" run_database_backup "$profile"
}

show_backup_status_for_profile() {
    local profile="$1"
    local state_file
    local line
    local key
    local value
    local last_run=""
    local result=""
    local latest=""
    local size=""
    local remote=""
    local schedule="not scheduled"

    load_backup_profile "$profile" || return 0
    state_file="$(backup_run_state_path "$profile")"
    if [[ -f "$state_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            key="${line%%=*}"
            value="${line#*=}"
            case "$key" in
                LAST_RUN) last_run="$value" ;;
                LAST_RESULT) result="$value" ;;
                LAST_LOCAL_FILE) latest="$value" ;;
                LAST_SIZE) size="$value" ;;
                LAST_REMOTE_RESULT) remote="$value" ;;
            esac
        done < "$state_file"
    fi

    if crontab -l 2>/dev/null | grep -F "# HOSTCTL:backup:${profile}" >/dev/null; then
        schedule="$(crontab -l 2>/dev/null | awk -v marker="# HOSTCTL:backup:${profile}" 'index($0, marker) { print $1, $2, $3, $4, $5; exit }')"
    fi

    printf '   Source: %s / %s\n' "$BACKUP_SOURCE_MODE" "$BACKUP_DB_TYPE"
    printf '   Database: %s\n' "$BACKUP_DB_NAME"
    printf '   Destination: %s\n' "$BACKUP_DESTINATION"
    printf '   Local path: %s\n' "$BACKUP_LOCAL_PATH"
    [[ -n "$BACKUP_RCLONE_REMOTE" ]] && printf '   Remote: %s%s\n' "$BACKUP_RCLONE_REMOTE" "$BACKUP_RCLONE_PATH"
    printf '   Retention: %s days\n' "$BACKUP_LOCAL_RETENTION_DAYS"
    echo
    printf '   Schedule: %s\n' "$schedule"
    printf '   Last run: %s\n' "${last_run:-never}"
    printf '   Result: %s\n' "${result:-unknown}"
    printf '   Latest backup: %s\n' "${latest:-none}"
    printf '   Size: %s\n' "${size:-unknown}"
    printf '   Remote upload: %s\n' "${remote:-unknown}"
}

cmd_backup_status() {
    local profiles=()
    local profile
    local index=0

    require_root
    require_debian_based
    ensure_backup_dirs

    while IFS= read -r profile; do
        [[ -n "$profile" ]] && profiles+=("$profile")
    done < <(list_backup_profiles)

    echo
    echo "Backup Status"
    echo
    printf 'Profiles: %d\n' "${#profiles[@]}"
    echo

    for profile in "${profiles[@]}"; do
        index=$((index + 1))
        printf '%d. %s\n' "$index" "$profile"
        show_backup_status_for_profile "$profile"
        echo
    done
}

cmd_backup_schedule() {
    local profile

    require_root
    require_debian_based
    ensure_backup_dirs

    profile="$(select_backup_profile)" || return 0
    schedule_backup_profile "$profile"
}

cmd_db_backup() {
    local action
    local profile

    require_root
    require_debian_based
    ensure_backup_dirs

    echo
    echo "Database Backup Profiles"
    echo

    action="$(
        select_option \
            "Database Backup Profiles" \
            "Create profile" \
            "List profiles" \
            "Inspect profile" \
            "Edit profile" \
            "Delete profile" \
            "Run profile now" \
            "Cancel"
    )" || return 1

    case "$action" in
        "Create profile")
            collect_backup_config || return 0
            if confirm "Test database connection now?" "yes"; then
                if ! test_database_connection; then
                    warning "Database connection test failed."
                    local failed_action
                    failed_action="$(
                        select_option \
                            "Connection test:" \
                            "Fix configuration" \
                            "Save profile anyway" \
                            "Cancel"
                    )" || return 1
                    case "$failed_action" in
                        "Fix configuration") collect_backup_config || return 0 ;;
                        "Cancel") warning "Profile creation cancelled."; return 0 ;;
                    esac
                fi
            fi
            save_profile_interactive
            ;;
        "List profiles")
            list_backup_profiles
            ;;
        "Inspect profile")
            profile="$(select_backup_profile)" || return 0
            inspect_backup_profile "$profile"
            ;;
        "Edit profile")
            profile="$(select_backup_profile)" || return 0
            backup_file "$(backup_profile_path "$profile")" >/dev/null 2>&1 || true
            collect_backup_config || return 0
            BACKUP_PROFILE_NAME="$profile"
            write_backup_profile "$profile"
            success "Backup profile updated: ${profile}"
            ;;
        "Delete profile")
            profile="$(select_backup_profile)" || return 0
            delete_backup_profile "$profile"
            ;;
        "Run profile now")
            profile="$(select_backup_profile)" || return 0
            run_profile_now "$profile"
            ;;
        "Cancel")
            warning "Backup profile management cancelled."
            ;;
    esac
}

test_database_connection() {
    local temp

    temp="$(mktemp)"
    backup_resolve_runtime_values || {
        rm -f "$temp"
        return 1
    }
    if dump_database_to_sql "$temp"; then
        rm -f "$temp"
        success "Database connection test succeeded."
        return 0
    fi
    rm -f "$temp"
    return 1
}

parse_backup_now_args() {
    local arg

    while [[ $# -gt 0 ]]; do
        arg="$1"
        case "$arg" in
            --profile)
                shift
                if [[ $# -eq 0 || "${1:-}" == --* ]]; then
                    error "--profile requires a profile name."
                    return 1
                fi
                valid_profile_name "$1" || {
                    error "Invalid backup profile name: $1"
                    return 1
                }
                BACKUP_PROFILE_NAME="${1:-}"
                ;;
            --cron)
                BACKUP_CRON_MODE=1
                ;;
            *)
                error "Unknown backup option: ${arg}"
                return 1
                ;;
        esac
        shift || true
    done
}

cmd_backup_now() {
    local save_status=0

    require_root
    require_debian_based
    ensure_backup_dirs
    BACKUP_CRON_MODE=0
    parse_backup_now_args "$@" || return 1

    if [[ "$BACKUP_CRON_MODE" -eq 0 ]]; then
        echo
        echo "Database Backup"
        echo
    fi

    if [[ -n "$BACKUP_PROFILE_NAME" ]]; then
        load_backup_profile "$BACKUP_PROFILE_NAME" || return 1
        with_backup_lock "$BACKUP_PROFILE_NAME" run_database_backup "$BACKUP_PROFILE_NAME"
        return
    fi

    collect_backup_config || return 0
    if ! confirm "Run backup?" "yes"; then
        warning "Backup cancelled."
        return 0
    fi

    run_database_backup "one-time" || save_status=$?

    if [[ "$save_status" -eq 0 ]]; then
        if confirm "Save this configuration as a backup profile?" "no"; then
            save_profile_interactive || warning "PROFILE SAVE FAILED"
        fi
    fi

    return "$save_status"
}

# ---------------------------------------------------------
# Restore
# ---------------------------------------------------------

select_local_restore_file() {
    local profiles=()
    local profile
    local choice
    local path

    while IFS= read -r profile; do
        [[ -n "$profile" ]] && profiles+=("$profile")
    done < <(list_backup_profiles)

    echo "Backup source:" >&2
    echo >&2
    local i
    for i in "${!profiles[@]}"; do
        printf '%d. Profile directory: %s\n' "$((i + 1))" "${profiles[$i]}" >&2
    done
    printf '%d. Enter backup file path\n' "$(( ${#profiles[@]} + 1 ))" >&2

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-$(( ${#profiles[@]} + 1 ))]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-$(( ${#profiles[@]} + 1 ))]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#profiles[@]} )); then
                path="$(backup_profile_value "${profiles[$((choice - 1))]}" "LOCAL_PATH")" || return 1
                select_backup_file_from_dir "$path"
                return
            elif (( choice == ${#profiles[@]} + 1 )); then
                path="$(ask_input "Backup file path")" || return 1
                printf '%s\n' "$path"
                return 0
            fi
        fi
        warning "Invalid selection."
    done
}

select_backup_file_from_dir() {
    local dir="$1"
    local files=()
    local file
    local choice

    while IFS= read -r file; do
        [[ -f "$file" ]] && files+=("$file")
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' \) -print | sort)

    [[ "${#files[@]}" -gt 0 ]] || {
        error "No backup files found in: ${dir}"
        return 1
    }

    echo "Backup files:" >&2
    local i
    for i in "${!files[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "$(basename "${files[$i]}")" >&2
    done
    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${#files[@]}]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-${#files[@]}]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
            printf '%s\n' "${files[$((choice - 1))]}"
            return 0
        fi
        warning "Invalid selection."
    done
}

validate_restore_file() {
    local file="$1"

    [[ -f "$file" && -s "$file" ]] || { error "Backup file not found or empty: ${file}"; return 1; }
    case "$file" in
        *.sql) return 0 ;;
        *.sql.gz) gzip -t "$file" ;;
        *) error "Unsupported backup format. Use .sql or .sql.gz."; return 1 ;;
    esac
}

download_remote_restore_file() {
    local profile
    local files=()
    local file
    local choice
    local remote_base
    local remote
    local remote_path
    local local_file

    profile="$(select_backup_profile)" || return 1
    remote="$(backup_profile_value "$profile" "RCLONE_REMOTE")" || return 1
    remote_path="$(backup_profile_value "$profile" "RCLONE_PATH")" || return 1
    ensure_rclone_available_for_backup || return 1
    remote_base="${remote}${remote_path}"

    while IFS= read -r file; do
        [[ -n "$file" ]] && files+=("$file")
    done < <(rclone lsf "$remote_base" --files-only 2>/dev/null | awk '/\.sql(\.gz)?$/')

    [[ "${#files[@]}" -gt 0 ]] || { error "No remote backup files found."; return 1; }
    echo "Remote backup files:" >&2
    local i
    for i in "${!files[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${files[$i]}" >&2
    done
    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${#files[@]}]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-${#files[@]}]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#files[@]} )); then
            file="${files[$((choice - 1))]}"
            break
        fi
        warning "Invalid selection."
    done

    mkdir -p "$BACKUP_RESTORE_TMP_DIR"
    local_file="${BACKUP_RESTORE_TMP_DIR}/${file}"
    rclone copyto "${remote_base}/${file}" "$local_file" || return 1
    validate_restore_file "$local_file" || return 1
    printf '%s\n' "$local_file"
}

restore_database_from_file() {
    local file="$1"
    local password

    backup_resolve_runtime_values || return 1
    password="$(backup_password_env_prefix)"

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        case "$BACKUP_DB_TYPE" in
            postgres)
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | compose_exec exec -T -e "PGPASSWORD=${password}" "$BACKUP_DB_SERVICE" psql -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | compose_exec exec -T "$BACKUP_DB_SERVICE" psql -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        compose_exec exec -T -e "PGPASSWORD=${password}" "$BACKUP_DB_SERVICE" psql -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    else
                        compose_exec exec -T "$BACKUP_DB_SERVICE" psql -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
            mysql|mariadb)
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | compose_exec exec -T -e "MYSQL_PWD=${password}" "$BACKUP_DB_SERVICE" sh -c "command -v mariadb >/dev/null 2>&1 && exec mariadb -u \"\$1\" \"\$2\" || exec mysql -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | compose_exec exec -T "$BACKUP_DB_SERVICE" sh -c "command -v mariadb >/dev/null 2>&1 && exec mariadb -u \"\$1\" \"\$2\" || exec mysql -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        compose_exec exec -T -e "MYSQL_PWD=${password}" "$BACKUP_DB_SERVICE" sh -c "command -v mariadb >/dev/null 2>&1 && exec mariadb -u \"\$1\" \"\$2\" || exec mysql -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    else
                        compose_exec exec -T "$BACKUP_DB_SERVICE" sh -c "command -v mariadb >/dev/null 2>&1 && exec mariadb -u \"\$1\" \"\$2\" || exec mysql -u \"\$1\" \"\$2\"" sh "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
        esac
    else
        case "$BACKUP_DB_TYPE" in
            postgres)
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | PGPASSWORD="$password" psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        PGPASSWORD="$password" psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    else
                        psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
            mysql|mariadb)
                local mysql_cmd="mysql"
                command_exists mariadb && mysql_cmd="mariadb"
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | MYSQL_PWD="$password" "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        MYSQL_PWD="$password" "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    else
                        "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
        esac
    fi
}

cmd_db_restore() {
    local source_choice
    local file
    local confirm_name

    require_root
    require_debian_based
    ensure_backup_dirs

    echo
    echo "Database Restore"
    echo

    source_choice="$(
        select_option \
            "Target database:" \
            "Docker" \
            "Native / OS"
    )" || return 1

    case "$source_choice" in
        "Docker") collect_docker_database_config ;;
        "Native / OS") collect_native_database_config ;;
    esac

    source_choice="$(
        select_option \
            "Backup source:" \
            "Local" \
            "Remote via rclone"
    )" || return 1

    case "$source_choice" in
        "Local") file="$(select_local_restore_file)" || return 1 ;;
        "Remote via rclone") file="$(download_remote_restore_file)" || return 1 ;;
    esac

    validate_restore_file "$file" || return 1

    warning "Restore will overwrite/change the target database."
    echo
    printf 'Target: %s\n' "$BACKUP_DB_NAME"
    printf 'Backup: %s\n' "$(basename "$file")"
    echo

    if confirm "Create safety backup before restore?" "yes"; then
        local original_destination="$BACKUP_DESTINATION"
        BACKUP_DESTINATION="local"
        BACKUP_LOCAL_PATH="${BACKUP_DATABASE_DIR}/pre-restore"
        if ! run_database_backup "pre-restore-$(sanitize_backup_name "$BACKUP_DB_NAME")" "pre_restore"; then
            error "Safety backup failed."
            if ! confirm "Continue without safety backup?" "no"; then
                BACKUP_DESTINATION="$original_destination"
                return 1
            fi
        fi
        BACKUP_DESTINATION="$original_destination"
    fi

    confirm_name="$(ask_input "Type database name to confirm restore")" || return 1
    if [[ "$confirm_name" != "$BACKUP_DB_NAME" ]]; then
        warning "Restore cancelled."
        return 0
    fi

    restore_database_from_file "$file" || {
        log_event "RESTORE_FAILED database=${BACKUP_DB_NAME}"
        error "RESTORE FAILED"
        return 1
    }

    success "Database restore completed."
    success "Database connectivity verified."
    log_event "RESTORE database=${BACKUP_DB_NAME} result=success"
}
