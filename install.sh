#!/usr/bin/env bash
#
# 3XUI-SNI — установщик сайта-прикрытия для 3X-UI (VLESS Reality).
# Репозиторий: https://github.com/KirgizAzur/3XUI-SNI
#
set -euo pipefail
umask 022

REPO_OWNER="KirgizAzur"
REPO_NAME="3XUI-SNI"
TMP_DIR="/tmp/3xui-sni-installer"
SITE_DIR="/var/www/html"
NGINX_CONF="/etc/nginx/conf.d/main.conf"
STATE_FILE="/etc/3xui-sni.conf"
DEFAULT_PORT="9443"

DOMAIN="${DOMAIN:-}"
PORT="${PORT:-}"
TEMPLATE="${TEMPLATE:-}"
CERT_DIR="${CERT_DIR:-}"
RANDOM_TEMPLATE=0
LIST_ONLY=0
UNINSTALL=0
FORCE=0

NGINX_VERSION=""
TEMPLATES_DIR=""
TEMPLATE_DIR=""
TEMPLATE_NAME=""
ID=""
VERSION_CODENAME=""
UBUNTU_CODENAME=""

if [[ -t 1 ]]; then
    C_RESET=$'\033[0m'
    C_RED=$'\033[31m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_CYAN=$'\033[36m'
    C_BOLD=$'\033[1m'
else
    C_RESET="" C_RED="" C_GREEN="" C_YELLOW="" C_CYAN="" C_BOLD=""
fi

info() { printf '%s%s%s\n' "$C_CYAN" "$*" "$C_RESET"; }
step() { printf '%s==>%s %s\n' "$C_CYAN$C_BOLD" "$C_RESET" "$*"; }
ok() { printf '%s✓%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s!%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%s✗ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; exit 1; }

usage() {
    cat <<'EOF'
3XUI-SNI — установщик сайта-прикрытия для 3X-UI (VLESS Reality)

Использование: bash install.sh [параметры]

Параметры:
  -d, --domain <домен>     домен для SNI (например, example.com)
  -p, --port <порт>        порт Nginx на localhost (по умолчанию 9443)
  -t, --template <имя>     шаблон сайта (список: --list)
  -r, --random             выбрать случайный шаблон
  -c, --cert-dir <путь>    каталог сертификата (по умолчанию /root/cert/<домен>)
  -l, --list               показать доступные шаблоны и выйти
  -u, --uninstall          удалить конфигурацию Nginx и завершить
  -f, --force              продолжить без проверки сертификата
  -h, --help               показать эту справку

Без параметров запускается интерактивный режим.

Примеры:
  bash install.sh
  bash install.sh --domain example.com --port 9443 --template converter
  bash install.sh --domain example.com --random
  bash install.sh --uninstall

Переменные окружения DOMAIN, PORT, TEMPLATE, CERT_DIR работают так же, как
одноимённые параметры.
EOF
}

cleanup() { rm -rf "$TMP_DIR"; }

require_root() {
    [[ ${EUID} -eq 0 ]] || die "Запустите скрипт от root (sudo bash install.sh)."
    command -v apt-get >/dev/null 2>&1 || die "Поддерживаются только Debian/Ubuntu (нет apt-get)."
    command -v systemctl >/dev/null 2>&1 || die "Не найден systemd (systemctl)."
}

banner() {
    [[ -t 1 ]] && clear || true
    printf '%s' "$C_CYAN$C_BOLD"
    cat <<'EOF'
=========================================
        3XUI-SNI · установщик
=========================================
EOF
    printf '%s' "$C_RESET"
}

load_os_release() {
    if [[ -r /etc/os-release ]]; then
        set +u
        . /etc/os-release
        set -u
    fi
    case "${ID:-}" in
        debian | ubuntu) ;;
        *) warn "Скрипт рассчитан на Debian/Ubuntu, на этой системе возможны ошибки." ;;
    esac
}

