#!/usr/bin/env bash

# =========================================================
# hostctl - SSL / Certbot Operations
# =========================================================

LETSENCRYPT_LIVE_DIR="/etc/letsencrypt/live"

ssl_certificate_dir() {
    printf '%s/%s\n' "$LETSENCRYPT_LIVE_DIR" "$1"
}

ssl_certificate_fullchain() {
    printf '%s/fullchain.pem\n' "$(ssl_certificate_dir "$1")"
}

ssl_certificate_privkey() {
    printf '%s/privkey.pem\n' "$(ssl_certificate_dir "$1")"
}

ssl_certificate_exists() {
    local domain="$1"

    [[ -f "$(ssl_certificate_fullchain "$domain")" ]] &&
    [[ -f "$(ssl_certificate_privkey "$domain")" ]]
}

ssl_certificate_valid() {
    local domain="$1"

    ssl_certificate_exists "$domain" || return 1
    command_exists openssl || return 1
    openssl x509 -checkend 86400 -noout -in "$(ssl_certificate_fullchain "$domain")" >/dev/null 2>&1
}

domain_certificate_exists() {
    ssl_certificate_exists "$1"
}

domain_certificate_valid() {
    ssl_certificate_valid "$1"
}

ssl_certificate_status_label() {
    local domain="$1"

    if ! ssl_certificate_exists "$domain"; then
        printf 'not detected'
    elif ssl_certificate_valid "$domain"; then
        if domain_has_https_active "$domain"; then
            printf 'active'
        else
            printf 'available'
        fi
    else
        printf 'present but expired or near expiry'
    fi
}

ssl_domain_config_for_update() {
    local domain="$1"
    local record
    local source

    record="$(active_domain_config_records "$domain" | first_nonempty_line || true)"
    if [[ -n "$record" ]]; then
        source="$(cut -d'|' -f2 <<< "$record")"
        [[ -f "$source" ]] && {
            printf '%s\n' "$source"
            return 0
        }
    fi

    preferred_domain_source_config "$domain"
}

ssl_proxy_pass_for_domain() {
    local file="$1"
    local domain="$2"

    awk -v domain="$domain" '
        BEGIN { in_server = 0; depth = 0; has_domain = 0 }
        /server[[:space:]]*\{/ {
            in_server = 1;
            line = $0;
            opens = gsub(/\{/, "{", line);
            line = $0;
            closes = gsub(/\}/, "}", line);
            depth = opens - closes;
            has_domain = 0;
        }
        in_server {
            line = $0;
            opens = gsub(/\{/, "{", line);
            line = $0;
            closes = gsub(/\}/, "}", line);
            if ($0 !~ /server[[:space:]]*\{/) depth += opens - closes;

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

            if (has_domain && $1 == "proxy_pass") {
                value = $2;
                gsub(/;/, "", value);
                print value;
                exit;
            }

            if (depth <= 0) in_server = 0;
        }
    ' "$file"
}

ssl_body_size_for_domain() {
    local file="$1"
    local domain="$2"

    awk -v domain="$domain" '
        BEGIN { in_server = 0; depth = 0; has_domain = 0 }
        /server[[:space:]]*\{/ {
            in_server = 1;
            line = $0;
            opens = gsub(/\{/, "{", line);
            line = $0;
            closes = gsub(/\}/, "}", line);
            depth = opens - closes;
            has_domain = 0;
        }
        in_server {
            line = $0;
            opens = gsub(/\{/, "{", line);
            line = $0;
            closes = gsub(/\}/, "}", line);
            if ($0 !~ /server[[:space:]]*\{/) depth += opens - closes;

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

            if (has_domain && $1 == "client_max_body_size") {
                value = $2;
                gsub(/;/, "", value);
                print value;
                exit;
            }

            if (depth <= 0) in_server = 0;
        }
    ' "$file"
}

ssl_append_managed_https_server() {
    local file="$1"
    local domain="$2"
    local upstream="$3"
    local body_size="$4"
    local output="$5"

    cp "$file" "$output" || return 1

    cat >> "$output" <<EOF

# HOSTCTL:SSL:BEGIN domain=${domain}
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name ${domain};

    ssl_certificate $(ssl_certificate_fullchain "$domain");
    ssl_certificate_key $(ssl_certificate_privkey "$domain");

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
# HOSTCTL:SSL:END domain=${domain}
EOF
}

ssl_enable_existing_controlled() {
    local domain="$1"
    local source
    local upstream
    local body_size
    local backup=""
    local temp_file
    local auth_status=0

    source="$(ssl_domain_config_for_update "$domain")"
    if [[ -z "$source" || ! -f "$source" ]]; then
        error "No Nginx configuration found for ${domain}."
        return 1
    fi

    upstream="$(ssl_proxy_pass_for_domain "$source" "$domain" | first_nonempty_line || true)"
    if [[ -z "$upstream" ]]; then
        error "Cannot enable existing certificate automatically."
        error "Unable to infer proxy_pass from: ${source}"
        return 1
    fi

    body_size="$(ssl_body_size_for_domain "$source" "$domain" | first_nonempty_line || true)"
    body_size="${body_size:-10M}"

    if ! grep -q 'Managed by hostctl' "$source"; then
        if declare -F authorize_nginx_config_modification >/dev/null 2>&1; then
            authorize_nginx_config_modification "$source" || auth_status=$?
            case "$auth_status" in
                0) ;;
                2)
                    warning "SSL enable skipped for non-hostctl configuration."
                    return 0
                    ;;
                *)
                    warning "SSL enable cancelled."
                    return 0
                    ;;
            esac
        else
            error "Refusing to modify non-hostctl configuration: ${source}"
            return 1
        fi
    fi

    ensure_domain_snippet
    ensure_global_access_snippet
    ensure_domain_access_snippet "$domain"

    backup="$(backup_file "$source" || true)"
    temp_file="$(mktemp)"
    ssl_append_managed_https_server "$source" "$domain" "$upstream" "$body_size" "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    cp "$temp_file" "$source" || {
        rm -f "$temp_file"
        return 1
    }
    rm -f "$temp_file"

    if nginx_test_and_reload "$domain"; then
        domain_has_https_active "$domain" || {
            error "HTTPS is still inactive after controlled SSL configuration."
            rollback_file "$backup" "$source" || true
            validate_nginx_config || true
            restart_nginx || true
            return 1
        }
        success "SSL enabled: ${domain}"
        return 0
    fi

    warning "SSL configuration failed validation; rolling back."
    rollback_file "$backup" "$source" || true
    validate_nginx_config || true
    restart_nginx || true
    return 1
}

