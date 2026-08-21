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

DOMAIN_TARGET_PATH=""
DOMAIN_ENABLED_PATH=""
DOMAIN_CONFLICT_LINK_TO_DISABLE=""
DOMAIN_CONFLICT_LINK_TARGET=""
DOMAIN_CONFLICT_BACKUP=""
NGINX_LAST_TEST_OUTPUT=""

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

nginx_test_output_has_conflict() {
    grep -qi 'conflicting server name' <<< "$NGINX_LAST_TEST_OUTPUT"
}

nginx_test_output_has_domain_conflict() {
    local domain="$1"

    [[ -n "$domain" ]] &&
    grep -qi 'conflicting server name' <<< "$NGINX_LAST_TEST_OUTPUT" &&
    grep -Fqi "$domain" <<< "$NGINX_LAST_TEST_OUTPUT"
}

validate_nginx_config() {
    local domain="${1:-}"
    local output
    local status=0

    output="$(nginx -t 2>&1)" || status=$?
    NGINX_LAST_TEST_OUTPUT="$output"
    printf '%s\n' "$output" >&2

    if (( status != 0 )); then
        return "$status"
    fi

    if nginx_test_output_has_conflict; then
        warning "Nginx syntax is valid, but configuration conflicts were detected."
        if nginx_test_output_has_domain_conflict "$domain"; then
            error "Configuration conflict involves ${domain}."
            return 1
        fi
    fi

    return 0
}

reload_nginx() {
    systemctl reload nginx
}

nginx_test_and_reload() {
    local domain="${1:-}"

    validate_nginx_config "$domain" || return 1
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

    local test_output
    if test_output="$(nginx -t 2>&1)"; then
        if grep -qi 'conflicting server name' <<< "$test_output"; then
            config="valid with conflicts"
        else
            config="valid"
        fi
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
    {
        extract_domains_from_config_dir "$NGINX_SITES_ENABLED"
        extract_domains_from_config_dir "$NGINX_SITES_AVAILABLE"
        extract_domains_from_config_dir "$NGINX_CONF_D"
    } | sort -u
}

is_ignored_nginx_config_path() {
    local path="$1"
    local name

    name="$(basename "$path")"

    [[ "$name" == default ]] ||
    [[ "$name" == *.bak ]] ||
    [[ "$name" == *.hostctl.* ]] ||
    [[ "$name" == *~ ]] ||
    [[ "$name" == *.tmp ]] ||
    [[ "$name" == *.disabled ]]
}

extract_server_names_from_file() {
    local file="$1"

    awk '
        /^[[:space:]]*#/ { next }
        /server_name[[:space:]]/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "server_name") {
                    for (j = i + 1; j <= NF; j++) {
                        name = $j;
                        gsub(/;/, "", name);
                        if (name != "_" && name !~ /\*/ && name != "") print name;
                        if ($j ~ /;/) break;
                    }
                }
            }
        }
    ' "$file"
}

extract_domains_from_config_dir() {
    local dir="$1"
    local file
    local resolved

    [[ -d "$dir" ]] || return 0

    find "$dir" -maxdepth 1 \( -type f -o -type l \) -print |
        while IFS= read -r file; do
            is_ignored_nginx_config_path "$file" && continue
            if [[ -L "$file" ]]; then
                resolved="$(real_config_path "$file" 2>/dev/null || true)"
                [[ -n "$resolved" && -f "$resolved" ]] || continue
                is_ignored_nginx_config_path "$resolved" && continue
                extract_server_names_from_file "$resolved"
            elif [[ -f "$file" ]]; then
                extract_server_names_from_file "$file"
            fi
        done
}