parse_args() {
    while (($#)); do
        case "$1" in
            -d | --domain)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует значения."
                DOMAIN="$2"
                shift 2
                ;;
            -p | --port)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует значения."
                PORT="$2"
                shift 2
                ;;
            -t | --template)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует значения."
                TEMPLATE="$2"
                shift 2
                ;;
            -c | --cert-dir)
                [[ -n "${2:-}" ]] || die "Параметр $1 требует значения."
                CERT_DIR="$2"
                shift 2
                ;;
            -r | --random)
                RANDOM_TEMPLATE=1
                shift
                ;;
            -l | --list)
                LIST_ONLY=1
                shift
                ;;
            -u | --uninstall)
                UNINSTALL=1
                shift
                ;;
            -f | --force)
                FORCE=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                die "Неизвестный параметр: $1 (справка: --help)"
                ;;
        esac
    done
}

valid_domain() {
    [[ "$1" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]
}

valid_port() {
    [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535))
}

version_ge() {
    local sorted
    sorted="$(printf '%s\n%s\n' "$2" "$1" | sort -V)"
    [[ "${sorted%%$'\n'*}" == "$2" ]]
}

port_busy() {
    local port="$1" out
    command -v ss >/dev/null 2>&1 || return 1
    out="$(ss -Hltn "sport = :${port}" 2>/dev/null || true)"
    [[ -n "$out" ]] && return 0
    out="$(ss -Hltn 2>/dev/null | awk '{ print $4 }' || true)"
    grep -qE "[:.]${port}$" <<<"$out"
}

describe_template() {
    case "$1" in
        10gag) echo "лента мемов (Meme Flow), EN" ;;
        converter) echo "конвертер файлов (ConvertMaster), EN" ;;
        convertit) echo "видеоредактор (VidCraft), RU" ;;
        downloader) echo "безопасная передача данных (DataVault), RU" ;;
        filecloud) echo "облачное хранилище (CloudStore), EN" ;;
        games-site) echo "ретро-игры (RetroStream), RU" ;;
        speedtest) echo "тест скорости (SpeedCheck), RU" ;;
        youtube-captcha) echo "видеохостинг (Видеоландия), RU" ;;
        *) echo "статический сайт" ;;
    esac
}

choose_domain() {
    DOMAIN="${DOMAIN,,}"
    DOMAIN="${DOMAIN%.}"
    if [[ -n "$DOMAIN" ]]; then
        valid_domain "$DOMAIN" || die "Некорректный домен: ${DOMAIN}"
        return 0
    fi
    [[ -t 0 ]] || die "Домен не задан. Укажите --domain example.com"
    while true; do
        read -r -p "Домен (например, example.com): " DOMAIN || die "Ввод прерван."
        DOMAIN="${DOMAIN,,}"
        DOMAIN="${DOMAIN%.}"
        valid_domain "$DOMAIN" && break
        warn "Некорректный домен, попробуйте ещё раз."
    done
    return 0
}

ensure_port_free() {
    port_busy "$PORT" || return 0
    if [[ -f "$NGINX_CONF" ]] && grep -q "127.0.0.1:${PORT} " "$NGINX_CONF"; then
        return 0
    fi
    die "Порт ${PORT} уже занят. Выберите другой: --port <порт>"
}

choose_port() {
    local choice
    if [[ -n "$PORT" ]]; then
        valid_port "$PORT" || die "Некорректный порт: ${PORT} (допустимо 1024-65535)."
    elif [[ ! -t 0 ]]; then
        PORT="$DEFAULT_PORT"
    else
        echo
        echo "Порт Nginx на localhost:"
        echo "  1) ${DEFAULT_PORT} (по умолчанию)"
        echo "  2) указать свой"
        read -r -p "Выбор [1]: " choice || die "Ввод прерван."
        case "${choice:-1}" in
            2)
                while true; do
                    read -r -p "Порт (1024-65535): " PORT || die "Ввод прерван."
                    valid_port "$PORT" && break
                    warn "Некорректный порт."
                done
                ;;
            *) PORT="$DEFAULT_PORT" ;;
        esac
    fi
    PORT="$((10#$PORT))"
    ensure_port_free
    return 0
}

