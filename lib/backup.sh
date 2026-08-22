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
BACKUP_DOCKER_TARGET_TYPE=""
BACKUP_DOCKER_CONTAINER=""
BACKUP_DOCKER_IMAGE=""
BACKUP_DB_HOST=""
BACKUP_DB_PORT=""
BACKUP_DB_NAME=""
BACKUP_DB_USER=""
BACKUP_DB_NAME_VAR=""
BACKUP_DB_USER_VAR=""
BACKUP_DB_PASSWORD_VAR=""
BACKUP_DB_HOST_VAR=""
BACKUP_DB_PORT_VAR=""
BACKUP_MONGO_URI_VAR=""
BACKUP_MONGO_URI=""
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
BACKUP_PREFLIGHT_DONE=0

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
    BACKUP_DOCKER_TARGET_TYPE=""
    BACKUP_DOCKER_CONTAINER=""
    BACKUP_DOCKER_IMAGE=""
    BACKUP_DB_HOST=""
    BACKUP_DB_PORT=""
    BACKUP_DB_NAME=""
    BACKUP_DB_USER=""
    BACKUP_DB_NAME_VAR=""
    BACKUP_DB_USER_VAR=""
    BACKUP_DB_PASSWORD_VAR=""
    BACKUP_DB_HOST_VAR=""
    BACKUP_DB_PORT_VAR=""
    BACKUP_MONGO_URI_VAR=""
    BACKUP_MONGO_URI=""
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
    BACKUP_PREFLIGHT_DONE=0
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

ask_required_input() {
    local prompt="$1"
    local value

    while true; do
        value="$(ask_input "$prompt")" || return 1
        if [[ -n "$value" ]]; then
            printf '%s\n' "$value"
            return 0
        fi
        warning "${prompt} is required."
    done
}

backup_client_name() {
    case "$1" in
        postgresql|postgres) printf 'pg_dump\n' ;;
        mysql) printf 'mysqldump\n' ;;
        mariadb) printf 'mariadb-dump or mysqldump\n' ;;
        mongodb) printf 'mongodump\n' ;;
    esac
}

db_engine_label() {
    case "$1" in
        postgresql|postgres) printf 'PostgreSQL\n' ;;
        mysql) printf 'MySQL\n' ;;
        mariadb) printf 'MariaDB\n' ;;
        mongodb) printf 'MongoDB\n' ;;
        *) printf '%s\n' "$1" ;;
    esac
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
        PROFILE_NAME|SOURCE_MODE|DB_TYPE|PROJECT_DIR|COMPOSE_FILE|ENV_FILE|DB_SERVICE|DOCKER_TARGET_TYPE|DOCKER_CONTAINER|DOCKER_IMAGE|DB_HOST|DB_PORT|DB_NAME|DB_USER|DB_NAME_VAR|DB_USER_VAR|DB_PASSWORD_VAR|DB_HOST_VAR|DB_PORT_VAR|MONGO_URI_VAR|CREDENTIAL_SOURCE|DESTINATION|LOCAL_PATH|LOCAL_RETENTION_DAYS|RCLONE_REMOTE|RCLONE_PATH)
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
        DOCKER_TARGET_TYPE) BACKUP_DOCKER_TARGET_TYPE="$value" ;;
        DOCKER_CONTAINER) BACKUP_DOCKER_CONTAINER="$value" ;;
        DOCKER_IMAGE) BACKUP_DOCKER_IMAGE="$value" ;;
        DB_HOST) BACKUP_DB_HOST="$value" ;;
        DB_PORT) BACKUP_DB_PORT="$value" ;;
        DB_NAME) BACKUP_DB_NAME="$value" ;;
        DB_USER) BACKUP_DB_USER="$value" ;;
        DB_NAME_VAR) BACKUP_DB_NAME_VAR="$value" ;;
        DB_USER_VAR) BACKUP_DB_USER_VAR="$value" ;;
        DB_PASSWORD_VAR) BACKUP_DB_PASSWORD_VAR="$value" ;;
        DB_HOST_VAR) BACKUP_DB_HOST_VAR="$value" ;;
        DB_PORT_VAR) BACKUP_DB_PORT_VAR="$value" ;;
        MONGO_URI_VAR) BACKUP_MONGO_URI_VAR="$value" ;;
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
        printf 'DOCKER_TARGET_TYPE=%s\n' "$BACKUP_DOCKER_TARGET_TYPE"
        printf 'DOCKER_CONTAINER=%s\n' "$BACKUP_DOCKER_CONTAINER"
        printf 'DOCKER_IMAGE=%s\n' "$BACKUP_DOCKER_IMAGE"
        printf 'DB_HOST=%s\n' "$BACKUP_DB_HOST"
        printf 'DB_PORT=%s\n' "$BACKUP_DB_PORT"
        printf 'DB_NAME=%s\n' "$BACKUP_DB_NAME"
        printf 'DB_USER=%s\n' "$BACKUP_DB_USER"
        printf 'DB_NAME_VAR=%s\n' "$BACKUP_DB_NAME_VAR"
        printf 'DB_USER_VAR=%s\n' "$BACKUP_DB_USER_VAR"
        printf 'DB_PASSWORD_VAR=%s\n' "$BACKUP_DB_PASSWORD_VAR"
        printf 'DB_HOST_VAR=%s\n' "$BACKUP_DB_HOST_VAR"
        printf 'DB_PORT_VAR=%s\n' "$BACKUP_DB_PORT_VAR"
        printf 'MONGO_URI_VAR=%s\n' "$BACKUP_MONGO_URI_VAR"
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
    [[ "$BACKUP_DB_TYPE" == "postgres" ]] && BACKUP_DB_TYPE="postgresql"
    case "$BACKUP_DB_TYPE" in postgresql|mysql|mariadb|mongodb) ;; *) error "Invalid profile database type."; return 1 ;; esac
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
            "MariaDB" \
            "MongoDB"
    )" || return 1

    case "$choice" in
        "PostgreSQL") printf 'postgresql\n' ;;
        "MySQL") printf 'mysql\n' ;;
        "MariaDB") printf 'mariadb\n' ;;
        "MongoDB") printf 'mongodb\n' ;;
    esac
}

compose_exec_all_profiles() {
    if [[ -n "${ENV_FILE:-}" ]]; then
        docker compose --profile '*' --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@" 2>/dev/null ||
            docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
    else
        docker compose --profile '*' -f "$COMPOSE_FILE" "$@" 2>/dev/null ||
            docker compose -f "$COMPOSE_FILE" "$@"
    fi
}

get_all_compose_services() {
    compose_exec_all_profiles config --services
}

