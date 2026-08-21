#!/usr/bin/env bash

# =========================================================
# hostctl - Nginx Operations
# =========================================================

NGINX_ROOT="/etc/nginx"
NGINX_CONF="${NGINX_ROOT}/nginx.conf"
NGINX_SITES_AVAILABLE="${NGINX_ROOT}/sites-available"
NGINX_SITES_ENABLED="${NGINX_ROOT}/sites-enabled"
NGINX_CONF_D="${NGINX_ROOT}/conf.d"
NGINX_SNIPPETS="${NGINX_ROOT}/snippets"

HOSTCTL_NGINX_SECURITY_CONF="${NGINX_CONF_D}/hostctl-security.conf"
HOSTCTL_NGINX_RATE_ZONE_CONF="${NGINX_CONF_D}/hostctl-rate-limit.conf"
HOSTCTL_NGINX_BLOCKED_IPS_CONF="${NGINX_CONF_D}/hostctl-blocked-ips.conf"
HOSTCTL_NGINX_ALLOWED_IPS_CONF="${NGINX_CONF_D}/hostctl-allowed-ips.conf"
HOSTCTL_NGINX_DOMAIN_SNIPPET="${NGINX_SNIPPETS}/hostctl-domain-access.conf"

# ---------------------------------------------------------
# Common helpers
# ---------------------------------------------------------

nginx_template_dir() {
    printf '%s/templates/nginx\n' "$SCRIPT_DIR"
}

ensure_nginx_layout() {
    [[ -f "$NGINX_CONF" ]] || die "Missing Nginx config: $NGINX_CONF"
    [[ -d "$NGINX_CONF_D" ]] || die "Missing Nginx conf.d directory: $NGINX_CONF_D"
    [[ -d "$NGINX_SITES_AVAILABLE" ]] || mkdir -p "$NGINX_SITES_AVAILABLE"
    [[ -d "$NGINX_SITES_ENABLED" ]] || mkdir -p "$NGINX_SITES_ENABLED"
    [[ -d "$NGINX_SNIPPETS" ]] || mkdir -p "$NGINX_SNIPPETS"
}

ensure_nginx_installed() {
    if ! command_exists nginx; then
        die "Nginx is not installed. Run: sudo hostctl --nginx"
    fi

    ensure_nginx_layout
}

validate_nginx_config() {
    nginx -t
}

reload_nginx() {
    systemctl reload nginx
}

nginx_test_and_reload() {
    validate_nginx_config || return 1
    reload_nginx || return 1
}

restore_file_backup() {
    local backup="$1"
    local target="$2"

    if [[ -n "$backup" && -f "$backup" ]]; then
        rollback_file "$backup" "$target"
    else
        rm -f "$target"
    fi
}

write_managed_file_with_rollback() {
    local target="$1"
    local content_file="$2"
    local log_name="$3"
    local backup=""

    if [[ -f "$target" ]]; then
        backup="$(backup_file "$target" || true)"
        if ! grep -q 'Managed by hostctl' "$target"; then
            warning "This Nginx configuration was not created by hostctl."
            warning "hostctl will create a backup before modifying it."
            if ! confirm "Continue?" "no"; then
                warning "Operation cancelled."
                return 0
            fi
        fi
    fi

    cp "$content_file" "$target" || return 1

    if nginx_test_and_reload; then
        log_event "${log_name} result=success target=${target}"
        success "Nginx configuration applied."
        return 0
    fi

    warning "Nginx validation failed; rolling back."
    restore_file_backup "$backup" "$target"
    validate_nginx_config || true
    log_event "${log_name} result=failed target=${target}"
    return 1
}

nginx_port_listening() {
    local port="$1"

    if command_exists ss; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    elif command_exists netstat; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${port}$"
    else
        return 1
    fi
}

nginx_conf_includes_conf_d() {
    grep -Eq 'include[[:space:]]+/etc/nginx/conf\.d/\*\.conf;' "$NGINX_CONF"
}

# ---------------------------------------------------------
# Install / status
# ---------------------------------------------------------

