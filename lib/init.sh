#!/usr/bin/env bash

# =========================================================
# hostctl - Initialization
# =========================================================

install_base_packages() {
    info "Updating package index..."

    apt update

    local packages=(
        curl
        wget
        git
        unzip
        zip
        jq
        ca-certificates
        gnupg
        lsb-release
        htop
        net-tools
        cron
        software-properties-common
    )

    info "Installing base packages..."

    apt install -y "${packages[@]}"

    success "Base packages installed."
}

install_docker() {
    if command_exists docker; then
        success "Docker is already installed."
        docker --version || true
        return 0
    fi

    if ! confirm "Install Docker Engine and Docker Compose?" "yes"; then
        warning "Docker installation skipped."
        return 0
    fi

    info "Installing Docker..."

    apt install -y ca-certificates curl gnupg

    install -m 0755 -d /etc/apt/keyrings

    curl -fsSL https://download.docker.com/linux/debian/gpg \
        -o /etc/apt/keyrings/docker.asc

    chmod a+r /etc/apt/keyrings/docker.asc

    local codename
    codename="$(
        . /etc/os-release
        echo "${VERSION_CODENAME:-}"
    )"

    if [[ -z "$codename" ]]; then
        die "Unable to determine Debian codename for Docker repository."
    fi

    cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${codename} stable
EOF

    apt update

    apt install -y \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin

    systemctl enable --now docker

    success "Docker installed."

    docker --version
    docker compose version
}

install_nginx() {
    if command_exists nginx; then
        success "Nginx is already installed."
        return 0
    fi

    if confirm "Install Nginx?" "yes"; then
        apt install -y nginx
        systemctl enable --now nginx
        success "Nginx installed."
    else
        warning "Nginx installation skipped."
    fi
}

install_certbot() {
    if command_exists certbot; then
        success "Certbot is already installed."
        return 0
    fi

    if confirm "Install Certbot and Nginx plugin?" "yes"; then
        apt install -y certbot python3-certbot-nginx
        success "Certbot installed."
    else
        warning "Certbot installation skipped."
    fi
}

install_ufw() {
    if command_exists ufw; then
        success "UFW is already installed."
        return 0
    fi

    if confirm "Install UFW?" "yes"; then
        apt install -y ufw
        success "UFW installed."
    else
        warning "UFW installation skipped."
    fi
}

install_fail2ban() {
    if command_exists fail2ban-client; then
        success "Fail2Ban is already installed."
        return 0
    fi

    if confirm "Install Fail2Ban?" "yes"; then
        apt install -y fail2ban
        systemctl enable fail2ban
        success "Fail2Ban installed."
    else
        warning "Fail2Ban installation skipped."
    fi
}

install_rclone() {
    if command_exists rclone; then
        success "rclone is already installed."
        return 0
    fi

    if confirm "Install rclone?" "yes"; then
        apt install -y rclone
        success "rclone installed."
    else
        warning "rclone installation skipped."
    fi
}

install_hostctl_systemwide() {
    local source_dir
    local stage_dir
    local backup_dir=""
    local required_libs=(
        common.sh
        init.sh
        system.sh
        docker.sh
        nginx.sh
        ssl.sh
        firewall.sh
        backup.sh
        db_diagnostics.sh
        rclone.sh
    )
    local install_status=0

    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    info "Installing hostctl into ${HOSTCTL_HOME}..."

    validate_hostctl_source_tree "$source_dir" || return 1

    stage_dir="$(mktemp -d /tmp/hostctl-install.XXXXXX)" || {
        error "Failed to create installation staging directory."
        return 1
    }

    if ! cp -a "${source_dir}/hostctl.sh" "${stage_dir}/"; then
        rm -rf "$stage_dir"
        error "Failed to copy hostctl.sh:"
        error "cp -a ${source_dir}/hostctl.sh ${stage_dir}/"
        return 1
    fi

    if ! cp -a "${source_dir}/lib" "${stage_dir}/"; then
        rm -rf "$stage_dir"
        error "Failed to copy lib/:"
        error "cp -a ${source_dir}/lib ${stage_dir}/"
        return 1
    fi

    if [[ -d "${source_dir}/templates" ]]; then
        if ! cp -a "${source_dir}/templates" "${stage_dir}/"; then
            rm -rf "$stage_dir"
            error "Failed to copy templates/:"
            error "cp -a ${source_dir}/templates ${stage_dir}/"
            return 1
        fi
    fi

    validate_hostctl_staged_tree "$stage_dir" || {
        rm -rf "$stage_dir"
        return 1
    }

    chmod 755 "${stage_dir}/hostctl.sh"
    find "${stage_dir}/lib" -type d -exec chmod 755 {} \;
    find "${stage_dir}/lib" -type f -name "*.sh" -exec chmod 755 {} \;
    if [[ -d "${stage_dir}/templates" ]]; then
        find "${stage_dir}/templates" -type d -exec chmod 755 {} \;
        find "${stage_dir}/templates" -type f -exec chmod 644 {} \;
    fi

    ensure_hostctl_runtime_layout || {
        rm -rf "$stage_dir"
        return 1
    }

    backup_dir="$(mktemp -d "${HOSTCTL_HOME}/tmp/install-backup.XXXXXX")" || {
        rm -rf "$stage_dir"
        error "Failed to create installation rollback backup directory."
        return 1
    }

    backup_existing_hostctl_app "$backup_dir" || {
        rm -rf "$stage_dir" "$backup_dir"
        return 1
    }

    set +e
    install_staged_hostctl_app "$stage_dir"
    install_status=$?
    set -e

    if [[ "$install_status" -ne 0 ]]; then
        rollback_hostctl_app "$backup_dir"
        rm -rf "$stage_dir" "$backup_dir"
        return 1
    fi

    if ! bash -n "${HOSTCTL_HOME}/hostctl.sh"; then
        error "Installed hostctl.sh failed syntax validation after install."
        rollback_hostctl_app "$backup_dir"
        rm -rf "$stage_dir" "$backup_dir"
        return 1
    fi

    rm -rf "$stage_dir" "$backup_dir"

    chmod 755 "${HOSTCTL_HOME}/hostctl.sh"
    find "${HOSTCTL_HOME}/lib" -type f -name "*.sh" -exec chmod 755 {} \;

    success "hostctl application files installed."
}

