#!/usr/bin/env bash

# =========================================================
# hostctl - Database Diagnostics / Health
# =========================================================

# ---------------------------------------------------------
# Database diagnostics
# ---------------------------------------------------------

DB_DIAG_TIMEOUT="${DB_DIAG_TIMEOUT:-12}"
DB_DIAG_LONG_QUERY_SECONDS="${DB_DIAG_LONG_QUERY_SECONDS:-300}"
DB_DIAG_IDLE_TX_SECONDS="${DB_DIAG_IDLE_TX_SECONDS:-300}"
diag_short_query() {
    local value="$1"

    value="${value//$'\n'/ }"
    value="${value//$'\t'/ }"
    printf '%s\n' "${value:0:180}"
}

diag_postgres_query() {
    local sql="$1"
    local password
    local mode
    local args=()
    local arg

    password="$(backup_password_env_prefix)"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        if [[ "${BACKUP_DIAG_MODE:-0}" -eq 1 && ( -z "${BACKUP_RUNTIME_CONTAINER:-}" || "${BACKUP_RUNTIME_CONTAINER_STATE:-}" != "running" ) ]]; then
            printf 'Docker runtime container unavailable: state=%s\n' "${BACKUP_RUNTIME_CONTAINER_STATE:-unknown}"
            return 1
        fi
        mode="$(docker_postgres_connection_mode)" || return 1
        while IFS= read -r -d '' arg; do
            args+=("$arg")
        done < <(docker_postgres_base_connection_args "$mode")
        timeout_command "$DB_DIAG_TIMEOUT" docker_postgres_exec_noninteractive "$password" \
            psql -At -F '|' "${args[@]}" -d "$BACKUP_DB_NAME" -c "$sql"
    else
        if [[ -n "$password" ]]; then
            timeout_command "$DB_DIAG_TIMEOUT" env "PGPASSWORD=${password}" PGPASSFILE=/dev/null \
                psql -w -At -F '|' -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c "$sql"
        else
            timeout_command "$DB_DIAG_TIMEOUT" env PGPASSFILE=/dev/null \
                psql -w -At -F '|' -h "$BACKUP_DB_HOST" -p "$BACKUP_DB_PORT" -U "$BACKUP_DB_USER" -d "$BACKUP_DB_NAME" -c "$sql"
        fi
    fi
}

diag_mysql_query() {
    local sql="$1"
    local password
    local client
    local db_args=()

    [[ -n "${BACKUP_DB_NAME:-}" ]] && db_args+=("--database=${BACKUP_DB_NAME}")

    password="$(backup_password_env_prefix)"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        if [[ "${BACKUP_DIAG_MODE:-0}" -eq 1 && ( -z "${BACKUP_RUNTIME_CONTAINER:-}" || "${BACKUP_RUNTIME_CONTAINER_STATE:-}" != "running" ) ]]; then
            printf 'Docker runtime container unavailable: state=%s\n' "${BACKUP_RUNTIME_CONTAINER_STATE:-unknown}"
            return 1
        fi
        client="$(docker_mysql_client_command_name)"
        if [[ -n "$password" ]]; then
            timeout_command "$DB_DIAG_TIMEOUT" docker_target_exec_env "MYSQL_PWD=${password}" "$client" \
                --batch --raw --skip-column-names -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "${db_args[@]}" -e "$sql"
        else
            timeout_command "$DB_DIAG_TIMEOUT" docker_target_exec "$client" \
                --batch --raw --skip-column-names -h "${BACKUP_DB_HOST:-127.0.0.1}" -P "${BACKUP_DB_PORT:-3306}" -u "$BACKUP_DB_USER" "${db_args[@]}" -e "$sql"
        fi
    else
        client="$(native_mysql_command_name)"
        if [[ -n "$password" ]]; then
            timeout_command "$DB_DIAG_TIMEOUT" env "MYSQL_PWD=${password}" "$client" \
                --batch --raw --skip-column-names -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "${db_args[@]}" -e "$sql"
        else
            timeout_command "$DB_DIAG_TIMEOUT" "$client" \
                --batch --raw --skip-column-names -h "$BACKUP_DB_HOST" -P "$BACKUP_DB_PORT" -u "$BACKUP_DB_USER" "${db_args[@]}" -e "$sql"
        fi
    fi
}

diag_mongo_shell_name() {
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        [[ "${BACKUP_DIAG_MODE:-0}" -eq 0 || -n "${BACKUP_RUNTIME_CONTAINER:-}" ]] || return 1
        if docker_target_has_executable mongosh; then
            printf 'mongosh\n'
        elif docker_target_has_executable mongo; then
            printf 'mongo\n'
        else
            return 1
        fi
    else
        if command_exists mongosh; then
            printf 'mongosh\n'
        elif command_exists mongo; then
            printf 'mongo\n'
        else
            return 1
        fi
    fi
}

diag_mongo_eval() {
    local js="$1"
    local shell
    local uri

    shell="$(diag_mongo_shell_name)" || return 1
    uri="$(mongo_connection_uri)"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        if [[ "${BACKUP_DIAG_MODE:-0}" -eq 1 && ( -z "${BACKUP_RUNTIME_CONTAINER:-}" || "${BACKUP_RUNTIME_CONTAINER_STATE:-}" != "running" ) ]]; then
            printf 'Docker runtime container unavailable: state=%s\n' "${BACKUP_RUNTIME_CONTAINER_STATE:-unknown}"
            return 1
        fi
        timeout_command "$DB_DIAG_TIMEOUT" docker_target_exec "$shell" "$uri" --quiet --eval "$js"
    else
        timeout_command "$DB_DIAG_TIMEOUT" "$shell" "$uri" --quiet --eval "$js"
    fi
}

DB_HEALTH_WARN_COUNT=0
DB_HEALTH_FAIL_COUNT=0
DB_HEALTH_UNKNOWN_COUNT=0
DB_HEALTH_UNSUPPORTED_COUNT=0
DB_HEALTH_BACKUP_RISK=0
DB_DIAGNOSTIC_RENDER_MODE="health"
DB_DIAGNOSTIC_RESULT_COUNT=0
DB_DIAGNOSTIC_FIX_SELECTED=0
DB_DIAGNOSTIC_PROFILE=""
DB_DIAGNOSTIC_IDS=()
DB_DIAGNOSTIC_TITLES=()
DB_DIAGNOSTIC_STATUSES=()
DB_DIAGNOSTIC_SUMMARIES=()
DB_DIAGNOSTIC_DETAILS=()
DB_DIAGNOSTIC_FIX_SUPPORTED=()

