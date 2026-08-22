#!/usr/bin/env bash

# =========================================================
# hostctl - rclone Operations
# =========================================================

install_rclone() {
    if command_exists rclone; then
        success "rclone is already installed."
        return 0
    fi

    require_debian_based
    info "Installing rclone..."
    apt update
    apt install -y rclone
    command_exists rclone || {
        error "rclone installation failed."
        return 1
    }
    success "rclone installed."
}

rclone_show_remotes() {
    local remotes=()
    local remote

    if ! command_exists rclone; then
        warning "rclone is not installed."
        return 1
    fi

    while IFS= read -r remote; do
        [[ -n "$remote" ]] && remotes+=("$remote")
    done < <(rclone listremotes 2>/dev/null || true)

    echo
    echo "Configured rclone remotes:"
    echo
    if [[ "${#remotes[@]}" -eq 0 ]]; then
        echo "none"
    else
        local i
        for i in "${!remotes[@]}"; do
            printf '%d. %s\n' "$((i + 1))" "${remotes[$i]}"
        done
    fi
}

run_rclone_config_interactive() {
    local rc

    echo
    echo "rclone's interactive configuration will open."
    echo "Complete setup and choose q to return to hostctl."
    echo

    if ! confirm "Open rclone config now?" "yes"; then
        warning "rclone configuration cancelled."
        return 0
    fi

    set +e
    rclone config
    rc=$?
    set -e

    if [[ "$rc" -ne 0 ]]; then
        warning "rclone config exited with status ${rc}."
        return "$rc"
    fi

    success "Returned from rclone configuration."
}

cmd_rclone() {
    require_root
    require_debian_based

    echo
    echo "rclone"
    echo

    install_rclone || return 1
    rclone_show_remotes || return 1

    if confirm "Open rclone interactive configuration?" "yes"; then
        run_rclone_config_interactive || return 1
    fi

    rclone_show_remotes || return 1
}