compose_service_block() {
    local service="$1"

    compose_exec_all_profiles config 2>/dev/null | awk -v service="$service" '
        $1 == service ":" { in_service = 1; next }
        in_service && /^[[:space:]]{2}[A-Za-z0-9_.-]+:/ { exit }
        in_service { print }
    ' || true
}

compose_service_image() {
    local service="$1"

    compose_service_block "$service" |
        awk '$1 == "image:" { print $2; exit }'
}

image_repo_name() {
    local image="$1"
    local repo

    image="${image%@*}"
    image="${image%%:*}"
    repo="${image##*/}"
    printf '%s\n' "$(tr '[:upper:]' '[:lower:]' <<< "$repo")"
}

image_matches_db_type() {
    local image="$1"
    local db_type="$2"
    local repo

    repo="$(image_repo_name "$image")"
    case "$db_type" in
        postgresql|postgres)
            [[ "$repo" == *postgres* || "$repo" == *postgresql* ]]
            ;;
        mysql)
            [[ "$repo" == *mysql* && "$repo" != *mariadb* ]]
            ;;
        mariadb)
            [[ "$repo" == *mariadb* ]]
            ;;
        mongodb)
            [[ "$repo" == *mongo* || "$repo" == *mongodb* ]]
            ;;
    esac
}

detect_docker_db_type_for_service() {
    local service="$1"
    local image

    image="$(compose_service_image "$service")"
    [[ -n "$image" ]] || return 1

    if image_matches_db_type "$image" postgresql; then
        printf 'postgresql\n'
    elif image_matches_db_type "$image" mariadb; then
        printf 'mariadb\n'
    elif image_matches_db_type "$image" mysql; then
        printf 'mysql\n'
    elif image_matches_db_type "$image" mongodb; then
        printf 'mongodb\n'
    else
        return 1
    fi
}

docker_target_exec() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        docker exec "$BACKUP_DOCKER_CONTAINER" "$@"
    else
        compose_exec exec -T "$BACKUP_DB_SERVICE" "$@"
    fi
}

docker_target_exec_input() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        docker exec -i "$BACKUP_DOCKER_CONTAINER" "$@"
    else
        compose_exec exec -T "$BACKUP_DB_SERVICE" "$@"
    fi
}

docker_target_label() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        printf 'container: %s\n' "$BACKUP_DOCKER_CONTAINER"
    else
        printf 'service: %s\n' "$BACKUP_DB_SERVICE"
    fi
}

docker_target_image() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        docker inspect -f '{{.Config.Image}}' "$BACKUP_DOCKER_CONTAINER" 2>/dev/null || true
    else
        compose_service_image "$BACKUP_DB_SERVICE"
    fi
}

select_custom_docker_target() {
    local target_type
    local input

    target_type="$(
        select_option \
            "Target type:" \
            "Compose service" \
            "Docker container"
    )" || return 1

    case "$target_type" in
        "Compose service")
            while true; do
                input="$(ask_required_input "Enter Compose service name")" || return 1
                if get_all_compose_services | awk -v service="$input" '$0 == service { found = 1 } END { exit found ? 0 : 1 }'; then
                    BACKUP_DOCKER_TARGET_TYPE="service"
                    BACKUP_DB_SERVICE="$input"
                    BACKUP_DOCKER_CONTAINER=""
                    return 0
                fi
                warning "Compose service not found: ${input}"
                confirm "Enter another service?" "yes" || return 1
            done
            ;;
        "Docker container")
            while true; do
                input="$(ask_required_input "Enter Docker container name or ID")" || return 1
                if docker inspect "$input" >/dev/null 2>&1; then
                    BACKUP_DOCKER_TARGET_TYPE="container"
                    BACKUP_DOCKER_CONTAINER="$input"
                    BACKUP_DB_SERVICE=""
                    return 0
                fi
                error "Docker container not found: ${input}"
                confirm "Enter another container?" "yes" || return 1
            done
            ;;
    esac
}

confirm_selected_docker_target() {
    local image

    image="$(docker_target_image)"
    BACKUP_DOCKER_IMAGE="$image"

    echo
    echo "Selected target:"
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        printf 'Container: %s\n' "$BACKUP_DOCKER_CONTAINER"
    else
        printf 'Service: %s\n' "$BACKUP_DB_SERVICE"
    fi
    printf 'Image: %s\n' "${image:-not declared}"
    echo

    if [[ -n "$image" ]] && ! image_matches_db_type "$image" "$BACKUP_DB_TYPE"; then
        warning "Selected target image does not appear to be $(db_engine_label "$BACKUP_DB_TYPE")."
        confirm "Continue with executable/connectivity verification anyway?" "no" || return 1
    fi
}

select_docker_image_candidate() {
    local candidates=("$@")
    local choice

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-$(( ${#candidates[@]} + 4 ))]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-$(( ${#candidates[@]} + 4 ))]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#candidates[@]} )); then
                BACKUP_DOCKER_TARGET_TYPE="service"
                BACKUP_DB_SERVICE="${candidates[$((choice - 1))]%%|*}"
                BACKUP_DOCKER_IMAGE="${candidates[$((choice - 1))]#*|}"
                return 0
            fi

            case "$(( choice - ${#candidates[@]} ))" in
                1) select_available_compose_service_target; return ;;
                2) select_custom_docker_target; return ;;
                3) collect_native_database_config; return ;;
                4) return 1 ;;
            esac
        fi
        warning "Invalid selection."
    done
}