health_reset() {
    DB_HEALTH_WARN_COUNT=0
    DB_HEALTH_FAIL_COUNT=0
    DB_HEALTH_UNKNOWN_COUNT=0
    DB_HEALTH_UNSUPPORTED_COUNT=0
    DB_HEALTH_BACKUP_RISK=0
    DB_DIAGNOSTIC_RESULT_COUNT=0
    DB_DIAGNOSTIC_FIX_SELECTED=0
    DB_DIAGNOSTIC_IDS=()
    DB_DIAGNOSTIC_TITLES=()
    DB_DIAGNOSTIC_STATUSES=()
    DB_DIAGNOSTIC_SUMMARIES=()
    DB_DIAGNOSTIC_DETAILS=()
    DB_DIAGNOSTIC_FIX_SUPPORTED=()
}

health_icon() {
    case "$1" in
        PASS)
            if [[ "${HOSTCTL_ASCII_HEALTH:-0}" == "1" ]]; then
                printf 'OK'
            else
                printf '✓'
            fi
            ;;
        WARNING) printf '!' ;;
        FAIL) printf 'X' ;;
        UNKNOWN) printf '?' ;;
        UNSUPPORTED) printf '-' ;;
    esac
}

health_record() {
    local status="$1"
    local label="$2"
    local detail="${3:-}"
    local detail_body="${4:-}"
    local icon
    local result_id

    case "$status" in
        WARNING) DB_HEALTH_WARN_COUNT=$((DB_HEALTH_WARN_COUNT + 1)) ;;
        FAIL) DB_HEALTH_FAIL_COUNT=$((DB_HEALTH_FAIL_COUNT + 1)) ;;
        UNKNOWN) DB_HEALTH_UNKNOWN_COUNT=$((DB_HEALTH_UNKNOWN_COUNT + 1)) ;;
        UNSUPPORTED) DB_HEALTH_UNSUPPORTED_COUNT=$((DB_HEALTH_UNSUPPORTED_COUNT + 1)) ;;
    esac

    result_id="$((DB_DIAGNOSTIC_RESULT_COUNT + 1))"
    DB_DIAGNOSTIC_IDS+=("$result_id")
    DB_DIAGNOSTIC_TITLES+=("$label")
    DB_DIAGNOSTIC_STATUSES+=("$status")
    DB_DIAGNOSTIC_SUMMARIES+=("$detail")
    DB_DIAGNOSTIC_DETAILS+=("$(diagnostic_detail_for_result "$status" "$label" "$detail" "$detail_body")")
    DB_DIAGNOSTIC_FIX_SUPPORTED+=("0")
    DB_DIAGNOSTIC_RESULT_COUNT=$((DB_DIAGNOSTIC_RESULT_COUNT + 1))

    [[ "$DB_DIAGNOSTIC_RENDER_MODE" == "health" ]] || return 0

    icon="$(health_icon "$status")"
    if [[ -n "$detail" ]]; then
        printf '%d. [%s] %s — %s\n' "$result_id" "$icon" "$label" "$detail"
    else
        printf '%d. [%s] %s\n' "$result_id" "$icon" "$label"
    fi
}

diagnostic_detail_for_result() {
    local status="$1"
    local label="$2"
    local detail="${3:-}"
    local detail_body="${4:-}"

    printf '%s\n' "$label"
    printf '%s\n\n' "----------------------------------------"
    printf 'Status: %s\n' "$status"
    [[ -n "$detail" ]] && printf 'Summary: %s\n' "$detail"
    if [[ -n "$detail_body" ]]; then
        echo
        echo "Details:"
        printf '%s\n' "$detail_body"
    fi
    echo
    case "$status" in
        PASS)
            echo "Result:"
            echo "- This check completed successfully."
            ;;
        WARNING)
            echo "Risk:"
            echo "- Current conditions may degrade reliability or backup readiness."
            echo
            echo "Recommended:"
            echo "- Run sudo hostctl --db-diagnose again if the condition persists."
            echo "- Inspect the relevant application/database session lifecycle."
            ;;
        FAIL)
            echo "Risk:"
            echo "- This condition can affect database availability or backup safety."
            echo
            echo "Recommended:"
            echo "- Inspect the affected database sessions, locks, runtime, or credentials."
            echo "- Avoid terminating sessions until the owner and transaction impact are understood."
            ;;
        UNKNOWN)
            echo "Reason:"
            echo "- hostctl could not verify this check with the current permissions/tools."
            echo
            echo "Recommended:"
            echo "- Confirm diagnostic client availability and database monitoring privileges."
            ;;
        UNSUPPORTED)
            echo "Reason:"
            echo "- This check is not applicable or is not safely detectable for this target."
            ;;
    esac
}

health_overall() {
    if [[ "$DB_HEALTH_FAIL_COUNT" -gt 0 ]]; then
        printf 'FAIL\n'
    elif [[ "$DB_HEALTH_WARN_COUNT" -gt 0 || "$DB_HEALTH_UNKNOWN_COUNT" -gt 0 ]]; then
        printf 'WARN\n'
    else
        printf 'OK\n'
    fi
}

health_exit_code() {
    local overall="$1"

    case "$overall" in
        OK) printf '0\n' ;;
        FAIL) printf '1\n' ;;
        WARN) printf '2\n' ;;
        *) printf '3\n' ;;
    esac
}

diagnostic_confidence() {
    if [[ "$DB_HEALTH_UNKNOWN_COUNT" -gt 0 || "$DB_HEALTH_UNSUPPORTED_COUNT" -gt 0 ]]; then
        printf 'Partial\n'
    else
        printf 'Full\n'
    fi
}

render_diagnostic_checklist() {
    local i
    local icon
    local summary

    for i in "${!DB_DIAGNOSTIC_IDS[@]}"; do
        icon="$(health_icon "${DB_DIAGNOSTIC_STATUSES[$i]}")"
        summary="${DB_DIAGNOSTIC_SUMMARIES[$i]}"
        if [[ -n "$summary" ]]; then
            printf '%d. [%s] %s — %s\n' "$((i + 1))" "$icon" "${DB_DIAGNOSTIC_TITLES[$i]}" "$summary"
        else
            printf '%d. [%s] %s\n' "$((i + 1))" "$icon" "${DB_DIAGNOSTIC_TITLES[$i]}"
        fi
    done
}

render_diagnostic_header() {
    local title="$1"

    echo
    printf '%s\n' "$title"
    echo
    printf 'Engine: %s\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
    printf 'Database: %s\n' "${BACKUP_DB_NAME:-configured/uri}"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        printf 'Source: Docker\n'
    else
        printf 'Source: Native / External\n'
    fi
    echo
}