ssl_certbot_available() {
    if ! command_exists certbot; then
        error "Certbot is not installed. Run: sudo hostctl --init"
        return 1
    fi

    return 0
}

ssl_enable_existing() {
    local domain="$1"
    local status=0

    ssl_certbot_available || return 1

    info "Enabling existing certificate with Certbot: ${domain}"
    nginx_debug "command: certbot install --cert-name ${domain} --nginx --redirect"
    certbot install --cert-name "$domain" --nginx --redirect || status=$?
    nginx_debug "return code: ${status}"
    if (( status != 0 )); then
        warning "Certbot install failed; trying controlled Nginx SSL configuration."
        ssl_enable_existing_controlled "$domain"
        return
    fi

    nginx_test_and_reload "$domain" || return 1
    domain_has_https_active "$domain" || {
        error "HTTPS is still inactive after Certbot install."
        return 1
    }

    success "SSL enabled: ${domain}"
    return 0
}

ssl_issue_certificate() {
    local domain="$1"
    local email
    local status=0

    ssl_certbot_available || return 1

    email="$(ask_input "Email for Let's Encrypt")" || return 1
    [[ -n "$email" ]] || {
        error "Email is required to issue a Let's Encrypt certificate."
        return 1
    }

    info "Issuing Let's Encrypt certificate: ${domain}"
    nginx_debug "command: certbot --nginx -d ${domain} --redirect --agree-tos -m <email>"
    certbot --nginx -d "$domain" --redirect --agree-tos -m "$email" || status=$?
    nginx_debug "return code: ${status}"
    (( status == 0 )) || return "$status"

    nginx_test_and_reload "$domain" || return 1
    domain_has_https_active "$domain" || {
        error "HTTPS is still inactive after certificate issuance."
        return 1
    }

    success "SSL enabled: ${domain}"
    return 0
}

ssl_setup_domain() {
    local domain="$1"
    local action

    if domain_has_https_active "$domain"; then
        success "SSL already active: ${domain}"
        return 0
    fi

    if ! domain_has_http_active "$domain"; then
        error "HTTP must be active before enabling SSL for ${domain}."
        return 1
    fi

    if ssl_certificate_exists "$domain"; then
        echo
        printf 'An SSL certificate already exists for %s.\n' "$domain"
        echo

        if ! ssl_certificate_valid "$domain"; then
            warning "Existing certificate is expired or close to expiry."
            if confirm "Renew/reissue certificate?" "yes"; then
                ssl_issue_certificate "$domain"
                return
            fi
            warning "SSL setup skipped."
            return 0
        fi

        action="$(
            select_option \
                "SSL certificate:" \
                "Enable existing certificate" \
                "Reissue/renew certificate" \
                "Skip"
        )" || return 1

        case "$action" in
            "Enable existing certificate") ssl_enable_existing "$domain" ;;
            "Reissue/renew certificate") ssl_issue_certificate "$domain" ;;
            "Skip") warning "SSL setup skipped." ;;
        esac
    else
        echo
        printf 'No SSL certificate found for %s.\n' "$domain"
        echo

        action="$(
            select_option \
                "SSL certificate:" \
                "Issue Let's Encrypt certificate" \
                "Skip"
        )" || return 1

        case "$action" in
            "Issue Let's Encrypt certificate") ssl_issue_certificate "$domain" ;;
            "Skip") warning "SSL setup skipped." ;;
        esac
    fi
}

maybe_offer_ssl_activation() {
    local domain="$1"

    domain_has_http_active "$domain" || return 0
    domain_has_https_active "$domain" && return 0

    echo
    printf 'HTTPS is not enabled for %s.\n' "$domain"

    if confirm "Enable SSL now?" "yes"; then
        if ! ssl_setup_domain "$domain"; then
            error "SSL certificate setup failed."
            warning "HTTP remains active."
            return 0
        fi
    fi
}

cmd_ssl() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local domain

    domain="$(select_nginx_domain "no")" || return 1
    ssl_setup_domain "$domain" || {
        error "SSL certificate setup failed."
        warning "Existing HTTP configuration was not removed."
        return 0
    }
}

cmd_ssl_status() {
    require_root
    require_debian_based
    ensure_nginx_installed

    local domain

    echo
    echo "SSL Status"
    echo

    while IFS= read -r domain; do
        [[ -n "$domain" ]] || continue
        printf '%s\n' "$domain"
        printf '  HTTP: %s\n' "$(domain_has_http_active "$domain" && printf 'active' || printf 'inactive')"
        printf '  HTTPS: %s\n' "$(domain_has_https_active "$domain" && printf 'active' || printf 'inactive')"
        printf '  Certificate: %s\n' "$(ssl_certificate_status_label "$domain")"
        if ssl_certificate_exists "$domain"; then
            printf '  Certificate Path: %s\n' "$(ssl_certificate_fullchain "$domain")"
        fi
        echo
    done < <(detect_nginx_domains)
}