select_available_compose_service_target() {
    local services=()
    local service
    local image
    local choice

    while IFS= read -r service; do
        [[ -n "$service" ]] && services+=("$service")
    done < <(get_all_compose_services || true)

    [[ "${#services[@]}" -gt 0 ]] || {
        warning "No Compose services were found."
        select_custom_docker_target
        return
    }

    echo
    echo "Available Compose services:"
    echo
    local i
    for i in "${!services[@]}"; do
        image="$(compose_service_image "${services[$i]}")"
        printf '%d. %s\n' "$((i + 1))" "${services[$i]}"
        printf '   Image: %s\n' "${image:-not declared}"
    done
    printf '%d. Custom service/container name\n' "$(( ${#services[@]} + 1 ))"
    printf '%d. Use native/external database\n' "$(( ${#services[@]} + 2 ))"
    printf '%d. Cancel\n' "$(( ${#services[@]} + 3 ))"

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-$(( ${#services[@]} + 3 ))]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-$(( ${#services[@]} + 3 ))]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#services[@]} )); then
                BACKUP_DOCKER_TARGET_TYPE="service"
                BACKUP_DB_SERVICE="${services[$((choice - 1))]}"
                BACKUP_DOCKER_IMAGE="$(compose_service_image "$BACKUP_DB_SERVICE")"
                return 0
            elif (( choice == ${#services[@]} + 1 )); then
                select_custom_docker_target
                return
            elif (( choice == ${#services[@]} + 2 )); then
                collect_native_database_config
                return
            elif (( choice == ${#services[@]} + 3 )); then
                return 1
            fi
        fi
        warning "Invalid selection."
    done
}

select_docker_db_service() {
    local services=()
    local candidates=()
    local service
    local image

    while IFS= read -r service; do
        [[ -n "$service" ]] && services+=("$service")
    done < <(get_all_compose_services || true)

    for service in "${services[@]}"; do
        image="$(compose_service_image "$service")"
        if [[ -n "$image" ]] && image_matches_db_type "$image" "$BACKUP_DB_TYPE"; then
            candidates+=("${service}|${image}")
        fi
    done

    if [[ "${#candidates[@]}" -gt 0 ]]; then
        echo
        printf '%s-compatible image detected:\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
        echo
        local i
        for i in "${!candidates[@]}"; do
            printf '%d. %s\n' "$((i + 1))" "${candidates[$i]%%|*}"
            printf '   Image: %s\n' "${candidates[$i]#*|}"
            echo
        done
        printf '%d. Select another available service\n' "$(( ${#candidates[@]} + 1 ))"
        printf '%d. Enter service/container manually\n' "$(( ${#candidates[@]} + 2 ))"
        printf '%d. Use native/external database\n' "$(( ${#candidates[@]} + 3 ))"
        printf '%d. Cancel\n' "$(( ${#candidates[@]} + 4 ))"
        select_docker_image_candidate "${candidates[@]}" || {
            info "Database backup cancelled."
            return 1
        }
    else
        warning "No $(db_engine_label "$BACKUP_DB_TYPE")-compatible service image was detected."
        local action
        action="$(
            select_option \
                "Database execution target:" \
                "Select from available Compose services" \
                "Enter service/container manually" \
                "Use native/external database" \
                "Cancel"
        )" || return 1
        case "$action" in
            "Select from available Compose services") select_available_compose_service_target ;;
            "Enter service/container manually") select_custom_docker_target ;;
            "Use native/external database") collect_native_database_config; return ;;
            "Cancel") info "Database backup cancelled."; return 1 ;;
        esac
    fi

    [[ "$BACKUP_SOURCE_MODE" == "native" ]] && return 0
    confirm_selected_docker_target
}

docker_service_has_client() {
    local service="${1:-$BACKUP_DB_SERVICE}"
    local db_type="$2"

    case "$db_type" in
        postgresql|postgres)
            docker_target_exec sh -c 'command -v pg_dump >/dev/null 2>&1'
            ;;
        mysql)
            docker_target_exec sh -c 'command -v mysqldump >/dev/null 2>&1'
            ;;
        mariadb)
            docker_target_exec sh -c 'command -v mariadb-dump >/dev/null 2>&1 || command -v mysqldump >/dev/null 2>&1'
            ;;
        mongodb)
            docker_target_exec sh -c 'command -v mongodump >/dev/null 2>&1'
            ;;
    esac
}

resolve_required_env_value() {
    local label="$1"
    local var_name_ref="$2"
    local value_name_ref="$3"
    local default_var="${!var_name_ref}"
    local action
    local value=""

    while true; do
        if [[ -n "$BACKUP_ENV_FILE" && -n "$default_var" ]]; then
            value="$(env_file_value "$BACKUP_ENV_FILE" "$default_var" || true)"
        fi

        if [[ -n "$value" ]]; then
            if [[ "$label" != "Database password" ]]; then
                printf '%s: %s\n' "$label" "$value" >&2
                printf -v "$value_name_ref" '%s' "$value"
            fi
            printf -v "$var_name_ref" '%s' "$default_var"
            return 0
        fi

        if [[ -n "$BACKUP_ENV_FILE" ]]; then
            warning "${default_var} was not found in:"
            warning "$BACKUP_ENV_FILE"
        else
            warning "No environment file is configured."
        fi

        action="$(
            select_option \
                "${label}:" \
                "Enter ${label} manually" \
                "Enter another variable name" \
                "Choose another env file" \
                "Cancel"
        )" || return 1

        case "$action" in
            "Enter ${label} manually")
                if [[ "$label" == "Database password" ]]; then
                    BACKUP_RUNTIME_PASSWORD="$(read_secret "$label")" || return 1
                    BACKUP_CREDENTIAL_SOURCE="prompt"
                    printf -v "$value_name_ref" ''
                else
                    value="$(ask_required_input "$label")" || return 1
                    printf -v "$value_name_ref" '%s' "$value"
                fi
                return 0
                ;;
            "Enter another variable name")
                default_var="$(ask_required_input "${label} env var")" || return 1
                ;;
            "Choose another env file")
                BACKUP_ENV_FILE="$(prompt_manual_env_file "${DOCKER_PROJECT_DIR:-$(pwd)}")" || return 1
                ;;
            "Cancel")
                return 1
                ;;
        esac
    done
}

default_db_port() {
    case "$1" in
        postgresql|postgres) printf '5432\n' ;;
        mysql|mariadb) printf '3306\n' ;;
        mongodb) printf '27017\n' ;;
    esac
}

resolve_optional_env_value() {
    local label="$1"
    local var_name="$2"
    local value_name_ref="$3"
    local default_value="$4"
    local value=""

    if [[ -n "$BACKUP_ENV_FILE" && -n "$var_name" ]]; then
        value="$(env_file_value "$BACKUP_ENV_FILE" "$var_name" || true)"
    fi

    if [[ -z "$value" ]]; then
        value="$(ask_input "$label" "$default_value")" || return 1
    else
        printf '%s: %s\n' "$label" "$value" >&2
    fi

    printf -v "$value_name_ref" '%s' "$value"
}

