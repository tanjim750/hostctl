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
HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET="${NGINX_SNIPPETS}/hostctl-global-access.conf"
HOSTCTL_NGINX_STATE_DIR="${HOSTCTL_STATE_DIR}/nginx"

DOMAIN_TARGET_PATH=""
DOMAIN_ENABLED_PATH=""
DOMAIN_CONFLICT_LINK_TO_DISABLE=""
DOMAIN_CONFLICT_LINK_TARGET=""
DOMAIN_CONFLICT_BACKUP=""
NGINX_LAST_TEST_OUTPUT=""
RULE_TYPE=""
RULE_SCOPE=""
RULE_VALUE=""
RULE_FILE=""
RULE_ID=""
RULE_LINE=""
RULE_RATE=""
RULE_BURST=""
RULE_ZONE=""
RULE_MODE=""
PREPARED_ACCESS_TARGET=""
PREPARED_ACCESS_ACCEPTED_DOMAINS=""
PREPARED_ACCESS_SKIPPED_DOMAINS=""
HOSTCTL_AUTHORIZED_NGINX_CONFIGS=""
HOSTCTL_SKIPPED_NGINX_CONFIGS=""

# ---------------------------------------------------------
# Common helpers
# ---------------------------------------------------------

nginx_template_dir() {
    printf '%s/templates/nginx\n' "$SCRIPT_DIR"
}

nginx_debug() {
    if [[ "${HOSTCTL_DEBUG:-0}" == "1" ]]; then
        printf '[DEBUG] %s\n' "$*" >&2
    fi
}

first_nonempty_line() {
    local line

    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        printf '%s\n' "$line"
        return 0
    done

    return 1
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

    nginx_debug "command: nginx -t"
    output="$(nginx -t 2>&1)" || status=$?
    nginx_debug "return code: ${status}"
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

restart_nginx() {
    nginx_debug "command: systemctl restart nginx"
    if ! systemctl restart nginx; then
        error "Nginx failed to restart after configuration change."
        return 1
    fi

    nginx_debug "command: systemctl is-active --quiet nginx"
    if ! systemctl is-active --quiet nginx; then
        error "Nginx failed to start after configuration change."
        return 1
    fi

    success "Nginx restarted."
    return 0
}

reload_nginx() {
    restart_nginx
}

nginx_test_and_reload() {
    local domain="${1:-}"

    validate_nginx_config "$domain" || return 1
    success "Nginx configuration valid."
    restart_nginx || return 1
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
    restart_nginx || true
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
    local files=()

    [[ -d "$dir" ]] || return 0

    while IFS= read -r file; do
        files+=("$file")
    done < <(find "$dir" -maxdepth 1 \( -type f -o -type l \) -print)

    [[ "${#files[@]}" -eq 0 ]] && return 0
    for file in "${files[@]}"; do
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
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${max_choice}]: " choice </dev/tty || {
                error "Unable to read interactive input."
                return 1
            }
        else
            read -r -p "Select [1-${max_choice}]: " choice || {
                error "Unable to read interactive input."
                return 1
            }
        fi
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
    local enabled_files=()

    [[ -d "$NGINX_SITES_ENABLED" ]] || return 1
    [[ -n "$ignore_path" ]] && ignore_real="$(real_config_path "$ignore_path" 2>/dev/null || true)"

    while IFS= read -r enabled; do
        enabled_files+=("$enabled")
    done < <(find "$NGINX_SITES_ENABLED" -maxdepth 1 \( -type f -o -type l \) -print)

    [[ "${#enabled_files[@]}" -eq 0 ]] && return 0
    for enabled in "${enabled_files[@]}"; do
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
        fi
    done
}