cmd_nginx() {
    require_root
    require_debian_based

    echo
    echo "Nginx"
    echo

    if ! command_exists nginx; then
        echo "Nginx is not installed."
        echo
        if confirm "Install Nginx?" "yes"; then
            log_event "NGINX_INSTALL start"
            apt update
            apt install -y nginx
            systemctl enable nginx
            systemctl start nginx
            log_event "NGINX_INSTALL result=success"
        else
            warning "Nginx installation skipped."
            return 0
        fi
    fi

    ensure_nginx_layout

    if ! systemctl is-active nginx >/dev/null 2>&1; then
        warning "Nginx is installed but not running."
        if confirm "Start Nginx now?" "yes"; then
            systemctl start nginx
        fi
    fi

    show_nginx_status
}

show_nginx_status() {
    local version
    local service
    local enabled
    local config="invalid"
    local http="not detected"
    local https="not detected"

    version="$(nginx -v 2>&1 | sed 's/^nginx version: //')"
    service="$(systemctl is-active nginx 2>/dev/null || printf 'unknown')"
    enabled="$(systemctl is-enabled nginx 2>/dev/null || printf 'unknown')"

    if nginx -t >/dev/null 2>&1; then
        config="valid"
    fi

    if nginx_port_listening 80; then
        http="listening"
    fi

    if nginx_port_listening 443; then
        https="listening"
    fi

    echo
    echo "Nginx Status"
    echo
    printf 'Version:    %s\n' "$version"
    printf 'Service:    %s\n' "$service"
    printf 'Enabled:    %s\n' "$enabled"
    printf 'Config:     %s\n' "$config"
    printf 'HTTP Port:  %s\n' "$http"
    printf 'HTTPS Port: %s\n' "$https"
}

# ---------------------------------------------------------
# Domain helpers
# ---------------------------------------------------------