install_packages() {
    step "Проверка базовых пакетов"
    apt-get update -qq || warn "Не удалось обновить список пакетов, продолжаем с текущим."

    local pkg
    local missing=()
    for pkg in curl ca-certificates gnupg iproute2 tar; do
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done
    if ((${#missing[@]})); then
        step "Установка: ${missing[*]}"
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
    fi
    ok "Базовые пакеты установлены"
}

add_nginx_repo() {
    local base codename
    case "${ID:-}" in
        debian) base="http://nginx.org/packages/debian" ;;
        ubuntu) base="http://nginx.org/packages/ubuntu" ;;
        *) return 1 ;;
    esac
    codename="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    [[ -n "$codename" ]] || return 1

    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --max-time 30 https://nginx.org/keys/nginx_signing.key |
        gpg --dearmor --yes -o /etc/apt/keyrings/nginx-archive-keyring.gpg 2>/dev/null; then
        return 1
    fi
    printf 'deb [signed-by=/etc/apt/keyrings/nginx-archive-keyring.gpg] %s %s nginx\n' \
        "$base" "$codename" >/etc/apt/sources.list.d/nginx.list
    if ! apt-get update -qq; then
        rm -f /etc/apt/sources.list.d/nginx.list
        apt-get update -qq || true
        return 1
    fi
    return 0
}

install_nginx() {
    step "Установка Nginx"
    rm -f /etc/apt/sources.list.d/nginx.list
    if add_nginx_repo; then
        ok "Подключён репозиторий nginx.org"
    else
        warn "Репозиторий nginx.org недоступен, используется Nginx из дистрибутива."
    fi

    if ! DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx; then
        warn "Не удалось установить Nginx из репозитория nginx.org, пробуем версию дистрибутива."
        rm -f /etc/apt/sources.list.d/nginx.list
        apt-get update -qq || true
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq nginx ||
            die "Не удалось установить Nginx."
    fi

    NGINX_VERSION="$(nginx -v 2>&1 | sed -n 's#.*nginx/\([0-9.]*\).*#\1#p')"
    [[ -n "$NGINX_VERSION" ]] || die "Не удалось определить версию Nginx."
    ok "Nginx ${NGINX_VERSION}"
}

fetch_templates() {
    step "Загрузка шаблонов с GitHub"
    rm -rf "$TMP_DIR"
    mkdir -p "$TMP_DIR"
    local url="https://codeload.github.com/${REPO_OWNER}/${REPO_NAME}/tar.gz/refs/heads/main"
    if ! curl -fsSL --retry 2 --max-time 120 "$url" |
        tar -xz -C "$TMP_DIR" --strip-components=1; then
        die "Не удалось скачать ${REPO_OWNER}/${REPO_NAME}."
    fi
    TEMPLATES_DIR="${TMP_DIR}/templates"
    [[ -d "$TEMPLATES_DIR" ]] || die "В репозитории нет каталога templates."
    ok "Репозиторий загружен"
}