collect_mongodb_connection_config() {
    local mode

    mode="$(
        select_option \
            "MongoDB connection:" \
            "Connection URI" \
            "Host/port/database/user/password"
    )" || return 1

    case "$mode" in
        "Connection URI")
            BACKUP_MONGO_URI_VAR="$(ask_input "MongoDB URI env var" "MONGO_URI")" || return 1
            if [[ -n "$BACKUP_ENV_FILE" ]]; then
                BACKUP_MONGO_URI="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_MONGO_URI_VAR" || true)"
            fi
            if [[ -z "$BACKUP_MONGO_URI" ]]; then
                warning "${BACKUP_MONGO_URI_VAR} was not found in:"
                warning "${BACKUP_ENV_FILE:-no env file}"
                BACKUP_MONGO_URI="$(read_secret "MongoDB URI")" || return 1
                BACKUP_CREDENTIAL_SOURCE="prompt"
            else
                BACKUP_CREDENTIAL_SOURCE="env"
            fi
            BACKUP_DB_NAME="$(mongo_database_from_uri "$BACKUP_MONGO_URI")"
            [[ -n "$BACKUP_DB_NAME" ]] || BACKUP_DB_NAME="$(ask_required_input "MongoDB database")" || return 1
            ;;
        "Host/port/database/user/password")
            BACKUP_DB_HOST_VAR="$(ask_input "MongoDB host env var" "MONGO_HOST")" || return 1
            BACKUP_DB_PORT_VAR="$(ask_input "MongoDB port env var" "MONGO_PORT")" || return 1
            BACKUP_DB_NAME_VAR="$(ask_input "MongoDB database env var" "MONGO_DB")" || return 1
            BACKUP_DB_USER_VAR="$(ask_input "MongoDB user env var" "MONGO_USER")" || return 1
            BACKUP_DB_PASSWORD_VAR="$(ask_input "MongoDB password env var" "MONGO_PASSWORD")" || return 1
            BACKUP_CREDENTIAL_SOURCE="env"
            resolve_optional_env_value "MongoDB host" "$BACKUP_DB_HOST_VAR" BACKUP_DB_HOST "localhost" || return 1
            resolve_optional_env_value "MongoDB port" "$BACKUP_DB_PORT_VAR" BACKUP_DB_PORT "27017" || return 1
            resolve_required_env_value "MongoDB database" BACKUP_DB_NAME_VAR BACKUP_DB_NAME || return 1
            resolve_required_env_value "MongoDB user" BACKUP_DB_USER_VAR BACKUP_DB_USER || return 1
            resolve_password_env_value || return 1
            ;;
    esac
}

mongo_database_from_uri() {
    local uri="$1"
    local without_scheme
    local path

    without_scheme="${uri#*://}"
    [[ "$without_scheme" != "$uri" ]] || return 0
    [[ "$without_scheme" == */* ]] || return 0
    path="${without_scheme#*/}"
    path="${path%%\?*}"
    [[ -n "$path" ]] && printf '%s\n' "$path"
}

mongo_connection_uri() {
    local password

    if [[ -n "$BACKUP_MONGO_URI" ]]; then
        printf '%s\n' "$BACKUP_MONGO_URI"
        return 0
    fi

    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "env" && -n "$BACKUP_ENV_FILE" && -n "$BACKUP_MONGO_URI_VAR" ]]; then
        BACKUP_MONGO_URI="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_MONGO_URI_VAR" || true)"
        [[ -n "$BACKUP_MONGO_URI" ]] && printf '%s\n' "$BACKUP_MONGO_URI" && return 0
    fi

    password="$(backup_password_env_prefix)"
    if [[ -n "$BACKUP_DB_USER" && -n "$password" ]]; then
        printf 'mongodb://%s:%s@%s:%s/%s\n' "$BACKUP_DB_USER" "$password" "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-27017}" "$BACKUP_DB_NAME"
    else
        printf 'mongodb://%s:%s/%s\n' "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-27017}" "$BACKUP_DB_NAME"
    fi
}

resolve_password_env_value() {
    local default_var="$BACKUP_DB_PASSWORD_VAR"
    local action

    while true; do
        if [[ -n "$BACKUP_ENV_FILE" && -n "$default_var" ]] &&
           env_file_value "$BACKUP_ENV_FILE" "$default_var" >/dev/null 2>&1; then
            BACKUP_DB_PASSWORD_VAR="$default_var"
            return 0
        fi

        if [[ -n "$BACKUP_ENV_FILE" ]]; then
            warning "${default_var} was not found in:"
            warning "$BACKUP_ENV_FILE"
        else
            warning "No environment file is configured."
        fi

        action="$(
            select_option \
                "Database password:" \
                "Prompt securely now" \
                "Enter another variable name" \
                "Choose another env file" \
                "Cancel"
        )" || return 1

        case "$action" in
            "Prompt securely now")
                BACKUP_RUNTIME_PASSWORD="$(read_secret "Database password")" || return 1
                BACKUP_CREDENTIAL_SOURCE="prompt"
                return 0
                ;;
            "Enter another variable name")
                default_var="$(ask_required_input "Database password env var")" || return 1
                ;;
            "Choose another env file")
                BACKUP_ENV_FILE="$(prompt_manual_env_file "${DOCKER_PROJECT_DIR:-$(pwd)}")" || return 1
                ;;
            "Cancel")
                return 1
                ;;
        esac
    done
}

ensure_native_backup_client() {
    local db_type="$1"
    local package=""
    local missing_label

    case "$db_type" in
        postgresql|postgres)
            command_exists pg_dump && command_exists psql && return 0
            package="postgresql-client"
            missing_label="PostgreSQL client tools (pg_dump/psql)"
            ;;
        mysql)
            command_exists mysqldump && command_exists mysql && return 0
            package="default-mysql-client"
            missing_label="MySQL client tools (mysqldump/mysql)"
            ;;
        mariadb)
            { command_exists mariadb-dump || command_exists mysqldump; } && { command_exists mariadb || command_exists mysql; } && return 0
            package="mariadb-client"
            missing_label="MariaDB client tools (mariadb-dump/mariadb)"
            ;;
        mongodb)
            command_exists mongodump && command_exists mongorestore && return 0
            package="mongodb-database-tools"
            missing_label="MongoDB database tools (mongodump/mongorestore)"
            ;;
    esac

    error "${missing_label} is not installed."
    if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
        return 1
    fi

    if confirm "Install ${missing_label} tools now?" "yes"; then
        apt update
        apt install -y "$package"
    else
        return 1
    fi

    case "$db_type" in
        postgresql|postgres) command_exists pg_dump && command_exists psql ;;
        mysql) command_exists mysqldump && command_exists mysql ;;
        mariadb) { command_exists mariadb-dump || command_exists mysqldump; } && { command_exists mariadb || command_exists mysql; } ;;
        mongodb) command_exists mongodump && command_exists mongorestore ;;
    esac
}

preflight_docker_client() {
    local db_type="$1"
    local service="$BACKUP_DB_SERVICE"
    local action

    if docker_service_has_client "$service" "$db_type"; then
        return 0
    fi

    error "$(backup_client_name "$db_type") is not available in service: ${service}"
    error "This service does not appear to be a $(db_engine_label "$db_type") database backup target."

    if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
        return 1
    fi

    action="$(
        select_option \
            "Backup execution:" \
            "Select another Compose service" \
            "Enter service/container manually" \
            "Use host/native DB client" \
            "Cancel"
    )" || return 1

    case "$action" in
        "Select another Compose service")
            select_available_compose_service_target || return 1
            preflight_docker_client "$db_type"
            ;;
        "Enter service/container manually")
            select_custom_docker_target || return 1
            preflight_docker_client "$db_type"
            ;;
        "Use host/native DB client")
            collect_native_database_config
            ;;
        "Cancel")
            return 1
            ;;
    esac
}

