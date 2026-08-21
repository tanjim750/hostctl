#!/usr/bin/env bash

# =========================================================
# hostctl - Firewall / UFW Operations
# =========================================================

FIREWALL_STATE_DIR="${HOSTCTL_STATE_DIR}/firewall"
FIREWALL_LAST_BACKUP_DIR=""

# ---------------------------------------------------------
# UFW / environment helpers
# ---------------------------------------------------------

ensure_ufw_installed() {
    if command_exists ufw; then
        return 0
    fi

    echo
    echo "UFW is not installed."
    if ! confirm "Install UFW?" "yes"; then
        warning "UFW installation skipped."
        return 1
    fi

    log_event "FIREWALL_INSTALL start"
    apt update
    apt install -y ufw
    log_event "FIREWALL_INSTALL result=success"
}

ufw_installed() {
    command_exists ufw
}

ufw_is_active() {
    local status

    status="$(ufw status 2>/dev/null | awk 'NR == 1 { print; exit }' || true)"
    [[ "$status" =~ Status:[[:space:]]+active ]]
}

ufw_status_value() {
    local key="$1"

    ufw status verbose 2>/dev/null |
        awk -F: -v key="$key" '$1 == key { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit }'
}

show_docker_ufw_warning() {
    if command_exists docker; then
        warning "Docker is installed."
        warning "Published Docker ports may bypass UFW rules depending on Docker networking/iptables configuration."
        warning "Avoid exposing application/database ports publicly unless required."
    fi
}

detect_ssh_client_ip() {
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        printf '%s\n' "${SSH_CONNECTION%% *}"
        return 0
    fi

    if [[ -n "${SSH_CLIENT:-}" ]]; then
        printf '%s\n' "${SSH_CLIENT%% *}"
        return 0
    fi

    return 1
}

is_ssh_session() {
    [[ -n "${SSH_CONNECTION:-}" || -n "${SSH_CLIENT:-}" ]]
}

detect_ssh_port() {
    local server_port
    local detected

    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        server_port="$(awk '{print $4}' <<< "$SSH_CONNECTION")"
        if fw_validate_port "$server_port"; then
            printf '%s\n' "$server_port"
            return 0
        fi
    fi

    if command_exists sshd; then
        detected="$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)"
        if fw_validate_port "$detected"; then
            printf '%s\n' "$detected"
            return 0
        fi
    fi

    if command_exists ss; then
        detected="$(
            ss -ltnp 2>/dev/null |
                awk '/sshd/ {
                    split($4, parts, ":");
                    port = parts[length(parts)];
                    if (port ~ /^[0-9]+$/) { print port; exit }
                }' || true
        )"
        if fw_validate_port "$detected"; then
            printf '%s\n' "$detected"
            return 0
        fi
    fi

    printf '22\n'
}

fw_validate_port() {
    local port="$1"

    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 ))
}

validate_protocol() {
    local protocol

    protocol="$(tr '[:upper:]' '[:lower:]' <<< "$1")"
    case "$protocol" in
        tcp|udp|both) return 0 ;;
        *) return 1 ;;
    esac
}

