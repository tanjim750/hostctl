#!/usr/bin/env bash

# =========================================================
# hostctl - Database Backup / Restore Operations
# =========================================================

BACKUP_STATE_DIR="${HOSTCTL_STATE_DIR}/backups"
BACKUP_RUN_STATE_DIR="${BACKUP_STATE_DIR}/runs"
BACKUP_SCHEDULE_STATE_DIR="${BACKUP_STATE_DIR}/schedules"
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
BACKUP_RUNTIME_CONTAINER=""
BACKUP_RUNTIME_CONTAINER_STATE=""
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
BACKUP_SCHEDULE_CONFIG_NAME=""
BACKUP_CRON_EXPR=""
BACKUP_RUNTIME_PASSWORD=""
BACKUP_LAST_LOCAL_FILE=""
BACKUP_LAST_SIZE=""
BACKUP_LAST_REMOTE_RESULT=""
BACKUP_LAST_RESULT=""
BACKUP_LAST_ERROR=""
BACKUP_PREFLIGHT_DONE=0
BACKUP_RESTORE_SAFETY_FILE=""

# ---------------------------------------------------------
# Common helpers
# ---------------------------------------------------------

ensure_backup_dirs() {
    mkdir -p \
        "$BACKUP_STATE_DIR" \
        "$BACKUP_RUN_STATE_DIR" \
        "$BACKUP_SCHEDULE_STATE_DIR" \
        "$BACKUP_DATABASE_DIR" \
        "$BACKUP_RESTORE_TMP_DIR" \
        "$HOSTCTL_LOG_DIR"

    chmod 700 "$BACKUP_STATE_DIR" "$BACKUP_RUN_STATE_DIR" "$BACKUP_SCHEDULE_STATE_DIR" "$BACKUP_DATABASE_DIR" "$BACKUP_RESTORE_TMP_DIR" 2>/dev/null || true
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

backup_schedule_path() {
    valid_profile_name "$1" || {
        error "Invalid backup profile name: $1"
        return 1
    }
    printf '%s/%s.conf\n' "$BACKUP_SCHEDULE_STATE_DIR" "$1"
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
    BACKUP_RUNTIME_CONTAINER=""
    BACKUP_RUNTIME_CONTAINER_STATE=""
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
    BACKUP_SCHEDULE_CONFIG_NAME=""
    BACKUP_CRON_EXPR=""
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

backup_config_file_value() {
    local path="$1"
    local wanted_key="$2"
    local line
    local key
    local value

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

write_backup_schedule_config() {
    local profile="$1"
    local expr="$2"
    local path

    ensure_backup_dirs
    path="$(backup_schedule_path "$profile")"
    {
        printf 'PROFILE_NAME=%s\n' "$profile"
        printf 'CRON_EXPR=%s\n' "$expr"
        printf 'DESTINATION=%s\n' "$BACKUP_DESTINATION"
        printf 'LOCAL_PATH=%s\n' "$BACKUP_LOCAL_PATH"
        printf 'LOCAL_RETENTION_DAYS=%s\n' "$BACKUP_LOCAL_RETENTION_DAYS"
        printf 'RCLONE_REMOTE=%s\n' "$BACKUP_RCLONE_REMOTE"
        printf 'RCLONE_PATH=%s\n' "$BACKUP_RCLONE_PATH"
    } > "$path"
    chmod 600 "$path"
}

load_backup_schedule_config() {
    local profile="$1"
    local path

    path="$(backup_schedule_path "$profile")"
    [[ -f "$path" ]] || {
        error "Backup schedule config not found: ${path}"
        return 1
    }

    BACKUP_DESTINATION="$(backup_config_file_value "$path" "DESTINATION" || true)"
    BACKUP_LOCAL_PATH="$(backup_config_file_value "$path" "LOCAL_PATH" || true)"
    BACKUP_LOCAL_RETENTION_DAYS="$(backup_config_file_value "$path" "LOCAL_RETENTION_DAYS" || true)"
    BACKUP_RCLONE_REMOTE="$(backup_config_file_value "$path" "RCLONE_REMOTE" || true)"
    BACKUP_RCLONE_PATH="$(backup_config_file_value "$path" "RCLONE_PATH" || true)"
    BACKUP_CRON_EXPR="$(backup_config_file_value "$path" "CRON_EXPR" || true)"

    case "$BACKUP_DESTINATION" in
        local|remote|both) ;;
        *) error "Invalid schedule destination: ${BACKUP_DESTINATION:-missing}"; return 1 ;;
    esac
    [[ -n "$BACKUP_LOCAL_RETENTION_DAYS" ]] || BACKUP_LOCAL_RETENTION_DAYS=7
}

validate_loaded_backup_profile() {
    case "$BACKUP_SOURCE_MODE" in docker|native) ;; *) error "Invalid profile source mode."; return 1 ;; esac
    [[ "$BACKUP_DB_TYPE" == "postgres" ]] && BACKUP_DB_TYPE="postgresql"
    case "$BACKUP_DB_TYPE" in postgresql|mysql|mariadb|mongodb) ;; *) error "Invalid profile database type."; return 1 ;; esac
    if [[ -n "$BACKUP_DESTINATION" ]]; then
        case "$BACKUP_DESTINATION" in local|remote|both) ;; *) error "Invalid profile destination."; return 1 ;; esac
    fi
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
        printf 'LAST_DESTINATION=%s\n' "$BACKUP_DESTINATION"
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

backup_compose_file_args() {
    local compose_value="${COMPOSE_FILE:-$BACKUP_COMPOSE_FILE}"
    local item
    local files=()

    [[ -n "$compose_value" ]] || return 1
    compose_value="${compose_value//$'\n'/:}"
    IFS=':' read -r -a files <<< "$compose_value"
    for item in "${files[@]}"; do
        [[ -n "$item" ]] && printf '%s\n' "$item"
    done
}