show_diagnostic_detail() {
    local choice="$1"
    local idx=$((choice - 1))

    [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$DB_DIAGNOSTIC_RESULT_COUNT" ]] || return 1
    DB_DIAGNOSTIC_FIX_SELECTED="$choice"
    echo
    printf '%s\n' "${DB_DIAGNOSTIC_DETAILS[$idx]}"
}

show_diagnostic_actions() {
    local idx
    local action
    local has_fix=0

    [[ "$DB_DIAGNOSTIC_FIX_SELECTED" =~ ^[0-9]+$ && "$DB_DIAGNOSTIC_FIX_SELECTED" -ge 1 ]] || return 0
    idx=$((DB_DIAGNOSTIC_FIX_SELECTED - 1))
    [[ "${DB_DIAGNOSTIC_FIX_SUPPORTED[$idx]:-0}" == "1" ]] && has_fix=1

    echo
    echo "Possible Actions"
    echo "----------------------------------------"
    echo
    if [[ "$has_fix" -eq 1 ]]; then
        echo "1. Fix selected issue"
        echo "2. Re-run diagnosis"
        echo "3. Exit"
        action="$(ask_input "Select [1-3]" "3")" || return 0
        case "$action" in
            1) apply_diagnostic_fix "$DB_DIAGNOSTIC_FIX_SELECTED" ;;
            2) return 2 ;;
            *) return 0 ;;
        esac
    else
        warning "Automatic fix unavailable."
        echo
        echo "Recommended:"
        echo "Inspect application transaction/session lifecycle."
        echo
        echo "1. Re-run diagnosis"
        echo "2. Exit"
        action="$(ask_input "Select [1-2]" "2")" || return 0
        if [[ "$action" == "1" ]]; then
            return 2
        fi
        return 0
    fi
}

apply_diagnostic_fix() {
    local selected="$1"

    warning "Automatic fix unavailable for selected check ${selected}."
    echo
    echo "Recommended:"
    echo "Inspect the reported database session, lock, or runtime condition manually."
    return 0
}

diagnostic_detail_loop() {
    local prompt="Show details [1-${DB_DIAGNOSTIC_RESULT_COUNT}, 0 to continue]"
    local choice
    local action_status

    while true; do
        choice="$(ask_input "$prompt" "0")" || return 0
        if [[ "$choice" == "0" ]]; then
            return 0
        fi
        if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le "$DB_DIAGNOSTIC_RESULT_COUNT" ]]; then
            show_diagnostic_detail "$choice"
            set +e
            show_diagnostic_actions
            action_status=$?
            set -e
            case "$action_status" in
                2) return 2 ;;
            esac
            prompt="Show another detail [1-${DB_DIAGNOSTIC_RESULT_COUNT}, 0 to continue]"
        else
            warning "Invalid selection."
        fi
    done
}

health_show_header() {
    echo
    echo "Database Health"
    echo
    printf 'Engine: %s\n' "$(db_engine_label "$BACKUP_DB_TYPE")"
    printf 'Database: %s\n' "${BACKUP_DB_NAME:-configured/uri}"
    if [[ "$BACKUP_SOURCE_MODE" == "docker" ]]; then
        printf 'Source: Docker\n'
    else
        printf 'Source: Native / External\n'
    fi
    echo
}

health_docker_runtime() {
    local state
    local health
    local container=""
    local containers=()
    local id

    if [[ "$BACKUP_SOURCE_MODE" != "docker" ]]; then
        health_record UNSUPPORTED "Container/runtime state unsupported" "native/external target"
        return 0
    fi

    if [[ "${BACKUP_DOCKER_TARGET_TYPE:-service}" == "container" ]]; then
        if ! docker inspect "$BACKUP_DOCKER_CONTAINER" >/dev/null 2>&1; then
            health_record FAIL "Container/runtime state failed" "container not found: ${BACKUP_DOCKER_CONTAINER}"
            return 1
        fi
        container="$BACKUP_DOCKER_CONTAINER"
    else
        if [[ "$BACKUP_CRON_MODE" -eq 1 ]]; then
            while IFS= read -r id; do
                [[ -n "$id" ]] && containers+=("$id")
            done < <(backup_compose_exec --profile '*' ps -a -q "$BACKUP_DB_SERVICE" 2>/dev/null || backup_compose_exec ps -a -q "$BACKUP_DB_SERVICE" 2>/dev/null || true)
            if [[ "${#containers[@]}" -eq 0 ]]; then
                health_record FAIL "Container/runtime state failed" "no runtime container for service: ${BACKUP_DB_SERVICE}"
                return 1
            fi
            if [[ "${#containers[@]}" -gt 1 ]]; then
                health_record UNKNOWN "Container/runtime state unknown" "multiple containers match service: ${BACKUP_DB_SERVICE}"
                return 0
            fi
            container="${containers[0]}"
        else
            container="$(resolve_compose_service_container "$BACKUP_DB_SERVICE")" || {
                health_record FAIL "Container/runtime state failed" "no runtime container for service: ${BACKUP_DB_SERVICE}"
                return 1
            }
        fi
        [[ -n "$container" ]] || {
            health_record FAIL "Container/runtime state failed" "no runtime container for service: ${BACKUP_DB_SERVICE}"
            return 1
        }
    fi

    state="$(docker inspect -f '{{.State.Status}}' "$container" 2>/dev/null || true)"
    BACKUP_RUNTIME_CONTAINER="$container"
    BACKUP_RUNTIME_CONTAINER_STATE="$state"
    BACKUP_DOCKER_IMAGE="$(container_image_for_display "$container")"

    if [[ "$state" != "running" ]]; then
        health_record FAIL "Container/runtime state failed" "container=$(container_name_for_display "$container"), state=${state:-unknown}"
        return 1
    fi

    health="$(container_health_status "$container")"
    case "$health" in
        unhealthy)
            health_record FAIL "Container/runtime state failed" "container health is unhealthy"
            return 1
            ;;
        starting)
            health_record WARNING "Container/runtime state warning" "container health is still starting"
            return 0
            ;;
        *)
            health_record PASS "Container/runtime state passed"
            return 0
            ;;
    esac
}

health_check_backup_tool() {
    if [[ "$BACKUP_SOURCE_MODE" == "docker" && ( -z "${BACKUP_RUNTIME_CONTAINER:-}" || "${BACKUP_RUNTIME_CONTAINER_STATE:-}" != "running" ) ]]; then
        health_record UNKNOWN "DB client/tool availability unknown" "Docker runtime is not available"
        return 0
    fi

    case "$BACKUP_SOURCE_MODE:$BACKUP_DB_TYPE" in
        docker:postgresql|docker:postgres)
            docker_target_has_executable pg_dump &&
                health_record PASS "DB client/tool availability passed" "pg_dump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "pg_dump not found in selected executor"
            ;;
        docker:mysql)
            docker_target_has_executable mysqldump &&
                health_record PASS "DB client/tool availability passed" "mysqldump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mysqldump not found in selected executor"
            ;;
        docker:mariadb)
            { docker_target_has_executable mariadb-dump || docker_target_has_executable mysqldump; } &&
                health_record PASS "DB client/tool availability passed" "MariaDB dump client available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mariadb-dump/mysqldump not found in selected executor"
            ;;
        docker:mongodb)
            docker_target_has_executable mongodump &&
                health_record PASS "DB client/tool availability passed" "mongodump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mongodump not found in selected executor"
            ;;
        native:postgresql|native:postgres)
            command_exists pg_dump &&
                health_record PASS "DB client/tool availability passed" "pg_dump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "pg_dump not found"
            ;;
        native:mysql)
            command_exists mysqldump &&
                health_record PASS "DB client/tool availability passed" "mysqldump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mysqldump not found"
            ;;
        native:mariadb)
            { command_exists mariadb-dump || command_exists mysqldump; } &&
                health_record PASS "DB client/tool availability passed" "MariaDB dump client available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mariadb-dump/mysqldump not found"
            ;;
        native:mongodb)
            command_exists mongodump &&
                health_record PASS "DB client/tool availability passed" "mongodump available" ||
                health_record UNKNOWN "DB client/tool availability unknown" "mongodump not found"
            ;;
    esac
}