preflight_postgres() {
    local password

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        preflight_docker_client postgresql || return 1
        password="$(backup_password_env_prefix)"
        if docker_target_exec sh -c 'command -v psql >/dev/null 2>&1'; then
            if [[ -n "$password" ]]; then
                docker_target_exec env "PGPASSWORD=${password}" psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null 2>&1
            else
                docker_target_exec psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null 2>&1
            fi || {
                error "PostgreSQL connectivity test failed."
                [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
                preflight_failure_action
                return
            }
        fi
        return 0
    fi

    ensure_native_backup_client postgresql || return 1
    info "Checking PostgreSQL connection..."
    if command_exists pg_isready && pg_isready -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" >/dev/null 2>&1; then
        success "PostgreSQL is reachable."
        return 0
    fi

    password="$(backup_password_env_prefix)"
    if command_exists psql; then
        if [[ -n "$password" ]]; then
            PGPASSWORD="$password" psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null 2>&1 && {
                success "PostgreSQL is reachable."
                return 0
            }
        else
            psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null 2>&1 && {
                success "PostgreSQL is reachable."
                return 0
            }
        fi
    fi

    error "PostgreSQL is not reachable."
    printf 'Host: %s\nPort: %s\nDatabase: %s\n' "$BACKUP_DB_HOST" "$BACKUP_DB_PORT" "$BACKUP_DB_NAME" >&2
    [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
    preflight_failure_action
}

preflight_mysql_like() {
    local db_type="$1"
    local client="mysql"
    local password

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        preflight_docker_client "$db_type" || return 1
        password="$(backup_password_env_prefix)"
        if docker_target_exec sh -c 'command -v mariadb >/dev/null 2>&1 || command -v mysql >/dev/null 2>&1'; then
            if [[ -n "$password" ]]; then
                docker_target_exec env "MYSQL_PWD=${password}" sh -c 'if command -v mariadb >/dev/null 2>&1; then exec mariadb -h "$1" -P "$2" -u "$3" "$4" -e "select 1"; else exec mysql -h "$1" -P "$2" -u "$3" "$4" -e "select 1"; fi' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME" >/dev/null 2>&1
            else
                docker_target_exec sh -c 'if command -v mariadb >/dev/null 2>&1; then exec mariadb -h "$1" -P "$2" -u "$3" "$4" -e "select 1"; else exec mysql -h "$1" -P "$2" -u "$3" "$4" -e "select 1"; fi' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME" >/dev/null 2>&1
            fi || {
                error "$(db_engine_label "$db_type") connectivity test failed."
                [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
                preflight_failure_action
                return
            }
        fi
        return 0
    fi

    ensure_native_backup_client "$db_type" || return 1
    command_exists mariadb && client="mariadb"
    command_exists mysql && client="mysql"

    info "Checking $(db_engine_label "$db_type") connection..."
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        MYSQL_PWD="$password" "$client" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null 2>&1 && {
            success "$(db_engine_label "$db_type") is reachable."
            return 0
        }
    else
        "$client" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null 2>&1 && {
            success "$(db_engine_label "$db_type") is reachable."
            return 0
        }
    fi

    error "$(db_engine_label "$db_type") is not reachable."
    printf 'Host: %s\nPort: %s\nDatabase: %s\n' "$BACKUP_DB_HOST" "$BACKUP_DB_PORT" "$BACKUP_DB_NAME" >&2
    [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
    preflight_failure_action
}

preflight_mysql() {
    preflight_mysql_like mysql
}

preflight_mariadb() {
    preflight_mysql_like mariadb
}

preflight_mongodb() {
    local uri

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        preflight_docker_client mongodb || return 1
        if docker_target_exec sh -c 'command -v mongosh >/dev/null 2>&1 || command -v mongo >/dev/null 2>&1'; then
            uri="$(mongo_connection_uri)"
            docker_target_exec sh -c 'if command -v mongosh >/dev/null 2>&1; then mongosh "$1" --quiet --eval "db.runCommand({ ping: 1 }).ok"; else mongo "$1" --quiet --eval "db.runCommand({ ping: 1 }).ok"; fi' sh "$uri" >/dev/null 2>&1 || {
                error "MongoDB connectivity test failed."
                [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
                preflight_failure_action
                return
            }
        else
            uri="$(mongo_connection_uri)"
            docker_target_exec mongodump --uri="$uri" --db "$BACKUP_DB_NAME" --collection "__hostctl_preflight_nonexistent__" --archive --gzip >/dev/null 2>&1 || {
                error "MongoDB connectivity test failed."
                [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
                preflight_failure_action
                return
            }
        fi
        return 0
    fi

    ensure_native_backup_client mongodb || return 1
    uri="$(mongo_connection_uri)"
    if command_exists mongosh; then
        mongosh "$uri" --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1 || {
            error "MongoDB connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
    elif command_exists mongo; then
        mongo "$uri" --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1 || {
            error "MongoDB connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
    else
        mongodump --uri="$uri" --db "$BACKUP_DB_NAME" --collection "__hostctl_preflight_nonexistent__" --archive=/dev/null --gzip >/dev/null 2>&1 || {
            error "MongoDB connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
    fi
}

preflight_failure_action() {
    local action

    action="$(
        select_option \
            "Connection preflight:" \
            "Edit database configuration" \
            "Continue anyway" \
            "Cancel"
    )" || return 1

    case "$action" in
        "Edit database configuration")
            if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
                collect_docker_database_config
            else
                collect_native_database_config
            fi
            ;;
        "Continue anyway")
            return 0
            ;;
        "Cancel")
            return 1
            ;;
    esac
}

show_preflight_summary() {
    echo
    echo "Database Preflight"
    echo
    printf 'Source: %s\n' "$BACKUP_SOURCE_MODE"
    printf 'Engine: %s\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        echo "Executor:"
        if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
            printf 'Container: %s\n' "$BACKUP_DOCKER_CONTAINER"
        else
            printf 'Service: %s\n' "$BACKUP_DB_SERVICE"
        fi
        printf 'Image: %s\n' "${BACKUP_DOCKER_IMAGE:-not declared}"
    else
        echo "Executor:"
        printf 'Host OS client\n'
    fi
    echo
    echo "Target:"
    if [[ "$BACKUP_DB_TYPE" == "mongodb" && -n "$BACKUP_MONGO_URI" ]]; then
        printf 'MongoDB URI: configured\n'
    else
        printf 'Host: %s\n' "$BACKUP_DB_HOST"
        printf 'Port: %s\n' "$BACKUP_DB_PORT"
        printf 'Database: %s\n' "$BACKUP_DB_NAME"
        printf 'User: %s\n' "$BACKUP_DB_USER"
    fi
    echo
    echo "Backup client:"
    printf '%s available\n' "$(backup_client_name "$BACKUP_DB_TYPE")"
    echo
    echo "Connectivity:"
    printf 'successful\n'
    echo
    success "Database is ready for backup."
}

preflight_database_config() {
    backup_resolve_runtime_values || return 1

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres) preflight_postgres || return 1 ;;
        mysql) preflight_mysql || return 1 ;;
        mariadb) preflight_mariadb || return 1 ;;
        mongodb) preflight_mongodb || return 1 ;;
    esac

    show_preflight_summary
    BACKUP_PREFLIGHT_DONE=1
}

collect_docker_database_config() {
    BACKUP_SOURCE_MODE="docker"

    prepare_docker_project_command || return 1
    BACKUP_PROJECT_DIR="$DOCKER_PROJECT_DIR"
    BACKUP_COMPOSE_FILE="$COMPOSE_FILE"
    BACKUP_ENV_FILE="${ENV_FILE:-}"

    BACKUP_DB_TYPE="$(select_db_type)" || return 1
    select_docker_db_service || return 1
    [[ "$BACKUP_SOURCE_MODE" == "native" ]] && return 0

    case "$BACKUP_DB_TYPE" in
        postgresql)
            BACKUP_DB_HOST_VAR="$(ask_input "Database host env var" "DB_HOST")" || return 1
            BACKUP_DB_PORT_VAR="$(ask_input "Database port env var" "DB_PORT")" || return 1
            BACKUP_DB_NAME_VAR="$(ask_input "Database name env var" "DB_NAME")" || return 1
            BACKUP_DB_USER_VAR="$(ask_input "Database user env var" "DB_USER")" || return 1
            BACKUP_DB_PASSWORD_VAR="$(ask_input "Database password env var" "DB_PASSWORD")" || return 1
            ;;
        mysql)
            BACKUP_DB_HOST_VAR="$(ask_input "Database host env var" "MYSQL_HOST")" || return 1
            BACKUP_DB_PORT_VAR="$(ask_input "Database port env var" "MYSQL_PORT")" || return 1
            BACKUP_DB_NAME_VAR="$(ask_input "Database name env var" "MYSQL_DATABASE")" || return 1
            BACKUP_DB_USER_VAR="$(ask_input "Database user env var" "MYSQL_USER")" || return 1
            BACKUP_DB_PASSWORD_VAR="$(ask_input "Database password env var" "MYSQL_PASSWORD")" || return 1
            ;;
        mariadb)
            BACKUP_DB_HOST_VAR="$(ask_input "Database host env var" "MARIADB_HOST")" || return 1
            BACKUP_DB_PORT_VAR="$(ask_input "Database port env var" "MARIADB_PORT")" || return 1
            BACKUP_DB_NAME_VAR="$(ask_input "Database name env var" "MARIADB_DATABASE")" || return 1
            BACKUP_DB_USER_VAR="$(ask_input "Database user env var" "MARIADB_USER")" || return 1
            BACKUP_DB_PASSWORD_VAR="$(ask_input "Database password env var" "MARIADB_PASSWORD")" || return 1
            ;;
        mongodb)
            collect_mongodb_connection_config
            preflight_database_config || return 1
            return 0
            ;;
    esac

    BACKUP_CREDENTIAL_SOURCE="env"

    resolve_optional_env_value "Database host" "$BACKUP_DB_HOST_VAR" BACKUP_DB_HOST "${BACKUP_DB_SERVICE:-localhost}" || return 1
    resolve_optional_env_value "Database port" "$BACKUP_DB_PORT_VAR" BACKUP_DB_PORT "$(default_db_port "$BACKUP_DB_TYPE")" || return 1
    resolve_required_env_value "Database" BACKUP_DB_NAME_VAR BACKUP_DB_NAME || return 1
    resolve_required_env_value "Database user" BACKUP_DB_USER_VAR BACKUP_DB_USER || return 1
    resolve_password_env_value || return 1

    preflight_database_config || return 1
}