backup_compose_exec() {
    local args=(docker compose)
    local file

    if [[ -n "${ENV_FILE:-}" ]]; then
        args+=(--env-file "$ENV_FILE")
    fi
    while IFS= read -r file; do
        args+=(-f "$file")
    done < <(backup_compose_file_args)
    args+=("$@")
    "${args[@]}"
}

compose_exec_all_profiles() {
    backup_compose_exec --profile '*' "$@" 2>/dev/null ||
        backup_compose_exec "$@"
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

compose_service_container_name() {
    local service="$1"

    compose_service_block "$service" |
        awk '$1 == "container_name:" { print $2; exit }'
}

compose_project_name() {
    backup_compose_exec config --name 2>/dev/null || true
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

docker_target_label() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        printf 'container: %s\n' "$BACKUP_DOCKER_CONTAINER"
    else
        printf 'service: %s\n' "$BACKUP_DB_SERVICE"
    fi
}

select_custom_docker_target() {
    local target_type

    target_type="$(
        select_option \
            "Target type:" \
            "Compose service" \
            "Docker container"
    )" || return 1

    case "$target_type" in
        "Compose service") select_custom_compose_service_target ;;
        "Docker container") select_custom_container_target ;;
    esac
}

select_numbered_container() {
    local prompt="$1"
    shift
    local containers=("$@")
    local choice
    local container
    local name
    local state
    local image

    [[ "${#containers[@]}" -gt 0 ]] || return 1
    if [[ "${#containers[@]}" -eq 1 ]]; then
        printf '%s\n' "${containers[0]}"
        return 0
    fi

    echo >&2
    printf '%s\n' "$prompt" >&2
    echo >&2
    local i
    for i in "${!containers[@]}"; do
        container="${containers[$i]}"
        name="$(docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's#^/##' || true)"
        state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
        image="$(docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true)"
        printf '%d. %s\n' "$((i + 1))" "${name:-$container}" >&2
        printf '   ID: %s\n' "$container" >&2
        printf '   State: %s\n' "${state:-unknown}" >&2
        printf '   Image: %s\n' "${image:-unknown}" >&2
    done

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${#containers[@]}]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-${#containers[@]}]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#containers[@]} )); then
            printf '%s\n' "${containers[$((choice - 1))]}"
            return 0
        fi
        warning "Invalid selection."
    done
}

container_health_status() {
    local container="$1"

    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>/dev/null || true
}

container_name_for_display() {
    local container="$1"
    docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's#^/##' || printf '%s\n' "$container"
}

container_image_for_display() {
    local container="$1"
    docker inspect -f '{{.Config.Image}}' "$container" 2>/dev/null || true
}

resolve_compose_service_container() {
    local service="$1"
    local containers=()
    local id
    local cname
    local project_name

    while IFS= read -r id; do
        [[ -n "$id" ]] && containers+=("$id")
    done < <(backup_compose_exec --profile '*' ps -a -q "$service" 2>/dev/null || backup_compose_exec ps -a -q "$service" 2>/dev/null || true)

    if [[ "${#containers[@]}" -eq 0 ]]; then
        cname="$(compose_service_container_name "$service")"
        if [[ -n "$cname" ]] && docker inspect "$cname" >/dev/null 2>&1; then
            containers+=("$cname")
        fi
    fi

    if [[ "${#containers[@]}" -eq 0 ]]; then
        project_name="$(compose_project_name)"
        if [[ -n "$project_name" ]]; then
            while IFS= read -r id; do
                [[ -n "$id" ]] && containers+=("$id")
            done < <(
                docker ps -aq \
                    --filter "label=com.docker.compose.service=${service}" \
                    --filter "label=com.docker.compose.project=${project_name}" \
                    2>/dev/null || true
            )
        fi
    fi

    if [[ "${#containers[@]}" -eq 0 ]]; then
        while IFS= read -r id; do
            [[ -n "$id" ]] && containers+=("$id")
        done < <(
            docker ps -aq \
                --filter "label=com.docker.compose.service=${service}" \
                --filter "label=com.docker.compose.project.working_dir=${DOCKER_PROJECT_DIR:-$BACKUP_PROJECT_DIR}" \
                2>/dev/null || true
        )
    fi

    if [[ "${#containers[@]}" -eq 0 ]]; then
        return 1
    fi

    select_numbered_container "Multiple containers match Compose service ${service}:" "${containers[@]}"
}

resolve_backup_executor_runtime() {
    local state
    local health
    local container=""

    [[ "$BACKUP_SOURCE_MODE" == "docker" ]] || return 0

    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        if ! docker inspect "$BACKUP_DOCKER_CONTAINER" >/dev/null 2>&1; then
            error "Docker container not found: ${BACKUP_DOCKER_CONTAINER}"
            return 1
        fi
        container="$BACKUP_DOCKER_CONTAINER"
    else
        container="$(resolve_compose_service_container "$BACKUP_DB_SERVICE")" || {
            error "No runtime container exists for Compose service: ${BACKUP_DB_SERVICE}"
            if [[ "$BACKUP_CRON_MODE" -eq 0 ]] && confirm "Start this Compose service now?" "yes"; then
                backup_compose_exec --profile '*' up -d "$BACKUP_DB_SERVICE" || backup_compose_exec up -d "$BACKUP_DB_SERVICE" || return 1
                container="$(resolve_compose_service_container "$BACKUP_DB_SERVICE")" || {
                    error "Container was not created for service: ${BACKUP_DB_SERVICE}"
                    return 1
                }
            else
                return 1
            fi
        }
    fi

    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    BACKUP_RUNTIME_CONTAINER="$container"
    BACKUP_RUNTIME_CONTAINER_STATE="$state"
    BACKUP_DOCKER_IMAGE="$(container_image_for_display "$container")"

    case "$state" in
        running)
            ;;
        exited|created)
            warning "Docker container is ${state}: $(container_name_for_display "$container")"
            if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "service" && "$BACKUP_CRON_MODE" -eq 0 ]] && confirm "Start this Compose service now?" "yes"; then
                backup_compose_exec --profile '*' up -d "$BACKUP_DB_SERVICE" || backup_compose_exec up -d "$BACKUP_DB_SERVICE" || return 1
                container="$(resolve_compose_service_container "$BACKUP_DB_SERVICE")" || return 1
                state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
                BACKUP_RUNTIME_CONTAINER="$container"
                BACKUP_RUNTIME_CONTAINER_STATE="$state"
                BACKUP_DOCKER_IMAGE="$(container_image_for_display "$container")"
                [[ "$state" == "running" ]] || { error "Container is still ${state:-unknown} after start."; return 1; }
            else
                error "Container is not running: ${state:-unknown}"
                return 1
            fi
            ;;
        restarting)
            error "Container is restarting: $(container_name_for_display "$container")"
            return 1
            ;;
        paused|removing|dead|"")
            error "Container is not usable: ${state:-unknown}"
            return 1
            ;;
        *)
            error "Container state is not usable: ${state}"
            return 1
            ;;
    esac

    health="$(container_health_status "$container")"
    if [[ "$health" == "unhealthy" ]]; then
        error "Container health check is unhealthy: $(container_name_for_display "$container")"
        return 1
    elif [[ "$health" == "starting" ]]; then
        warning "Container health check is still starting."
    fi
}

