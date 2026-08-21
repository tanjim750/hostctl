#!/usr/bin/env bash

# =========================================================
# hostctl - Docker Operations
# =========================================================

# ---------------------------------------------------------
# Docker availability / installation
# ---------------------------------------------------------

ensure_docker_available() {
    if ! command_exists docker; then
        die "Docker is not installed. Run: sudo hostctl --docker"
    fi
}

ensure_docker_compose() {
    ensure_docker_available

    if ! docker compose version >/dev/null 2>&1; then
        die "Docker Compose plugin is not available. Run: sudo hostctl --docker"
    fi
}

ensure_docker_daemon() {
    ensure_docker_available

    if docker info >/dev/null 2>&1; then
        return 0
    fi

    error "Docker daemon is not running."

    if command_exists systemctl && confirm "Start Docker now?" "yes"; then
        systemctl enable --now docker || return 1
        docker info >/dev/null 2>&1 || die "Docker daemon is still unavailable."
        return 0
    fi

    return 1
}

ensure_docker_project_ready() {
    require_root
    require_debian_based
    ensure_docker_available
    ensure_docker_daemon
    ensure_docker_compose
}

detect_docker_repo() {
    local os_id=""
    local os_like=""
    local codename=""
    local repo_os=""

    if [[ -f /etc/os-release ]]; then
        # shellcheck disable=SC1091
        . /etc/os-release
        os_id="${ID:-}"
        os_like="${ID_LIKE:-}"
        codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    fi

    case "$os_id" in
        ubuntu)
            repo_os="ubuntu"
            ;;
        debian)
            repo_os="debian"
            ;;
        *)
            if [[ " ${os_like} " == *" debian "* ]]; then
                warning "Detected Debian-derived distribution: ${os_id:-unknown}."
                if confirm "Attempt Docker's Debian repository anyway?" "no"; then
                    repo_os="debian"
                else
                    die "Docker installation cancelled."
                fi
            else
                die "Unsupported distribution for automatic Docker installation."
            fi
            ;;
    esac

    if [[ -z "$codename" ]]; then
        die "Unable to determine distribution codename for Docker repository."
    fi

    printf '%s %s\n' "$repo_os" "$codename"
}

install_docker_engine() {
    local repo_info
    local repo_os
    local codename
    local repo_url

    repo_info="$(detect_docker_repo)"
    repo_os="${repo_info%% *}"
    codename="${repo_info##* }"
    repo_url="https://download.docker.com/linux/${repo_os}"

    log_event "DOCKER_INSTALL start repo_os=${repo_os} codename=${codename}"

    info "Installing Docker prerequisites..."
    apt update
    apt install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings

    info "Installing Docker repository key..."
    curl -fsSL "${repo_url}/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    info "Configuring Docker apt repository..."
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] %s %s stable\n' \
        "$(dpkg --print-architecture)" \
        "$repo_url" \
        "$codename" > /etc/apt/sources.list.d/docker.list

    apt update

    info "Installing Docker Engine and Compose plugin..."
    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    log_event "DOCKER_INSTALL success repo_os=${repo_os} codename=${codename}"
}

docker_daemon_state() {
    if command_exists systemctl; then
        systemctl is-active docker 2>/dev/null || true
    else
        docker info >/dev/null 2>&1 && printf 'active\n' || printf 'unavailable\n'
    fi
}

docker_count_lines() {
    wc -l | tr -d '[:space:]'
}

cmd_docker() {
    require_root
    require_debian_based

    echo
    echo "Docker"
    echo

    if ! command_exists docker; then
        if confirm "Docker is not installed. Install Docker Engine and Docker Compose?" "yes"; then
            install_docker_engine
        else
            warning "Docker installation skipped."
            log_event "DOCKER_CHECK skipped_install"
            return 0
        fi
    else
        success "Docker binary found."
    fi

    if ! docker info >/dev/null 2>&1; then
        warning "Docker daemon is not available."
        if command_exists systemctl && confirm "Start Docker now?" "yes"; then
            systemctl enable --now docker
        fi
    fi

    echo
    cmd_docker_status
}