detect_native_db_types() {
    command_exists pg_dump && printf 'postgresql\n'
    { command_exists mysqldump || command_exists mariadb-dump; } && printf 'mysql\n'
    command_exists mongodump && printf 'mongodb\n'
}

collect_native_database_config() {
    local detected=()
    local type

    BACKUP_SOURCE_MODE="native"
    while IFS= read -r type; do
        [[ -n "$type" ]] && detected+=("$type")
    done < <(detect_native_db_types | awk '!seen[$0]++' || true)

    if [[ "${#detected[@]}" -eq 1 ]]; then
        BACKUP_DB_TYPE="${detected[0]}"
        echo "Detected database engine: ${BACKUP_DB_TYPE}"
        if ! confirm "Use this database engine?" "yes"; then
            BACKUP_DB_TYPE="$(select_db_type)"
        fi
    else
        BACKUP_DB_TYPE="$(select_db_type)"
    fi

    ensure_native_backup_client "$BACKUP_DB_TYPE" || {
        local native_action
        native_action="$(
            select_option \
                "$(db_engine_label "$BACKUP_DB_TYPE") client tools:" \
                "Choose another DB type" \
                "Cancel"
        )" || return 1
        case "$native_action" in
            "Choose another DB type") collect_native_database_config; return ;;
            "Cancel") info "Database backup cancelled."; return 1 ;;
        esac
    }

    if [[ "$BACKUP_DB_TYPE" == "mongodb" ]]; then
        collect_mongodb_connection_config
        preflight_database_config || return 1
        return
    fi

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres) BACKUP_DB_PORT="$(ask_input "Port" "5432")" ;;
        mysql|mariadb) BACKUP_DB_PORT="$(ask_input "Port" "3306")" ;;
    esac
    BACKUP_DB_HOST="$(ask_input "Host" "127.0.0.1")" || return 1
    BACKUP_DB_NAME="$(ask_required_input "Database")" || return 1
    BACKUP_DB_USER="$(ask_required_input "Username")" || return 1

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

    preflight_database_config || return 1
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