docker_target_exec() {
    [[ -n "${BACKUP_RUNTIME_CONTAINER:-}" ]] || resolve_backup_executor_runtime || return 1
    docker exec "$BACKUP_RUNTIME_CONTAINER" "$@"
}

docker_target_exec_input() {
    [[ -n "${BACKUP_RUNTIME_CONTAINER:-}" ]] || resolve_backup_executor_runtime || return 1
    docker exec -i "$BACKUP_RUNTIME_CONTAINER" "$@"
}

docker_target_image() {
    if [[ -n "${BACKUP_RUNTIME_CONTAINER:-}" ]]; then
        container_image_for_display "$BACKUP_RUNTIME_CONTAINER"
    elif [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        docker inspect -f '{{.Config.Image}}' "$BACKUP_DOCKER_CONTAINER" 2>/dev/null || true
    else
        compose_service_image "$BACKUP_DB_SERVICE"
    fi
}

confirm_selected_docker_target() {
    local image

    image="$(docker_target_image)"
    BACKUP_DOCKER_IMAGE="$image"

    echo
    echo "Selected backup executor:"
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        printf 'Container: %s\n' "$BACKUP_DOCKER_CONTAINER"
    else
        printf 'Compose service: %s\n' "$BACKUP_DB_SERVICE"
    fi
    printf 'Image: %s\n' "${image:-not declared}"
    echo

    if [[ -n "$image" ]] && ! image_matches_db_type "$image" "$BACKUP_DB_TYPE"; then
        warning "Selected executor image does not appear to be $(db_engine_label "$BACKUP_DB_TYPE")."
        warning "This is allowed if the required client executable is present and connectivity succeeds."
        confirm "Continue with executable/connectivity verification?" "yes" || return 1
    fi
}

select_docker_target_from_menu() {
    local choices=("$@")
    local total="${#choices[@]}"
    local choice
    local record
    local action

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${total}]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-${total}]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= total )); then
            record="${choices[$((choice - 1))]}"
            action="${record%%|*}"
            case "$action" in
                service)
                    BACKUP_DOCKER_TARGET_TYPE="service"
                    BACKUP_DB_SERVICE="${record#service|}"
                    BACKUP_DOCKER_CONTAINER=""
                    BACKUP_RUNTIME_CONTAINER=""
                    return 0
                    ;;
                custom_service)
                    select_custom_compose_service_target
                    return
                    ;;
                custom_container)
                    select_custom_container_target
                    return
                    ;;
                native)
                    collect_native_database_config
                    return
                    ;;
                cancel)
                    return 1
                    ;;
            esac
        fi
        warning "Invalid selection."
    done
}

select_custom_compose_service_target() {
    local input

    while true; do
        input="$(ask_required_input "Enter Compose service name")" || return 1
        if get_all_compose_services | awk -v service="$input" '$0 == service { found = 1 } END { exit found ? 0 : 1 }'; then
            BACKUP_DOCKER_TARGET_TYPE="service"
            BACKUP_DB_SERVICE="$input"
            BACKUP_DOCKER_CONTAINER=""
            BACKUP_RUNTIME_CONTAINER=""
            return 0
        fi
        warning "Compose service not found: ${input}"
        confirm "Use it anyway?" "no" && {
            BACKUP_DOCKER_TARGET_TYPE="service"
            BACKUP_DB_SERVICE="$input"
            BACKUP_DOCKER_CONTAINER=""
            BACKUP_RUNTIME_CONTAINER=""
            return 0
        }
        confirm "Enter another service?" "yes" || return 1
    done
}

select_custom_container_target() {
    local input

    while true; do
        input="$(ask_required_input "Enter Docker container name or ID")" || return 1
        if docker inspect "$input" >/dev/null 2>&1; then
            BACKUP_DOCKER_TARGET_TYPE="container"
            BACKUP_DOCKER_CONTAINER="$(container_name_for_display "$input")"
            BACKUP_DB_SERVICE=""
            BACKUP_RUNTIME_CONTAINER=""
            return 0
        fi
        error "Docker container not found: ${input}"
        confirm "Enter another container?" "yes" || return 1
    done
}