cmd_docker_status() {
    require_root
    require_debian_based

    local engine="not installed"
    local compose="not available"
    local daemon="unavailable"
    local running="n/a"
    local total="n/a"
    local stopped="n/a"
    local images="n/a"

    echo
    echo "Docker Status"
    echo

    if command_exists docker; then
        engine="$(docker --version 2>/dev/null || printf 'installed')"
        daemon="$(docker_daemon_state)"

        if docker compose version >/dev/null 2>&1; then
            compose="$(docker compose version --short 2>/dev/null || docker compose version 2>/dev/null || printf 'available')"
        fi

        if docker info >/dev/null 2>&1; then
            running="$(docker ps -q 2>/dev/null | docker_count_lines)"
            total="$(docker ps -aq 2>/dev/null | docker_count_lines)"
            stopped=$((total - running))
            images="$(docker images -q 2>/dev/null | sort -u | docker_count_lines)"
        fi
    fi

    printf 'Engine:        %s\n' "$engine"
    printf 'Daemon:        %s\n' "$daemon"
    printf 'Compose:       %s\n' "$compose"
    printf 'Running:       %s\n' "$running"
    printf 'Stopped:       %s\n' "$stopped"
    printf 'Images:        %s\n' "$images"

    if command_exists docker && docker info >/dev/null 2>&1; then
        echo
        docker system df || true
    fi

    log_event "DOCKER_STATUS engine=${engine} daemon=${daemon} compose=${compose} running=${running} stopped=${stopped} images=${images}"
}

# ---------------------------------------------------------
# Compose helpers
# ---------------------------------------------------------

find_compose_files() {
    local project_dir

    project_dir="$(get_project_dir)"
    find "$project_dir" -maxdepth 1 -type f -name 'docker-compose*' | sort
}

get_compose_file() {
    local project_dir
    local files=()
    local file
    local choice
    local selected_index

    project_dir="$(get_project_dir)"

    while IFS= read -r file; do
        files+=("$file")
    done < <(find_compose_files)

    if [[ "${#files[@]}" -eq 0 ]]; then
        error "No docker-compose* file found in ${project_dir}"
        return 1
    fi

    if [[ "${#files[@]}" -eq 1 ]]; then
        info "Using: $(basename "${files[0]}")" >&2
        printf '%s\n' "${files[0]}"
        return 0
    fi

    echo "Multiple Docker Compose files found:" >&2
    echo >&2

    local i
    for i in "${!files[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "$(basename "${files[$i]}")" >&2
    done

    while true; do
        read -r -p "Select [1-${#files[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#files[@]} )); then
            selected_index=$((choice - 1))
            printf '%s\n' "${files[$selected_index]}"
            return 0
        fi

        warning "Invalid selection."
    done
}

compose_cmd() {
    local compose_file="$1"
    shift

    docker compose -f "$compose_file" "$@"
}

get_compose_services() {
    local compose_file="$1"

    compose_cmd "$compose_file" config --services
}

select_compose_service() {
    local compose_file="$1"
    local services=()
    local service
    local choice
    local selected_index

    while IFS= read -r service; do
        [[ -n "$service" ]] && services+=("$service")
    done < <(get_compose_services "$compose_file")

    if [[ "${#services[@]}" -eq 0 ]]; then
        die "No services found in $(basename "$compose_file")."
    fi

    echo "Services:" >&2
    echo >&2

    local i
    for i in "${!services[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${services[$i]}" >&2
    done

    while true; do
        read -r -p "Select [1-${#services[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#services[@]} )); then
            selected_index=$((choice - 1))
            printf '%s\n' "${services[$selected_index]}"
            return 0
        fi

        warning "Invalid selection."
    done
}

get_compose_container_ids() {
    local compose_file="$1"
    local service="${2:-}"

    if [[ -n "$service" ]]; then
        compose_cmd "$compose_file" ps -q "$service"
    else
        compose_cmd "$compose_file" ps -q
    fi
}

show_docker_project_context() {
    local compose_file="$1"

    echo
    printf 'Project: %s\n' "$(get_project_dir)"
    printf 'Compose: %s\n' "$(basename "$compose_file")"
    echo
}