run_rclone_config_for_backup() {
    local rc

    echo
    echo "hostctl will now open rclone's interactive configuration utility."
    echo
    echo "Complete the remote setup, then choose \"q\" inside rclone to return to hostctl."
    echo

    if ! confirm "Continue?" "yes"; then
        return 1
    fi

    set +e
    rclone config
    rc=$?
    set -e
    if [[ "$rc" -ne 0 ]]; then
        warning "rclone configuration exited with status ${rc}."
        return "$rc"
    fi

    info "Returned from rclone configuration."
}

load_rclone_remotes() {
    local remote

    while IFS= read -r remote; do
        [[ -n "$remote" ]] && printf '%s\n' "$remote"
    done < <(rclone listremotes 2>/dev/null || true)
}

select_rclone_remote() {
    local remotes=()
    local remote
    local choice

    ensure_rclone_available_for_backup || return 1
    while IFS= read -r remote; do
        remotes+=("$remote")
    done < <(load_rclone_remotes)

    if [[ "${#remotes[@]}" -eq 0 ]]; then
        while true; do
            if confirm "Configure rclone now?" "yes"; then
                run_rclone_config_for_backup || return 1
            else
                return 1
            fi

            remotes=()
            while IFS= read -r remote; do
                remotes+=("$remote")
            done < <(load_rclone_remotes)
            [[ "${#remotes[@]}" -gt 0 ]] && break

            warning "No rclone remote was created."
            choice="$(
                select_option \
                    "rclone remote:" \
                    "Open rclone config again" \
                    "Continue with Local backup instead" \
                    "Cancel"
            )" || return 1
            case "$choice" in
                "Open rclone config again") continue ;;
                "Continue with Local backup instead")
                    BACKUP_DESTINATION="local"
                    printf '\n'
                    return 1
                    ;;
                "Cancel") return 1 ;;
            esac
        done
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
                run_rclone_config_for_backup || return 1
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
        if ! BACKUP_RCLONE_REMOTE="$(select_rclone_remote)"; then
            if [[ "$BACKUP_DESTINATION" == "local" ]]; then
                BACKUP_RCLONE_REMOTE=""
                BACKUP_RCLONE_PATH=""
                return 0
            fi
            return 1
        fi
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
    [[ "$BACKUP_DB_TYPE" == "postgres" ]] && BACKUP_DB_TYPE="postgresql"

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

    if [[ "$BACKUP_DB_TYPE" == "mongodb" && -z "$BACKUP_MONGO_URI" && -n "$BACKUP_MONGO_URI_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_MONGO_URI="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_MONGO_URI_VAR" || true)"
    fi
    if [[ "$BACKUP_DB_TYPE" == "mongodb" && -n "$BACKUP_MONGO_URI" && -z "$BACKUP_DB_NAME" ]]; then
        BACKUP_DB_NAME="$(mongo_database_from_uri "$BACKUP_MONGO_URI")"
    fi

    if [[ -z "$BACKUP_DB_NAME" && -n "$BACKUP_DB_NAME_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_DB_NAME="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_NAME_VAR" || true)"
    fi
    if [[ -z "$BACKUP_DB_USER" && -n "$BACKUP_DB_USER_VAR" && -n "$BACKUP_ENV_FILE" ]]; then
        BACKUP_DB_USER="$(env_file_value "$BACKUP_ENV_FILE" "$BACKUP_DB_USER_VAR" || true)"
    fi

    [[ -n "$BACKUP_DB_NAME" ]] || { error "Database name is missing."; return 1; }
    if [[ "$BACKUP_DB_TYPE" != "mongodb" || -z "$BACKUP_MONGO_URI" ]]; then
        [[ -n "$BACKUP_DB_USER" ]] || { error "Database user is missing."; return 1; }
    fi

    if [[ "$BACKUP_CREDENTIAL_SOURCE" == "env" ]]; then
        if [[ -z "$BACKUP_ENV_FILE" || ! -f "$BACKUP_ENV_FILE" ]]; then
            error "Configured environment file is missing: ${BACKUP_ENV_FILE:-none}"
            return 1
        fi
        if [[ "$BACKUP_DB_TYPE" == "mongodb" && -n "$BACKUP_MONGO_URI_VAR" ]]; then
            if ! env_file_value "$BACKUP_ENV_FILE" "$BACKUP_MONGO_URI_VAR" >/dev/null 2>&1; then
                error "MongoDB URI variable not found in environment file: ${BACKUP_MONGO_URI_VAR}"
                return 1
            fi
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

run_dump_command_to_file() {
    local failure_label="$1"
    local output_file="$2"
    shift 2
    local error_file
    local rc

    error_file="$(mktemp)"
    set +e
    "$@" > "$output_file" 2>"$error_file"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        if [[ -s "$error_file" ]]; then
            cat "$error_file" >&2
        fi
        error "$failure_label failed."
        info "No valid backup file was created."
        BACKUP_LAST_ERROR="$failure_label failed"
        rm -f "$error_file"
        return "$rc"
    fi

    rm -f "$error_file"
    return 0
}

run_command_capture_stderr() {
    local failure_label="$1"
    shift
    local error_file
    local rc

    error_file="$(mktemp)"
    set +e
    "$@" 2>"$error_file"
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        [[ -s "$error_file" ]] && cat "$error_file" >&2
        error "$failure_label failed."
        info "No valid backup file was created."
        BACKUP_LAST_ERROR="$failure_label failed"
        rm -f "$error_file"
        return "$rc"
    fi

    rm -f "$error_file"
    return 0
}

docker_dump_database_to_sql() {
    local sql_file="$1"
    local password

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres)
            info "Creating PostgreSQL dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                run_dump_command_to_file "PostgreSQL backup" "$sql_file" \
                    docker_target_exec env "PGPASSWORD=${password}" \
                    pg_dump -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "PostgreSQL backup" "$sql_file" \
                    docker_target_exec \
                    pg_dump -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            fi
            ;;
        mysql|mariadb)
            info "Creating MySQL/MariaDB dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    docker_target_exec env "MYSQL_PWD=${password}" \
                    sh -c "command -v mariadb-dump >/dev/null 2>&1 && exec mariadb-dump --no-tablespaces -h \"\$1\" -P \"\$2\" -u \"\$3\" \"\$4\" || exec mysqldump --no-tablespaces -h \"\$1\" -P \"\$2\" -u \"\$3\" \"\$4\"" sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    docker_target_exec \
                    sh -c "command -v mariadb-dump >/dev/null 2>&1 && exec mariadb-dump --no-tablespaces -h \"\$1\" -P \"\$2\" -u \"\$3\" \"\$4\" || exec mysqldump --no-tablespaces -h \"\$1\" -P \"\$2\" -u \"\$3\" \"\$4\"" sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            fi
            ;;
        mongodb)
            info "Creating MongoDB dump..."
            run_dump_command_to_file "MongoDB backup" "$sql_file" \
                docker_target_exec mongodump --uri="$(mongo_connection_uri)" --archive --gzip
            ;;
    esac
}

native_dump_database_to_sql() {
    local sql_file="$1"
    local password
    local dump_cmd

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres)
            command_exists pg_dump || { error "pg_dump not found."; return 1; }
            info "Creating PostgreSQL dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                run_dump_command_to_file "PostgreSQL backup" "$sql_file" \
                    env "PGPASSWORD=${password}" pg_dump -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "PostgreSQL backup" "$sql_file" \
                    pg_dump -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
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
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    env "MYSQL_PWD=${password}" "$dump_cmd" --no-tablespaces -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    "$dump_cmd" --no-tablespaces -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            fi
            ;;
        mongodb)
            command_exists mongodump || { error "mongodump not found."; return 1; }
            info "Creating MongoDB dump..."
            run_command_capture_stderr "MongoDB backup" \
                mongodump --uri="$(mongo_connection_uri)" --archive="$sql_file" --gzip
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

    if [[ "$BACKUP_DB_TYPE" == "mongodb" ]]; then
        gzip -t "$file" || {
            error "MongoDB archive gzip integrity check failed: ${file}"
            return 1
        }
        return 0
    fi

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

    if [[ "$BACKUP_DB_TYPE" == "mongodb" ]]; then
        tmp_gz="${output_file}.tmp"
        rm -f "$tmp_gz"
        if ! dump_database_to_sql "$tmp_gz"; then
            rm -f "$tmp_gz"
            return 1
        fi
        validate_backup_file "$tmp_gz" || {
            rm -f "$tmp_gz"
            return 1
        }
        mv "$tmp_gz" "$output_file"
        success "Database dump created."
        success "Backup integrity verified."
        return 0
    fi

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
    if [[ "$BACKUP_DB_TYPE" == "mongodb" ]]; then
        printf '%s_%s.archive.gz\n' "$db" "$(date '+%Y%m%d_%H%M%S')"
    else
        printf '%s_%s.sql.gz\n' "$db" "$(date '+%Y%m%d_%H%M%S')"
    fi
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

    find "$path" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.archive.gz' \) -mtime "+${days}" -print |
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
    if [[ "${BACKUP_PREFLIGHT_DONE:-0}" -ne 1 ]]; then
        preflight_database_config || return 1
    fi

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
        backup_failure_summary "${BACKUP_LAST_ERROR:-BACKUP FAILED}"
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