list_templates() {
    local t
    echo
    printf '  %-16s %s\n' "ШАБЛОН" "ОПИСАНИЕ"
    while IFS= read -r t; do
        printf '  %-16s %s\n' "$(basename "$t")" "$(describe_template "$(basename "$t")")"
    done < <(find "$TEMPLATES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    echo
}

choose_template() {
    local t
    local -a templates
    TEMPLATE_DIR=""
    mapfile -t templates < <(find "$TEMPLATES_DIR" -mindepth 1 -maxdepth 1 -type d | sort)
    ((${#templates[@]} > 0)) || die "Шаблоны не найдены."

    if [[ -n "$TEMPLATE" ]]; then
        for t in "${templates[@]}"; do
            if [[ "$(basename "$t")" == "$TEMPLATE" ]]; then
                TEMPLATE_DIR="$t"
                break
            fi
        done
        [[ -n "$TEMPLATE_DIR" ]] || die "Шаблон «${TEMPLATE}» не найден. Список: --list"
    elif [[ $RANDOM_TEMPLATE -eq 1 || ! -t 0 ]]; then
        TEMPLATE_DIR="$(shuf -n 1 -e "${templates[@]}")"
    else
        local i n
        echo
        echo "Доступные шаблоны:"
        for i in "${!templates[@]}"; do
            printf '  %2d) %-16s %s\n' "$((i + 1))" \
                "$(basename "${templates[$i]}")" \
                "$(describe_template "$(basename "${templates[$i]}")")"
        done
        while true; do
            echo
            read -r -p "Номер шаблона [1]: " n || die "Ввод прерван."
            n="${n:-1}"
            if [[ "$n" =~ ^[0-9]+$ ]] && ((10#$n >= 1 && 10#$n <= ${#templates[@]})); then
                TEMPLATE_DIR="${templates[$((10#$n - 1))]}"
                break
            fi
            warn "Введите число от 1 до ${#templates[@]}."
        done
    fi

    TEMPLATE_NAME="$(basename "$TEMPLATE_DIR")"
    ok "Шаблон: ${TEMPLATE_NAME} — $(describe_template "$TEMPLATE_NAME")"
}

check_certificate() {
    CERT_DIR="${CERT_DIR:-/root/cert/${DOMAIN}}"
    local crt="${CERT_DIR}/fullchain.pem"
    local key="${CERT_DIR}/privkey.pem"
    local answer

    if [[ -s "$crt" && -s "$key" ]]; then
        ok "Сертификат найден: ${CERT_DIR}"
        return 0
    fi

    warn "Сертификат не найден: ${crt}"
    cat <<EOF

Выпустите сертификат для ${DOMAIN} в панели 3X-UI:
  Settings → Certificates → Get SSL → ${DOMAIN}

Файлы должны находиться здесь:
  ${crt}
  ${key}

Другой каталог можно указать параметром --cert-dir.

EOF

    if [[ $FORCE -eq 1 ]]; then
        warn "Продолжаем без сертификата (--force)."
        return 0
    fi
    if [[ -t 0 ]]; then
        read -r -p "Продолжить без сертификата? [y/N]: " answer || answer="n"
        case "${answer,,}" in
            y | yes) warn "Продолжаем без сертификата." ; return 0 ;;
        esac
    fi
    die "Установка прервана: нет сертификата."
}

deploy_site() {
    step "Копирование шаблона в ${SITE_DIR}"
    if [[ -d "$SITE_DIR" ]] && [[ -n "$(ls -A "$SITE_DIR" 2>/dev/null || true)" ]]; then
        if [[ -f "$STATE_FILE" ]]; then
            rm -rf "$SITE_DIR"
        else
            local backup="${SITE_DIR%/}.backup.$(date +%Y%m%d-%H%M%S)"
            mv "$SITE_DIR" "$backup"
            warn "Прежнее содержимое сохранено в ${backup}"
        fi
    fi
    mkdir -p "$SITE_DIR"
    cp -a "${TEMPLATE_DIR}/." "${SITE_DIR}/"
    find "$SITE_DIR" -type d -exec chmod 755 {} +
    find "$SITE_DIR" -type f -exec chmod 644 {} +
    ok "Файлы сайта развёрнуты"
}

disable_default_site() {
    local f
    for f in /etc/nginx/conf.d/default.conf /etc/nginx/sites-enabled/default; do
        if [[ -e "$f" || -L "$f" ]]; then
            rm -f "$f"
            ok "Отключён стандартный сайт: ${f}"
        fi
    done
    return 0
}

write_config() {
    step "Запись конфигурации ${NGINX_CONF}"
    local listen_extra="" http2_line=""
    if version_ge "$NGINX_VERSION" "1.25.1"; then
        http2_line="    http2 on;"
    else
        listen_extra=" http2"
    fi

    install -d -m 0755 "$(dirname "$NGINX_CONF")"
    cat >"$NGINX_CONF" <<EOF
server {
    listen 127.0.0.1:${PORT} ssl${listen_extra};
${http2_line}
    server_name ${DOMAIN};

    server_tokens off;

    ssl_certificate     ${CERT_DIR}/fullchain.pem;
    ssl_certificate_key ${CERT_DIR}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;

    root  ${SITE_DIR};
    index index.html;

    location / {
        try_files \$uri \$uri/ /index.html;
    }

    access_log /var/log/nginx/${DOMAIN}-access.log;
    error_log  /var/log/nginx/${DOMAIN}-error.log;
}
EOF
    ok "Конфигурация записана"
}

test_and_reload() {
    step "Проверка конфигурации Nginx"
    if ! nginx -t; then
        die "Ошибка в конфигурации Nginx (см. вывод выше)."
    fi
    ok "Синтаксис конфигурации корректен"

    local dump
    dump="$(nginx -T 2>/dev/null || true)"
    if ! grep -qF "server_name ${DOMAIN};" <<<"$dump"; then
        warn "Конфигурация ${NGINX_CONF} не попала в итоговый конфиг Nginx."
    fi

    systemctl enable nginx >/dev/null 2>&1 || true
    systemctl restart nginx || die "Не удалось запустить Nginx."
    ok "Nginx перезапущен"
}

verify_listen() {
    local i
    for i in {1..10}; do
        if port_busy "$PORT"; then
            ok "Nginx слушает 127.0.0.1:${PORT}"
            return 0
        fi
        sleep 0.5
    done
    warn "Порт 127.0.0.1:${PORT} не прослушивается: systemctl status nginx"
    return 0
}

save_state() {
    cat >"$STATE_FILE" <<EOF
DOMAIN=${DOMAIN}
PORT=${PORT}
TEMPLATE=${TEMPLATE_NAME}
CERT_DIR=${CERT_DIR}
EOF
    chmod 600 "$STATE_FILE"
}

print_summary() {
    echo
    printf '%sГотово%s\n' "$C_GREEN$C_BOLD" "$C_RESET"
    cat <<EOF

Домен:        ${DOMAIN}
Шаблон:       ${TEMPLATE_NAME} — $(describe_template "$TEMPLATE_NAME")
Каталог сайта: ${SITE_DIR}
Nginx:        127.0.0.1:${PORT} (TLS, HTTP/2)
Сертификат:   ${CERT_DIR}

Настройки Reality в 3X-UI:
  SNI:          ${DOMAIN}
  Dest/Target:  127.0.0.1
  Порт:         ${PORT}

Проверка на сервере:
  curl -sI --resolve ${DOMAIN}:${PORT}:127.0.0.1 https://${DOMAIN}:${PORT}/

Сменить шаблон:  bash install.sh --template <имя> --domain ${DOMAIN} --port ${PORT}
Удалить настройку: bash install.sh --uninstall
EOF
}

uninstall() {
    local domain="" port="" template=""
    if [[ -f "$STATE_FILE" ]]; then
        domain="$(sed -n 's/^DOMAIN=//p' "$STATE_FILE")"
        port="$(sed -n 's/^PORT=//p' "$STATE_FILE")"
        template="$(sed -n 's/^TEMPLATE=//p' "$STATE_FILE")"
    fi

    step "Удаление конфигурации"
    if [[ -f "$NGINX_CONF" ]]; then
        rm -f "$NGINX_CONF"
        ok "Удалён ${NGINX_CONF}"
    else
        warn "${NGINX_CONF} не найден"
    fi
    rm -f "$STATE_FILE"

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx 2>/dev/null || systemctl restart nginx || true
        ok "Nginx перезагружен"
    else
        warn "В конфигурации Nginx есть ошибки, проверьте вручную: nginx -t"
    fi

    if [[ -n "$domain" ]]; then
        printf 'Домен: %s, порт: %s, шаблон: %s\n' "$domain" "$port" "$template"
    fi
    printf 'Файлы сайта остались в %s — удалите вручную при необходимости.\n' "$SITE_DIR"
}

main() {
    parse_args "$@"
    require_root
    banner
    load_os_release

    trap cleanup EXIT

    if [[ $UNINSTALL -eq 1 ]]; then
        uninstall
        exit 0
    fi

    if [[ $LIST_ONLY -eq 1 ]]; then
        install_packages
        fetch_templates
        list_templates
        exit 0
    fi

    if [[ -f "$STATE_FILE" ]]; then
        info "Найдена предыдущая установка (${STATE_FILE}), она будет обновлена."
    fi

    choose_domain
    choose_port
    install_packages
    install_nginx
    fetch_templates
    choose_template
    check_certificate
    deploy_site
    disable_default_site
    write_config
    test_and_reload
    verify_listen
    save_state
    print_summary
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