prepare_docker_project_command() {
    local compose_file

    ensure_docker_project_ready
    compose_file="$(get_compose_file)" || return 1
    show_docker_project_context "$compose_file" >&2
    printf '%s\n' "$compose_file"
}

log_docker_result() {
    local operation="$1"
    local result="$2"
    local compose_file="$3"
    local details="${4:-}"

    log_event "${operation} result=${result} cwd=$(get_project_dir) compose=$(basename "$compose_file") ${details}"
}

# ---------------------------------------------------------
# Project operations
# ---------------------------------------------------------

cmd_docker_build() {
    local compose_file
    local mode
    local service=""
    local args=(build)
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(
        select_option \
            "Build mode:" \
            "Build all services" \
            "Build all services without cache" \
            "Build a specific service" \
            "Build a specific service without cache"
    )"

    case "$mode" in
        "Build all services")
            ;;
        "Build all services without cache")
            args+=(--no-cache)
            ;;
        "Build a specific service")
            service="$(select_compose_service "$compose_file")"
            args+=("$service")
            ;;
        "Build a specific service without cache")
            service="$(select_compose_service "$compose_file")"
            args+=(--no-cache "$service")
            ;;
    esac

    if ! confirm "Run Docker build?" "yes"; then
        warning "Docker build cancelled."
        return 0
    fi

    log_event "DOCKER_BUILD start cwd=$(get_project_dir) compose=$(basename "$compose_file") mode=${mode} service=${service:-all}"
    compose_cmd "$compose_file" "${args[@]}" || exit_code=$?
    log_docker_result "DOCKER_BUILD" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "mode=${mode} service=${service:-all}"
    return "$exit_code"
}

cmd_docker_start() {
    local compose_file
    local mode
    local service=""
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Start:" "Full compose stack" "Specific service")"

    if [[ "$mode" == "Specific service" ]]; then
        service="$(select_compose_service "$compose_file")"
    fi

    if [[ -n "$service" ]]; then
        compose_cmd "$compose_file" up -d "$service" || exit_code=$?
    else
        compose_cmd "$compose_file" up -d || exit_code=$?
    fi

    compose_cmd "$compose_file" ps || true
    log_docker_result "DOCKER_START" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "service=${service:-all}"
    return "$exit_code"
}

cmd_docker_stop() {
    local compose_file
    local mode
    local service=""
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Stop:" "Full compose stack" "Specific service")"

    if [[ "$mode" == "Specific service" ]]; then
        service="$(select_compose_service "$compose_file")"
    fi

    if [[ -n "$service" ]]; then
        compose_cmd "$compose_file" stop "$service" || exit_code=$?
    else
        compose_cmd "$compose_file" stop || exit_code=$?
    fi

    log_docker_result "DOCKER_STOP" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "service=${service:-all}"
    return "$exit_code"
}

cmd_docker_restart() {
    local compose_file
    local mode
    local service=""
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Restart:" "Full compose stack" "Specific service")"

    if [[ "$mode" == "Specific service" ]]; then
        service="$(select_compose_service "$compose_file")"
    fi

    if [[ -n "$service" ]]; then
        compose_cmd "$compose_file" restart "$service" || exit_code=$?
    else
        compose_cmd "$compose_file" restart || exit_code=$?
    fi

    compose_cmd "$compose_file" ps || true
    log_docker_result "DOCKER_RESTART" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "service=${service:-all}"
    return "$exit_code"
}