diag_postgres_session_details() {
    local sql="$1"
    local output

    output="$(diag_postgres_query "$sql" 2>/dev/null || true)"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | while IFS='|' read -r pid user db client state age wait blockers query; do
            [[ -n "$pid" ]] || continue
            printf -- '- PID: %s | user=%s | db=%s | client=%s | state=%s | age=%s | wait=%s | blockers=%s\n' \
                "${pid:-unknown}" "${user:-unknown}" "${db:-unknown}" "${client:-unknown}" \
                "${state:-unknown}" "${age:-unknown}" "${wait:-none}" "${blockers:-none}"
            [[ -n "${query:-}" ]] && printf '  query: %s\n' "$(diag_short_query "$query")"
        done
    fi
}

diag_postgres_stale_transaction_details() {
    diag_postgres_session_details "select pid, usename, datname, coalesce(client_addr::text,''), coalesce(state,''), coalesce(now()-xact_start, interval '0')::text, coalesce(wait_event_type || ':' || wait_event,''), array_to_string(pg_blocking_pids(pid), ','), regexp_replace(coalesce(query,''), '[[:space:]]+', ' ', 'g') from pg_stat_activity where pid <> pg_backend_pid() and xact_start is not null and now()-xact_start > (${DB_DIAG_IDLE_TX_SECONDS} || ' seconds')::interval order by xact_start asc limit 5;"
}

diag_postgres_idle_transaction_details() {
    diag_postgres_session_details "select pid, usename, datname, coalesce(client_addr::text,''), coalesce(state,''), coalesce(now()-coalesce(xact_start,query_start), interval '0')::text, coalesce(wait_event_type || ':' || wait_event,''), array_to_string(pg_blocking_pids(pid), ','), regexp_replace(coalesce(query,''), '[[:space:]]+', ' ', 'g') from pg_stat_activity where pid <> pg_backend_pid() and state like 'idle in transaction%' and now()-coalesce(xact_start,query_start) > (${DB_DIAG_IDLE_TX_SECONDS} || ' seconds')::interval order by coalesce(xact_start,query_start) asc limit 5;"
}

diag_postgres_long_query_details() {
    diag_postgres_session_details "select pid, usename, datname, coalesce(client_addr::text,''), coalesce(state,''), coalesce(now()-query_start, interval '0')::text, coalesce(wait_event_type || ':' || wait_event,''), array_to_string(pg_blocking_pids(pid), ','), regexp_replace(coalesce(query,''), '[[:space:]]+', ' ', 'g') from pg_stat_activity where pid <> pg_backend_pid() and state='active' and now()-query_start > (${DB_DIAG_LONG_QUERY_SECONDS} || ' seconds')::interval order by query_start asc limit 5;"
}

diag_postgres_lock_details() {
    diag_postgres_session_details "select pid, usename, datname, coalesce(client_addr::text,''), coalesce(state,''), coalesce(now()-coalesce(query_start,xact_start), interval '0')::text, coalesce(wait_event_type || ':' || wait_event,''), array_to_string(pg_blocking_pids(pid), ','), regexp_replace(coalesce(query,''), '[[:space:]]+', ' ', 'g') from pg_stat_activity where pid <> pg_backend_pid() and (coalesce(array_length(pg_blocking_pids(pid), 1), 0) > 0 or wait_event_type='Lock') order by coalesce(query_start,xact_start) asc limit 5;"
}

diag_mysql_process_details() {
    local where_clause="$1"
    local output

    output="$(diag_mysql_query "SELECT ID, USER, COALESCE(DB,''), COALESCE(HOST,''), COMMAND, TIME, COALESCE(STATE,''), LEFT(REPLACE(REPLACE(COALESCE(INFO,''), CHAR(10), ' '), CHAR(9), ' '), 160) FROM information_schema.PROCESSLIST WHERE ${where_clause} ORDER BY TIME DESC LIMIT 5;" 2>/dev/null || true)"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | while IFS=$'\t' read -r id user db host command seconds state info; do
            [[ -n "$id" ]] || continue
            printf -- '- Session: %s | user=%s | db=%s | client=%s | command=%s | age=%ss | state=%s\n' \
                "${id:-unknown}" "${user:-unknown}" "${db:-unknown}" "${host:-unknown}" \
                "${command:-unknown}" "${seconds:-unknown}" "${state:-unknown}"
            [[ -n "${info:-}" ]] && printf '  query: %s\n' "$(diag_short_query "$info")"
        done
    fi
}

diag_mysql_stale_transaction_details() {
    local output

    output="$(diag_mysql_query "SELECT trx_mysql_thread_id, trx_started, trx_state, COALESCE(trx_query,''), TIMESTAMPDIFF(SECOND,trx_started,NOW()) FROM information_schema.INNODB_TRX WHERE TIMESTAMPDIFF(SECOND,trx_started,NOW()) > ${DB_DIAG_IDLE_TX_SECONDS} ORDER BY trx_started ASC LIMIT 5;" 2>/dev/null || true)"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | while IFS=$'\t' read -r thread started state query seconds; do
            [[ -n "$thread" ]] || continue
            printf -- '- Thread: %s | state=%s | age=%ss | started=%s\n' \
                "${thread:-unknown}" "${state:-unknown}" "${seconds:-unknown}" "${started:-unknown}"
            [[ -n "${query:-}" ]] && printf '  query: %s\n' "$(diag_short_query "$query")"
        done
    fi
}

diag_mysql_lock_wait_details() {
    local output

    output="$(diag_mysql_query "SELECT REQUESTING_ENGINE_TRANSACTION_ID, BLOCKING_ENGINE_TRANSACTION_ID, OBJECT_SCHEMA, OBJECT_NAME, LOCK_TYPE, LOCK_MODE FROM performance_schema.data_lock_waits JOIN performance_schema.data_locks ON data_lock_waits.REQUESTING_ENGINE_LOCK_ID=data_locks.ENGINE_LOCK_ID LIMIT 5;" 2>/dev/null || diag_mysql_query "SELECT requesting_trx_id, blocking_trx_id, '', '', '', '' FROM information_schema.INNODB_LOCK_WAITS LIMIT 5;" 2>/dev/null || true)"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | while IFS=$'\t' read -r waiting blocker schema object lock_type lock_mode; do
            [[ -n "$waiting" ]] || continue
            printf -- '- Waiting transaction: %s | blocker=%s | object=%s.%s | lock=%s %s\n' \
                "${waiting:-unknown}" "${blocker:-unknown}" "${schema:-unknown}" "${object:-unknown}" \
                "${lock_type:-unknown}" "${lock_mode:-unknown}"
        done
    fi
}