validate_domain() {
    local domain="$1"

    [[ "$domain" != http://* ]] &&
    [[ "$domain" != https://* ]] &&
    [[ "$domain" != */* ]] &&
    [[ "$domain" != *[[:space:]]* ]] &&
    [[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)*$ ]]
}

normalize_domain() {
    local domain="$1"

    domain="${domain%/}"
    printf '%s\n' "$domain" | tr '[:upper:]' '[:lower:]'
}

detect_nginx_domains() {
    local domain

    if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
        find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f -print |
            while IFS= read -r file; do
                basename "$file"
                awk '
                    /server_name/ {
                        for (i = 2; i <= NF; i++) {
                            gsub(/;/, "", $i);
                            if ($i != "_" && $i !~ /\*/) print $i;
                        }
                    }
                ' "$file"
            done | sort -u
    fi
}

select_nginx_domain() {
    local allow_new="${1:-yes}"
    local domains=()
    local domain
    local choice
    local max_choice

    while IFS= read -r domain; do
        [[ -n "$domain" ]] && validate_domain "$domain" && domains+=("$domain")
    done < <(detect_nginx_domains)

    if [[ "${#domains[@]}" -eq 0 ]]; then
        while true; do
            domain="$(normalize_domain "$(ask_input "Enter domain")")"
            if validate_domain "$domain"; then
                printf '%s\n' "$domain"
                return 0
            fi
            warning "Invalid domain. Provide a hostname only, such as api.example.com."
        done
    fi

    echo "Existing domains:" >&2
    echo >&2

    local i
    for i in "${!domains[@]}"; do
        printf '%d. %s\n' "$((i + 1))" "${domains[$i]}" >&2
    done

    max_choice="${#domains[@]}"
    if [[ "$allow_new" == "yes" ]]; then
        printf '%d. Add a new domain\n' "$((max_choice + 1))" >&2
        max_choice=$((max_choice + 1))
    fi

    while true; do
        read -r -p "Select [1-${max_choice}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= max_choice )); then
            if [[ "$allow_new" == "yes" && "$choice" -eq "$max_choice" ]]; then
                while true; do
                    domain="$(normalize_domain "$(ask_input "Enter domain")")"
                    if validate_domain "$domain"; then
                        printf '%s\n' "$domain"
                        return 0
                    fi
                    warning "Invalid domain. Provide a hostname only, such as api.example.com."
                done
            fi

            printf '%s\n' "${domains[$((choice - 1))]}"
            return 0
        fi

        warning "Invalid selection."
    done
}

domain_available_path() {
    printf '%s/%s\n' "$NGINX_SITES_AVAILABLE" "$1"
}

domain_enabled_path() {
    printf '%s/%s\n' "$NGINX_SITES_ENABLED" "$1"
}

hostctl_domain_exists() {
    local domain="$1"
    local target

    target="$(domain_available_path "$domain")"
    [[ -f "$target" ]]
}

validate_port() {
    is_valid_port "$1"
}

validate_ip_or_cidr() {
    local value="$1"
    local ip
    local cidr=""
    local o1
    local o2
    local o3
    local o4

    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}(/[0-9]{1,2})?$ ]]; then
        ip="${value%%/*}"
        [[ "$value" == */* ]] && cidr="${value##*/}"
        IFS=. read -r o1 o2 o3 o4 <<< "$ip"

        (( o1 <= 255 && o2 <= 255 && o3 <= 255 && o4 <= 255 )) || return 1
        if [[ -n "$cidr" ]]; then
            (( cidr >= 0 && cidr <= 32 )) || return 1
        fi
        return 0
    fi

    if [[ "$value" =~ ^[0-9A-Fa-f:]+(/[0-9]{1,3})?$ && "$value" == *:* ]]; then
        [[ "$value" != */* ]] && return 0
        cidr="${value##*/}"
        (( cidr >= 0 && cidr <= 128 ))
        return
    fi

    return 1
}

validate_upstream() {
    local upstream="$1"

    [[ "$upstream" =~ ^https?://[A-Za-z0-9._:-]+/?$ ]] ||
    [[ "$upstream" == http://unix:/*: && "$upstream" != *";"* && "$upstream" != *[[:space:]]* ]]
}

validate_body_size() {
    [[ "$1" =~ ^[1-9][0-9]*[kKmMgG]$ ]]
}

select_body_size() {
    local choice
    local custom

    choice="$(
        select_option \
            "Maximum request body:" \
            "10 MB" \
            "50 MB" \
            "100 MB" \
            "Custom"
    )"

    case "$choice" in
        "10 MB") printf '10M\n' ;;
        "50 MB") printf '50M\n' ;;
        "100 MB") printf '100M\n' ;;
        "Custom")
            while true; do
                custom="$(ask_input "Maximum request body (example: 25M)")"
                if validate_body_size "$custom"; then
                    printf '%s\n' "$custom"
                    return 0
                fi
                warning "Invalid size. Use values like 10M, 100M, or 1G."
            done
            ;;
    esac
}

select_backend_upstream() {
    local choice
    local port
    local ip
    local socket_path
    local upstream

    choice="$(
        select_option \
            "Backend target:" \
            "localhost / 127.0.0.1" \
            "Custom IP" \
            "Unix socket" \
            "Custom upstream URL"
    )"

    case "$choice" in
        "localhost / 127.0.0.1")
            while true; do
                port="$(ask_input "Backend port")"
                validate_port "$port" && break
                warning "Invalid port. Use 1-65535."
            done
            printf 'http://127.0.0.1:%s\n' "$port"
            ;;
        "Custom IP")
            while true; do
                ip="$(ask_input "Backend IP")"
                validate_ip_or_cidr "$ip" && [[ "$ip" != */* ]] && break
                warning "Invalid IP address."
            done
            while true; do
                port="$(ask_input "Backend port")"
                validate_port "$port" && break
                warning "Invalid port. Use 1-65535."
            done
            printf 'http://%s:%s\n' "$ip" "$port"
            ;;
        "Unix socket")
            while true; do
                socket_path="$(ask_input "Unix socket path")"
                if [[ "$socket_path" == /* && "$socket_path" != *[[:space:]\;]* ]]; then
                    printf 'http://unix:%s:\n' "$socket_path"
                    return 0
                fi
                warning "Invalid socket path. Use an absolute path."
            done
            ;;
        "Custom upstream URL")
            while true; do
                upstream="$(ask_input "Complete upstream URL")"
                if validate_upstream "$upstream"; then
                    printf '%s\n' "$upstream"
                    return 0
                fi
                warning "Invalid upstream. Use http://127.0.0.1:8000 or http://10.0.0.5:8080."
            done
            ;;
    esac
}

detect_backend_reachability() {
    local upstream="$1"

    if [[ "$upstream" != http://* && "$upstream" != https://* ]]; then
        return 0
    fi

    if ! command_exists curl; then
        warning "curl not found; skipping backend reachability check."
        return 0
    fi

    if curl -I --max-time 5 "$upstream" >/dev/null 2>&1; then
        return 0
    fi

    warning "Backend does not appear reachable at ${upstream}."
    confirm "Continue configuring Nginx anyway?" "no"
}

ensure_domain_template() {
    local template

    template="$(nginx_template_dir)/domain.conf"
    if [[ -s "$template" ]]; then
        printf '%s\n' "$template"
        return 0
    fi

    return 1
}

render_domain_config() {
    local domain="$1"
    local upstream="$2"
    local body_size="$3"
    local output="$4"
    local template

    if template="$(ensure_domain_template)"; then
        sed \
            -e "s|{{DOMAIN}}|${domain}|g" \
            -e "s|{{UPSTREAM}}|${upstream}|g" \
            -e "s|{{CLIENT_MAX_BODY_SIZE}}|${body_size}|g" \
            "$template" > "$output"
        return 0
    fi

    cat > "$output" <<EOF
# Managed by hostctl
server {
    listen 80;
    listen [::]:80;

    server_name ${domain};

    client_max_body_size ${body_size};

    location / {
        include ${HOSTCTL_NGINX_DOMAIN_SNIPPET};
        proxy_pass ${upstream};

        proxy_http_version 1.1;

        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto \$scheme;

        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";

        proxy_connect_timeout 60s;
        proxy_send_timeout 60s;
        proxy_read_timeout 60s;
    }
}
EOF
}

ensure_domain_snippet() {
    if [[ -f "$HOSTCTL_NGINX_SECURITY_CONF" ]]; then
        cat > "$HOSTCTL_NGINX_DOMAIN_SNIPPET" <<'EOF'
# Managed by hostctl
if ($hostctl_bad_method) {
    return 403;
}

if ($hostctl_scanner_path) {
    return 403;
}

if ($hostctl_bad_bot) {
    return 403;
}
EOF
    elif [[ ! -f "$HOSTCTL_NGINX_DOMAIN_SNIPPET" ]]; then
        cat > "$HOSTCTL_NGINX_DOMAIN_SNIPPET" <<'EOF'
# Managed by hostctl
# Domain-level hostctl rules may be inserted here after --nginx-security is enabled.
EOF
    fi
}

disable_default_site_if_requested() {
    local default_link="${NGINX_SITES_ENABLED}/default"

    if [[ -e "$default_link" ]]; then
        warning "Default Nginx site is enabled."
        if confirm "Disable the default site?" "yes"; then
            rm -f "$default_link"
            if ! nginx_test_and_reload; then
                ln -sfn "${NGINX_SITES_AVAILABLE}/default" "$default_link"
                validate_nginx_config || true
                return 1
            fi
        fi
    fi
}

deploy_domain_config() {
    local domain="$1"
    local temp_file="$2"
    local target
    local enabled
    local backup=""
    local had_symlink="no"
    local symlink_target=""

    target="$(domain_available_path "$domain")"
    enabled="$(domain_enabled_path "$domain")"

    if [[ -f "$target" ]]; then
        backup="$(backup_file "$target" || true)"
        if ! grep -q 'Managed by hostctl' "$target"; then
            warning "This Nginx configuration was not created by hostctl."
            warning "hostctl will create a backup before modifying it."
            if ! confirm "Continue?" "no"; then
                warning "Domain update cancelled."
                return 0
            fi
        fi
    fi

    if [[ -L "$enabled" ]]; then
        had_symlink="yes"
        symlink_target="$(readlink "$enabled")"
    fi

    cp "$temp_file" "$target" || return 1
    ln -sfn "$target" "$enabled"

    if nginx_test_and_reload; then
        log_event "NGINX_DOMAIN_CREATE domain=${domain} result=success"
        success "Domain configured: ${domain}"
        return 0
    fi

    warning "Generated Nginx config failed validation; rolling back."
    restore_file_backup "$backup" "$target"
    rm -f "$enabled"
    if [[ "$had_symlink" == "yes" ]]; then
        ln -sfn "$symlink_target" "$enabled"
    fi
    validate_nginx_config || true
    log_event "NGINX_DOMAIN_CREATE domain=${domain} result=failed"
    return 1
}

inspect_domain_config() {
    local domain="$1"
    local target

    target="$(domain_available_path "$domain")"
    if [[ -f "$target" ]]; then
        sed -n '1,220p' "$target"
    else
        warning "No config found for ${domain}."
    fi
}

disable_domain() {
    local domain="$1"
    local enabled
    local target

    enabled="$(domain_enabled_path "$domain")"
    target="$(domain_available_path "$domain")"

    if [[ ! -e "$enabled" ]]; then
        warning "Domain is already disabled: ${domain}"
        return 0
    fi

    if ! confirm "Disable ${domain}?" "no"; then
        warning "Disable cancelled."
        return 0
    fi

    rm -f "$enabled"
    if nginx_test_and_reload; then
        log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=success"
        success "Domain disabled: ${domain}"
        return 0
    fi

    ln -sfn "$target" "$enabled"
    validate_nginx_config || true
    log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=failed"
    return 1
}

configure_reverse_proxy() {
    local domain="$1"
    local upstream
    local body_size
    local temp_file

    upstream="$(select_backend_upstream)"
    detect_backend_reachability "$upstream" || return 0
    body_size="$(select_body_size)"

    ensure_domain_snippet
    temp_file="$(mktemp)"
    render_domain_config "$domain" "$upstream" "$body_size" "$temp_file"
    deploy_domain_config "$domain" "$temp_file"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

cmd_domain() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local domain
    local action

    domain="$(select_nginx_domain "yes")"

    if hostctl_domain_exists "$domain"; then
        echo
        echo "Domain already exists."
        echo
        action="$(
            select_option \
                "Domain action:" \
                "Inspect configuration" \
                "Update reverse proxy" \
                "Disable domain" \
                "Cancel"
        )"

        case "$action" in
            "Inspect configuration") inspect_domain_config "$domain" ;;
            "Update reverse proxy") configure_reverse_proxy "$domain" ;;
            "Disable domain") disable_domain "$domain" ;;
            "Cancel") warning "Domain configuration cancelled." ;;
        esac
    else
        configure_reverse_proxy "$domain"
        disable_default_site_if_requested || true
    fi
}

# ---------------------------------------------------------
# Managed global configs
# ---------------------------------------------------------

render_security_config() {
    local output="$1"
    local include_bots="${2:-yes}"

    cat > "$output" <<EOF
# Managed by hostctl
# HOSTCTL MANAGED SECURITY
server_tokens off;

map \$request_method \$hostctl_bad_method {
    default 1;
    GET 0;
    HEAD 0;
    POST 0;
    PUT 0;
    PATCH 0;
    DELETE 0;
    OPTIONS 0;
}

map \$request_uri \$hostctl_scanner_path {
    default 0;
    ~*^/\\.git 1;
    ~*^/\\.svn 1;
    ~*^/\\.env$ 1;
    ~*^/\\.DS_Store$ 1;
    ~*^/wp-admin 1;
    ~*^/wp-login\\.php$ 1;
    ~*^/xmlrpc\\.php$ 1;
    ~*^/phpmyadmin 1;
    ~*^/phpMyAdmin 1;
    ~*^/vendor/phpunit 1;
    ~*^/(docker-compose\\.ya?ml|Dockerfile|requirements\\.txt|pyproject\\.toml|Pipfile|\\.gitignore)$ 1;
}
EOF

    if [[ "$include_bots" == "yes" ]]; then
        cat >> "$output" <<'EOF'

map $http_user_agent $hostctl_bad_bot {
    default 0;
    ~*sqlmap 1;
    ~*nikto 1;
    ~*masscan 1;
    ~*nmap 1;
    ~*zgrab 1;
    ~*dirbuster 1;
    ~*gobuster 1;
    ~*wpscan 1;
}
EOF
    else
        cat >> "$output" <<'EOF'

map $http_user_agent $hostctl_bad_bot {
    default 0;
}
EOF
    fi
}

cmd_nginx_security() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local action
    local temp_file
    local include_bots="yes"

    action="$(
        select_option \
            "Nginx Security" \
            "Apply recommended security rules" \
            "Configure manually" \
            "Show current hostctl security config" \
            "Remove hostctl security config"
    )"

    case "$action" in
        "Apply recommended security rules")
            ;;
        "Configure manually")
            if ! confirm "Enable known-bad scanner User-Agent blocking?" "yes"; then
                include_bots="no"
            fi
            ;;
        "Show current hostctl security config")
            [[ -f "$HOSTCTL_NGINX_SECURITY_CONF" ]] && sed -n '1,220p' "$HOSTCTL_NGINX_SECURITY_CONF" || warning "No hostctl security config installed."
            return 0
            ;;
        "Remove hostctl security config")
            remove_managed_nginx_file "$HOSTCTL_NGINX_SECURITY_CONF" "NGINX_SECURITY"
            return
            ;;
    esac

    nginx_conf_includes_conf_d || warning "Could not verify that /etc/nginx/conf.d/*.conf is included from nginx.conf."
    temp_file="$(mktemp)"
    render_security_config "$temp_file" "$include_bots"
    write_managed_file_with_rollback "$HOSTCTL_NGINX_SECURITY_CONF" "$temp_file" "NGINX_SECURITY" || {
        local result=$?
        rm -f "$temp_file"
        return "$result"
    }
    rm -f "$temp_file"
    ensure_domain_snippet
    nginx_test_and_reload
}

remove_managed_nginx_file() {
    local target="$1"
    local log_name="$2"
    local backup=""

    if [[ ! -f "$target" ]]; then
        warning "No managed config found: ${target}"
        return 0
    fi

    if ! confirm "Remove ${target}?" "no"; then
        warning "Remove cancelled."
        return 0
    fi

    backup="$(backup_file "$target" || true)"
    rm -f "$target"

    if nginx_test_and_reload; then
        log_event "${log_name} action=remove result=success target=${target}"
        success "Removed ${target}."
        return 0
    fi

    rollback_file "$backup" "$target" || true
    validate_nginx_config || true
    log_event "${log_name} action=remove result=failed target=${target}"
    return 1
}

render_rate_zone_config() {
    local rate="$1"
    local output="$2"

    cat > "$output" <<EOF
# Managed by hostctl
limit_req_zone \$binary_remote_addr zone=hostctl_api:10m rate=${rate}r/s;
EOF
}

ensure_domain_location_marker() {
    local domain="$1"
    local directive="$2"
    local target
    local temp_file
    local backup=""

    target="$(domain_available_path "$domain")"
    [[ -f "$target" ]] || die "Domain config not found: ${target}"

    backup="$(backup_file "$target" || true)"
    temp_file="$(mktemp)"

    awk -v directive="$directive" '
        BEGIN { inserted = 0 }
        /location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
            print;
            print "        # Managed by hostctl";
            print "        " directive;
            inserted = 1;
            next;
        }
        { print }
        END { if (inserted == 0) exit 2 }
    ' "$target" > "$temp_file"

    local awk_status=$?
    if [[ "$awk_status" -eq 2 ]]; then
        rm -f "$temp_file"
        die "Could not find a location / block in ${target}."
    elif [[ "$awk_status" -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi

    if grep -Fq "$directive" "$target"; then
        rm -f "$temp_file"
        warning "Directive already present for ${domain}."
        return 0
    fi

    cp "$temp_file" "$target"
    rm -f "$temp_file"

    if nginx_test_and_reload; then
        success "Domain updated: ${domain}"
        return 0
    fi

    rollback_file "$backup" "$target" || true
    validate_nginx_config || true
    return 1
}

cmd_nginx_rate_limit() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local profile
    local rate
    local burst
    local domain
    local temp_file

    profile="$(
        select_option \
            "Rate limit profile:" \
            "Conservative" \
            "Balanced" \
            "Strict" \
            "Custom"
    )"

    case "$profile" in
        "Conservative") rate=30; burst=60 ;;
        "Balanced") rate=15; burst=30 ;;
        "Strict") rate=5; burst=10 ;;
        "Custom")
            while true; do
                rate="$(ask_input "Requests per second")"
                is_positive_integer "$rate" && break
                warning "Requests per second must be a positive integer."
            done
            while true; do
                burst="$(ask_input "Burst")"
                is_positive_integer "$burst" && break
                warning "Burst must be a positive integer."
            done
            ;;
    esac

    domain="$(select_nginx_domain "no")"
    warning "Rate limiting will be applied only to ${domain}."
    if ! confirm "Continue?" "yes"; then
        return 0
    fi

    temp_file="$(mktemp)"
    render_rate_zone_config "$rate" "$temp_file"
    write_managed_file_with_rollback "$HOSTCTL_NGINX_RATE_ZONE_CONF" "$temp_file" "NGINX_RATE_LIMIT" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    ensure_domain_location_marker "$domain" "limit_req zone=hostctl_api burst=${burst} nodelay;" || return 1
    log_event "NGINX_RATE_LIMIT domain=${domain} rate=${rate} burst=${burst} result=success"
}

# ---------------------------------------------------------
# IP access controls
# ---------------------------------------------------------

warn_real_ip_if_needed() {
    if ! grep -RqsE 'real_ip_header|set_real_ip_from' "$NGINX_ROOT"; then
        warning "No real-IP proxy configuration detected."
        warning "If this server is behind Cloudflare or a load balancer, Nginx may see proxy IPs instead of client IPs."
    fi
}

append_unique_rule_file() {
    local target="$1"
    local rule="$2"
    local log_name="$3"
    local temp_file
    local backup=""

    [[ -f "$target" ]] && backup="$(backup_file "$target" || true)"
    temp_file="$(mktemp)"

    if [[ -f "$target" ]]; then
        cp "$target" "$temp_file"
    else
        printf '# Managed by hostctl\n' > "$temp_file"
    fi

    if grep -Fxq "$rule" "$temp_file"; then
        warning "Rule already exists: ${rule}"
        rm -f "$temp_file"
        return 0
    fi

    printf '%s\n' "$rule" >> "$temp_file"
    cp "$temp_file" "$target"
    rm -f "$temp_file"

    if nginx_test_and_reload; then
        log_event "${log_name} rule=${rule} result=success"
        success "Rule applied: ${rule}"
        return 0
    fi

    restore_file_backup "$backup" "$target"
    validate_nginx_config || true
    log_event "${log_name} rule=${rule} result=failed"
    return 1
}

append_unique_domain_rule() {
    local domain="$1"
    local rule="$2"
    local log_name="$3"

    ensure_domain_location_marker "$domain" "$rule" || return 1
    log_event "${log_name} domain=${domain} rule=${rule} result=success"
}

select_ip_scope() {
    select_option "$1" "Globally" "Specific domain"
}

cmd_nginx_block_ip() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local scope
    local value
    local domain
    local rule

    warn_real_ip_if_needed
    scope="$(select_ip_scope "Block IP:")"

    while true; do
        value="$(ask_input "IP or CIDR")"
        validate_ip_or_cidr "$value" && break
        warning "Invalid IP/CIDR."
    done

    rule="deny ${value};"

    if [[ "$scope" == "Globally" ]]; then
        append_unique_rule_file "$HOSTCTL_NGINX_BLOCKED_IPS_CONF" "$rule" "NGINX_BLOCK_IP"
    else
        domain="$(select_nginx_domain "no")"
        append_unique_domain_rule "$domain" "$rule" "NGINX_BLOCK_IP"
    fi
}

cmd_nginx_whitelist_ip() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local scope
    local mode
    local value
    local domain
    local rule

    warn_real_ip_if_needed
    scope="$(select_ip_scope "Whitelist IP:")"

    while true; do
        value="$(ask_input "IP or CIDR")"
        validate_ip_or_cidr "$value" && break
        warning "Invalid IP/CIDR."
    done

    mode="$(
        select_option \
            "Whitelist mode:" \
            "Add trusted IP without blocking others" \
            "Allow only selected IPs and deny everyone else"
    )"

    rule="allow ${value};"
    if [[ "$mode" == "Allow only selected IPs and deny everyone else" ]]; then
        warning "This can lock users or services out."
        confirm "Add deny all after the allow rule?" "no" || return 0
        rule="${rule}
deny all;"
    fi

    if [[ "$scope" == "Globally" ]]; then
        append_unique_rule_file "$HOSTCTL_NGINX_ALLOWED_IPS_CONF" "$rule" "NGINX_WHITELIST_IP"
    else
        domain="$(select_nginx_domain "no")"
        append_unique_domain_rule "$domain" "$rule" "NGINX_WHITELIST_IP"
    fi
}

# ---------------------------------------------------------
# Logs
# ---------------------------------------------------------

validate_nginx_log_path() {
    local path="$1"

    [[ -f "$path" && "$path" == /var/log/nginx/* ]]
}

tail_nginx_log() {
    local path="$1"
    local follow="$2"

    if ! validate_nginx_log_path "$path"; then
        warning "Log file not found or unsafe path: ${path}"
        return 0
    fi

    if [[ "$follow" == "yes" ]]; then
        tail -f "$path"
    else
        tail -n 200 "$path"
    fi
}

cmd_nginx_logs() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local choice
    local follow="no"
    local domain

    choice="$(
        select_option \
            "Nginx Logs" \
            "Access log" \
            "Error log" \
            "Both" \
            "Domain-specific logs"
    )"

    confirm "Follow continuously?" "yes" && follow="yes"

    case "$choice" in
        "Access log")
            tail_nginx_log /var/log/nginx/access.log "$follow"
            ;;
        "Error log")
            tail_nginx_log /var/log/nginx/error.log "$follow"
            ;;
        "Both")
            if [[ "$follow" == "yes" ]]; then
                tail -f /var/log/nginx/access.log /var/log/nginx/error.log
            else
                tail -n 200 /var/log/nginx/access.log /var/log/nginx/error.log
            fi
            ;;
        "Domain-specific logs")
            domain="$(select_nginx_domain "no")"
            detect_domain_logs "$domain" "$follow"
            ;;
    esac
}

detect_domain_logs() {
    local domain="$1"
    local follow="$2"
    local target
    local logs=()
    local path

    target="$(domain_available_path "$domain")"
    while IFS= read -r path; do
        [[ -n "$path" ]] && logs+=("$path")
    done < <(awk '/access_log|error_log/ { gsub(/;/, "", $2); print $2 }' "$target" 2>/dev/null)

    if [[ "${#logs[@]}" -eq 0 ]]; then
        warning "No custom domain log paths found; ${domain} likely uses global Nginx logs."
        return 0
    fi

    for path in "${logs[@]}"; do
        tail_nginx_log "$path" "$follow"
    done
}

clear_one_nginx_log() {
    local path="$1"

    if ! validate_nginx_log_path "$path"; then
        die "Unsafe or missing log path: ${path}"
    fi

    if ! confirm "Truncate ${path}?" "no"; then
        warning "Log clear cancelled."
        return 0
    fi

    truncate -s 0 "$path"
    log_event "NGINX_LOG_CLEAR path=${path} result=success"
    success "Cleared ${path}."
}

cmd_nginx_logs_clear() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local choice

    choice="$(
        select_option \
            "Clear Nginx logs:" \
            "Access log" \
            "Error log" \
            "Both" \
            "Run logrotate"
    )"

    case "$choice" in
        "Access log")
            clear_one_nginx_log /var/log/nginx/access.log
            ;;
        "Error log")
            clear_one_nginx_log /var/log/nginx/error.log
            ;;
        "Both")
            clear_one_nginx_log /var/log/nginx/access.log
            clear_one_nginx_log /var/log/nginx/error.log
            ;;
        "Run logrotate")
            if ! command_exists logrotate || [[ ! -f /etc/logrotate.d/nginx ]]; then
                die "logrotate or /etc/logrotate.d/nginx is not available."
            fi
            if confirm "Force Nginx logrotate?" "no"; then
                logrotate -f /etc/logrotate.d/nginx
                log_event "NGINX_LOG_CLEAR action=logrotate result=success"
            fi
            ;;
    esac
}
