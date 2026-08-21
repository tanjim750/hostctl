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

    source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

    info "Installing hostctl into ${HOSTCTL_HOME}..."

    mkdir -p "$HOSTCTL_HOME"

    cp -a "${source_dir}/hostctl.sh" "${HOSTCTL_HOME}/hostctl.sh"
    cp -a "${source_dir}/lib" "${HOSTCTL_HOME}/"

    if [[ -d "${source_dir}/templates" ]]; then
        cp -a "${source_dir}/templates" "${HOSTCTL_HOME}/"
    fi

    mkdir -p \
        "${HOSTCTL_HOME}/logs" \
        "${HOSTCTL_HOME}/state" \
        "${HOSTCTL_HOME}/backups"

    chmod +x "${HOSTCTL_HOME}/hostctl.sh"

    find "${HOSTCTL_HOME}/lib" \
        -type f \
        -name "*.sh" \
        -exec chmod +x {} \;

    ln -sfn "${HOSTCTL_HOME}/hostctl.sh" /usr/local/bin/hostctl

    success "hostctl registered as a system-wide command."
}

verify_installation() {
    echo
    info "Verifying installation..."

    local failed=0

    if [[ -x /usr/local/bin/hostctl ]]; then
        success "hostctl command registered."
    else
        error "hostctl command registration failed."
        failed=1
    fi

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

    if (( failed != 0 )); then
        die "hostctl initialization completed with critical errors."
    fi

    echo
    success "hostctl initialization completed."
    info "Run: sudo hostctl --help"
}

cmd_init() {
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

    install_base_packages

    install_docker
    install_nginx
    install_certbot
    install_ufw
    install_fail2ban
    install_rclone

    install_hostctl_systemwide
    verify_installation

    log_event "hostctl initialization completed"
}