diag_mongo_currentop_details() {
    local match="$1"
    local output

    output="$(diag_mongo_eval 'var ops=db.getSiblingDB("admin").aggregate([{$currentOp:{allUsers:false,idleConnections:true,idleSessions:true}},{$match:'"${match}"'},{$limit:5}]).toArray(); ops.forEach(function(o){ print([o.opid||o.op||"", o.appName||"", o.client||"", o.active, o.secs_running||0, o.waitingForLock||false, (o.ns||""), JSON.stringify(o.command||o.query||{}).substring(0,160)].join("|")); });' 2>/dev/null || true)"
    if [[ -n "$output" ]]; then
        printf '%s\n' "$output" | while IFS='|' read -r opid app client active seconds waiting ns command; do
            [[ -n "$opid" || -n "$ns" || -n "$command" ]] || continue
            printf -- '- Operation: %s | app=%s | client=%s | active=%s | age=%ss | waitingForLock=%s | ns=%s\n' \
                "${opid:-unknown}" "${app:-unknown}" "${client:-unknown}" "${active:-unknown}" \
                "${seconds:-unknown}" "${waiting:-unknown}" "${ns:-unknown}"
            [[ -n "${command:-}" ]] && printf '  operation: %s\n' "$(diag_short_query "$command")"
        done
    fi
}

health_postgres() {
    local output
    local total max pct idle active idle_tx
    local stale idle_tx_count old_tx long_count lock_count deadlocks role size
    local lock_details

    health_check_backup_tool

    if output="$(diag_postgres_query 'select 1,current_database()' 2>&1)"; then
        health_record PASS "Connectivity passed"
        health_record PASS "Authentication passed"
        health_record PASS "Database availability passed" "database=${output#*|}"
    else
        output="$(diag_short_query "$output")"
        health_record FAIL "Connectivity failed" "$output"
        health_record FAIL "Authentication failed" "$output"
        health_record UNKNOWN "Database availability unknown" "connectivity failed"
        return 0
    fi

    output="$(diag_postgres_query "select count(*), current_setting('max_connections')::int, round(count(*) * 100.0 / current_setting('max_connections')::int, 1), count(*) filter (where state='idle'), count(*) filter (where state='active'), count(*) filter (where state like 'idle in transaction%') from pg_stat_activity;" 2>&1)" || {
        health_record UNKNOWN "Connection utilization unknown" "$(diag_short_query "$output")"
        health_record UNKNOWN "Excessive active connections unknown" "pg_stat_activity unavailable"
        output=""
    }
    if [[ -n "$output" ]]; then
        IFS='|' read -r total max pct idle active idle_tx <<< "$output"
        if [[ "${pct%.*}" =~ ^[0-9]+$ && "${pct%.*}" -ge 95 ]]; then
            health_record FAIL "Connection utilization failed" "total=${total}/${max} (${pct}%)"
        elif [[ "${pct%.*}" =~ ^[0-9]+$ && "${pct%.*}" -ge 75 ]]; then
            health_record WARNING "Connection utilization warning" "total=${total}/${max} (${pct}%)"
        else
            health_record PASS "Connection utilization passed" "total=${total}/${max} (${pct}%)"
        fi
        if [[ "$max" =~ ^[0-9]+$ && "$active" =~ ^[0-9]+$ && "$active" -ge $(( max * 80 / 100 )) ]]; then
            health_record WARNING "Excessive active connections warning" "active=${active}/${max}"
        else
            health_record PASS "Excessive active connections passed" "active=${active}"
        fi
    fi

    stale="$(diag_postgres_query "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and xact_start is not null and now()-xact_start > (${DB_DIAG_IDLE_TX_SECONDS} || ' seconds')::interval;" 2>/dev/null || true)"
    old_tx="$(diag_postgres_query "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and xact_start is not null and now()-xact_start > '1 hour'::interval;" 2>/dev/null || true)"
    if [[ "$old_tx" =~ ^[0-9]+$ && "$old_tx" -gt 0 ]]; then
        health_record FAIL "Stale transactions failed" "${old_tx} extremely old transaction(s)" "$(diag_postgres_stale_transaction_details)"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$stale" =~ ^[0-9]+$ && "$stale" -gt 0 ]]; then
        health_record WARNING "Stale transactions warning" "${stale} detected" "$(diag_postgres_stale_transaction_details)"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$stale" =~ ^[0-9]+$ ]]; then
        health_record PASS "Stale transactions passed"
    else
        health_record UNKNOWN "Stale transactions unknown" "pg_stat_activity unavailable"
    fi

    idle_tx_count="$(diag_postgres_query "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state like 'idle in transaction%' and now()-coalesce(xact_start,query_start) > (${DB_DIAG_IDLE_TX_SECONDS} || ' seconds')::interval;" 2>/dev/null || true)"
    if [[ "$idle_tx_count" =~ ^[0-9]+$ && "$idle_tx_count" -gt 0 ]]; then
        health_record WARNING "Idle-in-transaction warning" "${idle_tx_count} detected" "$(diag_postgres_idle_transaction_details)"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$idle_tx_count" =~ ^[0-9]+$ ]]; then
        health_record PASS "Idle-in-transaction passed"
    else
        health_record UNKNOWN "Idle-in-transaction unknown" "pg_stat_activity unavailable"
    fi

    long_count="$(diag_postgres_query "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and state='active' and now()-query_start > (${DB_DIAG_LONG_QUERY_SECONDS} || ' seconds')::interval;" 2>/dev/null || true)"
    if [[ "$long_count" =~ ^[0-9]+$ && "$long_count" -gt 0 ]]; then
        health_record WARNING "Long-running queries warning" "${long_count} detected" "$(diag_postgres_long_query_details)"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$long_count" =~ ^[0-9]+$ ]]; then
        health_record PASS "Long-running queries passed"
    else
        health_record UNKNOWN "Long-running queries unknown" "pg_stat_activity unavailable"
    fi

    lock_count="$(diag_postgres_query "select count(*) from pg_stat_activity where pid <> pg_backend_pid() and (coalesce(array_length(pg_blocking_pids(pid), 1), 0) > 0 or wait_event_type='Lock');" 2>/dev/null || true)"
    if [[ "$lock_count" =~ ^[0-9]+$ && "$lock_count" -gt 0 ]]; then
        lock_details="$(diag_postgres_lock_details)"
        health_record FAIL "Blocking sessions failed" "${lock_count} blocked/waiting session(s)" "$lock_details"
        health_record FAIL "Blocking chains failed" "active blockers detected" "$lock_details"
        health_record FAIL "Lock waits failed" "${lock_count} detected" "$lock_details"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$lock_count" =~ ^[0-9]+$ ]]; then
        health_record PASS "Blocking sessions passed"
        health_record PASS "Blocking chains passed"
        health_record PASS "Lock waits passed"
    else
        health_record UNKNOWN "Blocking sessions unknown" "pg_blocking_pids unavailable"
        health_record UNKNOWN "Blocking chains unknown" "pg_blocking_pids unavailable"
        health_record UNKNOWN "Lock waits unknown" "pg_stat_activity unavailable"
    fi

    deadlocks="$(diag_postgres_query "select deadlocks from pg_stat_database where datname = current_database();" 2>/dev/null || true)"
    [[ "$deadlocks" =~ ^[0-9]+$ ]] && health_record PASS "Deadlock check passed" "database_deadlocks=${deadlocks}" || health_record UNKNOWN "Deadlock check unknown" "pg_stat_database unavailable"

    size="$(diag_postgres_query "select pg_database_size(current_database());" 2>/dev/null || true)"
    [[ "$size" =~ ^[0-9]+$ ]] && health_record PASS "DB/storage availability passed" "database_size_bytes=${size}" || health_record UNKNOWN "DB/storage availability unknown" "size check unavailable"

    role="$(diag_postgres_query "select pg_is_in_recovery();" 2>/dev/null || true)"
    [[ -n "$role" ]] && health_record PASS "Replication/role check passed" "in_recovery=${role}" || health_record UNKNOWN "Replication/role check unknown" "role check unavailable"

    if [[ "$DB_HEALTH_BACKUP_RISK" -eq 1 ]]; then
        health_record WARNING "Backup readiness warning" "current transactions/locks may interfere"
    else
        health_record PASS "Backup readiness passed"
    fi
}