backup_failure_summary() {
    local reason="$1"

    echo
    echo "Backup Failed"
    echo
    printf 'Source: %s\n' "$BACKUP_SOURCE_MODE"
    printf 'Engine: %s\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        printf 'Service: %s\n' "$BACKUP_DB_SERVICE"
    else
        printf 'Host: %s\n' "$BACKUP_DB_HOST"
        printf 'Port: %s\n' "$BACKUP_DB_PORT"
    fi
    printf 'Database: %s\n' "$BACKUP_DB_NAME"
    echo
    echo "Reason:"
    printf '%s\n' "$reason"
    echo
    echo "No backup was created."
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
    local status=0

    load_backup_profile "$profile" || return 1
    with_backup_lock "$profile" run_database_backup "$profile" || status=$?
    if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
        return "$status"
    fi
    return 0
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
        with_backup_lock "$BACKUP_PROFILE_NAME" run_database_backup "$BACKUP_PROFILE_NAME" || save_status=$?
        if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
            return "$save_status"
        fi
        return 0
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

    if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
        return "$save_status"
    fi
    return 0
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
    done < <(find "$dir" -maxdepth 1 -type f \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.archive.gz' \) -print | sort)

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
        *.archive.gz) gzip -t "$file" ;;
        *) error "Unsupported backup format. Use .sql, .sql.gz, or .archive.gz."; return 1 ;;
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
    done < <(rclone lsf "$remote_base" --files-only 2>/dev/null | awk '/(\.sql(\.gz)?|\.archive\.gz)$/')

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
            postgresql|postgres)
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | docker_target_exec_input env "PGPASSWORD=${password}" psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | docker_target_exec_input psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        docker_target_exec_input env "PGPASSWORD=${password}" psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" < "$file"
                    else
                        docker_target_exec_input psql -h "${BACKUP_DB_HOST:-localhost}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
            mysql|mariadb)
                if [[ "$file" == *.gz ]]; then
                    if [[ -n "$password" ]]; then
                        gzip -dc "$file" | docker_target_exec_input env "MYSQL_PWD=${password}" sh -c 'command -v mariadb >/dev/null 2>&1 && exec mariadb -h "$1" -P "$2" -u "$3" "$4" || exec mysql -h "$1" -P "$2" -u "$3" "$4"' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    else
                        gzip -dc "$file" | docker_target_exec_input sh -c 'command -v mariadb >/dev/null 2>&1 && exec mariadb -h "$1" -P "$2" -u "$3" "$4" || exec mysql -h "$1" -P "$2" -u "$3" "$4"' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                    fi
                else
                    if [[ -n "$password" ]]; then
                        docker_target_exec_input env "MYSQL_PWD=${password}" sh -c 'command -v mariadb >/dev/null 2>&1 && exec mariadb -h "$1" -P "$2" -u "$3" "$4" || exec mysql -h "$1" -P "$2" -u "$3" "$4"' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    else
                        docker_target_exec_input sh -c 'command -v mariadb >/dev/null 2>&1 && exec mariadb -h "$1" -P "$2" -u "$3" "$4" || exec mysql -h "$1" -P "$2" -u "$3" "$4"' sh "${BACKUP_DB_HOST:-localhost}" "${BACKUP_DB_PORT:-3306}" "$BACKUP_DB_USER" "$BACKUP_DB_NAME" < "$file"
                    fi
                fi
                ;;
            mongodb)
                [[ "$file" == *.archive.gz ]] || { error "MongoDB restore requires a .archive.gz backup."; return 1; }
                docker_target_exec sh -c 'command -v mongorestore >/dev/null 2>&1' || {
                    error "mongorestore not found in selected Docker target."
                    return 1
                }
                docker_target_exec_input mongorestore --uri="$(mongo_connection_uri)" --archive --gzip < "$file"
                ;;
        esac
    else
        case "$BACKUP_DB_TYPE" in
            postgresql|postgres)
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
            mongodb)
                [[ "$file" == *.archive.gz ]] || { error "MongoDB restore requires a .archive.gz backup."; return 1; }
                command_exists mongorestore || { error "mongorestore not found."; return 1; }
                mongorestore --uri="$(mongo_connection_uri)" --archive="$file" --gzip
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