select_nginx_domain() {
    local allow_new="${1:-yes}"
    local domains=()
    local domain
    local choice
    local max_choice
    local status

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
        status="$(domain_status_label "${domains[$i]}")"
        printf '%d. %s [%s]\n' "$((i + 1))" "${domains[$i]}" "$status" >&2
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

real_config_path() {
    local path="$1"
    local link_target
    local link_dir

    if [[ -L "$path" ]]; then
        link_target="$(readlink "$path")" || return 1
        if [[ "$link_target" != /* ]]; then
            link_dir="$(cd "$(dirname "$path")" && pwd -P)" || return 1
            link_target="${link_dir}/${link_target}"
        fi
        link_dir="$(cd "$(dirname "$link_target")" && pwd -P)" || return 1
        printf '%s/%s\n' "$link_dir" "$(basename "$link_target")"
    else
        printf '%s\n' "$path"
    fi
}

config_declares_domain() {
    local file="$1"
    local domain="$2"
    local server_name

    [[ -f "$file" ]] || return 1

    while IFS= read -r server_name; do
        if [[ "$server_name" == "$domain" ]]; then
            return 0
        fi
    done < <(extract_server_names_from_file "$file")

    return 1
}

find_enabled_domain_owner() {
    local domain="$1"
    local ignore_path="${2:-}"
    local ignore_real=""
    local enabled
    local resolved

    [[ -d "$NGINX_SITES_ENABLED" ]] || return 1
    [[ -n "$ignore_path" ]] && ignore_real="$(real_config_path "$ignore_path" 2>/dev/null || true)"

    find "$NGINX_SITES_ENABLED" -maxdepth 1 \( -type f -o -type l \) -print |
        while IFS= read -r enabled; do
            is_ignored_nginx_config_path "$enabled" && continue
            resolved="$(real_config_path "$enabled" 2>/dev/null || true)"
            [[ -n "$resolved" && -f "$resolved" ]] || continue
            is_ignored_nginx_config_path "$resolved" && continue

            if [[ -n "$ignore_path" ]] &&
               { [[ "$enabled" == "$ignore_path" ]] || [[ "$resolved" == "$ignore_path" ]] || [[ -n "$ignore_real" && "$resolved" == "$ignore_real" ]]; }; then
                continue
            fi

            if config_declares_domain "$resolved" "$domain"; then
                printf '%s|%s\n' "$enabled" "$resolved"
                return 0
            fi
        done
}

expand_nginx_include_pattern() {
    local pattern="$1"
    local file

    [[ "$pattern" == /* ]] || return 0

    if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"["* ]]; then
        compgen -G "$pattern" |
            while IFS= read -r file; do
                [[ -f "$file" || -L "$file" ]] && printf '%s\n' "$file"
            done
    elif [[ -f "$pattern" || -L "$pattern" ]]; then
        printf '%s\n' "$pattern"
    fi
}

nginx_included_config_paths() {
    local include_path

    {
        if [[ -d "$NGINX_SITES_ENABLED" ]]; then
            find "$NGINX_SITES_ENABLED" -maxdepth 1 \( -type f -o -type l \) -print
        fi

        if [[ -d "$NGINX_CONF_D" ]]; then
            find "$NGINX_CONF_D" -maxdepth 1 -type f -name '*.conf' -print
        fi

        if [[ -f "$NGINX_CONF" ]]; then
            awk '
                /^[[:space:]]*#/ { next }
                /include[[:space:]]/ {
                    for (i = 1; i <= NF; i++) {
                        if ($i == "include") {
                            path = $(i + 1);
                            gsub(/;/, "", path);
                            print path;
                        }
                    }
                }
            ' "$NGINX_CONF" |
                while IFS= read -r include_path; do
                    expand_nginx_include_pattern "$include_path"
                done
        fi
    } | awk 'NF && !seen[$0]++'
}

config_listeners_for_domain() {
    local file="$1"
    local domain="$2"

    awk -v domain="$domain" '
        BEGIN { in_server = 0; depth = 0; has_domain = 0; listeners = "" }
        /server[[:space:]]*\{/ {
            in_server = 1;
            line = $0;
            opens = gsub(/\{/, "{", line);
            line = $0;
            closes = gsub(/\}/, "}", line);
            depth = opens - closes;
            has_domain = 0;
            listeners = "";
        }
        in_server {
            line = $0;
            opens = gsub(/\{/, "{", line);
            closes = gsub(/\}/, "}", line);
            if ($0 !~ /server[[:space:]]*\{/) depth += opens - closes;

            if ($0 ~ /listen[[:space:]]/) {
                value = $0;
                sub(/^[[:space:]]*listen[[:space:]]+/, "", value);
                gsub(/;/, "", value);
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value);
                listeners = listeners ? listeners ", " value : value;
            }

            if ($0 ~ /server_name[[:space:]]/) {
                for (i = 1; i <= NF; i++) {
                    if ($i == "server_name") {
                        for (j = i + 1; j <= NF; j++) {
                            name = $j;
                            gsub(/;/, "", name);
                            if (name == domain) has_domain = 1;
                            if ($j ~ /;/) break;
                        }
                    }
                }
            }

            if (depth <= 0) {
                if (has_domain) print listeners ? listeners : "unspecified";
                in_server = 0;
            }
        }
    ' "$file" | paste -sd ', ' -
}

config_other_domains() {
    local file="$1"
    local domain="$2"

    extract_server_names_from_file "$file" |
        awk -v domain="$domain" '$0 != domain && $0 != "_" { print }' |
        sort -u
}

config_certificates_for_domain() {
    local file="$1"
    local domain="$2"
    local certs=""

    if [[ -f "$file" ]]; then
        certs="$(awk '/ssl_certificate[[:space:]]/ && $1 == "ssl_certificate" { gsub(/;/, "", $2); print $2 }' "$file" | sort -u | paste -sd ', ' -)"
    fi

    if [[ -z "$certs" && -d "/etc/letsencrypt/live/${domain}" ]]; then
        certs="/etc/letsencrypt/live/${domain}"
    fi

    [[ -n "$certs" ]] && printf '%s\n' "$certs" || printf 'not detected\n'
}

active_domain_config_records() {
    local domain="$1"
    local active_path
    local real_path
    local listeners
    local other_domains

    nginx_included_config_paths |
        while IFS= read -r active_path; do
            is_ignored_nginx_config_path "$active_path" && continue
            real_path="$(real_config_path "$active_path" 2>/dev/null || true)"
            [[ -n "$real_path" && -f "$real_path" ]] || continue
            is_ignored_nginx_config_path "$real_path" && continue
            config_declares_domain "$real_path" "$domain" || continue
            listeners="$(config_listeners_for_domain "$real_path" "$domain")"
            other_domains="$(config_other_domains "$real_path" "$domain" | paste -sd ',' -)"
            printf '%s|%s|%s|%s\n' "$active_path" "$real_path" "${listeners:-unspecified}" "$other_domains"
        done | awk -F'|' '!seen[$1 "|" $2]++'
}

domain_source_config_paths() {
    local domain="$1"
    local file

    {
        if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
            find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f -print
        fi
        if [[ -d "$NGINX_CONF_D" ]]; then
            find "$NGINX_CONF_D" -maxdepth 1 -type f -name '*.conf.disabled' -print
        fi
    } |
        while IFS= read -r file; do
            is_ignored_nginx_config_path "$file" && continue
            [[ -f "$file" ]] || continue
            config_declares_domain "$file" "$domain" && printf '%s\n' "$file"
        done | awk '!seen[$0]++'
}

domain_has_http_active() {
    active_domain_config_records "$1" | awk -F'|' '$3 ~ /(^|, )[[]?::[]]?:?80([ ,]|$)|(^|, )80([ ,]|$)/ { found = 1 } END { exit found ? 0 : 1 }'
}

domain_has_https_active() {
    active_domain_config_records "$1" | awk -F'|' '$3 ~ /443|ssl/ { found = 1 } END { exit found ? 0 : 1 }'
}

domain_is_active() {
    active_domain_config_records "$1" | grep -q .
}

domain_config_exists() {
    domain_source_config_paths "$1" | grep -q .
}

domain_status_label() {
    local domain="$1"
    local http="no"
    local https="no"

    domain_has_http_active "$domain" && http="yes"
    domain_has_https_active "$domain" && https="yes"

    if [[ "$http" == "yes" && "$https" == "yes" ]]; then
        printf 'Active'
    elif [[ "$http" == "yes" ]]; then
        printf 'Partial: HTTP active'
    elif [[ "$https" == "yes" ]]; then
        printf 'Partial: HTTPS active'
    else
        printf 'Disabled'
    fi
}

preferred_domain_source_config() {
    local domain="$1"
    local path

    path="$(domain_available_path "$domain")"
    if [[ -f "$path" ]] && config_declares_domain "$path" "$domain"; then
        printf '%s\n' "$path"
        return 0
    fi

    domain_source_config_paths "$domain" | head -n 1
}

resolve_domain_deployment_target() {
    local domain="$1"
    local default_target
    local default_enabled
    local conflict=""
    local conflict_link
    local conflict_target
    local action

    default_target="$(domain_available_path "$domain")"
    default_enabled="$(domain_enabled_path "$domain")"

    DOMAIN_TARGET_PATH="$default_target"
    DOMAIN_ENABLED_PATH="$default_enabled"
    DOMAIN_CONFLICT_LINK_TO_DISABLE=""
    DOMAIN_CONFLICT_LINK_TARGET=""
    DOMAIN_CONFLICT_BACKUP=""

    conflict="$(find_enabled_domain_owner "$domain" "$default_target" | head -n 1 || true)"
    [[ -z "$conflict" ]] && return 0

    conflict_link="${conflict%%|*}"
    conflict_target="${conflict#*|}"

    echo
    printf 'Domain %s is already configured in:\n' "$domain"
    echo
    printf '%s\n' "$conflict_link"
    echo

    action="$(
        select_option \
            "Duplicate domain action:" \
            "Use/update the existing configuration" \
            "Disable the existing configuration and create hostctl config" \
            "Cancel"
    )"

    case "$action" in
        "Use/update the existing configuration")
            DOMAIN_TARGET_PATH="$conflict_target"
            DOMAIN_ENABLED_PATH="$conflict_link"
            ;;
        "Disable the existing configuration and create hostctl config")
            DOMAIN_CONFLICT_LINK_TO_DISABLE="$conflict_link"
            DOMAIN_CONFLICT_LINK_TARGET="$(readlink "$conflict_link" 2>/dev/null || printf '%s\n' "$conflict_target")"
            if [[ -f "$conflict_target" ]]; then
                DOMAIN_CONFLICT_BACKUP="$(backup_file "$conflict_target" || true)"
            fi
            ;;
        "Cancel")
            warning "Domain configuration cancelled."
            return 1
            ;;
    esac
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

    resolve_domain_deployment_target "$domain" || return 0

    target="$DOMAIN_TARGET_PATH"
    enabled="$DOMAIN_ENABLED_PATH"

    if [[ -f "$target" ]]; then
        backup="$(backup_file "$target" || true)"
        if ! grep -q 'Managed by hostctl' "$target"; then
            warning "This configuration was not created by hostctl."
            warning "A backup will be created before modification."
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

    if [[ -n "$DOMAIN_CONFLICT_LINK_TO_DISABLE" ]]; then
        rm -f "$DOMAIN_CONFLICT_LINK_TO_DISABLE"
    fi

    cp "$temp_file" "$target" || {
        restore_conflicting_domain_link
        return 1
    }

    ln -sfn "$target" "$enabled" || {
        restore_file_backup "$backup" "$target"
        restore_conflicting_domain_link
        return 1
    }

    if nginx_test_and_reload "$domain"; then
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
    restore_conflicting_domain_link
    validate_nginx_config || true
    log_event "NGINX_DOMAIN_CREATE domain=${domain} result=failed"
    return 1
}

restore_conflicting_domain_link() {
    if [[ -n "$DOMAIN_CONFLICT_LINK_TO_DISABLE" ]]; then
        ln -sfn "$DOMAIN_CONFLICT_LINK_TARGET" "$DOMAIN_CONFLICT_LINK_TO_DISABLE"
        if [[ -n "$DOMAIN_CONFLICT_BACKUP" && -f "$DOMAIN_CONFLICT_BACKUP" ]]; then
            rollback_file "$DOMAIN_CONFLICT_BACKUP" "$(real_config_path "$DOMAIN_CONFLICT_LINK_TO_DISABLE")" || true
        fi
    fi
}

inspect_domain_config() {
    local domain="$1"
    local records
    local record
    local active_path
    local real_path
    local listeners
    local index=0
    local status
    local source_paths

    records="$(active_domain_config_records "$domain")"
    status="$(domain_status_label "$domain")"

    echo
    printf 'Domain: %s\n' "$domain"
    printf 'Status: %s\n' "$status"
    printf 'HTTP: %s\n' "$(domain_has_http_active "$domain" && printf 'active' || printf 'inactive')"
    printf 'HTTPS: %s\n' "$(domain_has_https_active "$domain" && printf 'active' || printf 'inactive')"

    if [[ -n "$records" ]]; then
        echo
        while IFS= read -r record; do
            index=$((index + 1))
            active_path="$(cut -d'|' -f1 <<< "$record")"
            real_path="$(cut -d'|' -f2 <<< "$record")"
            listeners="$(cut -d'|' -f3 <<< "$record")"

            printf '%d. Active config: %s\n' "$index" "$active_path"
            printf '   Source config: %s\n' "$real_path"
            printf '   HTTP listener: %s\n' "$(grep -Eq '(^|, )[[]?::[]]?:?80([ ,]|$)|(^|, )80([ ,]|$)' <<< "$listeners" && printf 'yes' || printf 'not detected')"
            printf '   HTTPS listener: %s\n' "$(grep -Eq '443|ssl' <<< "$listeners" && printf 'yes' || printf 'not detected')"
            printf '   Listeners: %s\n' "$listeners"
            printf '   Certificate: %s\n' "$(config_certificates_for_domain "$real_path" "$domain")"
            echo
        done <<< "$records"
    else
        source_paths="$(domain_source_config_paths "$domain")"
        if [[ -n "$source_paths" ]]; then
            while IFS= read -r real_path; do
                printf 'Config: %s\n' "$real_path"
                printf 'Certificate: %s\n' "$(config_certificates_for_domain "$real_path" "$domain")"
            done <<< "$source_paths"
        else
            warning "No active config found for ${domain}."
        fi
    fi
}

enable_domain() {
    local domain="$1"
    local source
    local enabled
    local conflict

    source="$(preferred_domain_source_config "$domain")"
    if [[ -z "$source" || ! -f "$source" ]]; then
        die "No disabled source config found for ${domain}."
    fi

    conflict="$(find_enabled_domain_owner "$domain" "$source" | head -n 1 || true)"
    if [[ -n "$conflict" ]]; then
        error "Domain ${domain} is already active in: ${conflict%%|*}"
        error "Resolve the duplicate server_name before enabling this config."
        return 1
    fi

    if [[ "$source" == "$NGINX_SITES_AVAILABLE/"* ]]; then
        enabled="$(domain_enabled_path "$(basename "$source")")"
    else
        error "Cannot automatically enable config outside sites-available: ${source}"
        return 1
    fi

    if ! confirm "Enable ${domain} using ${source}?" "yes"; then
        warning "Enable cancelled."
        return 0
    fi

    ln -sfn "$source" "$enabled"

    if nginx_test_and_reload "$domain"; then
        log_event "NGINX_DOMAIN_ENABLE domain=${domain} result=success source=${source}"
        success "Domain enabled: ${domain}"
        return 0
    fi

    rm -f "$enabled"
    validate_nginx_config || true
    log_event "NGINX_DOMAIN_ENABLE domain=${domain} result=failed source=${source}"
    return 1
}

delete_domain_config() {
    local domain="$1"
    local source
    local backup

    if domain_is_active "$domain"; then
        die "Cannot delete active domain config. Disable ${domain} first."
    fi

    source="$(preferred_domain_source_config "$domain")"
    if [[ -z "$source" || ! -f "$source" ]]; then
        warning "No source config found for ${domain}."
        return 0
    fi

    warning "This removes only the Nginx config, not SSL certificates."
    if ! confirm "Delete disabled config ${source}?" "no"; then
        warning "Delete cancelled."
        return 0
    fi

    backup="$(backup_file "$source" || true)"
    rm -f "$source"
    log_event "NGINX_DOMAIN_DELETE domain=${domain} source=${source} backup=${backup:-none}"
    success "Deleted disabled config for ${domain}. Backup: ${backup:-none}"
}

disable_domain() {
    local domain="$1"
    local records
    local record
    local active_path
    local real_path
    local listeners
    local other_domains
    local index=0
    local removed_links=()
    local moved_files=()
    local backup_pairs=()
    local disabled_path

    records="$(active_domain_config_records "$domain")"

    if [[ -z "$records" ]]; then
        warning "Domain is already disabled: ${domain}"
        return 0
    fi

    echo
    printf 'Domain %s is active in:\n' "$domain"
    echo
    while IFS= read -r record; do
        index=$((index + 1))
        active_path="$(cut -d'|' -f1 <<< "$record")"
        listeners="$(cut -d'|' -f3 <<< "$record")"
        printf '%d. %s\n' "$index" "$active_path"
        printf '   listeners: %s\n\n' "$listeners"
    done <<< "$records"

    while IFS= read -r record; do
        active_path="$(cut -d'|' -f1 <<< "$record")"
        real_path="$(cut -d'|' -f2 <<< "$record")"
        other_domains="$(cut -d'|' -f4 <<< "$record")"

        if [[ -n "$other_domains" ]]; then
            error "Cannot safely disable ${domain}; shared config also declares: ${other_domains}"
            error "Edit the shared server block safely before using hostctl disable."
            return 1
        fi

        if [[ "$active_path" != "$NGINX_SITES_ENABLED/"* && "$active_path" != "$NGINX_CONF_D/"*.conf ]]; then
            error "Cannot safely disable active config outside sites-enabled/conf.d: ${active_path}"
            error "Refusing to move an explicitly included config automatically."
            return 1
        fi
    done <<< "$records"

    if ! confirm "Disable all active server configs for this domain?" "no"; then
        warning "Disable cancelled."
        return 0
    fi

    while IFS= read -r record; do
        active_path="$(cut -d'|' -f1 <<< "$record")"
        real_path="$(cut -d'|' -f2 <<< "$record")"

        if [[ "$active_path" == "$NGINX_SITES_ENABLED/"* ]]; then
            removed_links+=("${active_path}|$(readlink "$active_path" 2>/dev/null || printf '%s' "$real_path")")
            rm -f "$active_path"
        elif [[ "$active_path" == "$NGINX_CONF_D/"*.conf ]]; then
            disabled_path="${active_path}.disabled"
            backup_pairs+=("${active_path}|$(backup_file "$active_path" || true)")
            moved_files+=("${disabled_path}|${active_path}")
            mv "$active_path" "$disabled_path"
        fi
    done <<< "$records"

    if nginx_test_and_reload "$domain" && ! active_domain_config_records "$domain" | grep -q .; then
        log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=success"
        success "Domain disabled on HTTP and HTTPS: ${domain}"
        return 0
    fi

    warning "Disable failed or domain is still active; rolling back."
    local pair
    local original
    local link_target
    for pair in "${removed_links[@]}"; do
        original="${pair%%|*}"
        link_target="${pair#*|}"
        ln -sfn "$link_target" "$original"
    done

    for pair in "${moved_files[@]}"; do
        disabled_path="${pair%%|*}"
        original="${pair#*|}"
        [[ -e "$disabled_path" ]] && mv "$disabled_path" "$original"
    done

    for pair in "${backup_pairs[@]}"; do
        original="${pair%%|*}"
        link_target="${pair#*|}"
        [[ -n "$link_target" && -f "$link_target" ]] && rollback_file "$link_target" "$original" || true
    done

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
    local status

    domain="$(select_nginx_domain "yes")"
    status="$(domain_status_label "$domain")"

    if domain_config_exists "$domain" || domain_is_active "$domain"; then
        echo
        printf 'Domain state: %s\n' "$status"
        echo

        if domain_is_active "$domain"; then
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
            action="$(
                select_option \
                    "Domain action:" \
                    "Inspect configuration" \
                    "Update configuration" \
                    "Enable domain" \
                    "Delete configuration" \
                    "Cancel"
            )"

            case "$action" in
                "Inspect configuration") inspect_domain_config "$domain" ;;
                "Update configuration") configure_reverse_proxy "$domain" ;;
                "Enable domain") enable_domain "$domain" ;;
                "Delete configuration") delete_domain_config "$domain" ;;
                "Cancel") warning "Domain configuration cancelled." ;;
            esac
        fi
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

rate_zone_name() {
    local domain="$1"

    printf 'hostctl_%s\n' "$domain" | tr '.-' '__' | tr -cd 'A-Za-z0-9_'
}

select_rate_profile() {
    local profile
    local rate
    local burst

    profile="$(
        select_option \
            "Rate profile:" \
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

    printf '%s|%s\n' "$rate" "$burst"
}

managed_rule_files() {
    local file

    printf '%s\n' "$HOSTCTL_NGINX_BLOCKED_IPS_CONF"
    printf '%s\n' "$HOSTCTL_NGINX_ALLOWED_IPS_CONF"
    printf '%s\n' "$HOSTCTL_NGINX_RATE_ZONE_CONF"

    if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
        find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f -print |
            while IFS= read -r file; do
                is_ignored_nginx_config_path "$file" && continue
                printf '%s\n' "$file"
            done
    fi
}

marker_field() {
    local marker="$1"
    local key="$2"

    tr ':' '\n' <<< "$marker" |
        awk -F= -v key="$key" '$1 == key { print substr($0, length(key) + 2); exit }'
}

marker_scope() {
    local marker="$1"
    local domain
    local scope

    scope="$(marker_field "$marker" scope)"
    domain="$(marker_field "$marker" domain)"

    if [[ -n "$domain" ]]; then
        printf '%s\n' "$domain"
    elif [[ -n "$scope" ]]; then
        printf '%s\n' "$scope"
    else
        printf 'unknown\n'
    fi
}

rule_record_matches_kind() {
    local marker="$1"
    local kind="$2"

    case "$kind" in
        block) [[ "$marker" == "# HOSTCTL:BLOCK-IP:"* ]] ;;
        allow) [[ "$marker" == "# HOSTCTL:ALLOW-IP:"* ]] ;;
        rate) [[ "$marker" == "# HOSTCTL:RATE-LIMIT:"* ]] ;;
        zone) [[ "$marker" == "# HOSTCTL:RATE-ZONE:"* ]] ;;
        allow-only) [[ "$marker" == "# HOSTCTL:ALLOW-ONLY:"* ]] ;;
    esac
}

collect_managed_rules() {
    local kind="$1"
    local file
    local line_no
    local line
    local scope
    local value
    local rate
    local burst
    local zone
    local mode

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        line_no=0
        while IFS= read -r line; do
            line_no=$((line_no + 1))
            line="${line#"${line%%[![:space:]]*}"}"
            rule_record_matches_kind "$line" "$kind" || continue

            scope="$(marker_scope "$line")"
            value="$(marker_field "$line" value)"
            rate="$(marker_field "$line" rate)"
            burst="$(marker_field "$line" burst)"
            zone="$(marker_field "$line" zone)"
            mode="trusted only"
            if [[ "$kind" == "allow" ]] && has_allow_only_for_scope "$scope"; then
                mode="allow-only"
            fi
            printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$file" "$line_no" "$scope" "$value" "$rate" "$burst" "$zone" "$mode"
        done < "$file"
    done < <(managed_rule_files)
}

has_allow_only_for_scope() {
    local scope="$1"
    local file
    local line

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        while IFS= read -r line; do
            line="${line#"${line%%[![:space:]]*}"}"
            [[ "$line" == "# HOSTCTL:ALLOW-ONLY:"* ]] || continue
            [[ "$(marker_scope "$line")" == "$scope" ]] && return 0
        done < "$file"
    done < <(managed_rule_files)

    return 1
}

count_allow_rules_for_scope() {
    local scope="$1"

    collect_managed_rules allow | awk -F'|' -v scope="$scope" '$4 == scope { count++ } END { print count + 0 }'
}

print_rule_records() {
    local kind="$1"
    local title="$2"
    local records
    local index=0
    local record
    local scope
    local value
    local rate
    local burst
    local mode

    records="$(collect_managed_rules "$kind")"
    echo
    echo "$title"
    echo

    if [[ -z "$records" ]]; then
        case "$kind" in
            block) echo "No hostctl-managed blocked IP rules found." ;;
            allow) echo "No hostctl-managed whitelist rules found." ;;
            rate) echo "No hostctl-managed rate limits found." ;;
        esac
        return 1
    fi

    while IFS= read -r record; do
        index=$((index + 1))
        scope="$(cut -d'|' -f4 <<< "$record")"
        value="$(cut -d'|' -f5 <<< "$record")"
        rate="$(cut -d'|' -f6 <<< "$record")"
        burst="$(cut -d'|' -f7 <<< "$record")"
        mode="$(cut -d'|' -f9 <<< "$record")"

        case "$kind" in
            block)
                printf '%d. %s\n' "$index" "$value"
                printf '   Scope: %s\n\n' "$scope"
                ;;
            allow)
                printf '%d. %s\n' "$index" "$value"
                printf '   Scope: %s\n' "$scope"
                printf '   Mode: %s\n\n' "$mode"
                ;;
            rate)
                printf '%d. %s\n' "$index" "$scope"
                printf '   Rate: %s req/s\n' "$rate"
                printf '   Burst: %s\n\n' "$burst"
                ;;
        esac
    done <<< "$records"
}

select_managed_rule() {
    local kind="$1"
    local title="$2"
    local records
    local count
    local choice

    records="$(collect_managed_rules "$kind")"
    if [[ -z "$records" ]]; then
        print_rule_records "$kind" "$title" || true
        return 1
    fi

    print_rule_records "$kind" "$title" || true
    count="$(wc -l <<< "$records" | tr -d '[:space:]')"

    while true; do
        read -r -p "Select [1-${count}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )); then
            sed -n "${choice}p" <<< "$records"
            return 0
        fi
        warning "Invalid selection."
    done
}

domain_config_for_rule_scope() {
    local scope="$1"
    local owner

    [[ "$scope" != "global" ]] || return 1

    if ! assert_single_enabled_domain_owner "$scope"; then
        return 1
    fi

    owner="$(find_enabled_domain_owner "$scope" | head -n 1 || true)"
    if [[ -n "$owner" ]]; then
        printf '%s\n' "${owner#*|}"
    else
        domain_available_path "$scope"
    fi
}

assert_single_enabled_domain_owner() {
    local domain="$1"
    local matches
    local count

    matches="$(find_enabled_domain_owner "$domain" || true)"
    count=0
    [[ -n "$matches" ]] && count="$(wc -l <<< "$matches" | tr -d '[:space:]')"
    if (( count > 1 )); then
        error "Domain ${domain} is configured in multiple enabled Nginx configs."
        error "Resolve the server-name conflict before modifying access rules."
        return 1
    fi
    return 0
}

apply_nginx_file_updates() {
    local log_name="$1"
    local domain="${2:-}"
    shift 2
    local files=("$@")
    local backups=()
    local file
    local backup

    for file in "${files[@]}"; do
        [[ -n "$file" ]] || continue
        if [[ -f "$file" ]]; then
            backup="$(backup_file "$file" || true)"
        else
            backup=""
        fi
        backups+=("${file}|${backup}")
    done

    if nginx_test_and_reload "$domain"; then
        log_event "${log_name} result=success domain=${domain:-none}"
        return 0
    fi

    warning "Nginx validation failed; rolling back."
    local pair
    for pair in "${backups[@]}"; do
        file="${pair%%|*}"
        backup="${pair#*|}"
        restore_file_backup "$backup" "$file"
    done
    validate_nginx_config || true
    log_event "${log_name} result=failed domain=${domain:-none}"
    return 1
}

replace_file_from_temp_with_validation() {
    local target="$1"
    local temp_file="$2"
    local log_name="$3"
    local domain="${4:-}"
    local backup=""

    [[ -f "$target" ]] && backup="$(backup_file "$target" || true)"
    cp "$temp_file" "$target" || return 1

    if nginx_test_and_reload "$domain"; then
        log_event "${log_name} result=success target=${target} domain=${domain:-none}"
        return 0
    fi

    warning "Nginx validation failed; rolling back."
    restore_file_backup "$backup" "$target"
    validate_nginx_config || true
    log_event "${log_name} result=failed target=${target} domain=${domain:-none}"
    return 1
}

insert_managed_block_in_location() {
    local target="$1"
    local marker="$2"
    local directive="$3"
    local log_name="$4"
    local domain="$5"
    local temp_file

    [[ -f "$target" ]] || die "Domain config not found: ${target}"

    if grep -Fq "$marker" "$target"; then
        warning "Managed rule already exists."
        return 0
    fi

    temp_file="$(mktemp)"
    awk -v marker="$marker" -v directive="$directive" '
        BEGIN { inserted = 0 }
        /location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
            print;
            print "        " marker;
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

    replace_file_from_temp_with_validation "$target" "$temp_file" "$log_name" "$domain"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

append_managed_global_rule() {
    local target="$1"
    local marker="$2"
    local directive="$3"
    local log_name="$4"
    local temp_file

    temp_file="$(mktemp)"
    if [[ -f "$target" ]]; then
        cp "$target" "$temp_file"
    else
        printf '# Managed by hostctl\n' > "$temp_file"
    fi

    if grep -Fq "$marker" "$temp_file"; then
        warning "Managed rule already exists."
        rm -f "$temp_file"
        return 0
    fi

    printf '%s\n%s\n' "$marker" "$directive" >> "$temp_file"
    replace_file_from_temp_with_validation "$target" "$temp_file" "$log_name"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

remove_marker_pair_from_file() {
    local file="$1"
    local marker_line="$2"
    local temp_file

    temp_file="$(mktemp)"
    awk -v marker="$marker_line" '
        $0 == marker { skip = 1; next }
        skip == 1 { skip = 0; next }
        { print }
    ' "$file" > "$temp_file"
    printf '%s\n' "$temp_file"
}

replace_marker_pair_in_file() {
    local file="$1"
    local old_marker="$2"
    local new_marker="$3"
    local new_directive="$4"
    local temp_file

    temp_file="$(mktemp)"
    awk -v old_marker="$old_marker" -v new_marker="$new_marker" -v new_directive="$new_directive" '
        $0 == old_marker {
            print new_marker;
            print new_directive;
            skip = 1;
            next
        }
        skip == 1 { skip = 0; next }
        { print }
    ' "$file" > "$temp_file"
    printf '%s\n' "$temp_file"
}

remove_allow_only_for_scope() {
    local scope="$1"
    local file
    local temp_file
    local changed="no"

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        if awk -v domain_marker="# HOSTCTL:ALLOW-ONLY:domain=${scope}" -v scope_marker="# HOSTCTL:ALLOW-ONLY:scope=${scope}" '
            { line = $0; sub(/^[[:space:]]+/, "", line) }
            line == domain_marker || line == scope_marker { found = 1 }
            END { exit found ? 0 : 1 }
        ' "$file"; then
            temp_file="$(mktemp)"
            awk -v domain_marker="# HOSTCTL:ALLOW-ONLY:domain=${scope}" -v scope_marker="# HOSTCTL:ALLOW-ONLY:scope=${scope}" '
                {
                    line = $0;
                    sub(/^[[:space:]]+/, "", line);
                }
                line == domain_marker || line == scope_marker { skip = 1; next }
                skip == 1 { skip = 0; next }
                { print }
            ' "$file" > "$temp_file"
            cp "$temp_file" "$file"
            rm -f "$temp_file"
            changed="yes"
        fi
    done < <(managed_rule_files)

    [[ "$changed" == "yes" ]]
}

add_allow_only_for_scope() {
    local scope="$1"
    local target="$2"
    local marker

    if [[ "$scope" == "global" ]]; then
        marker="# HOSTCTL:ALLOW-ONLY:scope=global"
    else
        marker="# HOSTCTL:ALLOW-ONLY:domain=${scope}"
    fi

    if grep -Fq "$marker" "$target"; then
        return 0
    fi

    if [[ "$scope" == "global" ]]; then
        printf '%s\ndeny all;\n' "$marker" >> "$target"
    else
        insert_managed_block_in_location "$target" "$marker" "deny all;" "NGINX_ALLOW_IP_ADD" "$scope"
    fi
}

warn_real_ip_if_needed() {
    if ! grep -RqsE 'real_ip_header|set_real_ip_from' "$NGINX_ROOT"; then
        warning "No real client IP configuration detected."
        warning "If this server is behind Cloudflare, a reverse proxy, or load balancer,"
        warning "Nginx may see the proxy IP instead of the actual client IP."
    fi
}

select_ip_scope() {
    select_option "$1" "Globally" "Specific domain"
}

select_scope_for_rule() {
    local current_scope="${1:-}"
    local action
    local domain

    if [[ -n "$current_scope" ]]; then
        action="$(
            select_option \
                "Scope:" \
                "Keep current scope" \
                "Move to global" \
                "Move to another domain"
        )"

        case "$action" in
            "Keep current scope") printf '%s\n' "$current_scope" ;;
            "Move to global") printf 'global\n' ;;
            "Move to another domain")
                domain="$(select_nginx_domain "no")"
                assert_single_enabled_domain_owner "$domain" || return 1
                printf '%s\n' "$domain"
                ;;
        esac
    else
        action="$(select_ip_scope "Scope:")"
        if [[ "$action" == "Globally" ]]; then
            printf 'global\n'
        else
            domain="$(select_nginx_domain "no")"
            assert_single_enabled_domain_owner "$domain" || return 1
            printf '%s\n' "$domain"
        fi
    fi
}

target_for_scope() {
    local scope="$1"
    local type="$2"

    if [[ "$scope" == "global" ]]; then
        case "$type" in
            block) printf '%s\n' "$HOSTCTL_NGINX_BLOCKED_IPS_CONF" ;;
            allow) printf '%s\n' "$HOSTCTL_NGINX_ALLOWED_IPS_CONF" ;;
        esac
    else
        domain_config_for_rule_scope "$scope"
    fi
}

add_block_ip_rule() {
    local scope="$1"
    local value="$2"
    local target
    local marker
    local directive

    target="$(target_for_scope "$scope" block)" || return 1
    directive="deny ${value};"
    if [[ "$scope" == "global" ]]; then
        marker="# HOSTCTL:BLOCK-IP:scope=global:value=${value}"
        append_managed_global_rule "$target" "$marker" "$directive" "NGINX_BLOCK_IP_ADD"
    else
        marker="# HOSTCTL:BLOCK-IP:domain=${scope}:value=${value}"
        insert_managed_block_in_location "$target" "$marker" "$directive" "NGINX_BLOCK_IP_ADD" "$scope"
    fi
}

add_allow_ip_rule() {
    local scope="$1"
    local value="$2"
    local mode="$3"
    local target
    local marker
    local directive
    local backup=""
    local temp_file

    target="$(target_for_scope "$scope" allow)" || return 1
    directive="allow ${value};"
    if [[ "$mode" == "allow-only" ]]; then
        warning "This mode will deny all clients except allowed addresses."
        confirm "Continue?" "no" || return 0
    fi

    if [[ "$scope" == "global" ]]; then
        marker="# HOSTCTL:ALLOW-IP:scope=global:value=${value}"
        temp_file="$(mktemp)"
        [[ -f "$target" ]] && cp "$target" "$temp_file" || printf '# Managed by hostctl\n' > "$temp_file"
        grep -Fq "$marker" "$temp_file" || printf '%s\n%s\n' "$marker" "$directive" >> "$temp_file"
        if [[ "$mode" == "allow-only" ]] && ! grep -Fq "# HOSTCTL:ALLOW-ONLY:scope=global" "$temp_file"; then
            printf '# HOSTCTL:ALLOW-ONLY:scope=global\ndeny all;\n' >> "$temp_file"
        fi
        replace_file_from_temp_with_validation "$target" "$temp_file" "NGINX_ALLOW_IP_ADD"
        local result=$?
        rm -f "$temp_file"
        return "$result"
    else
        marker="# HOSTCTL:ALLOW-IP:domain=${scope}:value=${value}"
        insert_managed_block_in_location "$target" "$marker" "$directive" "NGINX_ALLOW_IP_ADD" "$scope" || return 1
        if [[ "$mode" == "allow-only" ]] && ! has_allow_only_for_scope "$scope"; then
            backup="$(backup_file "$target" || true)"
            temp_file="$(mktemp)"
            awk -v marker="# HOSTCTL:ALLOW-ONLY:domain=${scope}" '
                BEGIN { inserted = 0 }
                /location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
                    print;
                    print "        " marker;
                    print "        deny all;";
                    inserted = 1;
                    next
                }
                { print }
            ' "$target" > "$temp_file"
            cp "$temp_file" "$target"
            rm -f "$temp_file"
            nginx_test_and_reload "$scope" || {
                rollback_file "$backup" "$target" || true
                validate_nginx_config || true
                return 1
            }
        fi
    fi
}

cmd_nginx_block_ip() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local action
    local scope
    local value

    action="$(select_option "IP Blocking" "Add rule" "List rules" "Edit rule" "Remove rule")"
    case "$action" in
        "List rules") cmd_nginx_block_ip_list; return ;;
        "Edit rule") cmd_nginx_block_ip_edit; return ;;
        "Remove rule") cmd_nginx_block_ip_remove; return ;;
    esac

    warn_real_ip_if_needed
    scope="$(select_scope_for_rule)" || return 1
    while true; do
        value="$(ask_input "IP or CIDR")"
        validate_ip_or_cidr "$value" && break
        warning "Invalid IP/CIDR."
    done
    add_block_ip_rule "$scope" "$value"
}

cmd_nginx_block_ip_list() {
    require_root
    require_debian_based
    ensure_nginx_installed
    print_rule_records block "Blocked IP Rules" || true
}

cmd_nginx_block_ip_edit() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record
    local file
    local line_no
    local scope
    local old_value
    local new_value
    local new_scope
    local old_marker
    local temp_file

    record="$(select_managed_rule block "Blocked IP Rules")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    scope="$(cut -d'|' -f4 <<< "$record")"
    old_value="$(cut -d'|' -f5 <<< "$record")"
    old_marker="$(sed -n "${line_no}p" "$file")"

    echo "Current IP/CIDR: ${old_value}"
    while true; do
        new_value="$(ask_input "New IP/CIDR" "$old_value")"
        validate_ip_or_cidr "$new_value" && break
        warning "Invalid IP/CIDR."
    done
    new_scope="$(select_scope_for_rule "$scope")" || return 1

    temp_file="$(remove_marker_pair_from_file "$file" "$old_marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_BLOCK_IP_EDIT" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    add_block_ip_rule "$new_scope" "$new_value"
}

cmd_nginx_block_ip_remove() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record
    local file
    local line_no
    local scope
    local value
    local marker
    local temp_file

    record="$(select_managed_rule block "Blocked IP Rules")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    scope="$(cut -d'|' -f4 <<< "$record")"
    value="$(cut -d'|' -f5 <<< "$record")"
    marker="$(sed -n "${line_no}p" "$file")"

    confirm "Remove block rule for ${value} from ${scope}?" "no" || return 0
    temp_file="$(remove_marker_pair_from_file "$file" "$marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_BLOCK_IP_REMOVE" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

cmd_nginx_whitelist_ip() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local action
    local scope
    local value
    local mode_choice
    local mode="trusted"

    action="$(select_option "Whitelist" "Add rule" "List rules" "Edit rule" "Remove rule")"
    case "$action" in
        "List rules") cmd_nginx_whitelist_ip_list; return ;;
        "Edit rule") cmd_nginx_whitelist_ip_edit; return ;;
        "Remove rule") cmd_nginx_whitelist_ip_remove; return ;;
    esac

    warn_real_ip_if_needed
    scope="$(select_scope_for_rule)" || return 1
    while true; do
        value="$(ask_input "IP or CIDR")"
        validate_ip_or_cidr "$value" && break
        warning "Invalid IP/CIDR."
    done
    mode_choice="$(select_option "Whitelist mode:" "Add trusted IP without blocking others" "Allow only selected IPs and deny everyone else")"
    [[ "$mode_choice" == "Allow only selected IPs and deny everyone else" ]] && mode="allow-only"
    add_allow_ip_rule "$scope" "$value" "$mode"
}

cmd_nginx_whitelist_ip_list() {
    require_root
    require_debian_based
    ensure_nginx_installed
    print_rule_records allow "Whitelist Rules" || true
}

cmd_nginx_whitelist_ip_edit() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no scope old_value old_marker new_value new_scope mode_choice mode temp_file

    record="$(select_managed_rule allow "Whitelist Rules")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    scope="$(cut -d'|' -f4 <<< "$record")"
    old_value="$(cut -d'|' -f5 <<< "$record")"
    old_marker="$(sed -n "${line_no}p" "$file")"

    echo "Current IP/CIDR: ${old_value}"
    while true; do
        new_value="$(ask_input "New IP/CIDR" "$old_value")"
        validate_ip_or_cidr "$new_value" && break
        warning "Invalid IP/CIDR."
    done
    new_scope="$(select_scope_for_rule "$scope")" || return 1
    mode_choice="$(select_option "Whitelist mode:" "trusted IP only" "allow-only")"
    mode="trusted"
    [[ "$mode_choice" == "allow-only" ]] && mode="allow-only"

    temp_file="$(remove_marker_pair_from_file "$file" "$old_marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_ALLOW_IP_EDIT" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    if has_allow_only_for_scope "$scope" && [[ "$(count_allow_rules_for_scope "$scope")" -eq 0 ]]; then
        warning "Removing hostctl deny-all for ${scope}; no hostctl allow rules remain there."
        remove_allow_only_for_scope "$scope" || true
        nginx_test_and_reload "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || return 1
    elif [[ "$mode" == "trusted" ]]; then
        remove_allow_only_for_scope "$scope" || true
        nginx_test_and_reload "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || return 1
    fi
    add_allow_ip_rule "$new_scope" "$new_value" "$mode"
}

cmd_nginx_whitelist_ip_remove() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no scope value marker temp_file allow_count remove_deny="no"

    record="$(select_managed_rule allow "Whitelist Rules")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    scope="$(cut -d'|' -f4 <<< "$record")"
    value="$(cut -d'|' -f5 <<< "$record")"
    marker="$(sed -n "${line_no}p" "$file")"

    if has_allow_only_for_scope "$scope"; then
        allow_count="$(count_allow_rules_for_scope "$scope")"
        if [[ "$allow_count" -le 1 ]]; then
            warning "This is the last allowed IP while deny-all is active."
            select_option "Choose:" "Remove rule and remove hostctl deny-all" "Cancel" | grep -q '^Remove' || return 0
            remove_deny="yes"
        fi
    fi

    confirm "Remove whitelist rule for ${value} from ${scope}?" "no" || return 0
    temp_file="$(remove_marker_pair_from_file "$file" "$marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_ALLOW_IP_REMOVE" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    if [[ "$remove_deny" == "yes" ]]; then
        remove_allow_only_for_scope "$scope" || true
        nginx_test_and_reload "$([[ "$scope" != "global" ]] && printf '%s' "$scope")"
    fi
}

render_rate_zone_file_from_markers() {
    local output="$1"
    local records
    local record
    local domain
    local rate
    local zone

    printf '# Managed by hostctl\n' > "$output"
    records="$(collect_managed_rules rate)"
    [[ -z "$records" ]] && return 0

    while IFS= read -r record; do
        domain="$(cut -d'|' -f4 <<< "$record")"
        rate="$(cut -d'|' -f6 <<< "$record")"
        zone="$(rate_zone_name "$domain")"
        printf '# HOSTCTL:RATE-ZONE:domain=%s:zone=%s:rate=%s\n' "$domain" "$zone" "$rate" >> "$output"
        printf 'limit_req_zone $binary_remote_addr zone=%s:10m rate=%sr/s;\n' "$zone" "$rate" >> "$output"
    done <<< "$records"
}

add_rate_limit_rule() {
    local domain="$1"
    local rate="$2"
    local burst="$3"
    local target
    local zone
    local marker
    local directive
    local temp_file

    assert_single_enabled_domain_owner "$domain" || return 1
    target="$(domain_config_for_rule_scope "$domain")" || return 1
    zone="$(rate_zone_name "$domain")"
    marker="# HOSTCTL:RATE-LIMIT:domain=${domain}:rate=${rate}:burst=${burst}"
    directive="limit_req zone=${zone} burst=${burst} nodelay;"

    insert_managed_block_in_location "$target" "$marker" "$directive" "NGINX_RATE_LIMIT_ADD" "$domain" || return 1
    temp_file="$(mktemp)"
    render_rate_zone_file_from_markers "$temp_file"
    replace_file_from_temp_with_validation "$HOSTCTL_NGINX_RATE_ZONE_CONF" "$temp_file" "NGINX_RATE_LIMIT_ADD" "$domain"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

cmd_nginx_rate_limit() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local action
    local domain
    local rate_burst
    local rate
    local burst

    action="$(select_option "Rate Limiting" "Add rule" "List rules" "Edit rule" "Remove rule")"
    case "$action" in
        "List rules") cmd_nginx_rate_limit_list; return ;;
        "Edit rule") cmd_nginx_rate_limit_edit; return ;;
        "Remove rule") cmd_nginx_rate_limit_remove; return ;;
    esac

    domain="$(select_nginx_domain "no")"
    assert_single_enabled_domain_owner "$domain" || return 1
    rate_burst="$(select_rate_profile)"
    rate="${rate_burst%%|*}"
    burst="${rate_burst##*|}"
    add_rate_limit_rule "$domain" "$rate" "$burst"
}

cmd_nginx_rate_limit_list() {
    require_root
    require_debian_based
    ensure_nginx_installed
    print_rule_records rate "Rate Limits" || true
}

cmd_nginx_rate_limit_edit() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no domain old_marker rate_burst rate burst temp_file

    record="$(select_managed_rule rate "Rate Limits")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    domain="$(cut -d'|' -f4 <<< "$record")"
    old_marker="$(sed -n "${line_no}p" "$file")"

    echo "Domain: ${domain}"
    echo "Rate: $(cut -d'|' -f6 <<< "$record") req/s"
    echo "Burst: $(cut -d'|' -f7 <<< "$record")"
    rate_burst="$(select_rate_profile)"
    rate="${rate_burst%%|*}"
    burst="${rate_burst##*|}"

    temp_file="$(remove_marker_pair_from_file "$file" "$old_marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_RATE_LIMIT_EDIT" "$domain" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    add_rate_limit_rule "$domain" "$rate" "$burst"
}

cmd_nginx_rate_limit_remove() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no domain old_marker temp_file zone_file

    record="$(select_managed_rule rate "Rate Limits")" || return 0
    file="$(cut -d'|' -f2 <<< "$record")"
    line_no="$(cut -d'|' -f3 <<< "$record")"
    domain="$(cut -d'|' -f4 <<< "$record")"
    old_marker="$(sed -n "${line_no}p" "$file")"

    confirm "Remove rate limit for ${domain}?" "no" || return 0
    temp_file="$(remove_marker_pair_from_file "$file" "$old_marker")"
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_RATE_LIMIT_REMOVE" "$domain" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    zone_file="$(mktemp)"
    render_rate_zone_file_from_markers "$zone_file"
    replace_file_from_temp_with_validation "$HOSTCTL_NGINX_RATE_ZONE_CONF" "$zone_file" "NGINX_RATE_LIMIT_REMOVE" "$domain"
    local result=$?
    rm -f "$zone_file"
    return "$result"
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