select_available_compose_service_target() {
    local services=()
    local service
    local image
    local choices=()

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
        choices+=("service|${services[$i]}")
    done
    printf '%d. Custom Compose service\n' "$(( ${#choices[@]} + 1 ))"; choices+=("custom_service|")
    printf '%d. Custom Docker container\n' "$(( ${#choices[@]} + 1 ))"; choices+=("custom_container|")
    printf '%d. Use native/external database\n' "$(( ${#choices[@]} + 1 ))"; choices+=("native|")
    printf '%d. Cancel\n' "$(( ${#choices[@]} + 1 ))"; choices+=("cancel|")

    select_docker_target_from_menu "${choices[@]}"
}

select_docker_db_service() {
    local services=()
    local candidates=()
    local choices=()
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

    echo
    printf '%s-compatible image candidates:\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
    echo
    local i
    if [[ "${#candidates[@]}" -gt 0 ]]; then
        for i in "${!candidates[@]}"; do
            printf '%d. %s\n' "$(( ${#choices[@]} + 1 ))" "${candidates[$i]%%|*}"
            printf '   Image: %s\n' "${candidates[$i]#*|}"
            choices+=("service|${candidates[$i]%%|*}")
        done
    else
        warning "No $(db_engine_label "$BACKUP_DB_TYPE")-compatible service image was detected."
    fi
    echo
    echo "All available Compose services:"
    echo
    for service in "${services[@]}"; do
        image="$(compose_service_image "$service")"
        printf '%d. %s\n' "$(( ${#choices[@]} + 1 ))" "$service"
        printf '   Image: %s\n' "${image:-not declared}"
        choices+=("service|${service}")
    done
    printf '%d. Custom Compose service\n' "$(( ${#choices[@]} + 1 ))"; choices+=("custom_service|")
    printf '%d. Custom Docker container\n' "$(( ${#choices[@]} + 1 ))"; choices+=("custom_container|")
    printf '%d. Use native/external database\n' "$(( ${#choices[@]} + 1 ))"; choices+=("native|")
    printf '%d. Cancel\n' "$(( ${#choices[@]} + 1 ))"; choices+=("cancel|")

    select_docker_target_from_menu "${choices[@]}" || {
        info "Database backup cancelled."
        return 1
    }

    [[ "$BACKUP_SOURCE_MODE" == "native" ]] && return 0
    confirm_selected_docker_target
}

docker_service_has_client() {
    local service="${1:-$BACKUP_DB_SERVICE}"
    local db_type="$2"

    resolve_backup_executor_runtime || return 1

    case "$db_type" in
        postgresql|postgres)
            docker_target_exec sh -c 'command -v pg_dump >/dev/null 2>&1' 2>/dev/null ||
                docker_target_exec pg_dump --version >/dev/null 2>&1
            ;;
        mysql)
            docker_target_exec sh -c 'command -v mysqldump >/dev/null 2>&1' 2>/dev/null ||
                docker_target_exec mysqldump --version >/dev/null 2>&1
            ;;
        mariadb)
            docker_target_exec sh -c 'command -v mariadb-dump >/dev/null 2>&1 || command -v mysqldump >/dev/null 2>&1' 2>/dev/null ||
                docker_target_exec mariadb-dump --version >/dev/null 2>&1 ||
                docker_target_exec mysqldump --version >/dev/null 2>&1
            ;;
        mongodb)
            docker_target_exec sh -c 'command -v mongodump >/dev/null 2>&1' 2>/dev/null ||
                docker_target_exec mongodump --version >/dev/null 2>&1
            ;;
    esac
}

docker_target_has_executable() {
    local exe="$1"

    docker_target_exec sh -c "command -v '$exe' >/dev/null 2>&1" 2>/dev/null ||
        docker_target_exec "$exe" --version >/dev/null 2>&1 ||
        docker_target_exec "$exe" --help >/dev/null 2>&1
}

docker_mysql_client_exec() {
    if docker_target_has_executable mariadb; then
        docker_target_exec mariadb "$@"
    else
        docker_target_exec mysql "$@"
    fi
}

docker_mysql_client_exec_input() {
    if docker_target_has_executable mariadb; then
        docker_target_exec_input mariadb "$@"
    else
        docker_target_exec_input mysql "$@"
    fi
}

docker_mysql_client_command_name() {
    if docker_target_has_executable mariadb; then
        printf 'mariadb\n'
    else
        printf 'mysql\n'
    fi
}

docker_mysql_dump_exec() {
    if [[ "$BACKUP_DB_TYPE" == "mariadb" ]] && docker_target_has_executable mariadb-dump; then
        docker_target_exec mariadb-dump "$@"
    else
        docker_target_exec mysqldump "$@"
    fi
}

docker_mysql_dump_command_name() {
    if [[ "$BACKUP_DB_TYPE" == "mariadb" ]] && docker_target_has_executable mariadb-dump; then
        printf 'mariadb-dump\n'
    else
        printf 'mysqldump\n'
    fi
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

default_docker_db_host() {
    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "service" ]] &&
       [[ -n "${BACKUP_DOCKER_IMAGE:-}" ]] &&
       image_matches_db_type "$BACKUP_DOCKER_IMAGE" "$BACKUP_DB_TYPE"; then
        printf '127.0.0.1\n'
    elif [[ -n "$BACKUP_DB_SERVICE" ]]; then
        printf '%s\n' "$BACKUP_DB_SERVICE"
    else
        printf '127.0.0.1\n'
    fi
}