cmd_docker_rebuild() {
    local compose_file
    local strategy
    local service=""
    local no_cache_choice
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    strategy="$(
        select_option \
            "Rebuild strategy:" \
            "Build then recreate" \
            "Build without cache then recreate" \
            "Bring stack down, build, then start" \
            "Specific service rebuild"
    )"

    case "$strategy" in
        "Build then recreate")
            compose_cmd "$compose_file" build || exit_code=$?
            [[ "$exit_code" -eq 0 ]] && compose_cmd "$compose_file" up -d --force-recreate || exit_code=$?
            ;;
        "Build without cache then recreate")
            compose_cmd "$compose_file" build --no-cache || exit_code=$?
            [[ "$exit_code" -eq 0 ]] && compose_cmd "$compose_file" up -d --force-recreate || exit_code=$?
            ;;
        "Bring stack down, build, then start")
            warning "Temporary downtime will occur."
            if ! confirm "Continue with down/build/start rebuild?" "no"; then
                warning "Docker rebuild cancelled."
                return 0
            fi
            compose_cmd "$compose_file" down || exit_code=$?
            [[ "$exit_code" -eq 0 ]] && compose_cmd "$compose_file" build || exit_code=$?
            [[ "$exit_code" -eq 0 ]] && compose_cmd "$compose_file" up -d || exit_code=$?
            ;;
        "Specific service rebuild")
            service="$(select_compose_service "$compose_file")"
            no_cache_choice="$(select_option "Service build mode:" "Normal build" "Build without cache")"
            if [[ "$no_cache_choice" == "Build without cache" ]]; then
                compose_cmd "$compose_file" build --no-cache "$service" || exit_code=$?
            else
                compose_cmd "$compose_file" build "$service" || exit_code=$?
            fi
            [[ "$exit_code" -eq 0 ]] && compose_cmd "$compose_file" up -d --force-recreate "$service" || exit_code=$?
            ;;
    esac

    compose_cmd "$compose_file" ps || true
    log_docker_result "DOCKER_REBUILD" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "strategy=${strategy} service=${service:-all}"
    return "$exit_code"
}

cmd_docker_down() {
    local compose_file
    local args=(down)
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    if confirm "Also remove compose volumes?" "no"; then
        echo
        warning "WARNING:"
        warning "This can permanently delete database/storage data stored in Docker volumes."
        echo

        if confirm "Permanently remove compose volumes?" "no"; then
            args+=(--volumes)
        else
            warning "Volume removal skipped."
        fi
    fi

    if ! confirm "Bring compose stack down?" "yes"; then
        warning "Docker down cancelled."
        return 0
    fi

    compose_cmd "$compose_file" "${args[@]}" || exit_code=$?
    log_docker_result "DOCKER_DOWN" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "volumes=$([[ " ${args[*]} " == *" --volumes "* ]] && printf yes || printf no)"
    return "$exit_code"
}

cmd_docker_pull() {
    local compose_file
    local mode
    local service=""
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Pull:" "All services" "Specific service")"

    if [[ "$mode" == "Specific service" ]]; then
        service="$(select_compose_service "$compose_file")"
        compose_cmd "$compose_file" pull "$service" || exit_code=$?
    else
        compose_cmd "$compose_file" pull || exit_code=$?
    fi

    log_docker_result "DOCKER_PULL" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file" "service=${service:-all}"
    return "$exit_code"
}

cmd_docker_logs() {
    local compose_file
    local mode
    local service=""
    local follow_args=()
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Logs:" "All services" "Specific service")"

    if [[ "$mode" == "Specific service" ]]; then
        service="$(select_compose_service "$compose_file")"
    fi

    if confirm "Follow logs continuously?" "yes"; then
        follow_args=(-f)
    else
        follow_args=(--tail=200)
    fi

    set +e
    if [[ -n "$service" ]]; then
        compose_cmd "$compose_file" logs "${follow_args[@]}" "$service"
    else
        compose_cmd "$compose_file" logs "${follow_args[@]}"
    fi
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 130 ]]; then
        return 0
    fi

    return "$exit_code"
}

cmd_docker_ps() {
    local compose_file

    compose_file="$(prepare_docker_project_command)"

    if ! compose_cmd "$compose_file" ps -a; then
        compose_cmd "$compose_file" ps
    fi
}

# ---------------------------------------------------------
# Docker log clearing
# ---------------------------------------------------------

docker_log_driver() {
    local container="$1"

    docker inspect -f '{{.HostConfig.LogConfig.Type}}' "$container"
}

docker_log_path() {
    local container="$1"

    docker inspect -f '{{.LogPath}}' "$container"
}

container_display_name() {
    local container="$1"

    docker inspect -f '{{.Name}}' "$container" 2>/dev/null | sed 's#^/##'
}

file_size_bytes() {
    local file="$1"

    if [[ -f "$file" ]]; then
        stat -c '%s' "$file" 2>/dev/null || printf '0'
    else
        printf '0'
    fi
}