health_mysql_like() {
    local engine="$1"
    local output total sleep_count active_count max_conn pct stale lock_waits long_count deadlock_text db_size
    local lock_details stale_details

    health_check_backup_tool

    if output="$(diag_mysql_query "SELECT 1, DATABASE();" 2>&1)"; then
        health_record PASS "Connectivity passed"
        health_record PASS "Authentication passed"
        health_record PASS "Database availability passed" "database=${output#*$'\t'}"
    else
        output="$(diag_short_query "$output")"
        health_record FAIL "Connectivity failed" "$output"
        health_record FAIL "Authentication failed" "$output"
        health_record UNKNOWN "Database availability unknown" "connectivity failed"
        return 0
    fi

    total="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.PROCESSLIST;" 2>/dev/null || true)"
    sleep_count="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND='Sleep';" 2>/dev/null || true)"
    active_count="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND<>'Sleep';" 2>/dev/null || true)"
    max_conn="$(diag_mysql_query "SHOW VARIABLES LIKE 'max_connections';" 2>/dev/null | awk '{print $2}' || true)"
    if [[ "$total" =~ ^[0-9]+$ && "$max_conn" =~ ^[0-9]+$ && "$max_conn" -gt 0 ]]; then
        pct=$(( total * 100 / max_conn ))
        if [[ "$pct" -ge 95 ]]; then
            health_record FAIL "Connection utilization failed" "total=${total}/${max_conn} (${pct}%)"
        elif [[ "$pct" -ge 75 ]]; then
            health_record WARNING "Connection utilization warning" "total=${total}/${max_conn} (${pct}%)"
        else
            health_record PASS "Connection utilization passed" "total=${total}/${max_conn} (${pct}%)"
        fi
        if [[ "$active_count" =~ ^[0-9]+$ && "$active_count" -ge $(( max_conn * 80 / 100 )) ]]; then
            health_record WARNING "Excessive active connections warning" "active=${active_count}/${max_conn}"
        else
            health_record PASS "Excessive active connections passed" "active=${active_count:-unknown}"
        fi
    else
        health_record UNKNOWN "Connection utilization unknown" "PROCESS privilege or variable visibility may be restricted"
        health_record UNKNOWN "Excessive active connections unknown" "PROCESSLIST unavailable"
    fi

    long_count="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.PROCESSLIST WHERE COMMAND <> 'Sleep' AND TIME > ${DB_DIAG_LONG_QUERY_SECONDS};" 2>/dev/null || true)"
    if [[ "$long_count" =~ ^[0-9]+$ && "$long_count" -gt 0 ]]; then
        health_record WARNING "Long-running queries warning" "${long_count} detected" "$(diag_mysql_process_details "COMMAND <> 'Sleep' AND TIME > ${DB_DIAG_LONG_QUERY_SECONDS}")"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$long_count" =~ ^[0-9]+$ ]]; then
        health_record PASS "Long-running queries passed"
    else
        health_record UNKNOWN "Long-running queries unknown" "PROCESSLIST unavailable"
    fi

    stale="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.INNODB_TRX WHERE TIMESTAMPDIFF(SECOND,trx_started,NOW()) > ${DB_DIAG_IDLE_TX_SECONDS};" 2>/dev/null || true)"
    if [[ "$stale" =~ ^[0-9]+$ && "$stale" -gt 0 ]]; then
        stale_details="$(diag_mysql_stale_transaction_details)"
        health_record WARNING "Stale transactions warning" "${stale} detected" "$stale_details"
        health_record WARNING "Idle-in-transaction warning" "review InnoDB transaction state" "$stale_details"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$stale" =~ ^[0-9]+$ ]]; then
        health_record PASS "Stale transactions passed"
        health_record PASS "Idle-in-transaction passed"
    else
        health_record UNKNOWN "Stale transactions unknown" "INNODB_TRX unavailable"
        health_record UNSUPPORTED "Idle-in-transaction unsupported" "${engine} does not expose PostgreSQL-style idle transaction state"
    fi

    if [[ "$engine" == "MySQL" ]]; then
        lock_waits="$(diag_mysql_query "SELECT COUNT(*) FROM performance_schema.data_lock_waits;" 2>/dev/null || diag_mysql_query "SELECT COUNT(*) FROM information_schema.INNODB_LOCK_WAITS;" 2>/dev/null || true)"
    else
        lock_waits="$(diag_mysql_query "SELECT COUNT(*) FROM information_schema.INNODB_LOCK_WAITS;" 2>/dev/null || true)"
    fi
    if [[ "$lock_waits" =~ ^[0-9]+$ && "$lock_waits" -gt 0 ]]; then
        lock_details="$(diag_mysql_lock_wait_details)"
        health_record FAIL "Blocking sessions failed" "${lock_waits} lock wait(s)" "$lock_details"
        health_record FAIL "Blocking chains failed" "active lock waits detected" "$lock_details"
        health_record FAIL "Lock waits failed" "${lock_waits} detected" "$lock_details"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$lock_waits" =~ ^[0-9]+$ ]]; then
        health_record PASS "Blocking sessions passed"
        health_record PASS "Blocking chains passed"
        health_record PASS "Lock waits passed"
    else
        health_record UNKNOWN "Blocking sessions unknown" "lock wait views unavailable"
        health_record UNKNOWN "Blocking chains unknown" "lock wait views unavailable"
        health_record UNKNOWN "Lock waits unknown" "lock wait views unavailable"
    fi

    deadlock_text="$(diag_mysql_query "SHOW ENGINE INNODB STATUS;" 2>/dev/null | awk '/LATEST DETECTED DEADLOCK/{found=1} found && NR<200 {print} /------------/{if(found && ++n>1) exit}' | head -n 5 || true)"
    if [[ -n "$deadlock_text" ]]; then
        health_record WARNING "Deadlock check warning" "latest deadlock information is present"
    else
        health_record PASS "Deadlock check passed"
    fi

    db_size="$(diag_mysql_query "SELECT COALESCE(SUM(DATA_LENGTH + INDEX_LENGTH),0) FROM information_schema.TABLES WHERE TABLE_SCHEMA=DATABASE();" 2>/dev/null || true)"
    [[ "$db_size" =~ ^[0-9]+$ ]] && health_record PASS "DB/storage availability passed" "database_size_bytes=${db_size}" || health_record UNKNOWN "DB/storage availability unknown" "information_schema.TABLES unavailable"

    health_record UNSUPPORTED "Replication/role check unsupported" "not safely inferred by this health check"

    if [[ "$DB_HEALTH_BACKUP_RISK" -eq 1 ]]; then
        health_record WARNING "Backup readiness warning" "current transactions/locks may interfere"
    else
        health_record PASS "Backup readiness passed"
    fi
}