compose_service_env_files() {
    local service="$1"
    local line
    local in_env_file=0
    local value

    while IFS= read -r line; do
        if [[ "$line" =~ ^[[:space:]]*env_file: ]]; then
            in_env_file=1
            value="${line#*:}"
            value="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$value")"
            value="${value%\"}"
            value="${value#\"}"
            value="${value%\'}"
            value="${value#\'}"
            [[ -n "$value" && "$value" != "[]" ]] && printf '%s\n' "$value"
            continue
        fi
        if [[ "$in_env_file" -eq 1 ]]; then
            if [[ "$line" =~ ^[[:space:]]*-[[:space:]]*(.+)$ ]]; then
                value="${BASH_REMATCH[1]}"
                value="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$value")"
                value="${value%\"}"
                value="${value#\"}"
                value="${value%\'}"
                value="${value#\'}"
                printf '%s\n' "$value"
                continue
            fi
            [[ "$line" =~ ^[[:space:]]{4,} ]] || in_env_file=0
        fi
    done < <(compose_service_block "$service")
}

resolve_compose_relative_file() {
    local path="$1"
    local base="${DOCKER_PROJECT_DIR:-$BACKUP_PROJECT_DIR}"

    [[ -n "$path" ]] || return 1
    if [[ "$path" == /* ]]; then
        printf '%s\n' "$path"
    else
        absolute_file_path "$path" "$base"
    fi
}

detect_compose_service_env_file() {
    local service="$1"
    local candidate
    local resolved

    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        resolved="$(resolve_compose_relative_file "$candidate" 2>/dev/null || true)"
        if [[ -n "$resolved" && -f "$resolved" ]]; then
            printf '%s\n' "$resolved"
            return 0
        fi
    done < <(compose_service_env_files "$service" || true)

    return 1
}

backup_compose_files_exist() {
    local file
    local found=0

    while IFS= read -r file; do
        found=1
        [[ -f "$file" ]] || return 1
    done < <(backup_compose_file_args)
    [[ "$found" -eq 1 ]]
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
    local action

    resolve_backup_executor_runtime || return 1

    if docker_service_has_client "$BACKUP_DB_SERVICE" "$db_type"; then
        return 0
    fi

    error "$(backup_client_name "$db_type") is not available in backup executor: $(docker_target_label)"
    error "Executor container: $(container_name_for_display "$BACKUP_RUNTIME_CONTAINER")"

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
            confirm_selected_docker_target || return 1
            preflight_docker_client "$db_type"
            ;;
        "Enter service/container manually")
            select_custom_docker_target || return 1
            confirm_selected_docker_target || return 1
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
        docker_target_has_executable psql || {
            error "psql is required in the selected executor for PostgreSQL connectivity validation."
            return 1
        }
        if [[ -n "$password" ]]; then
            docker_target_exec env "PGPASSWORD=${password}" psql -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null
        else
            docker_target_exec psql -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null
        fi || {
            error "PostgreSQL connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
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
            PGPASSWORD="$password" psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null && {
                success "PostgreSQL is reachable."
                return 0
            }
        else
            psql -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c 'select 1' >/dev/null && {
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
    local docker_client="mysql"
    local password

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        preflight_docker_client "$db_type" || return 1
        password="$(backup_password_env_prefix)"
        { docker_target_has_executable mariadb || docker_target_has_executable mysql; } || {
            error "mysql or mariadb client is required in the selected executor for connectivity validation."
            return 1
        }
        docker_client="$(docker_mysql_client_command_name)"
        if [[ -n "$password" ]]; then
            docker_target_exec env "MYSQL_PWD=${password}" "$docker_client" -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null
        else
            docker_mysql_client_exec -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null
        fi || {
            error "$(db_engine_label "$db_type") connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
        return 0
    fi

    ensure_native_backup_client "$db_type" || return 1
    command_exists mariadb && client="mariadb"
    command_exists mysql && client="mysql"

    info "Checking $(db_engine_label "$db_type") connection..."
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        MYSQL_PWD="$password" "$client" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null && {
            success "$(db_engine_label "$db_type") is reachable."
            return 0
        }
    else
        "$client" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME" -e 'select 1' >/dev/null && {
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
            docker_target_exec sh -c 'if command -v mongosh >/dev/null 2>&1; then mongosh "$1" --quiet --eval "db.runCommand({ ping: 1 }).ok"; else mongo "$1" --quiet --eval "db.runCommand({ ping: 1 }).ok"; fi' sh "$uri" >/dev/null || {
                error "MongoDB connectivity test failed."
                [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
                preflight_failure_action
                return
            }
        else
            uri="$(mongo_connection_uri)"
            docker_target_exec mongodump --uri="$uri" --db "$BACKUP_DB_NAME" --collection "__hostctl_preflight_nonexistent__" --archive --gzip >/dev/null || {
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
        mongosh "$uri" --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null || {
            error "MongoDB connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
    elif command_exists mongo; then
        mongo "$uri" --quiet --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null || {
            error "MongoDB connectivity test failed."
            [[ "$BACKUP_CRON_MODE" -eq 1 ]] && return 1
            preflight_failure_action
            return
        }
    else
        mongodump --uri="$uri" --db "$BACKUP_DB_NAME" --collection "__hostctl_preflight_nonexistent__" --archive=/dev/null --gzip >/dev/null || {
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
        if [[ -n "${BACKUP_RUNTIME_CONTAINER:-}" ]]; then
            printf 'Runtime container: %s\n' "$(container_name_for_display "$BACKUP_RUNTIME_CONTAINER")"
            printf 'Runtime state: %s\n' "${BACKUP_RUNTIME_CONTAINER_STATE:-unknown}"
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
    BACKUP_DOCKER_IMAGE="$(docker_target_image)"

    if [[ -z "$BACKUP_ENV_FILE" && -n "$BACKUP_DB_SERVICE" ]]; then
        BACKUP_ENV_FILE="$(detect_compose_service_env_file "$BACKUP_DB_SERVICE" || true)"
        ENV_FILE="$BACKUP_ENV_FILE"
        [[ -n "$BACKUP_ENV_FILE" ]] && info "Using Compose service env_file: ${BACKUP_ENV_FILE}"
    fi

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

    resolve_optional_env_value "Database host" "$BACKUP_DB_HOST_VAR" BACKUP_DB_HOST "$(default_docker_db_host)" || return 1
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

    error "rclone is not installed."
    echo
    echo "Configure rclone first with:"
    echo "    sudo hostctl --rclone"
    echo
    return 1
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
        error "rclone is not configured."
        echo
        echo "Configure rclone first with:"
        echo "    sudo hostctl --rclone"
        echo
        return 1
    fi

    echo "Remote destination:" >&2
    echo >&2
    local i
    for i in "${!remotes[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${remotes[$i]}" >&2
    done
    printf '%d. Cancel\n' "$(( ${#remotes[@]} + 1 ))" >&2

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-$(( ${#remotes[@]} + 1 ))]: " choice </dev/tty || return 1
        else
            read -r -p "Select [1-$(( ${#remotes[@]} + 1 ))]: " choice || return 1
        fi
        if [[ "$choice" =~ ^[0-9]+$ ]]; then
            if (( choice >= 1 && choice <= ${#remotes[@]} )); then
                printf '%s\n' "${remotes[$((choice - 1))]}"
                return 0
            elif (( choice == ${#remotes[@]} + 1 )); then
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

collect_database_access_config() {
    local source

    reset_backup_config
    source="$(
        select_option \
            "Database source:" \
            "Docker" \
            "Native / OS"
    )" || return 1

    case "$source" in
        "Docker") collect_docker_database_config || return 1 ;;
        "Native / OS") collect_native_database_config || return 1 ;;
    esac
}

collect_backup_config() {
    collect_database_access_config || return 1
    collect_destination_config
}

# ---------------------------------------------------------
# Backup engine
# ---------------------------------------------------------

backup_resolve_runtime_values() {
    [[ "$BACKUP_DB_TYPE" == "postgres" ]] && BACKUP_DB_TYPE="postgresql"
    BACKUP_RUNTIME_CONTAINER=""
    BACKUP_RUNTIME_CONTAINER_STATE=""

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        COMPOSE_FILE="$BACKUP_COMPOSE_FILE"
        ENV_FILE="$BACKUP_ENV_FILE"
        DOCKER_PROJECT_DIR="$BACKUP_PROJECT_DIR"

        if ! backup_compose_files_exist; then
            if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
                error "One or more saved Compose files do not exist: ${COMPOSE_FILE}"
                return 1
            fi
            warning "Saved Compose path no longer exists: ${COMPOSE_FILE}"
            COMPOSE_FILE="$(prompt_manual_compose_file)" || return 1
            BACKUP_COMPOSE_FILE="$COMPOSE_FILE"
            DOCKER_PROJECT_DIR="$(cd "$(dirname "$COMPOSE_FILE")" && pwd -P)" || return 1
            BACKUP_PROJECT_DIR="$DOCKER_PROJECT_DIR"
            if confirm "Update saved profile with new path?" "yes"; then
                write_backup_profile "$BACKUP_PROFILE_NAME"
            fi
        fi

        if [[ -n "$ENV_FILE" && ! -f "$ENV_FILE" ]]; then
            if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
                error "Saved environment file does not exist: ${ENV_FILE}"
                return 1
            fi
            warning "Saved environment file no longer exists: ${ENV_FILE}"
            ENV_FILE="$(prompt_manual_env_file "$DOCKER_PROJECT_DIR")" || return 1
            BACKUP_ENV_FILE="$ENV_FILE"
            if confirm "Update saved profile with new environment path?" "yes"; then
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
                    pg_dump -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "PostgreSQL backup" "$sql_file" \
                    docker_target_exec \
                    pg_dump -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            fi
            ;;
        mysql|mariadb)
            info "Creating MySQL/MariaDB dump..."
            password="$(backup_password_env_prefix)"
            if [[ -n "$password" ]]; then
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    docker_target_exec env "MYSQL_PWD=${password}" \
                    "$(docker_mysql_dump_command_name)" --no-tablespaces -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
            else
                run_dump_command_to_file "MySQL/MariaDB backup" "$sql_file" \
                    docker_mysql_dump_exec --no-tablespaces -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
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
                exit 75
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
    echo
    echo "Schedule:"
    if [[ -f "$(backup_schedule_path "$profile")" ]]; then
        printf 'Destination: %s\n' "$(backup_config_file_value "$(backup_schedule_path "$profile")" "DESTINATION" || printf 'unknown')"
        printf 'Cron: %s\n' "$(backup_config_file_value "$(backup_schedule_path "$profile")" "CRON_EXPR" || printf 'unknown')"
    else
        printf 'Not scheduled\n'
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
    local schedule_path

    temp="$(mktemp)"
    crontab -l 2>/dev/null | grep -Fv "# HOSTCTL:backup:${profile}" > "$temp" || true
    crontab "$temp"
    rm -f "$temp"
    schedule_path="$(backup_schedule_path "$profile")"
    [[ -f "$schedule_path" ]] && rm -f "$schedule_path"
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

    collect_destination_config || return 1

    echo
    printf 'Profile: %s\n' "$profile"
    printf 'Schedule: %s\n' "$expr"
    printf 'Destination: %s\n' "$BACKUP_DESTINATION"
    echo

    if ! confirm "Create/update schedule?" "yes"; then
        warning "Backup schedule cancelled."
        return 0
    fi

    write_backup_schedule_config "$profile" "$expr"
    backup_file "$(backup_profile_path "$profile")" >/dev/null 2>&1 || true
    write_backup_profile "$profile"
    command="/usr/local/bin/hostctl --backup-now --profile ${profile} --schedule-config ${profile} --cron >> ${HOSTCTL_LOG_DIR}/backup-${profile}.log 2>&1 # HOSTCTL:backup:${profile}"
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
    collect_destination_config || return 1
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
    local last_destination=""
    local schedule="not scheduled"
    local schedule_destination=""

    load_backup_profile "$profile" || return 0
    state_file="$(backup_run_state_path "$profile")"
    if [[ -f "$state_file" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            key="${line%%=*}"
            value="${line#*=}"
            case "$key" in
                LAST_RUN) last_run="$value" ;;
                LAST_RESULT) result="$value" ;;
                LAST_DESTINATION) last_destination="$value" ;;
                LAST_LOCAL_FILE) latest="$value" ;;
                LAST_SIZE) size="$value" ;;
                LAST_REMOTE_RESULT) remote="$value" ;;
            esac
        done < "$state_file"
    fi

    if crontab -l 2>/dev/null | grep -F "# HOSTCTL:backup:${profile}" >/dev/null; then
        schedule="$(crontab -l 2>/dev/null | awk -v marker="# HOSTCTL:backup:${profile}" 'index($0, marker) { print $1, $2, $3, $4, $5; exit }')"
    fi
    if [[ -f "$(backup_schedule_path "$profile")" ]]; then
        schedule_destination="$(backup_config_file_value "$(backup_schedule_path "$profile")" "DESTINATION" || true)"
        [[ -n "$schedule_destination" ]] && schedule="${schedule} (${schedule_destination})"
    fi

    printf '   Source: %s / %s\n' "$BACKUP_SOURCE_MODE" "$BACKUP_DB_TYPE"
    printf '   Database: %s\n' "$BACKUP_DB_NAME"
    echo
    printf '   Schedule: %s\n' "$schedule"
    printf '   Last run: %s\n' "${last_run:-never}"
    printf '   Destination used: %s\n' "${last_destination:-unknown}"
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
            collect_database_access_config || return 0
            if save_profile_interactive && confirm "Schedule this profile now?" "no"; then
                schedule_backup_profile "$BACKUP_PROFILE_NAME"
            fi
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
            collect_database_access_config || return 0
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
    BACKUP_PREFLIGHT_DONE=0
    if preflight_database_config; then
        success "Database connection test succeeded."
        return 0
    fi
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
            --schedule-config)
                shift
                if [[ $# -eq 0 || "${1:-}" == --* ]]; then
                    error "--schedule-config requires a schedule name."
                    return 1
                fi
                valid_profile_name "$1" || {
                    error "Invalid schedule config name: $1"
                    return 1
                }
                BACKUP_SCHEDULE_CONFIG_NAME="$1"
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
        if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
            if [[ -n "$BACKUP_SCHEDULE_CONFIG_NAME" ]]; then
                load_backup_schedule_config "$BACKUP_SCHEDULE_CONFIG_NAME" || return 1
            elif [[ -z "$BACKUP_DESTINATION" ]]; then
                error "Cron backup requires --schedule-config for destination settings."
                return 1
            else
                warning "Using legacy destination fields from DB profile."
            fi
        else
            collect_destination_config || return 1
        fi
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

    with_backup_lock "one-time-$(sanitize_backup_name "${BACKUP_DB_NAME:-database}")" run_database_backup "one-time" || save_status=$?

    if [[ "$save_status" -eq 0 ]]; then
        if confirm "Save this configuration as a backup profile?" "no"; then
            if save_profile_interactive; then
                if confirm "Schedule this profile now?" "no"; then
                    schedule_backup_profile "$BACKUP_PROFILE_NAME"
                fi
            else
                warning "PROFILE SAVE FAILED"
            fi
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
                path="$(backup_profile_value "${profiles[$((choice - 1))]}" "LOCAL_PATH" || true)"
                [[ -n "$path" ]] || path="${BACKUP_DATABASE_DIR}/$(sanitize_backup_name "${profiles[$((choice - 1))]}")"
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

restore_interrupted() {
    warning "Restore interrupted."
    if [[ -n "${BACKUP_RESTORE_SAFETY_FILE:-}" ]]; then
        info "Safety backup preserved at: ${BACKUP_RESTORE_SAFETY_FILE}"
    fi
    return 130
}

sql_stream_restore() {
    local file="$1"
    shift

    if [[ "$file" == *.gz ]]; then
        gzip -dc "$file" | "$@"
    else
        "$@" < "$file"
    fi
}

docker_postgres_exec() {
    local password
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        docker_target_exec env "PGPASSWORD=${password}" psql -v ON_ERROR_STOP=1 -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" "$@"
    else
        docker_target_exec psql -v ON_ERROR_STOP=1 -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" "$@"
    fi
}

native_postgres_exec() {
    local password
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        env "PGPASSWORD=${password}" psql -v ON_ERROR_STOP=1 -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" "$@"
    else
        psql -v ON_ERROR_STOP=1 -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" "$@"
    fi
}

docker_mysql_exec() {
    local password
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        docker_target_exec env "MYSQL_PWD=${password}" "$(docker_mysql_client_command_name)" -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$@"
    else
        docker_mysql_client_exec -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$@"
    fi
}

docker_mysql_exec_input() {
    local password
    password="$(backup_password_env_prefix)"
    if [[ -n "$password" ]]; then
        docker_target_exec_input env "MYSQL_PWD=${password}" "$(docker_mysql_client_command_name)" -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$@"
    else
        docker_mysql_client_exec_input -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$@"
    fi
}

native_mysql_command_name() {
    if command_exists mariadb; then
        printf 'mariadb\n'
    else
        printf 'mysql\n'
    fi
}

native_mysql_exec() {
    local password
    local mysql_cmd
    password="$(backup_password_env_prefix)"
    mysql_cmd="$(native_mysql_command_name)"
    if [[ -n "$password" ]]; then
        env "MYSQL_PWD=${password}" "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$@"
    else
        "$mysql_cmd" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$@"
    fi
}

mysql_quote_identifier() {
    local value="$1"
    value="${value//\`/\`\`}"
    printf '`%s`' "$value"
}

clean_restore_target() {
    local db_ident

    info "Preparing clean restore target..."
    case "$BACKUP_DB_TYPE" in
        postgresql|postgres)
            if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
                docker_postgres_exec -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO public;' || return 1
            else
                native_postgres_exec -c 'DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public; GRANT ALL ON SCHEMA public TO public;' || return 1
            fi
            ;;
        mysql|mariadb)
            db_ident="$(mysql_quote_identifier "$BACKUP_DB_NAME")"
            if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
                docker_mysql_exec -e "DROP DATABASE IF EXISTS ${db_ident}; CREATE DATABASE ${db_ident};" || return 1
            else
                native_mysql_exec -e "DROP DATABASE IF EXISTS ${db_ident}; CREATE DATABASE ${db_ident};" || return 1
            fi
            ;;
        mongodb)
            return 0
            ;;
    esac
}

download_remote_restore_file() {
    local files=()
    local file
    local choice
    local remote_base
    local remote
    local remote_path
    local local_file

    ensure_rclone_available_for_backup || return 1
    remote="$(select_rclone_remote)" || return 1
    remote_path="$(ask_input "Remote backup path" "hostctl/backups")" || return 1
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
    clean_restore_target || {
        error "Failed to prepare clean restore target."
        return 1
    }

    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        case "$BACKUP_DB_TYPE" in
            postgresql|postgres)
                if [[ -n "$password" ]]; then
                    sql_stream_restore "$file" docker_target_exec_input env "PGPASSWORD=${password}" psql -v ON_ERROR_STOP=1 -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                else
                    sql_stream_restore "$file" docker_target_exec_input psql -v ON_ERROR_STOP=1 -h "${BACKUP_DB_HOST:-127.0.0.1}" -p "${BACKUP_DB_PORT:-5432}" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                fi
                ;;
            mysql|mariadb)
                if [[ -n "$password" ]]; then
                    sql_stream_restore "$file" docker_target_exec_input env "MYSQL_PWD=${password}" "$(docker_mysql_client_command_name)" -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                else
                    sql_stream_restore "$file" docker_mysql_client_exec_input -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                fi
                ;;
            mongodb)
                [[ "$file" == *.archive.gz ]] || { error "MongoDB restore requires a .archive.gz backup."; return 1; }
                docker_target_exec sh -c 'command -v mongorestore >/dev/null 2>&1' || {
                    error "mongorestore not found in selected Docker target."
                    return 1
                }
                docker_target_exec_input mongorestore --uri="$(mongo_connection_uri)" --archive --gzip --drop < "$file"
                ;;
        esac
    else
        case "$BACKUP_DB_TYPE" in
            postgresql|postgres)
                if [[ -n "$password" ]]; then
                    sql_stream_restore "$file" env "PGPASSWORD=${password}" psql -v ON_ERROR_STOP=1 -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                else
                    sql_stream_restore "$file" psql -v ON_ERROR_STOP=1 -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME"
                fi
                ;;
            mysql|mariadb)
                if [[ -n "$password" ]]; then
                    sql_stream_restore "$file" env "MYSQL_PWD=${password}" "$(native_mysql_command_name)" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                else
                    sql_stream_restore "$file" "$(native_mysql_command_name)" -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "$BACKUP_DB_NAME"
                fi
                ;;
            mongodb)
                [[ "$file" == *.archive.gz ]] || { error "MongoDB restore requires a .archive.gz backup."; return 1; }
                command_exists mongorestore || { error "mongorestore not found."; return 1; }
                mongorestore --uri="$(mongo_connection_uri)" --archive="$file" --gzip --drop
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

    info "Creating mandatory safety backup before restore..."
    local original_destination="$BACKUP_DESTINATION"
    BACKUP_DESTINATION="local"
    BACKUP_LOCAL_PATH="${BACKUP_DATABASE_DIR}/pre-restore"
    if ! with_backup_lock "pre-restore-$(sanitize_backup_name "$BACKUP_DB_NAME")" run_database_backup "pre-restore-$(sanitize_backup_name "$BACKUP_DB_NAME")" "pre_restore"; then
        BACKUP_DESTINATION="$original_destination"
        error "Safety backup failed. Restore cancelled."
        return 1
    fi
    BACKUP_RESTORE_SAFETY_FILE="$BACKUP_LAST_LOCAL_FILE"
    BACKUP_DESTINATION="$original_destination"
    info "Safety backup preserved at: ${BACKUP_RESTORE_SAFETY_FILE}"

    confirm_name="$(ask_input "Type database name to confirm restore")" || return 1
    if [[ "$confirm_name" != "$BACKUP_DB_NAME" ]]; then
        warning "Restore cancelled."
        return 0
    fi

    trap 'restore_interrupted; exit 130' INT
    restore_database_from_file "$file" || {
        trap - INT
        log_event "RESTORE_FAILED database=${BACKUP_DB_NAME}"
        error "RESTORE FAILED"
        if [[ -n "${BACKUP_RESTORE_SAFETY_FILE:-}" ]]; then
            info "Safety backup preserved at: ${BACKUP_RESTORE_SAFETY_FILE}"
        fi
        return 1
    }
    trap - INT

    BACKUP_PREFLIGHT_DONE=0
    preflight_database_config || {
        log_event "RESTORE_VALIDATE_FAILED database=${BACKUP_DB_NAME}"
        error "RESTORE VALIDATION FAILED"
        if [[ -n "${BACKUP_RESTORE_SAFETY_FILE:-}" ]]; then
            info "Safety backup preserved at: ${BACKUP_RESTORE_SAFETY_FILE}"
        fi
        return 1
    }

    success "Database restore completed."
    success "Database connectivity verified."
    log_event "RESTORE database=${BACKUP_DB_NAME} result=success"
}