validate_hostctl_source_tree() {
    local source_dir="$1"
    local required_libs=(
        common.sh
        init.sh
        system.sh
        docker.sh
        nginx.sh
        ssl.sh
        firewall.sh
        backup.sh
        db_diagnostics.sh
        rclone.sh
    )
    local lib

    [[ -f "${source_dir}/hostctl.sh" ]] || {
        error "Source hostctl.sh not found: ${source_dir}/hostctl.sh"
        return 1
    }

    [[ -d "${source_dir}/lib" ]] || {
        error "Source lib/ directory not found: ${source_dir}/lib"
        return 1
    }

    for lib in "${required_libs[@]}"; do
        [[ -f "${source_dir}/lib/${lib}" ]] || {
            error "Required library missing from source: ${source_dir}/lib/${lib}"
            return 1
        }
    done
}

validate_hostctl_staged_tree() {
    local stage_dir="$1"
    local file

    [[ -f "${stage_dir}/hostctl.sh" ]] || {
        error "Staged hostctl.sh missing: ${stage_dir}/hostctl.sh"
        return 1
    }

    [[ -d "${stage_dir}/lib" ]] || {
        error "Staged lib/ directory missing: ${stage_dir}/lib"
        return 1
    }

    if ! bash -n "${stage_dir}/hostctl.sh"; then
        error "Staged hostctl.sh failed syntax validation: ${stage_dir}/hostctl.sh"
        return 1
    fi

    for file in "${stage_dir}"/lib/*.sh; do
        [[ -f "$file" ]] || continue
        if ! bash -n "$file"; then
            error "Staged library failed syntax validation: $file"
            return 1
        fi
    done
}

backup_existing_hostctl_app() {
    local backup_dir="$1"

    if [[ -e "${HOSTCTL_HOME}/hostctl.sh" || -L "${HOSTCTL_HOME}/hostctl.sh" ]]; then
        mv "${HOSTCTL_HOME}/hostctl.sh" "${backup_dir}/hostctl.sh" || {
            error "Failed to backup existing hostctl.sh:"
            error "mv ${HOSTCTL_HOME}/hostctl.sh ${backup_dir}/hostctl.sh"
            return 1
        }
    fi

    if [[ -e "${HOSTCTL_HOME}/lib" || -L "${HOSTCTL_HOME}/lib" ]]; then
        mv "${HOSTCTL_HOME}/lib" "${backup_dir}/lib" || {
            error "Failed to backup existing lib/:"
            error "mv ${HOSTCTL_HOME}/lib ${backup_dir}/lib"
            return 1
        }
    fi

    if [[ -e "${HOSTCTL_HOME}/templates" || -L "${HOSTCTL_HOME}/templates" ]]; then
        mv "${HOSTCTL_HOME}/templates" "${backup_dir}/templates" || {
            error "Failed to backup existing templates/:"
            error "mv ${HOSTCTL_HOME}/templates ${backup_dir}/templates"
            return 1
        }
    fi
}

install_staged_hostctl_app() {
    local stage_dir="$1"

    if ! mv "${stage_dir}/hostctl.sh" "${HOSTCTL_HOME}/hostctl.sh"; then
        error "Failed to install hostctl.sh:"
        error "mv ${stage_dir}/hostctl.sh ${HOSTCTL_HOME}/hostctl.sh"
        return 1
    fi

    if ! mv "${stage_dir}/lib" "${HOSTCTL_HOME}/lib"; then
        error "Failed to install lib/:"
        error "mv ${stage_dir}/lib ${HOSTCTL_HOME}/lib"
        return 1
    fi

    if [[ -d "${stage_dir}/templates" ]]; then
        if ! mv "${stage_dir}/templates" "${HOSTCTL_HOME}/templates"; then
            error "Failed to install templates/:"
            error "mv ${stage_dir}/templates ${HOSTCTL_HOME}/templates"
            return 1
        fi
    fi
}

rollback_hostctl_app() {
    local backup_dir="$1"

    warning "Rolling back hostctl application files."
    rm -rf "${HOSTCTL_HOME}/hostctl.sh" "${HOSTCTL_HOME}/lib" "${HOSTCTL_HOME}/templates"

    [[ ! -e "${backup_dir}/hostctl.sh" ]] || mv "${backup_dir}/hostctl.sh" "${HOSTCTL_HOME}/hostctl.sh" || true
    [[ ! -e "${backup_dir}/lib" ]] || mv "${backup_dir}/lib" "${HOSTCTL_HOME}/lib" || true
    [[ ! -e "${backup_dir}/templates" ]] || mv "${backup_dir}/templates" "${HOSTCTL_HOME}/templates" || true
}

ensure_hostctl_runtime_layout() {
    mkdir -p \
        "$HOSTCTL_HOME" \
        "${HOSTCTL_HOME}/state" \
        "${HOSTCTL_HOME}/logs" \
        "${HOSTCTL_HOME}/backups" \
        "${HOSTCTL_HOME}/tmp" || {
        error "Failed to create hostctl runtime directories."
        return 1
    }

    chmod 755 "$HOSTCTL_HOME"
    chmod 700 \
        "${HOSTCTL_HOME}/state" \
        "${HOSTCTL_HOME}/logs" \
        "${HOSTCTL_HOME}/backups" \
        "${HOSTCTL_HOME}/tmp" 2>/dev/null || true
}

current_hostctl_script_path() {
    if [[ -n "${SCRIPT_PATH:-}" ]]; then
        printf '%s\n' "$SCRIPT_PATH"
    elif command -v readlink >/dev/null 2>&1 && readlink -f "${BASH_SOURCE[0]}" >/dev/null 2>&1; then
        readlink -f "${BASH_SOURCE[0]}"
    elif command -v realpath >/dev/null 2>&1; then
        realpath "${BASH_SOURCE[0]}"
    else
        cd "$(dirname "${BASH_SOURCE[0]}")/.." && printf '%s/hostctl.sh\n' "$(pwd -P)"
    fi
}

hostctl_running_from_registered_installation() {
    local current_script

    current_script="$(current_hostctl_script_path)"
    [[ "$current_script" == "${HOSTCTL_HOME}/hostctl.sh" ]]
}

hostctl_command_belongs_to_hostctl() {
    local path="$1"
    local target

    if [[ -L "$path" ]]; then
        target="$(readlink "$path" 2>/dev/null || true)"
        [[ "$target" == "${HOSTCTL_HOME}/hostctl.sh" || "$target" == *hostctl* ]] && return 0
    fi

    if [[ -f "$path" ]] && grep -Eq 'hostctl - Main CLI Router|HOSTCTL_VERSION|HOSTCTL_HOME="/etc/hostctl"' "$path" 2>/dev/null; then
        return 0
    fi

    return 1
}

hostctl_command_symlink_valid() {
    local command_path="/usr/local/bin/hostctl"

    [[ -L "$command_path" ]] &&
    [[ "$(readlink "$command_path" 2>/dev/null || true)" == "${HOSTCTL_HOME}/hostctl.sh" ]] &&
    [[ -x "$command_path" ]]
}

register_hostctl_command() {
    local command_path="/usr/local/bin/hostctl"

    info "Registering system command..."

    mkdir -p /usr/local/bin || {
        error "Failed to create /usr/local/bin."
        return 1
    }

    if [[ -e "$command_path" || -L "$command_path" ]]; then
        if ! hostctl_command_belongs_to_hostctl "$command_path"; then
            warning "An unrelated executable already exists at ${command_path}."
            if ! confirm "Replace it with the hostctl command symlink?" "no"; then
                error "System command registration cancelled."
                return 1
            fi
        fi
    fi

    if ! ln -sfn "${HOSTCTL_HOME}/hostctl.sh" "$command_path"; then
        error "Failed to register ${command_path}:"
        error "ln -sfn ${HOSTCTL_HOME}/hostctl.sh ${command_path}"
        error "Failed to register ${command_path}."
        return 1
    fi

    success "${command_path} -> ${HOSTCTL_HOME}/hostctl.sh"
}

repair_hostctl_command_if_needed() {
    if hostctl_command_symlink_valid; then
        success "/usr/local/bin/hostctl -> ${HOSTCTL_HOME}/hostctl.sh"
        return 0
    fi

    warning "hostctl command symlink is missing or broken; repairing."
    register_hostctl_command
}

verify_hostctl_installation() {
    local command_path="/usr/local/bin/hostctl"
    local required_libs=(
        common.sh
        init.sh
        system.sh
        docker.sh
        nginx.sh
        ssl.sh
        firewall.sh
        backup.sh
        db_diagnostics.sh
        rclone.sh
    )
    local lib
    local registered_path
    local failed=0
    local libs_failed=0

    echo
    info "Verifying installation..."

    if [[ -L "$command_path" && "$(readlink "$command_path")" == "${HOSTCTL_HOME}/hostctl.sh" && -x "$command_path" ]]; then
        success "hostctl command registered."
    else
        error "hostctl command registration failed: ${command_path}"
        failed=1
    fi

    if [[ ! -x "${HOSTCTL_HOME}/hostctl.sh" ]]; then
        error "Installed hostctl.sh missing or not executable: ${HOSTCTL_HOME}/hostctl.sh"
        failed=1
    fi

    registered_path="$(command -v hostctl 2>/dev/null || true)"
    if [[ "$registered_path" == "$command_path" ]]; then
        success "command -v hostctl: ${registered_path}"
    elif [[ -n "$registered_path" ]]; then
        error "hostctl resolves to ${registered_path}, expected ${command_path}."
        failed=1
    else
        error "hostctl is not discoverable in PATH."
        failed=1
    fi

    if "$command_path" --version >/dev/null 2>&1; then
        success "hostctl --version works."
    else
        error "hostctl --version failed."
        failed=1
    fi

    if "$command_path" --help >/dev/null 2>&1; then
        success "hostctl --help works."
    else
        error "hostctl --help failed."
        failed=1
    fi

    for lib in "${required_libs[@]}"; do
        if [[ ! -r "${HOSTCTL_HOME}/lib/${lib}" ]]; then
            error "Required library missing: ${HOSTCTL_HOME}/lib/${lib}"
            libs_failed=1
        fi
    done

    if [[ "$libs_failed" -eq 0 ]]; then
        success "Required libraries available."
    else
        failed=1
    fi

    if (( failed != 0 )); then
        error "hostctl installation verification failed."
        return 1
    fi

    return 0
}

verify_dependency_installation() {
    echo
    info "Verifying optional dependencies..."

    if command_exists docker; then
        success "Docker available."
    else
        warning "Docker not installed."
    fi

    if command_exists nginx; then
        success "Nginx available."
    else
        warning "Nginx not installed."
    fi

    if command_exists certbot; then
        success "Certbot available."
    else
        warning "Certbot not installed."
    fi

    if command_exists ufw; then
        success "UFW available."
    else
        warning "UFW not installed."
    fi

    if command_exists fail2ban-client; then
        success "Fail2Ban available."
    else
        warning "Fail2Ban not installed."
    fi

    if command_exists rclone; then
        success "rclone available."
    else
        warning "rclone not installed."
    fi
}

cmd_init() {
    local already_registered=0

    require_root
    require_debian_based

    echo
    echo "hostctl ${HOSTCTL_VERSION} initialization"
    echo "--------------------------------"
    echo

    if ! confirm "Start hostctl initialization?" "yes"; then
        warning "Initialization cancelled."
        return 0
    fi

    if hostctl_running_from_registered_installation; then
        already_registered=1
        info "hostctl is already running from the registered installation."
        info "Skipping system registration."
    fi

    install_base_packages

    install_docker
    install_nginx
    install_certbot
    install_ufw
    install_fail2ban
    install_rclone

    if [[ "$already_registered" -eq 1 ]]; then
        ensure_hostctl_runtime_layout
        repair_hostctl_command_if_needed
    else
        install_hostctl_systemwide
        register_hostctl_command
    fi

    verify_hostctl_installation
    verify_dependency_installation

    echo
    success "hostctl initialization completed."
    echo
    echo "Run:"
    echo "sudo hostctl --help"

    log_event "hostctl initialization completed"
}