health_mongodb() {
    local output current available ops locks tx repl size long_seconds
    local lock_details

    long_seconds="$DB_DIAG_LONG_QUERY_SECONDS"
    [[ "$long_seconds" =~ ^[0-9]+$ ]] || long_seconds=300
    health_check_backup_tool

    if ! diag_mongo_shell_name >/dev/null 2>&1; then
        health_record UNKNOWN "Connectivity unknown" "mongosh/mongo unavailable"
        health_record UNKNOWN "Authentication unknown" "mongosh/mongo unavailable"
        health_record UNKNOWN "Database availability unknown" "diagnostic shell unavailable"
        return 0
    fi

    if output="$(diag_mongo_eval 'var r=db.runCommand({ping:1}); if (r.ok===1) print("ok"); else printjson(r);' 2>&1)"; then
        if [[ "$output" == *ok* ]]; then
            health_record PASS "Connectivity passed"
            health_record PASS "Authentication passed"
            health_record PASS "Database availability passed"
        else
            health_record UNKNOWN "Connectivity unknown" "$(diag_short_query "$output")"
            health_record UNKNOWN "Authentication unknown" "$(diag_short_query "$output")"
            health_record UNKNOWN "Database availability unknown" "unexpected ping output"
            return 0
        fi
    else
        output="$(diag_short_query "$output")"
        health_record FAIL "Connectivity failed" "$output"
        health_record FAIL "Authentication failed" "$output"
        health_record UNKNOWN "Database availability unknown" "connectivity failed"
        return 0
    fi

    output="$(diag_mongo_eval 'var s=db.serverStatus(); print([s.connections.current,s.connections.available].join("|"));' 2>&1)" || {
        health_record UNKNOWN "Connection utilization unknown" "$(diag_short_query "$output")"
        health_record UNKNOWN "Excessive active connections unknown" "serverStatus unavailable"
        output=""
    }
    if [[ "$output" == *"|"* ]]; then
        current="${output%%|*}"
        available="${output#*|}"
        if [[ "$available" =~ ^[0-9]+$ && "$available" -le 0 ]]; then
            health_record FAIL "Connection utilization failed" "available=${available}"
        elif [[ "$available" =~ ^[0-9]+$ && "$available" -lt 10 ]]; then
            health_record WARNING "Connection utilization warning" "current=${current}, available=${available}"
        else
            health_record PASS "Connection utilization passed" "current=${current}, available=${available}"
        fi
        health_record PASS "Excessive active connections passed" "current=${current}"
    fi

    ops="$(diag_mongo_eval 'var a=db.getSiblingDB("admin").aggregate([{$currentOp:{allUsers:false,idleConnections:true,idleSessions:true}},{$match:{active:true,secs_running:{$gt:'"${long_seconds}"'}}},{$count:"n"}]).toArray(); print(a.length ? a[0].n : 0);' 2>/dev/null || true)"
    locks="$(diag_mongo_eval 'var a=db.getSiblingDB("admin").aggregate([{$currentOp:{allUsers:false,idleConnections:true,idleSessions:true}},{$match:{waitingForLock:true}},{$count:"n"}]).toArray(); print(a.length ? a[0].n : 0);' 2>/dev/null || true)"
    tx="$(diag_mongo_eval 'var a=db.getSiblingDB("admin").aggregate([{$currentOp:{allUsers:false,idleConnections:true,idleSessions:true}},{$match:{"transaction.parameters.txnNumber":{$exists:true}}},{$count:"n"}]).toArray(); print(a.length ? a[0].n : 0);' 2>/dev/null || true)"

    if [[ "$tx" =~ ^[0-9]+$ && "$tx" -gt 0 ]]; then
        health_record WARNING "Stale transactions warning" "${tx} transaction operation(s) visible" "$(diag_mongo_currentop_details '{"transaction.parameters.txnNumber":{$exists:true}}')"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$tx" =~ ^[0-9]+$ ]]; then
        health_record PASS "Stale transactions passed"
    else
        health_record UNKNOWN "Stale transactions unknown" "\$currentOp unavailable or restricted"
    fi
    health_record UNSUPPORTED "Idle-in-transaction unsupported" "not a MongoDB health concept"

    if [[ "$ops" =~ ^[0-9]+$ && "$ops" -gt 0 ]]; then
        health_record WARNING "Long-running operations warning" "${ops} detected" "$(diag_mongo_currentop_details '{active:true,secs_running:{$gt:'"${long_seconds}"'}}')"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$ops" =~ ^[0-9]+$ ]]; then
        health_record PASS "Long-running operations passed"
    else
        health_record UNKNOWN "Long-running operations unknown" "\$currentOp unavailable or restricted"
    fi

    if [[ "$locks" =~ ^[0-9]+$ && "$locks" -gt 0 ]]; then
        lock_details="$(diag_mongo_currentop_details '{waitingForLock:true}')"
        health_record FAIL "Blocking sessions failed" "${locks} operation(s) waiting for lock" "$lock_details"
        health_record FAIL "Blocking chains failed" "lock wait operations detected" "$lock_details"
        health_record FAIL "Lock waits failed" "${locks} detected" "$lock_details"
        DB_HEALTH_BACKUP_RISK=1
    elif [[ "$locks" =~ ^[0-9]+$ ]]; then
        health_record PASS "Blocking sessions passed"
        health_record PASS "Blocking chains passed"
        health_record PASS "Lock waits passed"
    else
        health_record UNKNOWN "Blocking sessions unknown" "\$currentOp unavailable or restricted"
        health_record UNKNOWN "Blocking chains unknown" "\$currentOp unavailable or restricted"
        health_record UNKNOWN "Lock waits unknown" "\$currentOp unavailable or restricted"
    fi

    health_record UNSUPPORTED "Deadlock check unsupported" "MongoDB does not expose a SQL-style deadlock counter"

    size="$(diag_mongo_eval 'try { var s=db.stats(1); print(s.ok===1 ? Math.floor(s.storageSize||s.dataSize||0) : ""); } catch(e) { print(""); }' 2>/dev/null || true)"
    [[ "$size" =~ ^[0-9]+$ ]] && health_record PASS "DB/storage availability passed" "storage_bytes=${size}" || health_record UNKNOWN "DB/storage availability unknown" "db.stats unavailable"

    repl="$(diag_mongo_eval 'try { var r=db.adminCommand({replSetGetStatus:1}); print([r.set||"",r.myState||"",(r.members||[]).filter(function(m){return m.health!==1}).length].join("|")); } catch(e) { print("UNSUPPORTED|" + e.codeName); }' 2>/dev/null || true)"
    if [[ "$repl" == UNSUPPORTED* ]]; then
        health_record UNSUPPORTED "Replication/role check unsupported" "$(diag_short_query "$repl")"
    elif [[ "$repl" == *"|"* ]]; then
        health_record PASS "Replication/role check passed" "set|state|unhealthy_members=${repl}"
    else
        health_record UNKNOWN "Replication/role check unknown" "replica-set status unavailable"
    fi

    if [[ "$DB_HEALTH_BACKUP_RISK" -eq 1 ]]; then
        health_record WARNING "Backup readiness warning" "current operations/locks may interfere"
    else
        health_record PASS "Backup readiness passed"
    fi
}