expand_nginx_include_pattern() {
    local pattern="$1"
    local file
    local matches

    [[ "$pattern" == /* ]] || return 0

    if [[ "$pattern" == *"*"* || "$pattern" == *"?"* || "$pattern" == *"["* ]]; then
        matches="$(compgen -G "$pattern" || true)"
        [[ -z "$matches" ]] && return 0
        printf '%s\n' "$matches" |
            while IFS= read -r file; do
                [[ -f "$file" || -L "$file" ]] && printf '%s\n' "$file"
            done
    elif [[ -f "$pattern" || -L "$pattern" ]]; then
        printf '%s\n' "$pattern"
    fi
}

nginx_included_config_paths() {
    local include_path
    local path

    {
        if [[ -d "$NGINX_SITES_ENABLED" ]]; then
            while IFS= read -r path; do
                printf '%s\n' "$path"
            done < <(find "$NGINX_SITES_ENABLED" -maxdepth 1 \( -type f -o -type l \) -print)
        fi

        if [[ -d "$NGINX_CONF_D" ]]; then
            while IFS= read -r path; do
                printf '%s\n' "$path"
            done < <(find "$NGINX_CONF_D" -maxdepth 1 -type f -name '*.conf' -print)
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
            while IFS= read -r file; do
                printf '%s\n' "$file"
            done < <(find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f -print)
        fi
        if [[ -d "$NGINX_CONF_D" ]]; then
            while IFS= read -r file; do
                printf '%s\n' "$file"
            done < <(find "$NGINX_CONF_D" -maxdepth 1 -type f -name '*.conf.disabled' -print)
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

    domain_source_config_paths "$domain" | first_nonempty_line
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

    conflict="$(find_enabled_domain_owner "$domain" "$default_target" | first_nonempty_line || true)"
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
        if ! grep -Fq "include ${HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET};" "$output"; then
            local rendered_temp
            rendered_temp="$(mktemp)"
            awk -v old_include="include ${HOSTCTL_NGINX_DOMAIN_SNIPPET};" \
                -v global_include="include ${HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET};" \
                -v domain_include="include $(domain_access_snippet "$domain");" '
                index($0, old_include) {
                    indent = $0;
                    sub(/[^[:space:]].*$/, "", indent);
                    print indent global_include;
                    print indent domain_include;
                    print $0;
                    next;
                }
                { print }
            ' "$output" > "$rendered_temp"
            mv "$rendered_temp" "$output"
        fi
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
        include ${HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET};
        include $(domain_access_snippet "$domain");
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
                restart_nginx || true
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
    restart_nginx || true
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

domain_state_file() {
    local domain="$1"

    printf '%s/%s.state\n' "$HOSTCTL_NGINX_STATE_DIR" "$domain"
}

persist_domain_disable_state() {
    local domain="$1"
    local http_active="$2"
    local https_active="$3"
    local state_file
    local pair
    local index=0

    [[ "${#removed_links[@]}" -gt 0 ]] || return 0
    mkdir -p "$HOSTCTL_NGINX_STATE_DIR"
    state_file="$(domain_state_file "$domain")"

    {
        printf 'DOMAIN=%q\n' "$domain"
        printf 'TIMESTAMP=%q\n' "$(date +%Y%m%d%H%M%S)"
        [[ "$http_active" == "yes" ]] && printf 'HTTP_ACTIVE=1\n' || printf 'HTTP_ACTIVE=0\n'
        [[ "$https_active" == "yes" ]] && printf 'HTTPS_ACTIVE=1\n' || printf 'HTTPS_ACTIVE=0\n'
        for pair in "${removed_links[@]}"; do
            index=$((index + 1))
            printf 'SYMLINK_%d=%q\n' "$index" "${pair%%|*}"
            printf 'TARGET_%d=%q\n' "$index" "${pair#*|}"
        done
        printf 'SYMLINK_COUNT=%d\n' "$index"
    } > "$state_file"
}

saved_domain_state_exists() {
    local domain="$1"
    local state_file

    state_file="$(domain_state_file "$domain")"
    [[ -f "$state_file" ]]
}

restore_domain_previous_state() {
    local domain="$1"
    local state_file
    local expected_http=0
    local expected_https=0
    local count=0
    local index
    local symlink_var
    local target_var
    local symlink
    local target
    local conflict
    local restored_links=()

    state_file="$(domain_state_file "$domain")"
    if [[ ! -f "$state_file" ]]; then
        return 1
    fi

    # shellcheck disable=SC1090
    source "$state_file"
    expected_http="${HTTP_ACTIVE:-0}"
    expected_https="${HTTPS_ACTIVE:-0}"
    count="${SYMLINK_COUNT:-0}"

    if [[ "$count" -le 0 ]]; then
        error "Saved state for ${domain} does not contain any symlinks."
        return 1
    fi

    for ((index = 1; index <= count; index++)); do
        symlink_var="SYMLINK_${index}"
        target_var="TARGET_${index}"
        symlink="${!symlink_var:-}"
        target="${!target_var:-}"

        if [[ -z "$symlink" || -z "$target" ]]; then
            error "Saved state for ${domain} is incomplete at symlink ${index}."
            return 1
        fi
        if [[ ! -f "$target" ]]; then
            error "Cannot restore missing target: ${target}"
            return 1
        fi

        conflict="$(find_enabled_domain_owner "$domain" "$target" | first_nonempty_line || true)"
        if [[ -n "$conflict" && "${conflict%%|*}" != "$symlink" ]]; then
            error "Domain ${domain} is already active in: ${conflict%%|*}"
            error "Resolve the duplicate server_name before restoring saved state."
            return 1
        fi
    done

    for ((index = 1; index <= count; index++)); do
        symlink_var="SYMLINK_${index}"
        target_var="TARGET_${index}"
        symlink="${!symlink_var:-}"
        target="${!target_var:-}"
        info "Restoring enabled symlink: ${symlink} -> ${target}"
        ln -sfn "$target" "$symlink" || {
            error "Failed to restore symlink: ${symlink}"
            rollback_restored_domain_links
            return 1
        }
        restored_links+=("$symlink")
    done

    if ! nginx_test_and_reload "$domain"; then
        warning "Restored Nginx state failed validation; rolling back."
        rollback_restored_domain_links
        validate_nginx_config || true
        restart_nginx || true
        log_event "NGINX_DOMAIN_ENABLE domain=${domain} mode=restore result=failed"
        return 1
    fi

    if [[ "$expected_http" -eq 1 ]] && ! domain_has_http_active "$domain"; then
        error "Restored state did not reactivate HTTP for ${domain}."
        rollback_restored_domain_links
        validate_nginx_config || true
        restart_nginx || true
        return 1
    fi
    if [[ "$expected_https" -eq 1 ]] && ! domain_has_https_active "$domain"; then
        error "Restored state did not reactivate HTTPS for ${domain}."
        rollback_restored_domain_links
        validate_nginx_config || true
        restart_nginx || true
        return 1
    fi

    log_event "NGINX_DOMAIN_ENABLE domain=${domain} mode=restore result=success state=${state_file}"
    success "Domain enabled: ${domain}"
    return 0
}

rollback_restored_domain_links() {
    local symlink

    for symlink in "${restored_links[@]}"; do
        info "Removing restored symlink: ${symlink}"
        rm -f "$symlink"
    done
}

enable_domain() {
    local domain="$1"
    local source
    local enabled
    local conflict
    local mode

    if saved_domain_state_exists "$domain"; then
        mode="$(
            select_option \
                "Enable mode:" \
                "Restore previous active configuration" \
                "Enable another available configuration" \
                "Cancel"
        )"

        case "$mode" in
            "Restore previous active configuration")
                restore_domain_previous_state "$domain"
                return
                ;;
            "Cancel")
                warning "Enable cancelled."
                return 0
                ;;
        esac
    fi

    source="$(preferred_domain_source_config "$domain")"
    if [[ -z "$source" || ! -f "$source" ]]; then
        die "No disabled source config found for ${domain}."
    fi

    conflict="$(find_enabled_domain_owner "$domain" "$source" | first_nonempty_line || true)"
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
    restart_nginx || true
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

    if ! disable_domain_active_configs "$domain"; then
        HOSTCTL_ERROR_HANDLED=1
        return 1
    fi
}

disable_domain_active_configs() {
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
    local http_active="no"
    local https_active="no"
    local effective_status

    records="$(active_domain_config_records "$domain")"

    if [[ -z "$records" ]]; then
        error "No active config matching server_name ${domain} was found."
        return 1
    fi

    echo
    printf 'Disabling domain: %s\n' "$domain"
    echo
    echo "Active configs:"

    while IFS= read -r record; do
        index=$((index + 1))
        active_path="$(cut -d'|' -f1 <<< "$record")"
        listeners="$(cut -d'|' -f3 <<< "$record")"
        grep -Eq '(^|, )[[]?::[]]?:?80([ ,]|$)|(^|, )80([ ,]|$)' <<< "$listeners" && http_active="yes"
        grep -Eq '443|ssl' <<< "$listeners" && https_active="yes"
        printf '%d. %s\n' "$index" "$active_path"
        printf '   listeners: %s\n' "$listeners"
    done <<< "$records"
    echo
    printf 'HTTP active: %s\n' "$http_active"
    printf 'HTTPS active: %s\n' "$https_active"
    echo

    while IFS= read -r record; do
        active_path="$(cut -d'|' -f1 <<< "$record")"
        real_path="$(cut -d'|' -f2 <<< "$record")"
        other_domains="$(cut -d'|' -f4 <<< "$record")"

        if [[ -n "$other_domains" ]]; then
            error "Cannot disable shared config:"
            error "        ${active_path}"
            error ""
            error "The file also serves:"
            local other_domain
            local other_domain_array
            IFS=',' read -r -a other_domain_array <<< "$other_domains"
            for other_domain in "${other_domain_array[@]}"; do
                error "- ${other_domain}"
            done
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
        nginx_debug "disable_domain active_path=${active_path} real_path=${real_path}"

        if [[ -L "$active_path" ]]; then
            info "Removing enabled symlink: ${active_path}"
            removed_links+=("${active_path}|$(readlink "$active_path" 2>/dev/null || printf '%s' "$real_path")")
            if ! rm -f "$active_path"; then
                error "Failed to remove symlink: ${active_path}"
                rollback_domain_disable_state
                return 1
            fi
        elif [[ -f "$active_path" && "$active_path" == "$NGINX_CONF_D/"*.conf ]]; then
            disabled_path="${active_path}.disabled"
            info "Disabling config file: ${active_path} -> ${disabled_path}"
            backup_pairs+=("${active_path}|$(backup_file "$active_path" || true)")
            moved_files+=("${disabled_path}|${active_path}")
            if ! mv "$active_path" "$disabled_path"; then
                error "Failed to disable config file: ${active_path}"
                rollback_domain_disable_state
                return 1
            fi
        elif [[ -f "$active_path" ]]; then
            error "Refusing to delete regular enabled config file: ${active_path}"
            rollback_domain_disable_state
            return 1
        else
            error "Active config path is neither symlink nor regular file: ${active_path}"
            rollback_domain_disable_state
            return 1
        fi
    done <<< "$records"

    if ! nginx_test_and_reload "$domain"; then
        warning "Disable failed validation; rolling back."
        rollback_domain_disable_state
        validate_nginx_config || true
        restart_nginx || true
        log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=failed"
        return 1
    fi

    if active_domain_config_records "$domain" | grep -q .; then
        error "Domain still appears in active Nginx configuration after disable."
        rollback_domain_disable_state
        validate_nginx_config || true
        restart_nginx || true
        log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=failed"
        return 1
    fi

    if nginx_effective_config_has_domain "$domain"; then
        error "Domain still appears in active Nginx configuration after disable."
        rollback_domain_disable_state
        validate_nginx_config || true
        restart_nginx || true
        log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=failed"
        return 1
    else
        effective_status=$?
        if [[ "$effective_status" -ne 1 ]]; then
            error "Unable to inspect active Nginx configuration after disable."
            rollback_domain_disable_state
            validate_nginx_config || true
            restart_nginx || true
            log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=failed"
            return 1
        fi
    fi

    persist_domain_disable_state "$domain" "$http_active" "$https_active"
    log_event "NGINX_DOMAIN_DISABLE domain=${domain} result=success"
    success "Domain disabled: ${domain}"
    return 0
}

rollback_domain_disable_state() {
    local pair
    local original
    local link_target

    warning "Rolling back domain disable changes."

    for pair in "${removed_links[@]}"; do
        original="${pair%%|*}"
        link_target="${pair#*|}"
        info "Restoring symlink: ${original} -> ${link_target}"
        ln -sfn "$link_target" "$original"
    done

    for pair in "${moved_files[@]}"; do
        disabled_path="${pair%%|*}"
        original="${pair#*|}"
        info "Restoring config file: ${disabled_path} -> ${original}"
        [[ -e "$disabled_path" ]] && mv "$disabled_path" "$original"
    done

    for pair in "${backup_pairs[@]}"; do
        original="${pair%%|*}"
        link_target="${pair#*|}"
        [[ -n "$link_target" && -f "$link_target" ]] && rollback_file "$link_target" "$original" || true
    done
}

nginx_effective_config_has_domain() {
    local domain="$1"
    local output
    local status=0

    nginx_debug "command: nginx -T"
    output="$(nginx -T 2>/dev/null)" || status=$?
    nginx_debug "return code: ${status}"
    if (( status != 0 )); then
        return 2
    fi

    awk -v domain="$domain" '
        /^[[:space:]]*#/ { next }
        /server_name[[:space:]]/ {
            for (i = 1; i <= NF; i++) {
                if ($i == "server_name") {
                    for (j = i + 1; j <= NF; j++) {
                        name = $j;
                        gsub(/;/, "", name);
                        if (name == domain) found = 1;
                        if ($j ~ /;/) break;
                    }
                }
            }
        }
        END { exit found ? 0 : 1 }
    ' <<< "$output"
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
    ensure_global_access_snippet
    ensure_domain_access_snippet "$domain"
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
    local backup=""
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
    [[ -f "$HOSTCTL_NGINX_SECURITY_CONF" ]] && backup="$(backup_file "$HOSTCTL_NGINX_SECURITY_CONF" || true)"
    cp "$temp_file" "$HOSTCTL_NGINX_SECURITY_CONF" || return 1
    rm -f "$temp_file"
    ensure_domain_snippet
    ensure_security_enforcement_includes || {
        restore_file_backup "$backup" "$HOSTCTL_NGINX_SECURITY_CONF"
        validate_nginx_config || true
        restart_nginx || true
        return 1
    }

    if nginx_test_and_reload; then
        verify_security_enforcement || return 1
        log_event "NGINX_SECURITY result=success target=${HOSTCTL_NGINX_SECURITY_CONF}"
        success "Nginx security rules applied and active."
        return 0
    fi

    restore_file_backup "$backup" "$HOSTCTL_NGINX_SECURITY_CONF"
    validate_nginx_config || true
    restart_nginx || true
    log_event "NGINX_SECURITY result=failed target=${HOSTCTL_NGINX_SECURITY_CONF}"
    return 1
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
    restart_nginx || true
    log_event "${log_name} action=remove result=failed target=${target}"
    return 1
}

rate_zone_name() {
    local domain="$1"

    printf 'hostctl_%s\n' "$domain" | tr '.-' '__' | tr -cd 'A-Za-z0-9_'
}

domain_access_snippet() {
    local domain="$1"
    local safe_domain

    safe_domain="$(printf '%s\n' "$domain" | tr '.-' '__' | tr -cd 'A-Za-z0-9_')"
    printf '%s/hostctl-access-%s.conf\n' "$NGINX_SNIPPETS" "$safe_domain"
}

ensure_access_snippet_file() {
    local target="$1"
    local title="$2"

    if [[ ! -f "$target" ]]; then
        mkdir -p "$(dirname "$target")"
        {
            printf '# Managed by hostctl\n'
            printf '# %s\n' "$title"
        } > "$target"
    fi
}

ensure_global_access_snippet() {
    ensure_access_snippet_file "$HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET" "HOSTCTL GLOBAL ACCESS RULES"
}

ensure_domain_access_snippet() {
    local domain="$1"

    ensure_access_snippet_file "$(domain_access_snippet "$domain")" "HOSTCTL ACCESS RULES ${domain}"
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
    printf '%s\n' "$HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET"

    if [[ -d "$NGINX_SNIPPETS" ]]; then
        while IFS= read -r file; do
            printf '%s\n' "$file"
        done < <(find "$NGINX_SNIPPETS" -maxdepth 1 -type f -name 'hostctl-access-*.conf' -print)
    fi

    if [[ -d "$NGINX_SITES_AVAILABLE" ]]; then
        while IFS= read -r file; do
            is_ignored_nginx_config_path "$file" && continue
            printf '%s\n' "$file"
        done < <(find "$NGINX_SITES_AVAILABLE" -maxdepth 1 -type f -print)
    fi
}

marker_field() {
    local marker="$1"
    local key="$2"

    tr ': ' '\n\n' <<< "$marker" |
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
        allow) [[ "$marker" == "# HOSTCTL:ALLOW-IP:"* || "$marker" == "# HOSTCTL:ALLOW-ONLY:"* ]] ;;
        rate) [[ "$marker" == "# HOSTCTL:RATE-LIMIT:"* ]] ;;
        zone) [[ "$marker" == "# HOSTCTL:RATE-ZONE:"* ]] ;;
        allow-only) [[ "$marker" == "# HOSTCTL:ALLOW-ONLY:"* ]] ;;
    esac
}

rule_id() {
    local prefix="$1"
    local value="$2"

    printf '%s_%s_%s\n' "$prefix" "$(date +%Y%m%d%H%M%S)" "$value" | tr './:' '___' | tr -cd 'A-Za-z0-9_'
}

rule_kind_from_marker() {
    local marker="$1"

    case "$marker" in
        "# HOSTCTL:BLOCK-IP:"*) printf 'block\n' ;;
        "# HOSTCTL:ALLOW-IP:"*) printf 'allow\n' ;;
        "# HOSTCTL:ALLOW-ONLY:"*) printf 'allow\n' ;;
        "# HOSTCTL:RATE-LIMIT:"*) printf 'rate\n' ;;
        "# HOSTCTL:RATE-ZONE:"*) printf 'zone\n' ;;
    esac
}

rule_marker_type() {
    local kind="$1"
    local mode="${2:-}"

    case "$kind:$mode" in
        block:*) printf 'BLOCK-IP\n' ;;
        allow:allow-only) printf 'ALLOW-ONLY\n' ;;
        allow:*) printf 'ALLOW-IP\n' ;;
        rate:*) printf 'RATE-LIMIT\n' ;;
        zone:*) printf 'RATE-ZONE\n' ;;
    esac
}

find_managed_rule_block() {
    local file="$1"
    local type="$2"
    local id="$3"
    local begin_line
    local end_line

    begin_line="$(grep -nF "# HOSTCTL:${type}:BEGIN id=${id}" "$file" | first_nonempty_line | cut -d: -f1 || true)"
    end_line="$(grep -nF "# HOSTCTL:${type}:END id=${id}" "$file" | first_nonempty_line | cut -d: -f1 || true)"

    if [[ -z "$begin_line" || -z "$end_line" || ! "$begin_line" =~ ^[0-9]+$ || ! "$end_line" =~ ^[0-9]+$ || "$end_line" -le "$begin_line" ]]; then
        error "Managed rule block is incomplete or missing."
        return 1
    fi

    printf '%s|%s\n' "$begin_line" "$end_line"
}

rule_value_from_directive() {
    local kind="$1"
    local directive="$2"
    local value=""

    case "$kind" in
        block)
            value="$(awk '$1 == "deny" && $2 != "all;" { gsub(/;/, "", $2); print $2; exit }' <<< "$directive")"
            ;;
        allow)
            value="$(awk '$1 == "allow" { gsub(/;/, "", $2); print $2; exit }' <<< "$directive")"
            ;;
        rate)
            value="$(awk '
                $1 == "limit_req" {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^zone=/) {
                            sub(/^zone=/, "", $i);
                            gsub(/;/, "", $i);
                            print $i;
                            exit
                        }
                    }
                }
            ' <<< "$directive")"
            ;;
    esac

    printf '%s\n' "$value"
}

rule_record_from_marker() {
    local kind="$1"
    local file="$2"
    local line_no="$3"
    local marker="$4"
    local directive="$5"
    local actual_kind
    local scope
    local value
    local rate
    local burst
    local zone
    local id
    local mode="trusted only"

    actual_kind="$(rule_kind_from_marker "$marker")"
    [[ "$actual_kind" == "$kind" ]] || return 1

    scope="$(marker_scope "$marker")"
    value="$(marker_field "$marker" value)"
    rate="$(marker_field "$marker" rate)"
    burst="$(marker_field "$marker" burst)"
    zone="$(marker_field "$marker" zone)"
    id="$(marker_field "$marker" id)"
    [[ -n "$id" ]] || id="line_${line_no}"

    [[ -n "$value" ]] || value="$(rule_value_from_directive "$kind" "$directive")"
    if [[ "$kind" == "rate" && -z "$zone" ]]; then
        zone="$(rule_value_from_directive "$kind" "$directive")"
    fi
    if [[ "$kind" == "allow" ]] && [[ "$marker" == "# HOSTCTL:ALLOW-ONLY:"* ]]; then
        mode="allow-only"
    elif [[ "$kind" == "allow" ]] && has_allow_only_for_scope "$scope"; then
        mode="allow-only"
    fi

    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$kind" "$scope" "$value" "$file" "$id" "$line_no" "$rate" "$burst" "$zone" "$mode"
}

collect_legacy_managed_rules_from_file() {
    local kind="$1"
    local file="$2"
    local scope="$3"

    awk -v kind="$kind" -v file="$file" -v scope="$scope" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        function emit(line_no, value, rate, burst, zone, mode) {
            printf "%s|%s|%s|%s|legacy_%d|%d|%s|%s|%s|%s\n", kind, scope, value, file, line_no, line_no, rate, burst, zone, mode
        }
        {
            current = trim($0)
            if (previous == "# Managed by hostctl") {
                if (kind == "block" && current ~ /^deny[[:space:]]+/ && current !~ /^deny[[:space:]]+all;/) {
                    value = current; sub(/^deny[[:space:]]+/, "", value); gsub(/;/, "", value); emit(NR - 1, value, "", "", "", "trusted only")
                } else if (kind == "allow" && current ~ /^allow[[:space:]]+/) {
                    value = current; sub(/^allow[[:space:]]+/, "", value); gsub(/;/, "", value); emit(NR - 1, value, "", "", "", "trusted only")
                } else if (kind == "rate" && current ~ /^limit_req[[:space:]]+/) {
                    zone = ""; burst = "";
                    n = split(current, parts, /[[:space:]]+/);
                    for (i = 1; i <= n; i++) {
                        if (parts[i] ~ /^zone=/) { zone = parts[i]; sub(/^zone=/, "", zone); gsub(/;/, "", zone) }
                        if (parts[i] ~ /^burst=/) { burst = parts[i]; sub(/^burst=/, "", burst); gsub(/;/, "", burst) }
                    }
                    emit(NR - 1, zone, "", burst, zone, "trusted only")
                }
            }
            previous = current
        }
    ' "$file"
}

collect_managed_rules() {
    local kind="$1"
    local file
    local line_no
    local line
    local trimmed
    local marker
    local directive
    local marker_line
    local actual_kind
    local scope

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        scope="global"
        if [[ "$file" != "$HOSTCTL_NGINX_BLOCKED_IPS_CONF" && "$file" != "$HOSTCTL_NGINX_ALLOWED_IPS_CONF" && "$file" != "$HOSTCTL_NGINX_RATE_ZONE_CONF" ]]; then
            scope="$(extract_server_names_from_file "$file" | first_nonempty_line || true)"
            [[ -n "$scope" ]] || scope="unknown"
        fi

        line_no=0
        while IFS= read -r line; do
            line_no=$((line_no + 1))
            trimmed="${line#"${line%%[![:space:]]*}"}"
            rule_record_matches_kind "$trimmed" "$kind" || continue
            marker="$trimmed"
            marker_line="$line_no"
            directive=""

            if [[ "$marker" == *":BEGIN "* || "$marker" == *":BEGIN" ]]; then
                actual_kind="$(rule_kind_from_marker "$marker")"
                while IFS= read -r line; do
                    line_no=$((line_no + 1))
                    trimmed="${line#"${line%%[![:space:]]*}"}"
                    [[ "$trimmed" == "# HOSTCTL:"*":END"* ]] && break
                    [[ -n "$directive" ]] || directive="$trimmed"
                done
                rule_record_from_marker "$kind" "$file" "$marker_line" "$marker" "$directive" || true
            elif [[ "$marker" != *":END"* ]]; then
                if IFS= read -r directive; then
                    line_no=$((line_no + 1))
                    directive="${directive#"${directive%%[![:space:]]*}"}"
                    rule_record_from_marker "$kind" "$file" "$marker_line" "$marker" "$directive" || true
                fi
            fi
        done < "$file"
        collect_legacy_managed_rules_from_file "$kind" "$file" "$scope"
    done < <(managed_rule_files)
}

parse_rule_record() {
    local record="$1"

    IFS='|' read -r \
        RULE_TYPE \
        RULE_SCOPE \
        RULE_VALUE \
        RULE_FILE \
        RULE_ID \
        RULE_LINE \
        RULE_RATE \
        RULE_BURST \
        RULE_ZONE \
        RULE_MODE <<< "$record"

    if [[ ! "$RULE_LINE" =~ ^[0-9]+$ ]]; then
        error "Invalid rule record line number: ${RULE_LINE}"
        return 1
    fi

    if [[ ! -f "$RULE_FILE" ]]; then
        error "Rule config file not found: ${RULE_FILE}"
        return 1
    fi

    return 0
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

    collect_managed_rules allow | awk -F'|' -v scope="$scope" '$2 == scope { count++ } END { print count + 0 }'
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
        parse_rule_record "$record" || return 1
        scope="$RULE_SCOPE"
        value="$RULE_VALUE"
        rate="$RULE_RATE"
        burst="$RULE_BURST"
        mode="$RULE_MODE"

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
        print_rule_records "$kind" "$title" >&2 || true
        return 1
    fi

    print_rule_records "$kind" "$title" >&2 || true
    count="$(wc -l <<< "$records" | tr -d '[:space:]')"

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-${count}]: " choice </dev/tty || {
                error "Unable to read interactive input."
                return 1
            }
        else
            read -r -p "Select [1-${count}]: " choice || {
                error "Unable to read interactive input."
                return 1
            }
        fi
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

    owner="$(find_enabled_domain_owner "$scope" | first_nonempty_line || true)"
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

path_list_contains() {
    local list="$1"
    local item="$2"
    local existing

    while IFS= read -r existing; do
        [[ "$existing" == "$item" ]] && return 0
    done <<< "$list"

    return 1
}

append_unique_path_var() {
    local var_name="$1"
    local item="$2"
    local current

    eval "current=\"\${${var_name}:-}\""
    path_list_contains "$current" "$item" && return 0
    if [[ -n "$current" ]]; then
        eval "${var_name}=\"\${current}\"$'\\n'\"\${item}\""
    else
        eval "${var_name}=\"\${item}\""
    fi
}

authorize_nginx_config_modification() {
    local file="$1"
    local choice

    grep -q 'Managed by hostctl' "$file" && return 0
    path_list_contains "$HOSTCTL_AUTHORIZED_NGINX_CONFIGS" "$file" && return 0
    path_list_contains "$HOSTCTL_SKIPPED_NGINX_CONFIGS" "$file" && return 2

    echo >&2
    warning "This configuration was not created by hostctl:"
    printf '%s\n' "$file" >&2
    echo >&2

    printf '%s\n' "Modify non-hostctl config:" >&2
    printf '1. Backup and allow hostctl to modify it\n' >&2
    printf '2. Skip this configuration\n' >&2
    printf '3. Cancel\n' >&2

    while true; do
        if [[ -r /dev/tty ]]; then
            read -r -p "Select [1-3]: " choice </dev/tty || {
                error "Unable to read interactive input."
                return 3
            }
        else
            read -r -p "Select [1-3]: " choice || {
                error "Unable to read interactive input."
                return 3
            }
        fi

        case "$choice" in
            1)
                append_unique_path_var HOSTCTL_AUTHORIZED_NGINX_CONFIGS "$file"
                return 0
                ;;
            2)
                append_unique_path_var HOSTCTL_SKIPPED_NGINX_CONFIGS "$file"
                warning "Skipped non-hostctl configuration: ${file}"
                return 2
                ;;
            3)
                warning "Access rule update cancelled."
                return 3
                ;;
            *)
                warning "Invalid selection."
                ;;
        esac
    done
}

ensure_location_include() {
    local target="$1"
    local include_path="$2"
    local domain="${3:-}"
    local restart_now="${4:-yes}"
    local backup=""
    local temp_file
    local awk_status=0
    local auth_status=0

    [[ -f "$target" ]] || return 1
    if grep -Fq "include ${include_path};" "$target"; then
        return 0
    fi

    if ! grep -q 'Managed by hostctl' "$target"; then
        if authorize_nginx_config_modification "$target"; then
            auth_status=0
        else
            auth_status=$?
        fi
        [[ "$auth_status" -eq 0 ]] || return "$auth_status"
    fi

    backup="$(backup_file "$target" || true)"
    temp_file="$(mktemp)"
    if awk -v include_path="$include_path" '
        BEGIN { inserted = 0 }
        /location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
            print;
            if (include_path ~ /hostctl-global-access\.conf$/) {
                print "        # HOSTCTL:GLOBAL-ACCESS:BEGIN";
                print "        include " include_path ";";
                print "        # HOSTCTL:GLOBAL-ACCESS:END";
            } else if (include_path ~ /hostctl-access-/) {
                print "        # HOSTCTL:DOMAIN-ACCESS:BEGIN";
                print "        include " include_path ";";
                print "        # HOSTCTL:DOMAIN-ACCESS:END";
            } else {
                print "        include " include_path ";";
            }
            inserted = 1;
            next;
        }
        { print }
        END { if (inserted == 0) exit 2 }
    ' "$target" > "$temp_file"; then
        awk_status=0
    else
        awk_status=$?
    fi

    if [[ "$awk_status" -eq 2 ]]; then
        rm -f "$temp_file"
        error "Could not find a location / block in ${target}."
        return 1
    elif [[ "$awk_status" -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi

    cp "$temp_file" "$target" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    if [[ "$restart_now" != "yes" ]]; then
        return 0
    fi

    if nginx_test_and_reload "$domain"; then
        return 0
    fi

    warning "Access include failed validation; rolling back."
    restore_file_backup "$backup" "$target"
    validate_nginx_config || true
    restart_nginx || true
    return 1
}

ensure_domain_access_includes() {
    local domain="$1"
    local mode="${2:-all}"
    local target
    local status

    target="$(domain_config_for_rule_scope "$domain")" || return 1
    ensure_global_access_snippet
    ensure_domain_access_snippet "$domain"

    if ensure_location_include "$target" "$HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET" "$domain" "no"; then
        status=0
    else
        status=$?
    fi
    case "$status" in
        0) ;;
        2|3) return "$status" ;;
        *) return 1 ;;
    esac

    if [[ "$mode" == "domain" || "$mode" == "all" ]]; then
        if ensure_location_include "$target" "$(domain_access_snippet "$domain")" "$domain" "no"; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0) ;;
            2|3) return "$status" ;;
            *) return 1 ;;
        esac
    fi
}

ensure_security_enforcement_includes() {
    local domain
    local domains
    local target

    domains="$(detect_nginx_domains || true)"
    [[ -z "$domains" ]] && return 0

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        domain_is_active "$domain" || continue
        target="$(domain_config_for_rule_scope "$domain")" || return 1
        ensure_location_include "$target" "$HOSTCTL_NGINX_DOMAIN_SNIPPET" "$domain" "no" || return 1
    done <<< "$domains"
}

verify_security_enforcement() {
    local domain
    local domains
    local active_count=0

    domains="$(detect_nginx_domains || true)"
    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        domain_is_active "$domain" || continue
        active_count=$((active_count + 1))
        if ! active_domain_includes_snippet "$domain" "$HOSTCTL_NGINX_DOMAIN_SNIPPET"; then
            error "Security maps were written but active domain does not include enforcement snippet: ${domain}"
            return 1
        fi
    done <<< "$domains"

    if [[ "$active_count" -eq 0 ]]; then
        warning "No active Nginx domains found for security enforcement verification."
    fi

    return 0
}

ensure_global_access_includes() {
    local domain
    local records
    local status
    local accepted=()
    local skipped=()
    local item

    ensure_global_access_snippet
    records="$(detect_nginx_domains || true)"
    if [[ -z "$records" ]]; then
        warning "No active Nginx domains were selected for global access rules."
        return 2
    fi

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        domain_is_active "$domain" || continue
        if ensure_domain_access_includes "$domain" "global"; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0) accepted+=("$domain") ;;
            2) skipped+=("$domain") ;;
            3) return 3 ;;
            *) return 1 ;;
        esac
    done <<< "$records"

    if [[ "${#accepted[@]}" -gt 0 ]]; then
        PREPARED_ACCESS_ACCEPTED_DOMAINS="$(printf '%s\n' "${accepted[@]}")"
    fi
    if [[ "${#skipped[@]}" -gt 0 ]]; then
        PREPARED_ACCESS_SKIPPED_DOMAINS="$(printf '%s\n' "${skipped[@]}")"
    fi

    if [[ "${#accepted[@]}" -eq 0 ]]; then
        warning "No active Nginx domains were selected for global access rules."
        return 2
    fi

    echo >&2
    echo "Global access rule will apply to:" >&2
    echo >&2
    for item in "${accepted[@]}"; do
        printf -- '- %s\n' "$item" >&2
    done
    if [[ "${#skipped[@]}" -gt 0 ]]; then
        echo >&2
        echo "Skipped:" >&2
        echo >&2
        for item in "${skipped[@]}"; do
            printf -- '- %s\n' "$item" >&2
        done
    fi
    echo >&2
    confirm "Continue?" "yes" || return 3
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
    restart_nginx || true
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
    restart_nginx || true
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
    local end_marker

    [[ -f "$target" ]] || die "Domain config not found: ${target}"

    if grep -Fq "$marker" "$target"; then
        warning "Managed rule already exists."
        return 0
    fi

    temp_file="$(mktemp)"
    end_marker="$(managed_end_marker "$marker")"
    awk -v marker="$marker" -v directive="$directive" -v end_marker="$end_marker" '
        BEGIN { inserted = 0 }
        /location[[:space:]]+\/[[:space:]]*\{/ && inserted == 0 {
            print;
            print "        " marker;
            print "        " directive;
            print "        " end_marker;
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

    printf '%s\n%s\n%s\n' "$marker" "$directive" "$(managed_end_marker "$marker")" >> "$temp_file"
    replace_file_from_temp_with_validation "$target" "$temp_file" "$log_name"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

managed_end_marker() {
    local marker="$1"
    local prefix
    local id

    prefix="${marker%%:BEGIN*}"
    id="$(marker_field "$marker" id)"
    if [[ -n "$id" ]]; then
        printf '%s:END id=%s\n' "$prefix" "$id"
    else
        printf '%s:END\n' "$prefix"
    fi
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

remove_rule_record_from_file() {
    local file="$1"
    local rule_id="$2"
    local line_no="$3"
    local kind="${4:-}"
    local mode="${5:-}"
    local temp_file
    local marker_type
    local block
    local begin_line
    local end_line

    if [[ ! "$line_no" =~ ^[0-9]+$ ]]; then
        error "Internal rule parsing error: invalid line number '${line_no}'"
        return 1
    fi

    temp_file="$(mktemp)"
    if [[ -n "$rule_id" && "$rule_id" != legacy_* ]]; then
        marker_type="$(rule_marker_type "$kind" "$mode")"
        block="$(find_managed_rule_block "$file" "$marker_type" "$rule_id")" || {
            rm -f "$temp_file"
            return 1
        }
        begin_line="${block%%|*}"
        end_line="${block#*|}"
        awk -v begin_line="$begin_line" -v end_line="$end_line" 'NR < begin_line || NR > end_line { print }' "$file" > "$temp_file"
        printf '%s\n' "$temp_file"
        return 0
    fi

    local awk_status=0
    if awk -v rule_id="$rule_id" -v target_line="$line_no" '
        function trim(s) { sub(/^[[:space:]]+/, "", s); sub(/[[:space:]]+$/, "", s); return s }
        rule_id != "" && $0 ~ /^# HOSTCTL:.*:BEGIN/ && $0 ~ (" id=" rule_id "([[:space:]]|$)") {
            skip_block = 1;
            removed = 1;
            next;
        }
        skip_block {
            if (trim($0) ~ /^# HOSTCTL:.*:END/ && $0 ~ (" id=" rule_id "([[:space:]]|$)")) skip_block = 0;
            next;
        }
        removed == 0 && NR == target_line {
            line = trim($0);
            if (line ~ /^# HOSTCTL:.*:BEGIN/) {
                skip_line_block = 1;
                next
            }
            if (line ~ /^# HOSTCTL:/ || line == "# Managed by hostctl") {
                skip_next = 1;
                next;
            }
        }
        skip_line_block {
            if (trim($0) ~ /^# HOSTCTL:.*:END/) skip_line_block = 0;
            next;
        }
        skip_next == 1 {
            skip_next = 0;
            next;
        }
        { print }
        END {
            if (rule_id != "" && rule_id !~ /^legacy_/ && removed == 0) exit 3
        }
    ' "$file" > "$temp_file"; then
        awk_status=0
    else
        awk_status=$?
    fi
    if [[ "$awk_status" -eq 3 ]]; then
        rm -f "$temp_file"
        error "Managed rule marker not found: id=${rule_id}"
        return 1
    elif [[ "$awk_status" -ne 0 ]]; then
        rm -f "$temp_file"
        return 1
    fi
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
    local records
    local record
    local line_no

    records="$(collect_managed_rules allow | awk -F'|' -v scope="$scope" '$2 == scope && $10 == "allow-only"')"
    if [[ -n "$records" ]]; then
        while IFS= read -r record; do
            parse_rule_record "$record" || return 1
            file="$RULE_FILE"
            line_no="$RULE_LINE"
            temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
            cp "$temp_file" "$file"
            rm -f "$temp_file"
            changed="yes"
        done <<< "$records"
    fi

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

ssh_client_ip() {
    awk '{ print $1; exit }' <<< "${SSH_CONNECTION:-}"
}

warn_global_allow_only() {
    local value="$1"
    local client_ip

    warning "GLOBAL allow-only mode affects every hostctl-managed Nginx domain."
    warning "If your current public IP is not allowed, you may block your own HTTP/HTTPS access."
    client_ip="$(ssh_client_ip)"
    if [[ -n "$client_ip" && "$client_ip" != "$value" ]]; then
        warning "Allowed IP does not match the current SSH client IP: ${client_ip}"
    fi
    confirm "Continue?" "no"
}

prepare_access_rule_target() {
    local scope="$1"
    local type="$2"
    local status

    PREPARED_ACCESS_TARGET=""
    PREPARED_ACCESS_ACCEPTED_DOMAINS=""
    PREPARED_ACCESS_SKIPPED_DOMAINS=""
    if [[ "$scope" == "global" ]]; then
        ensure_global_access_snippet
        if ensure_global_access_includes; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0) ;;
            2|3) return "$status" ;;
            *) return 1 ;;
        esac
    else
        ensure_domain_access_snippet "$scope"
        if ensure_domain_access_includes "$scope" "domain"; then
            status=0
        else
            status=$?
        fi
        case "$status" in
            0) ;;
            2)
                return 2
                ;;
            3) return 3 ;;
            *) return 1 ;;
        esac
    fi

    PREPARED_ACCESS_TARGET="$(target_for_scope "$scope" "$type")"
    [[ -n "$PREPARED_ACCESS_TARGET" ]]
}

active_domain_includes_snippet() {
    local domain="$1"
    local snippet="$2"
    local records
    local record
    local real_path

    records="$(active_domain_config_records "$domain" || true)"
    [[ -z "$records" ]] && return 1

    while IFS= read -r record; do
        real_path="$(cut -d'|' -f2 <<< "$record")"
        [[ -f "$real_path" ]] || continue
        grep -Fq "include ${snippet};" "$real_path" && return 0
    done <<< "$records"

    return 1
}

verify_access_rule_effective() {
    local scope="$1"
    local target="$2"
    local rule_id="$3"
    local snippet
    local domain
    local domains

    grep -Fq "id=${rule_id}" "$target" || {
        error "Rule was not written to the managed access snippet."
        return 1
    }

    if [[ "$scope" == "global" ]]; then
        snippet="$HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET"
        if [[ -n "$PREPARED_ACCESS_ACCEPTED_DOMAINS" ]]; then
            domains="$PREPARED_ACCESS_ACCEPTED_DOMAINS"
        else
            domains="$(detect_nginx_domains || true)"
        fi
        while IFS= read -r domain; do
            [[ -n "$domain" ]] || continue
            domain_is_active "$domain" || continue
            if ! active_domain_includes_snippet "$domain" "$snippet"; then
                error "Rule was written but is not referenced by the active domain configuration."
                error "Missing include for ${domain}: ${snippet}"
                return 1
            fi
        done <<< "$domains"
    else
        snippet="$(domain_access_snippet "$scope")"
        if ! active_domain_includes_snippet "$scope" "$snippet"; then
            error "Rule was written but is not referenced by the active domain configuration."
            return 1
        fi
    fi

    return 0
}

verify_rule_removed() {
    local file="$1"
    local rule_id="$2"

    if [[ "$rule_id" != legacy_* ]] && grep -Fq "id=${rule_id}" "$file"; then
        error "Managed rule still exists after removal: id=${rule_id}"
        return 1
    fi

    return 0
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
            block|allow) printf '%s\n' "$HOSTCTL_NGINX_GLOBAL_ACCESS_SNIPPET" ;;
        esac
    else
        printf '%s\n' "$(domain_access_snippet "$scope")"
    fi
}

add_block_ip_rule() {
    local scope="$1"
    local value="$2"
    local target
    local marker
    local directive
    local id
    local result
    local prepare_status

    if prepare_access_rule_target "$scope" block; then
        prepare_status=0
    else
        prepare_status=$?
    fi
    case "$prepare_status" in
        0) target="$PREPARED_ACCESS_TARGET" ;;
        2)
            warning "Block rule was not created because the active domain configuration was skipped."
            return 0
            ;;
        3) return 0 ;;
        *) return 1 ;;
    esac
    directive="deny ${value};"
    if [[ "$scope" == "global" ]]; then
        marker="# HOSTCTL:BLOCK-IP:BEGIN id=$(rule_id block "$value") scope=global value=${value}"
        id="$(marker_field "$marker" id)"
        append_managed_global_rule "$target" "$marker" "$directive" "NGINX_BLOCK_IP_ADD"
        result=$?
    else
        marker="# HOSTCTL:BLOCK-IP:BEGIN id=$(rule_id block "$value") domain=${scope} value=${value}"
        id="$(marker_field "$marker" id)"
        append_managed_global_rule "$target" "$marker" "$directive" "NGINX_BLOCK_IP_ADD"
        result=$?
    fi
    [[ "$result" -eq 0 ]] || return "$result"
    verify_access_rule_effective "$scope" "$target" "$id" || return 1
    success "Block rule added and active."
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
    local id
    local result
    local prepare_status

    if [[ "$mode" == "allow-only" ]]; then
        if [[ "$scope" == "global" ]]; then
            warn_global_allow_only "$value" || return 0
        else
            warning "This mode will deny all clients except allowed addresses."
            confirm "Continue?" "no" || return 0
        fi
    fi
    if prepare_access_rule_target "$scope" allow; then
        prepare_status=0
    else
        prepare_status=$?
    fi
    case "$prepare_status" in
        0) target="$PREPARED_ACCESS_TARGET" ;;
        2)
            if [[ "$scope" != "global" ]]; then
                warning "Whitelist rule was not created because the active domain configuration was skipped."
            fi
            return 0
            ;;
        3) return 0 ;;
        *) return 1 ;;
    esac
    directive="allow ${value};"

    if [[ "$scope" == "global" ]]; then
        if [[ "$mode" == "allow-only" ]]; then
            marker="# HOSTCTL:ALLOW-ONLY:BEGIN id=$(rule_id allow "$value") scope=global value=${value}"
        else
            marker="# HOSTCTL:ALLOW-IP:BEGIN id=$(rule_id allow "$value") scope=global value=${value}"
        fi
        id="$(marker_field "$marker" id)"
        temp_file="$(mktemp)"
        [[ -f "$target" ]] && cp "$target" "$temp_file" || printf '# Managed by hostctl\n' > "$temp_file"
        grep -Fq "$marker" "$temp_file" || printf '%s\n%s\n' "$marker" "$directive" >> "$temp_file"
        if [[ "$mode" == "allow-only" ]]; then
            printf 'deny all;\n%s\n' "$(managed_end_marker "$marker")" >> "$temp_file"
        else
            printf '%s\n' "$(managed_end_marker "$marker")" >> "$temp_file"
        fi
        replace_file_from_temp_with_validation "$target" "$temp_file" "NGINX_ALLOW_IP_ADD"
        result=$?
        rm -f "$temp_file"
        [[ "$result" -eq 0 ]] || return "$result"
        verify_access_rule_effective "$scope" "$target" "$id" || return 1
        success "Whitelist rule added and active."
        return 0
    else
        if [[ "$mode" == "allow-only" ]]; then
            marker="# HOSTCTL:ALLOW-ONLY:BEGIN id=$(rule_id allow "$value") domain=${scope} value=${value}"
            directive="$(printf 'allow %s;\n        deny all;' "$value")"
        else
            marker="# HOSTCTL:ALLOW-IP:BEGIN id=$(rule_id allow "$value") domain=${scope} value=${value}"
        fi
        id="$(marker_field "$marker" id)"
        append_managed_global_rule "$target" "$marker" "$directive" "NGINX_ALLOW_IP_ADD" || return 1
        verify_access_rule_effective "$scope" "$target" "$id" || return 1
        success "Whitelist rule added and active."
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
    local temp_file

    record="$(select_managed_rule block "Blocked IP Rules")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    scope="$RULE_SCOPE"
    old_value="$RULE_VALUE"

    echo "Current IP/CIDR: ${old_value}"
    while true; do
        new_value="$(ask_input "New IP/CIDR" "$old_value")"
        validate_ip_or_cidr "$new_value" && break
        warning "Invalid IP/CIDR."
    done
    new_scope="$(select_scope_for_rule "$scope")" || return 1

    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_BLOCK_IP_EDIT" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    if add_block_ip_rule "$new_scope" "$new_value"; then
        success "Block rule updated."
        return 0
    fi
    return 1
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
    local temp_file

    record="$(select_managed_rule block "Blocked IP Rules")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    scope="$RULE_SCOPE"
    value="$RULE_VALUE"

    confirm "Remove ${value} from ${scope}?" "no" || return 0
    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_BLOCK_IP_REMOVE" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")"
    local result=$?
    rm -f "$temp_file"
    if [[ "$result" -eq 0 ]]; then
        verify_rule_removed "$file" "$RULE_ID" || return 1
        success "Block rule removed."
    fi
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

    local record file line_no scope old_value new_value new_scope mode_choice mode temp_file

    record="$(select_managed_rule allow "Whitelist Rules")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    scope="$RULE_SCOPE"
    old_value="$RULE_VALUE"

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

    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
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
    if add_allow_ip_rule "$new_scope" "$new_value" "$mode"; then
        success "Whitelist rule updated."
        return 0
    fi
    return 1
}

cmd_nginx_whitelist_ip_remove() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no scope value temp_file allow_count remove_deny="no"

    record="$(select_managed_rule allow "Whitelist Rules")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    scope="$RULE_SCOPE"
    value="$RULE_VALUE"

    if has_allow_only_for_scope "$scope"; then
        allow_count="$(count_allow_rules_for_scope "$scope")"
        if [[ "$allow_count" -le 1 ]]; then
            warning "This is the last allowed IP while deny-all is active."
            select_option "Choose:" "Remove rule and remove hostctl deny-all" "Cancel" | grep -q '^Remove' || return 0
            remove_deny="yes"
        fi
    fi

    confirm "Remove whitelist rule for ${value} from ${scope}?" "no" || return 0
    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_ALLOW_IP_REMOVE" "$([[ "$scope" != "global" ]] && printf '%s' "$scope")" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    if [[ "$remove_deny" == "yes" ]]; then
        remove_allow_only_for_scope "$scope" || true
        nginx_test_and_reload "$([[ "$scope" != "global" ]] && printf '%s' "$scope")"
    fi
    verify_rule_removed "$file" "$RULE_ID" || return 1
    success "Whitelist rule removed."
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
        parse_rule_record "$record" || return 1
        domain="$RULE_SCOPE"
        rate="$RULE_RATE"
        zone="$(rate_zone_name "$domain")"
        local marker
        marker="# HOSTCTL:RATE-ZONE:BEGIN id=$(rule_id zone "$domain") domain=${domain} zone=${zone} rate=${rate}"
        printf '%s\n' "$marker" >> "$output"
        printf 'limit_req_zone $binary_remote_addr zone=%s:10m rate=%sr/s;\n' "$zone" "$rate" >> "$output"
        printf '%s\n' "$(managed_end_marker "$marker")" >> "$output"
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
    marker="# HOSTCTL:RATE-LIMIT:BEGIN id=$(rule_id rate "$domain") domain=${domain} rate=${rate} burst=${burst} zone=${zone}"
    directive="limit_req zone=${zone} burst=${burst} nodelay;"

    insert_managed_block_in_location "$target" "$marker" "$directive" "NGINX_RATE_LIMIT_ADD" "$domain" || return 1
    temp_file="$(mktemp)"
    render_rate_zone_file_from_markers "$temp_file"
    replace_file_from_temp_with_validation "$HOSTCTL_NGINX_RATE_ZONE_CONF" "$temp_file" "NGINX_RATE_LIMIT_ADD" "$domain"
    local result=$?
    rm -f "$temp_file"
    return "$result"
}

rate_zone_referenced_elsewhere() {
    local zone="$1"
    local exclude_file="${2:-}"
    local file

    while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        [[ -n "$exclude_file" && "$file" == "$exclude_file" ]] && continue
        grep -Fq "limit_req zone=${zone}" "$file" && return 0
    done < <(managed_rule_files)

    return 1
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

    local record file line_no domain rate_burst rate burst temp_file

    record="$(select_managed_rule rate "Rate Limits")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    domain="$RULE_SCOPE"

    echo "Domain: ${domain}"
    echo "Rate: ${RULE_RATE} req/s"
    echo "Burst: ${RULE_BURST}"
    rate_burst="$(select_rate_profile)"
    rate="${rate_burst%%|*}"
    burst="${rate_burst##*|}"

    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_RATE_LIMIT_EDIT" "$domain" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"
    if add_rate_limit_rule "$domain" "$rate" "$burst"; then
        success "Rate limit updated."
        return 0
    fi
    return 1
}

cmd_nginx_rate_limit_remove() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local record file line_no domain temp_file zone_file zone

    record="$(select_managed_rule rate "Rate Limits")" || return 0
    parse_rule_record "$record" || return 1
    file="$RULE_FILE"
    line_no="$RULE_LINE"
    domain="$RULE_SCOPE"
    zone="$RULE_ZONE"
    [[ -n "$zone" ]] || zone="$(rate_zone_name "$domain")"

    confirm "Remove rate limit for ${domain}?" "no" || return 0
    temp_file="$(remove_rule_record_from_file "$file" "$RULE_ID" "$line_no" "$RULE_TYPE" "$RULE_MODE")" || return 1
    replace_file_from_temp_with_validation "$file" "$temp_file" "NGINX_RATE_LIMIT_REMOVE" "$domain" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    if rate_zone_referenced_elsewhere "$zone" "$file"; then
        info "Rate limit zone ${zone} is still referenced; keeping managed zone definition."
        return 0
    fi

    zone_file="$(mktemp)"
    render_rate_zone_file_from_markers "$zone_file"
    replace_file_from_temp_with_validation "$HOSTCTL_NGINX_RATE_ZONE_CONF" "$zone_file" "NGINX_RATE_LIMIT_REMOVE" "$domain"
    local result=$?
    rm -f "$zone_file"
    if [[ "$result" -eq 0 ]]; then
        verify_rule_removed "$file" "$RULE_ID" || return 1
        success "Rate limit removed."
    fi
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