validate_ip() {
    local value="$1"
    local ip="${value%%/*}"
    local cidr=""
    local o1
    local o2
    local o3
    local o4

    [[ "$value" != *[[:space:]\;\`\$\\\|\&\<\>\(\)\{\}]* ]] || return 1

    if [[ "$value" == */* ]]; then
        cidr="${value##*/}"
        [[ "$cidr" =~ ^[0-9]+$ ]] || return 1
    fi

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS=. read -r o1 o2 o3 o4 <<< "$ip"
        (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
        [[ -z "$cidr" ]] || (( cidr >= 0 && cidr <= 32 ))
        return
    fi

    if [[ "$ip" == *:* && "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        [[ -z "$cidr" ]] || (( cidr >= 0 && cidr <= 128 ))
        return
    fi

    return 1
}

validate_cidr() {
    [[ "$1" == */* ]] && validate_ip "$1"
}

normalize_comment() {
    local comment="$1"

    comment="${comment//[^A-Za-z0-9:._-]/-}"
    printf '%s\n' "${comment:0:48}"
}

ufw_status_output() {
    ufw status verbose 2>/dev/null || true
}

ufw_rule_exists() {
    local action="$1"
    local port="$2"
    local proto="$3"
    local source="${4:-Anywhere}"
    local action_upper

    action_upper="$(tr '[:lower:]' '[:upper:]' <<< "$action")"
    ufw_status_output |
        awk -v port="${port}/${proto}" -v action="$action_upper" -v source="$source" '
            $0 ~ port && $0 ~ action {
                if (source == "Anywhere") {
                    if ($0 ~ /Anywhere/) found = 1;
                } else if (index($0, source)) {
                    found = 1;
                }
            }
            END { exit found ? 0 : 1 }
        '
}

ssh_rule_exists() {
    local port="$1"

    ufw_rule_exists allow "$port" tcp "Anywhere" ||
    ufw_status_output | awk -v port="${port}/tcp" '$0 ~ port && $0 ~ /ALLOW/ { found = 1 } END { exit found ? 0 : 1 }'
}

ufw_run_with_optional_comment() {
    local comment="$1"
    shift
    local args=("$@")

    if [[ -n "$comment" ]]; then
        if ufw "${args[@]}" comment "$comment"; then
            return 0
        fi
        warning "UFW comments are not supported in this command form; retrying without comment."
    fi

    ufw "${args[@]}"
}

ufw_allow_rule() {
    local port="$1"
    local proto="$2"
    local source="$3"
    local comment="$4"

    if ufw_rule_exists allow "$port" "$proto" "$source"; then
        info "Matching allow rule already exists."
        return 0
    fi

    if [[ "$source" == "Anywhere" ]]; then
        ufw_run_with_optional_comment "$comment" allow "${port}/${proto}"
    else
        ufw_run_with_optional_comment "$comment" allow from "$source" to any port "$port" proto "$proto"
    fi
}

ufw_deny_rule() {
    local port="$1"
    local proto="$2"
    local source="$3"
    local comment="$4"

    if ufw_rule_exists deny "$port" "$proto" "$source"; then
        info "Matching deny rule already exists."
        return 0
    fi

    if [[ "$source" == "Anywhere" ]]; then
        ufw_run_with_optional_comment "$comment" deny "${port}/${proto}"
    else
        ufw_run_with_optional_comment "$comment" deny from "$source" to any port "$port" proto "$proto"
    fi
}

ensure_ssh_firewall_rule() {
    local port="${1:-}"

    [[ -n "$port" ]] || port="$(detect_ssh_port)"
    fw_validate_port "$port" || {
        error "Invalid SSH port detected: ${port}"
        return 1
    }

    if ssh_rule_exists "$port"; then
        return 0
    fi

    if is_ssh_session; then
        echo
        echo "Current SSH session detected."
        echo
        printf 'Client IP: %s\n' "$(detect_ssh_client_ip || printf 'unknown')"
        printf 'SSH port: %s\n' "$port"
        echo
        echo "SSH access must be preserved before enabling UFW."
    fi

    if confirm "Allow TCP ${port}?" "yes"; then
        ufw_allow_rule "$port" tcp "Anywhere" "hostctl:ssh"
        return
    fi

    if is_ssh_session; then
        error "Refusing to continue without preserving the active SSH port."
        return 1
    fi

    warning "SSH allow rule skipped."
    return 0
}

nginx_detected() {
    command_exists nginx || systemctl is-active nginx >/dev/null 2>&1
}

# ---------------------------------------------------------
# Interactive input
# ---------------------------------------------------------

prompt_firewall_port() {
    local port

    while true; do
        port="$(ask_input "Port")" || return 1
        if fw_validate_port "$port"; then
            printf '%s\n' "$port"
            return 0
        fi
        warning "Invalid port. Use 1-65535."
    done
}

prompt_firewall_protocols() {
    local choice

    choice="$(
        select_option \
            "Protocol:" \
            "TCP" \
            "UDP" \
            "Both"
    )" || return 1

    case "$choice" in
        "TCP") printf 'tcp\n' ;;
        "UDP") printf 'udp\n' ;;
        "Both") printf 'tcp udp\n' ;;
    esac
}

prompt_firewall_source() {
    local choice
    local source

    choice="$(
        select_option \
            "Source:" \
            "Anywhere" \
            "Specific IP" \
            "CIDR"
    )" || return 1

    case "$choice" in
        "Anywhere")
            printf 'Anywhere\n'
            ;;
        "Specific IP")
            while true; do
                source="$(ask_input "IP address")" || return 1
                if validate_ip "$source" && [[ "$source" != */* ]]; then
                    printf '%s\n' "$source"
                    return 0
                fi
                warning "Invalid IP address."
            done
            ;;
        "CIDR")
            while true; do
                source="$(ask_input "CIDR")" || return 1
                if validate_cidr "$source"; then
                    printf '%s\n' "$source"
                    return 0
                fi
                warning "Invalid CIDR."
            done
            ;;
    esac
}

prompt_firewall_comment() {
    local default_comment="$1"
    local comment

    comment="$(ask_input "Comment" "optional")" || return 1
    if [[ "$comment" == "optional" || -z "$comment" ]]; then
        printf '%s\n' "$default_comment"
    else
        printf 'hostctl:custom:%s\n' "$(normalize_comment "$comment")"
    fi
}

show_rule_summary() {
    local action="$1"
    local port="$2"
    local protocols="$3"
    local source="$4"

    echo
    echo "Rule:"
    echo
    printf 'Action: %s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$action")"
    printf 'Port: %s\n' "$port"
    printf 'Protocol: %s\n' "$(tr '[:lower:]' '[:upper:]' <<< "$protocols")"
    printf 'Source: %s\n' "$source"
    echo
}

# ---------------------------------------------------------
# Status / setup
# ---------------------------------------------------------

show_ufw_rules() {
    ufw status numbered || true
}

show_firewall_summary() {
    local state="not installed"
    local incoming="unknown"
    local outgoing="unknown"
    local default_line

    if command_exists ufw; then
        state="$(ufw status 2>/dev/null | awk -F: '/^Status:/ { gsub(/^[[:space:]]+/, "", $2); print $2; exit }' || true)"
        default_line="$(ufw_status_value "Default")"
        incoming="$(awk -F, '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $1); sub(/[[:space:]]+.*/, "", $1); print $1 }' <<< "$default_line")"
        outgoing="$(awk -F, '{ gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); sub(/[[:space:]]+.*/, "", $2); print $2 }' <<< "$default_line")"
    fi

    printf 'UFW: %s\n' "${state:-unknown}"
    printf 'Default incoming: %s\n' "${incoming:-unknown}"
    printf 'Default outgoing: %s\n' "${outgoing:-unknown}"
}

enable_firewall_baseline() {
    local ssh_port
    local requested_port

    ensure_ufw_installed || return 0
    show_docker_ufw_warning

    ssh_port="$(detect_ssh_port)"
    requested_port="$(ask_input "SSH port" "detected: ${ssh_port}")" || return 1
    if [[ "$requested_port" == detected:* ]]; then
        requested_port="$ssh_port"
    fi
    fw_validate_port "$requested_port" || {
        error "Invalid SSH port: ${requested_port}"
        return 1
    }

    ufw default deny incoming
    ufw default allow outgoing
    ensure_ssh_firewall_rule "$requested_port" || return 1

    if nginx_detected; then
        echo
        echo "Nginx detected."
        echo
        if confirm "Allow HTTP 80/tcp?" "yes"; then
            ufw_allow_rule 80 tcp "Anywhere" "hostctl:http"
        fi
        if confirm "Allow HTTPS 443/tcp?" "yes"; then
            ufw_allow_rule 443 tcp "Anywhere" "hostctl:https"
        fi
    fi

    ufw --force enable

    if ! ufw_is_active; then
        error "UFW did not become active."
        return 1
    fi

    if ! ssh_rule_exists "$requested_port"; then
        error "SSH allow rule was not verified after enabling UFW."
        if is_ssh_session; then
            ufw disable || true
            error "UFW disabled to avoid locking out the active SSH session."
        fi
        return 1
    fi

    ufw status verbose
    log_event "FIREWALL_ENABLE ssh_port=${requested_port} result=success"
    success "Firewall enabled."
}

disable_firewall() {
    ensure_ufw_installed || return 0

    if ! confirm "Disable UFW firewall?" "no"; then
        warning "Firewall disable cancelled."
        return 0
    fi

    ufw disable
    log_event "FIREWALL_DISABLE result=success"
    success "Firewall disabled."
}

# ---------------------------------------------------------
# Rule add/delete
# ---------------------------------------------------------

cmd_firewall_rule() {
    local action="$1"
    local title="$2"
    local action_upper
    local port
    local protocols
    local source
    local comment
    local proto

    ensure_ufw_installed || return 0

    echo
    echo "$title"
    echo

    port="$(prompt_firewall_port)" || return 1
    protocols="$(prompt_firewall_protocols)" || return 1
    source="$(prompt_firewall_source)" || return 1
    comment="$(prompt_firewall_comment "hostctl:custom:${action}-${port}")" || return 1

    show_rule_summary "$action" "$port" "$protocols" "$source"

    if [[ "$action" == "deny" ]]; then
        for proto in $protocols; do
            if ufw_rule_exists allow "$port" "$proto" "$source"; then
                warning "An existing ALLOW rule may conflict with this DENY rule."
                warning "Review rule ordering after creation."
                if ! confirm "Continue?" "no"; then
                    warning "Deny rule cancelled."
                    return 0
                fi
                break
            fi
        done
    fi

    if ! confirm "Apply rule?" "no"; then
        warning "Rule creation cancelled."
        return 0
    fi

    for proto in $protocols; do
        if [[ "$action" == "allow" ]]; then
            ufw_allow_rule "$port" "$proto" "$source" "$comment"
        else
            ufw_deny_rule "$port" "$proto" "$source" "$comment"
        fi
    done

    action_upper="$(tr '[:lower:]' '[:upper:]' <<< "$action")"
    log_event "FIREWALL_${action_upper} port=${port} protocol=${protocols// /,} source=${source} result=success"
    success "Firewall rule applied."
}

rule_line_for_number() {
    local number="$1"

    ufw status numbered 2>/dev/null |
        awk -v number="$number" '$0 ~ "^\\[[[:space:]]*" number "\\]" { print; exit }'
}

rule_line_allows_ssh_port() {
    local line="$1"
    local port="$2"

    [[ "$line" == *"${port}/tcp"* && "$line" == *"ALLOW"* ]]
}

delete_ufw_rule() {
    local number
    local rule_line
    local ssh_port

    ensure_ufw_installed || return 0

    echo
    echo "Firewall Rules"
    echo
    show_ufw_rules
    echo

    while true; do
        number="$(ask_input "Rule number to delete")" || return 1
        [[ "$number" =~ ^[0-9]+$ ]] && break
        warning "Invalid rule number."
    done

    rule_line="$(rule_line_for_number "$number")"
    if [[ -z "$rule_line" ]]; then
        error "No UFW rule found with number ${number}."
        return 1
    fi

    ssh_port="$(detect_ssh_port)"
    if rule_line_allows_ssh_port "$rule_line" "$ssh_port"; then
        warning "Rule #${number} appears to allow the current SSH port ${ssh_port}/tcp."
        warning "Deleting it may disconnect you from this server."
        if ! confirm "Continue?" "no"; then
            warning "Rule deletion cancelled."
            return 0
        fi
    fi

    if ! confirm "Delete rule #${number}?" "no"; then
        warning "Rule deletion cancelled."
        return 0
    fi

    ufw --force delete "$number"
    log_event "FIREWALL_DELETE rule=${number} result=success"
    success "Firewall rule deleted."
}

# ---------------------------------------------------------
# Backup / reset
# ---------------------------------------------------------

backup_ufw_state() {
    local ts
    local backup_dir

    ts="$(date '+%Y%m%d%H%M%S')"
    backup_dir="${FIREWALL_STATE_DIR}/${ts}"
    mkdir -p "$backup_dir"

    ufw status verbose > "${backup_dir}/ufw-status-${ts}.txt" 2>&1 || true
    [[ -f /etc/ufw/user.rules ]] && cp -a /etc/ufw/user.rules "${backup_dir}/user.rules-${ts}"
    [[ -f /etc/ufw/user6.rules ]] && cp -a /etc/ufw/user6.rules "${backup_dir}/user6.rules-${ts}"

    FIREWALL_LAST_BACKUP_DIR="$backup_dir"
    printf '%s\n' "$backup_dir"
}

restore_ufw_state() {
    local backup_dir="${1:-$FIREWALL_LAST_BACKUP_DIR}"
    local user_rules
    local user6_rules
    local user_rule_files=()
    local user6_rule_files=()

    [[ -n "$backup_dir" && -d "$backup_dir" ]] || return 1

    while IFS= read -r user_rules; do
        user_rule_files+=("$user_rules")
    done < <(find "$backup_dir" -maxdepth 1 -name 'user.rules-*' -type f -print)
    while IFS= read -r user6_rules; do
        user6_rule_files+=("$user6_rules")
    done < <(find "$backup_dir" -maxdepth 1 -name 'user6.rules-*' -type f -print)

    user_rules="${user_rule_files[0]:-}"
    user6_rules="${user6_rule_files[0]:-}"

    [[ -n "$user_rules" ]] && cp -a "$user_rules" /etc/ufw/user.rules
    [[ -n "$user6_rules" ]] && cp -a "$user6_rules" /etc/ufw/user6.rules

    ufw reload || true
}

cmd_firewall_reset() {
    local ssh_client
    local ssh_port
    local backup_dir

    ensure_ufw_installed || return 0

    ssh_client="$(detect_ssh_client_ip || printf 'not detected')"
    ssh_port="$(detect_ssh_port)"

    echo
    echo "Firewall Reset"
    echo
    warning "This will remove all existing UFW rules."
    echo
    printf 'Current SSH client: %s\n' "$ssh_client"
    printf 'Current SSH port: %s\n' "$ssh_port"
    echo

    if ! confirm "Continue with safe firewall reset?" "no"; then
        warning "Firewall reset cancelled."
        return 0
    fi

    backup_dir="$(backup_ufw_state)"
    info "Saved UFW state: ${backup_dir}"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    if confirm "Preserve SSH port ${ssh_port}/tcp?" "yes"; then
        ufw_allow_rule "$ssh_port" tcp "Anywhere" "hostctl:ssh"
    elif is_ssh_session; then
        error "Refusing to enable UFW without preserving the active SSH port."
        restore_ufw_state "$backup_dir" || true
        return 1
    fi

    if nginx_detected; then
        if confirm "Preserve HTTP 80/tcp?" "yes"; then
            ufw_allow_rule 80 tcp "Anywhere" "hostctl:http"
        fi
        if confirm "Preserve HTTPS 443/tcp?" "yes"; then
            ufw_allow_rule 443 tcp "Anywhere" "hostctl:https"
        fi
    fi

    ufw --force enable

    if ! ufw_is_active || ! ssh_rule_exists "$ssh_port"; then
        error "Firewall reset verification failed; attempting rollback."
        restore_ufw_state "$backup_dir" || true
        if is_ssh_session && ! ssh_rule_exists "$ssh_port"; then
            ufw disable || true
            error "UFW disabled to avoid locking out the active SSH session."
        fi
        log_event "FIREWALL_RESET result=failed"
        return 1
    fi

    log_event "FIREWALL_RESET ssh_port=${ssh_port} backup=${backup_dir} result=success"
    success "Firewall reset complete."
    ufw status verbose
}

# ---------------------------------------------------------
# Commands
# ---------------------------------------------------------

cmd_firewall_status() {
    local ssh_port

    if ! ufw_installed; then
        echo
        echo "Firewall Status"
        echo
        echo "UFW: not installed"
        echo
        show_docker_ufw_warning
        return 0
    fi

    ssh_port="$(detect_ssh_port)"

    echo
    echo "Firewall Status"
    echo
    show_firewall_summary
    echo
    echo "SSH:"
    printf 'Detected port: %s\n' "$ssh_port"
    printf 'Allow rule: %s\n' "$(ssh_rule_exists "$ssh_port" && printf 'yes' || printf 'no')"
    echo
    printf 'HTTP: %s\n' "$(ufw_rule_exists allow 80 tcp "Anywhere" && printf '80/tcp allowed' || printf '80/tcp not detected')"
    printf 'HTTPS: %s\n' "$(ufw_rule_exists allow 443 tcp "Anywhere" && printf '443/tcp allowed' || printf '443/tcp not detected')"
    echo
    echo "Rules:"
    ufw status numbered || true
    echo
    show_docker_ufw_warning
}

cmd_allow_port() {
    cmd_firewall_rule allow "Allow Port"
}

cmd_deny_port() {
    cmd_firewall_rule deny "Deny Port"
}

cmd_firewall() {
    local action

    ensure_ufw_installed || return 0

    echo
    echo "Firewall"
    echo
    show_firewall_summary
    echo
    show_docker_ufw_warning
    echo

    action="$(
        select_option \
            "Firewall action:" \
            "Show status" \
            "Enable firewall" \
            "Disable firewall" \
            "Allow port" \
            "Deny port" \
            "Delete rule" \
            "Reset firewall" \
            "Cancel"
    )" || return 1

    case "$action" in
        "Show status") cmd_firewall_status ;;
        "Enable firewall") enable_firewall_baseline ;;
        "Disable firewall") disable_firewall ;;
        "Allow port") cmd_allow_port ;;
        "Deny port") cmd_deny_port ;;
        "Delete rule") delete_ufw_rule ;;
        "Reset firewall") cmd_firewall_reset ;;
        "Cancel") warning "Firewall configuration cancelled." ;;
    esac
}