run_database_health() {
    local overall
    local exit_code

    DB_DIAGNOSTIC_RENDER_MODE="health"
    health_reset
    health_show_header

    health_docker_runtime || true

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres) health_postgres ;;
        mysql) health_mysql_like "MySQL" ;;
        mariadb) health_mysql_like "MariaDB" ;;
        mongodb) health_mongodb ;;
        *) health_record UNKNOWN "Diagnostic permission/access availability unknown" "unsupported database engine: ${BACKUP_DB_TYPE}" ;;
    esac

    overall="$(health_overall)"
    echo
    printf 'Overall: %s\n' "$overall"
    if [[ "$overall" != "OK" ]]; then
        echo
        echo "Run for details:"
        echo "sudo hostctl --db-diagnose"
    fi

    exit_code="$(health_exit_code "$overall")"
    return "$exit_code"
}

run_db_diagnostic_checks() {
    health_reset
    health_docker_runtime || true

    case "$BACKUP_DB_TYPE" in
        postgresql|postgres) health_postgres ;;
        mysql) health_mysql_like "MySQL" ;;
        mariadb) health_mysql_like "MariaDB" ;;
        mongodb) health_mongodb ;;
        *) health_record UNKNOWN "Diagnostic permission/access availability unknown" "unsupported database engine: ${BACKUP_DB_TYPE}" ;;
    esac
}

run_database_diagnosis() {
    local overall
    local confidence
    local detail_status=0

    DB_DIAGNOSTIC_RENDER_MODE="diagnose"
    while true; do
        run_db_diagnostic_checks
        overall="$(health_overall)"
        confidence="$(diagnostic_confidence)"

        render_diagnostic_header "Database Diagnose"
        render_diagnostic_checklist
        echo
        printf 'Overall: %s\n' "$overall"
        printf 'Confidence: %s\n' "$confidence"
        echo

        set +e
        diagnostic_detail_loop
        detail_status=$?
        set -e
        [[ "$detail_status" -eq 2 ]] || break
    done

    return 0
}

parse_db_diagnostic_args() {
    DB_DIAGNOSTIC_PROFILE=""
    BACKUP_CRON_MODE=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --profile)
                if [[ $# -lt 2 || "${2:-}" == --* ]]; then
                    HOSTCTL_ERROR_HANDLED=1
                    error "--profile requires a profile name."
                    return 3
                fi
                DB_DIAGNOSTIC_PROFILE="$2"
                shift 2
                ;;
            --cron)
                BACKUP_CRON_MODE=1
                shift
                ;;
            *)
                HOSTCTL_ERROR_HANDLED=1
                error "Unknown database diagnostic option: $1"
                return 3
                ;;
        esac
    done

    if [[ "$BACKUP_CRON_MODE" -eq 1 && -z "$DB_DIAGNOSTIC_PROFILE" ]]; then
        HOSTCTL_ERROR_HANDLED=1
        error "--cron requires --profile."
        return 3
    fi
}

collect_db_diagnostic_context() {
    local source_choice=""

    if [[ -n "$DB_DIAGNOSTIC_PROFILE" ]]; then
        load_backup_profile "$DB_DIAGNOSTIC_PROFILE" || return 3
        backup_resolve_runtime_values || return 3
        return 0
    fi

    source_choice="$(
        select_option \
            "Database target:" \
            "Docker" \
            "Native / OS"
    )" || return 3

    case "$source_choice" in
        "Docker") collect_docker_database_config || return 3 ;;
        "Native / OS") collect_native_database_config || return 3 ;;
        *) return 3 ;;
    esac
}

cmd_db_health() {
    local status=0

    require_root
    require_debian_based
    ensure_backup_dirs
    BACKUP_DIAG_MODE=1

    parse_db_diagnostic_args "$@" || status=$?
    if [[ "$status" -eq 0 ]]; then
        collect_db_diagnostic_context || status=$?
    fi

    if [[ "$status" -eq 0 ]]; then
        run_database_health || status=$?
    fi

    BACKUP_DIAG_MODE=0
    if [[ "$status" -ne 0 ]]; then
        HOSTCTL_ERROR_HANDLED=1
    fi
    exit "$status"
}

cmd_db_diagnose() {
    local status=0

    require_root
    require_debian_based
    ensure_backup_dirs
    BACKUP_DIAG_MODE=1

    parse_db_diagnostic_args "$@" || status=$?
    if [[ "$status" -eq 0 ]]; then
        collect_db_diagnostic_context || status=$?
    fi

    if [[ "$status" -eq 0 ]]; then
        run_database_diagnosis || status=$?
    fi

    BACKUP_DIAG_MODE=0
    if [[ "$status" -ne 0 ]]; then
        HOSTCTL_ERROR_HANDLED=1
    fi
    return "$status"
}