format_bytes() {
    local bytes="$1"

    awk -v bytes="$bytes" '
        BEGIN {
            split("B KB MB GB TB", unit, " ");
            size = bytes + 0;
            i = 1;
            while (size >= 1024 && i < 5) {
                size = size / 1024;
                i++;
            }
            if (i == 1) {
                printf "%d %s", size, unit[i];
            } else {
                printf "%.1f %s", size, unit[i];
            }
        }
    '
}

clear_container_log() {
    local container="$1"
    local driver
    local log_path
    local before_size
    local name

    name="$(container_display_name "$container")"
    [[ -n "$name" ]] || name="$container"

    driver="$(docker_log_driver "$container" 2>/dev/null || true)"

    if [[ "$driver" != "json-file" ]]; then
        warning "Container ${name} uses ${driver:-unknown}; direct log truncation skipped."
        return 0
    fi

    log_path="$(docker_log_path "$container" 2>/dev/null || true)"

    if [[ -z "$log_path" || ! -f "$log_path" || "$log_path" != /var/lib/docker/containers/* ]]; then
        warning "Container ${name} log path is not safe to truncate; skipped."
        return 0
    fi

    before_size="$(file_size_bytes "$log_path")"
    truncate -s 0 "$log_path" || return 1

    success "Cleared ${name} log ($(format_bytes "$before_size") reclaimed)."
}

select_compose_container() {
    local compose_file="$1"
    local service
    local containers=()
    local container
    local choice
    local selected_index

    service="$(select_compose_service "$compose_file")"

    while IFS= read -r container; do
        [[ -n "$container" ]] && containers+=("$container")
    done < <(get_compose_container_ids "$compose_file" "$service")

    if [[ "${#containers[@]}" -eq 0 ]]; then
        die "No running containers found for service: ${service}"
    fi

    if [[ "${#containers[@]}" -eq 1 ]]; then
        printf '%s\n' "${containers[0]}"
        return 0
    fi

    echo "Containers:" >&2
    echo >&2

    local i
    for i in "${!containers[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "$(container_display_name "${containers[$i]}")" >&2
    done

    while true; do
        read -r -p "Select [1-${#containers[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] &&
           (( choice >= 1 && choice <= ${#containers[@]} )); then
            selected_index=$((choice - 1))
            printf '%s\n' "${containers[$selected_index]}"
            return 0
        fi

        warning "Invalid selection."
    done
}

cmd_docker_logs_clear() {
    local compose_file
    local mode
    local container
    local containers=()
    local exit_code=0

    compose_file="$(prepare_docker_project_command)"

    mode="$(select_option "Clear Docker logs:" "Specific service/container" "All containers in this compose stack")"

    if [[ "$mode" == "Specific service/container" ]]; then
        container="$(select_compose_container "$compose_file")"
        if ! confirm "Clear logs for selected container?" "no"; then
            warning "Docker log clear cancelled."
            return 0
        fi

        log_event "DOCKER_LOG_CLEAR start cwd=$(get_project_dir) compose=$(basename "$compose_file") container=${container}"
        clear_container_log "$container" || exit_code=$?
    else
        while IFS= read -r container; do
            [[ -n "$container" ]] && containers+=("$container")
        done < <(get_compose_container_ids "$compose_file")

        if [[ "${#containers[@]}" -eq 0 ]]; then
            warning "No running containers found for this compose stack."
            return 0
        fi

        warning "This will truncate json-file logs for ${#containers[@]} running compose container(s)."
        if ! confirm "Clear all current compose container logs?" "no"; then
            warning "Docker log clear cancelled."
            return 0
        fi

        log_event "DOCKER_LOG_CLEAR start cwd=$(get_project_dir) compose=$(basename "$compose_file") containers=${#containers[@]}"

        for container in "${containers[@]}"; do
            clear_container_log "$container" || exit_code=$?
        done
    fi

    log_docker_result "DOCKER_LOG_CLEAR" "$([[ "$exit_code" -eq 0 ]] && printf success || printf failed)" "$compose_file"
    return "$exit_code"
}
