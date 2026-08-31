#!/bin/sh

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=12"
DEST_FILE="/usr/bin/sing-box"
DEST_DIR="/usr/bin"

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
B="\033[1m"
D="\033[2m"
N="\033[0m"

WORK_DIR=""
ARCHIVE_NAME=""
NEW_FILE=""
SERVICE_STOPPED="0"
SERVICE_WAS_RUNNING="0"
SYSTEM_MODIFIED="0"
PODKOP_PRESENT="0"
NEED_OPKG_FIX="0"
STOCK_IPK=""
GITHUB_TOKEN=""
BINARY_VARIANT=""
APK_COMPRESSED="0"
APK_COMPRESSED_APPLIED="0"
COMPRESSED_DOWNLOAD_URL=""
COMPRESSED_ARCHIVE_NAME=""
COMPRESSED_BINARY_MEMBER=""
INSECURE_TLS="0"
IS_PKG_INSTALL="0"
TTY_ECHO_DISABLED="0"

ui_line() {
    printf "${D}────────────────────────────────────────────────────────────${N}\n"
}

ui_banner() {
    printf "\n${C}${B}  Установщик sing-box-extended by NotDev${N}\n"
    ui_line
}

ui_section() {
    printf "\n${C}${B}▶ %s${N}\n" "$1"
}

ui_kv() {
    printf "  ${D}%s:${N} %s\n" "$1" "$2"
}

log_i()  { printf "  ${C}•${N} %s\n" "$1"; }
log_w()  { printf "  ${Y}!${N} ${Y}%s${N}\n" "$1"; }
log_ok() { printf "  ${G}✓${N} %s\n" "$1"; }
log_e()  { printf "\n  ${R}✗ Ошибка:${N} %s\n" "$1"; }

restore_tty() {
    if [ "$TTY_ECHO_DISABLED" = "1" ]; then
        stty echo 2>/dev/null || true
        TTY_ECHO_DISABLED="0"
    fi
}

cleanup_files() {
    restore_tty
    [ -n "$NEW_FILE" ] && rm -f "$NEW_FILE" 2>/dev/null || true
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR" 2>/dev/null || true
}

service_action() {
    _action="$1"
    if [ -n "${SERVICE_INIT:-}" ] && [ -x "$SERVICE_INIT" ]; then
        "$SERVICE_INIT" "$_action"
    elif command -v service >/dev/null 2>&1; then
        service "$SERVICE_NAME" "$_action"
    else
        return 1
    fi
}

service_is_running() {
    if [ "${PODKOP_PRESENT:-0}" = "1" ]; then
        pidof sing-box >/dev/null 2>&1 && return 0
        if command -v pgrep >/dev/null 2>&1; then
            pgrep -f '[s]ing-box' >/dev/null 2>&1 && return 0
        fi
        return 1
    fi
    if [ -n "${SERVICE_INIT:-}" ] && [ -x "$SERVICE_INIT" ]; then
        "$SERVICE_INIT" running >/dev/null 2>&1
        return $?
    fi
    pidof sing-box >/dev/null 2>&1
}

stop_managed_service() {
    if [ "$SERVICE_STOPPED" = "1" ]; then
        return 0
    fi
    service_action stop >/dev/null 2>&1 || true
    SERVICE_STOPPED="1"
}

start_managed_service_if_needed() {
    if [ "$SERVICE_WAS_RUNNING" != "1" ]; then
        SERVICE_STOPPED="0"
        return 0
    fi
    if service_action start >/dev/null 2>&1; then
        SERVICE_STOPPED="0"
        return 0
    fi
    return 1
}

fail() {
    _msg="$1"
    log_e "$_msg"

    if [ "$SYSTEM_MODIFIED" != "1" ] && [ "$SERVICE_STOPPED" = "1" ] && [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        service_action start >/dev/null 2>&1 || log_w "Не удалось снова запустить сервис '$SERVICE_NAME'."
        SERVICE_STOPPED="0"
    fi

    if [ "$SYSTEM_MODIFIED" = "1" ] && [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        log_i "Проверьте состояние сервиса: service $SERVICE_NAME status"
    fi

    cleanup_files
    exit 1
}
on_interrupt() {
    printf "\n"
    fail "Установка прервана."
}
trap 'on_interrupt' HUP INT TERM

get_mem_kb() {
    _key="$1"
    awk -v k="$_key" '$1 == k":" {print $2; exit}' /proc/meminfo 2>/dev/null
}

get_mem_available_kb() {
    _v=$(get_mem_kb MemAvailable)
    case "$_v" in
        ''|*[!0-9]*)
            _free=$(get_mem_kb MemFree)
            _buf=$(get_mem_kb Buffers)
            _cache=$(get_mem_kb Cached)
            _free=${_free:-0}
            _buf=${_buf:-0}
            _cache=${_cache:-0}
            echo $((_free + _buf + _cache))
            ;;
        *) echo "$_v" ;;
    esac
}

get_free_space_kb() {
    _path="$1"
    _space=$(df -Pk "$_path" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$_space" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$_space" ;;
    esac
}

get_total_space_kb() {
    _path="$1"
    _space=$(df -Pk "$_path" 2>/dev/null | awk 'NR==2 {print $2}')
    case "$_space" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$_space" ;;
    esac
}

ui_banner

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    log_e "Установщик необходимо запускать от имени root."
    exit 1
fi

if command -v curl >/dev/null 2>&1; then
    FETCH_TYPE="curl"
elif command -v wget >/dev/null 2>&1; then
    FETCH_TYPE="wget"
else
    log_e "Не найден curl или wget."
    exit 1
fi

api_get() {
    _url="$1"
    if [ "$FETCH_TYPE" = "curl" ]; then
        if [ "$INSECURE_TLS" = "1" ]; then
            if [ -n "$GITHUB_TOKEN" ]; then
                curl -sSL -k --connect-timeout 15 -H "Authorization: Bearer $GITHUB_TOKEN" "$_url" 2>/dev/null
            else
                curl -sSL -k --connect-timeout 15 "$_url" 2>/dev/null
            fi
        else
            if [ -n "$GITHUB_TOKEN" ]; then
                curl -sSL --connect-timeout 15 -H "Authorization: Bearer $GITHUB_TOKEN" "$_url" 2>/dev/null
            else
                curl -sSL --connect-timeout 15 "$_url" 2>/dev/null
            fi
        fi
    else
        if [ "$INSECURE_TLS" = "1" ]; then
            if [ -n "$GITHUB_TOKEN" ]; then
                wget -qO- --no-check-certificate --timeout=15 --header="Authorization: Bearer $GITHUB_TOKEN" "$_url" 2>/dev/null
            else
                wget -qO- --no-check-certificate --timeout=15 "$_url" 2>/dev/null
            fi
        else
            if [ -n "$GITHUB_TOKEN" ]; then
                wget -qO- --timeout=15 --header="Authorization: Bearer $GITHUB_TOKEN" "$_url" 2>/dev/null
            else
                wget -qO- --timeout=15 "$_url" 2>/dev/null
            fi
        fi
    fi
}

download_file() {
    _url="$1"
    _out="$2"
    if [ "$FETCH_TYPE" = "curl" ]; then
        if [ "$INSECURE_TLS" = "1" ]; then
            curl -fsSL -k --connect-timeout 15 -o "$_out" "$_url"
        else
            curl -fsSL --connect-timeout 15 -o "$_out" "$_url"
        fi
    else
        if [ "$INSECURE_TLS" = "1" ]; then
            wget -q --no-check-certificate --timeout=15 -O "$_out" "$_url"
        else
            wget -q --timeout=15 -O "$_out" "$_url"
        fi
    fi
}

read_token() {
    if stty -echo 2>/dev/null; then
        TTY_ECHO_DISABLED="1"
        printf "  ${C}${B}›${N} %s ${D}(ввод скрыт)${N}: " "$1"
        read -r -t 30 GITHUB_TOKEN
        restore_tty
        printf "\n"
    else
        printf "  ${C}${B}›${N} %s: " "$1"
        read -r -t 30 GITHUB_TOKEN
    fi
    GITHUB_TOKEN=$(printf '%s' "$GITHUB_TOKEN" | tr -d ' \t\n\r')
}

prompt_yes_no() {
    _question="$1"
    _default="${2:-no}"

    if [ "$_default" = "yes" ]; then
        _hint="Д/н"
    else
        _hint="д/Н"
    fi

    while :; do
        printf "  ${C}${B}›${N} %s ${D}[%s]${N}: " "$_question" "$_hint"
        if ! read -r -t 60 _answer; then
            printf "\n"
            return 1
        fi
        case "$_answer" in
            y|Y|yes|YES|Yes|д|Д|да|ДА|Да) return 0 ;;
            n|N|no|NO|No|н|Н|нет|НЕТ|Нет) return 1 ;;
            '') [ "$_default" = "yes" ] && return 0 || return 1 ;;
            *) log_w "Пожалуйста, ответьте «да» или «нет»." ;;
        esac
    done
}

choose_binary_variant() {
    ui_section "Выбор сборки"
    printf "  ${G}${B}1) Normal${N}\n"
    printf "     Рекомендуемый вариант. Без UPX, предсказуемее по памяти.\n\n"
    printf "  ${Y}${B}2) Compressed (UPX)${N}\n"
    printf "     Экономит место во flash-памяти, но создаёт дополнительную нагрузку на RAM\n"
    printf "     при запуске и на слабых роутерах может привести к OOM.\n"
    printf "\n  ${C}${B}›${N} Выберите вариант ${D}[1]${N}: "
    read -r -t 60 _variant_choice || _variant_choice=""

    case "$_variant_choice" in
        ''|1) BINARY_VARIANT="normal" ;;
        2) BINARY_VARIANT="compressed" ;;
        *) fail "Неверный выбор типа сборки." ;;
    esac
}

choose_apk_mode() {
    ui_section "Выбор способа установки"
    printf "  ${G}${B}1) APK-пакет${N}\n"
    printf "     Рекомендуемый вариант. Полная интеграция с пакетным менеджером APK.\n\n"
    printf "  ${Y}${B}2) APK + Compressed (UPX)${N}\n"
    printf "     Сначала устанавливается APK-пакет, затем /usr/bin/sing-box заменяется\n"
    printf "     на compressed-версию. Экономит flash, но повышает нагрузку на RAM.\n"
    printf "     После apk upgrade/fix обычный бинарник может быть восстановлен пакетом.\n"
    printf "\n  ${C}${B}›${N} Выберите вариант ${D}[1]${N}: "
    read -r -t 60 _apk_choice || _apk_choice=""

    case "$_apk_choice" in
        ''|1)
            APK_COMPRESSED="0"
            BINARY_VARIANT="normal"
            ;;
        2)
            APK_COMPRESSED="1"
            BINARY_VARIANT="compressed"
            ;;
        *) fail "Неверный выбор способа установки." ;;
    esac
}

ui_section "Проверка окружения"
if [ -x "/etc/init.d/podkop" ]; then
    PODKOP_PRESENT="1"
    SERVICE_NAME="podkop"
    SERVICE_INIT="/etc/init.d/podkop"
elif [ -x "/opt/etc/init.d/podkop" ]; then
    PODKOP_PRESENT="1"
    SERVICE_NAME="podkop"
    SERVICE_INIT="/opt/etc/init.d/podkop"
elif [ -x "/etc/init.d/sing-box" ]; then
    SERVICE_NAME="sing-box"
    SERVICE_INIT="/etc/init.d/sing-box"
else
    SERVICE_NAME="sing-box"
    SERVICE_INIT=""
fi

if service_is_running; then
    SERVICE_WAS_RUNNING="1"
fi

IS_OPENWRT="0"
USE_PKG="0"
PKG_MANAGER=""
PKG_EXT=""
DISTRIB_ARCH=""
OPENWRT_VERSION=""

if [ -f "/etc/openwrt_release" ]; then
    IS_OPENWRT="1"
    OPENWRT_VERSION=$(. /etc/openwrt_release 2>/dev/null; printf '%s' "${DISTRIB_RELEASE:-}")
    if [ -z "$OPENWRT_VERSION" ] && [ -f "/etc/os-release" ]; then
        OPENWRT_VERSION=$(. /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}")
    fi
    if command -v apk >/dev/null 2>&1 && [ "$(command -v apk)" != "/opt/bin/apk" ]; then
        USE_PKG="1"
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1 && [ "$(command -v opkg)" != "/opt/bin/opkg" ]; then
        USE_PKG="1"
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    fi
fi

if [ "$IS_OPENWRT" = "1" ]; then
    if [ -n "$OPENWRT_VERSION" ]; then
        ui_kv "Система" "OpenWrt $OPENWRT_VERSION"
    else
        ui_kv "Система" "OpenWrt · версия не определена"
    fi
else
    ui_kv "Система" "Linux / неизвестная"
fi
if [ "$PODKOP_PRESENT" = "1" ]; then
    ui_kv "Podkop" "обнаружен"
else
    ui_kv "Podkop" "не обнаружен"
fi
ui_kv "Пакетный менеджер" "${PKG_MANAGER:-не обнаружен}"
if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
    ui_kv "Сервис" "$SERVICE_NAME · запущен"
else
    ui_kv "Сервис" "$SERVICE_NAME · остановлен"
fi

opkg_pkg_installed() {
    _pkg="$1"
    opkg list-installed 2>/dev/null | awk -v p="$_pkg" '$1 == p {found=1} END {exit(found ? 0 : 1)}'
}

if [ "$PODKOP_PRESENT" = "1" ] && [ "$PKG_MANAGER" = "opkg" ]; then
    USE_PKG="0"
    if ! opkg_pkg_installed sing-box; then
        NEED_OPKG_FIX="1"
    fi
    log_i "Podkop + opkg обнаружены. Будет использоваться штатный пакет sing-box; заменится только /usr/bin/sing-box."
    if [ "$NEED_OPKG_FIX" = "1" ]; then
        if opkg_pkg_installed sing-box-extended; then
            log_w "В opkg найден sing-box-extended, но отсутствует штатный sing-box. Сначала исправлю состояние пакетов."
        else
            log_w "Штатный пакет sing-box не зарегистрирован в opkg. Перед заменой установлю его автоматически."
        fi
    fi
fi

if [ "$PODKOP_PRESENT" = "1" ] && [ "$PKG_MANAGER" = "opkg" ]; then
    ui_kv "Режим установки" "Замена бинарного файла"
    choose_binary_variant
elif [ "$USE_PKG" = "1" ] && [ "$PKG_MANAGER" = "apk" ]; then
    ui_kv "Режим установки" "APK-пакет"
    choose_apk_mode
elif [ "$USE_PKG" = "1" ] && [ "$PKG_MANAGER" = "opkg" ]; then
    ui_kv "Режим установки" "Установка IPK-пакета"
    BINARY_VARIANT="normal"
else
    ui_kv "Режим установки" "Замена бинарного файла"
    choose_binary_variant
fi

HOST_ARCH=$(uname -m)
if [ "$IS_OPENWRT" = "1" ]; then
    DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
    case "$DISTRIB_ARCH" in
        *mipsel*|*mipsle*) HOST_ARCH="mipsel" ;;
        *mips64el*|*mips64le*) HOST_ARCH="mips64el" ;;
    esac
fi

case "$HOST_ARCH" in
    aarch64)             ARCH_SUFFIX="arm64" ;;
    armv7*)              ARCH_SUFFIX="armv7" ;;
    armv6*)              ARCH_SUFFIX="armv6" ;;
    x86_64)              ARCH_SUFFIX="amd64" ;;
    i386|i686)           ARCH_SUFFIX="386" ;;
    mips)                ARCH_SUFFIX="mips-softfloat" ;;
    mipsel|mipsle)       ARCH_SUFFIX="mipsle-softfloat" ;;
    mips64)              ARCH_SUFFIX="mips64" ;;
    mips64el|mips64le)   ARCH_SUFFIX="mips64le" ;;
    riscv64)             ARCH_SUFFIX="riscv64" ;;
    s390x)               ARCH_SUFFIX="s390x" ;;
    *) fail "Архитектура $HOST_ARCH не поддерживается." ;;
esac

if [ "$BINARY_VARIANT" = "compressed" ]; then
    case "$ARCH_SUFFIX" in
        mips-softfloat|mipsle-softfloat|mips64|mips64le)
            log_w "Compressed (UPX) для этой MIPS-архитектуры не используется. Переключаю на Normal."
            BINARY_VARIANT="normal"
            APK_COMPRESSED="0"
            ;;
    esac
fi

case "$BINARY_VARIANT" in
    normal) ;;
    compressed)
        log_w "Выбран Compressed (UPX): меньше расход flash-памяти, но выше пиковое потребление RAM при запуске."
        ;;
    *)
        fail "Неизвестный тип сборки. Выберите Normal или Compressed."
        ;;
esac

MEM_TOTAL_KB=$(get_mem_kb MemTotal)
MEM_AVAILABLE_KB=$(get_mem_available_kb)
MEM_TOTAL_KB=${MEM_TOTAL_KB:-0}
MEM_AVAILABLE_KB=${MEM_AVAILABLE_KB:-0}

ui_kv "Оперативная память" "$((MEM_TOTAL_KB / 1024)) МБ всего · ~$((MEM_AVAILABLE_KB / 1024)) МБ доступно"

FLASH_TOTAL_KB=$(get_total_space_kb "$DEST_DIR")
FLASH_FREE_KB=$(get_free_space_kb "$DEST_DIR")
if [ "$FLASH_TOTAL_KB" -gt 0 ]; then
    ui_kv "Flash-память" "$((FLASH_TOTAL_KB / 1024)) МБ всего · ~$((FLASH_FREE_KB / 1024)) МБ свободно"
else
    ui_kv "Flash-память" "н/д"
fi

if [ "$BINARY_VARIANT" = "compressed" ]; then
    if [ "$MEM_TOTAL_KB" -lt 262144 ] || [ "$MEM_AVAILABLE_KB" -lt 98304 ]; then
        log_w "Для Compressed (UPX) памяти мало: $((MEM_TOTAL_KB / 1024)) МБ всего, ~$((MEM_AVAILABLE_KB / 1024)) МБ доступно."
        log_w "На таком устройстве ядро может завершить sing-box из-за OOM."
        if prompt_yes_no "Продолжить с Compressed, несмотря на риск OOM?" no; then
            log_w "Риск принят: продолжаю с Compressed (UPX)."
        else
            log_i "Выбран безопасный вариант: Normal."
            BINARY_VARIANT="normal"
            APK_COMPRESSED="0"
        fi
    fi
fi


ui_kv "Архитектура" "$HOST_ARCH → $ARCH_SUFFIX"
if [ "$USE_PKG" = "1" ]; then
    case "$PKG_MANAGER" in
        apk)
            if [ "$APK_COMPRESSED" = "1" ]; then
                ui_kv "Пакет" "APK + Compressed (UPX)"
            else
                ui_kv "Пакет" "APK"
            fi
            ;;
        opkg) ui_kv "Пакет" "IPK" ;;
    esac
else
    ui_kv "Сборка" "$BINARY_VARIANT"
fi

CURRENT_VER=""
DEFER_CURRENT_VER="0"
if [ -x "$DEST_FILE" ]; then
    if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        DEFER_CURRENT_VER="1"
    else
        CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
    fi
fi

ui_section "Выбор версии"
log_i "Получаю список стабильных релизов с GitHub…"
API_RESPONSE=$(api_get "$API_URL") || true

if [ -z "$API_RESPONSE" ] && [ "$INSECURE_TLS" != "1" ]; then
    log_w "Не удалось получить ответ GitHub по HTTPS. Причиной могут быть сеть, DNS, неверное системное время или TLS-сертификаты."
    log_w "Повтор без проверки сертификата стоит использовать только если сеть работает, а проблема именно в TLS."
    if prompt_yes_no "Повторить соединение без проверки TLS-сертификата?" no; then
        INSECURE_TLS="1"
        API_RESPONSE=$(api_get "$API_URL") || true
    fi
fi

[ -z "$API_RESPONSE" ] && fail "Не удалось подключиться к GitHub API. Проверьте сеть, DNS и системное время."

if ! printf '%s' "$API_RESPONSE" | grep -q '"tag_name"'; then
    if printf '%s' "$API_RESPONSE" | grep -qi 'bad credentials\|401\|rate limit\|API rate limit'; then
        log_w "GitHub API отклонил запрос или исчерпан анонимный лимит запросов."
        if [ "$INSECURE_TLS" = "1" ]; then
            fail "Не отправляю GitHub-токен через соединение без проверки TLS. Исправьте системное время или сертификаты и повторите установку."
        fi
        read_token "Введите личный GitHub-токен для повторного запроса"
        [ -z "$GITHUB_TOKEN" ] && fail "GitHub-токен не введён. Продолжение невозможно."

        API_RESPONSE=$(api_get "$API_URL") || true
        if [ -z "$API_RESPONSE" ] || ! printf '%s' "$API_RESPONSE" | grep -q '"tag_name"'; then
            fail "Не удалось получить список релизов GitHub с указанным токеном."
        fi
    else
        fail "GitHub API вернул неожиданный ответ."
    fi
fi

RELEASES=$(printf '%s' "$API_RESPONSE" \
    | tr ',' '\n' \
    | grep '"tag_name"' \
    | awk -F '"' '{print $4}' \
    | grep -v -i 'rc' \
    | grep -v -i 'beta' \
    | grep -v -i 'alpha' \
    | head -n 3)

ALL_RELEASES=$(printf '%s' "$API_RESPONSE" \
    | tr ',' '\n' \
    | grep '"tag_name"' \
    | awk -F '"' '{print $4}' \
    | grep -v -i 'rc' \
    | grep -v -i 'beta' \
    | grep -v -i 'alpha')

[ -z "$RELEASES" ] && fail "Не удалось получить стабильные релизы."

printf "\n  ${C}${B}Доступные стабильные версии:${N}\n"
i=1
for tag in $RELEASES; do
    printf "  ${Y}%d)${N} %s\n" "$i" "$tag"
    i=$((i + 1))
done
printf "  ${D}0) Отмена${N}\n"

printf "\n  ${C}${B}›${N} Выберите версию ${D}[0-$((i - 1))]${N}: "
read -r -t 60 choice

[ "$choice" = "0" ] && { printf "\n"; log_i "Установка отменена пользователем."; exit 0; }

SELECTED_TAG=""
i=1
for tag in $RELEASES; do
    if [ "$choice" = "$i" ]; then
        SELECTED_TAG="$tag"
        break
    fi
    i=$((i + 1))
done
[ -z "$SELECTED_TAG" ] && fail "Неверный номер версии."

SELECTED_VER=$(printf '%s' "$SELECTED_TAG" | sed 's/^v//')
if [ "$DEFER_CURRENT_VER" = "1" ]; then
    _current_display="работает; версия будет проверена после остановки"
else
    _current_display="${CURRENT_VER:-не определена}"
fi
printf "\n"
ui_kv "Текущая версия" "$_current_display"
ui_kv "Будет установлена" "$SELECTED_VER"

get_url_from_assets() {
    _al="$1"
    _url=""

    if [ "$USE_PKG" = "1" ]; then
        _url=$(printf '%s' "$_al" | grep 'browser_download_url' \
            | grep "sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.${PKG_EXT}" \
            | head -n 1 | awk -F '"' '{print $4}')
        echo "1:$_url"
        [ -n "$_url" ]
        return
    fi

    if [ "$BINARY_VARIANT" = "compressed" ]; then
        _url=$(printf '%s' "$_al" | grep 'browser_download_url' \
            | grep "linux-${ARCH_SUFFIX}-compressed\.tar\.gz" \
            | head -n 1 | awk -F '"' '{print $4}')
    else
        _url=$(printf '%s' "$_al" | grep 'browser_download_url' \
            | grep "linux-${ARCH_SUFFIX}\.tar\.gz" \
            | grep -v 'compressed' \
            | head -n 1 | awk -F '"' '{print $4}')
    fi

    echo "0:$_url"
    [ -n "$_url" ]
}

get_url_for_tag() {
    _tag="$1"
    _lines=$(printf '%s' "$API_RESPONSE" | tr ',' '\n' | awk -v tag="\"$_tag\"" '
        /"tag_name":/ { in_rel = (index($0, tag) > 0) }
        in_rel && /browser_download_url/ { print }
    ')

    if [ -z "$_lines" ]; then
        _resp=$(api_get "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$_tag") || true
        [ -z "$_resp" ] && { echo "0:"; return 1; }
        _lines=$(printf '%s' "$_resp" | tr ',' '\n')
    fi

    get_url_from_assets "$_lines"
}

get_binary_url_from_assets() {
    _al="$1"
    _variant="$2"
    _url=""

    if [ "$_variant" = "compressed" ]; then
        _url=$(printf '%s' "$_al" | grep 'browser_download_url' \
            | grep "linux-${ARCH_SUFFIX}-compressed\.tar\.gz" \
            | head -n 1 | awk -F '"' '{print $4}')
    else
        _url=$(printf '%s' "$_al" | grep 'browser_download_url' \
            | grep "linux-${ARCH_SUFFIX}\.tar\.gz" \
            | grep -v 'compressed' \
            | head -n 1 | awk -F '"' '{print $4}')
    fi

    printf '%s\n' "$_url"
    [ -n "$_url" ]
}

get_binary_url_for_tag() {
    _tag="$1"
    _variant="$2"
    _lines=$(printf '%s' "$API_RESPONSE" | tr ',' '\n' | awk -v tag="\"$_tag\"" '
        /"tag_name":/ { in_rel = (index($0, tag) > 0) }
        in_rel && /browser_download_url/ { print }
    ')

    if [ -z "$_lines" ]; then
        _resp=$(api_get "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$_tag") || true
        [ -z "$_resp" ] && return 1
        _lines=$(printf '%s' "$_resp" | tr ',' '\n')
    fi

    get_binary_url_from_assets "$_lines" "$_variant"
}

parse_url_result() {
    IS_PKG_INSTALL="${1%%:*}"
    DOWNLOAD_URL="${1#*:}"
}

if [ "$USE_PKG" = "1" ]; then
    if [ "$PKG_MANAGER" = "apk" ]; then
        log_i "Ищу APK-пакет релиза: $SELECTED_TAG · $DISTRIB_ARCH…"
    else
        log_i "Ищу IPK-пакет релиза: $SELECTED_TAG · $DISTRIB_ARCH…"
    fi
else
    log_i "Ищу подходящий файл релиза: $SELECTED_TAG · $ARCH_SUFFIX · $BINARY_VARIANT…"
fi
IS_PKG_INSTALL="0"
DOWNLOAD_URL=""
parse_url_result "$(get_url_for_tag "$SELECTED_TAG")"

if [ -z "$DOWNLOAD_URL" ]; then
    log_w "В выбранном релизе нет нужной сборки. Ищу ближайшую совместимую стабильную версию…"
    for _fb_tag in $ALL_RELEASES; do
        [ "$_fb_tag" = "$SELECTED_TAG" ] && continue
        _fb_result=$(get_url_for_tag "$_fb_tag")
        _fb_url="${_fb_result#*:}"
        if [ -n "$_fb_url" ]; then
            parse_url_result "$_fb_result"
            SELECTED_TAG="$_fb_tag"
            SELECTED_VER=$(printf '%s' "$SELECTED_TAG" | sed 's/^v//')
            log_i "Найдена совместимая версия: $SELECTED_VER"
            break
        fi
    done
fi

if [ -z "$DOWNLOAD_URL" ]; then
    if [ "$USE_PKG" = "1" ]; then
        fail "Подходящий пакет .$PKG_EXT для OpenWrt-архитектуры ${DISTRIB_ARCH:-н/д} не найден."
    else
        fail "Бинарная сборка $BINARY_VARIANT для $HOST_ARCH ($ARCH_SUFFIX) не найдена."
    fi
fi

if [ "$PKG_MANAGER" = "apk" ] && [ "$APK_COMPRESSED" = "1" ]; then
    log_i "Ищу Compressed (UPX) того же релиза: $SELECTED_TAG · $ARCH_SUFFIX…"
    COMPRESSED_DOWNLOAD_URL=$(get_binary_url_for_tag "$SELECTED_TAG" compressed) || true
    if [ -z "$COMPRESSED_DOWNLOAD_URL" ]; then
        fail "APK найден, но Compressed (UPX) для $ARCH_SUFFIX в том же релизе $SELECTED_TAG отсутствует. Выберите обычный APK-пакет."
    fi
fi

unset API_RESPONSE RELEASES ALL_RELEASES _resp _lines _fb_result _fb_url

if [ "$IS_PKG_INSTALL" = "1" ]; then
    ARCHIVE_NAME="sing-box-latest.${PKG_EXT}"
else
    ARCHIVE_NAME="sing-box-latest.tar.gz"
fi
if [ "$PKG_MANAGER" = "apk" ] && [ "$APK_COMPRESSED" = "1" ]; then
    COMPRESSED_ARCHIVE_NAME="sing-box-compressed.tar.gz"
fi

if [ "$IS_PKG_INSTALL" = "0" ] && [ "$MEM_AVAILABLE_KB" -lt 32768 ]; then
    log_w "Доступно менее 32 МБ RAM. Перед проверкой нового бинарника сервис будет остановлен, чтобы освободить память."
fi

ui_section "Подготовка"
HOME_DIR="${HOME:-/root}"
DIR_RAM="/tmp/sing-box-install"
DIR_DISK="$HOME_DIR/sing-box-install_tmp"
REQ_TEMP_KB=49152
[ "$NEED_OPKG_FIX" = "1" ] && REQ_TEMP_KB=65536
if [ "$PKG_MANAGER" = "apk" ]; then
    REQ_TEMP_KB=24576
fi

RAM_FS_FREE_KB=$(get_free_space_kb /tmp)
DISK_FREE_KB=$(get_free_space_kb "$HOME_DIR")
RAM_SAFE_TEMP_KB=$((MEM_AVAILABLE_KB - 32768))
[ "$RAM_SAFE_TEMP_KB" -lt 0 ] && RAM_SAFE_TEMP_KB=0
[ "$RAM_SAFE_TEMP_KB" -gt "$RAM_FS_FREE_KB" ] && RAM_SAFE_TEMP_KB="$RAM_FS_FREE_KB"
DISK_SAFE_TEMP_KB=$((DISK_FREE_KB - 8192))
[ "$DISK_SAFE_TEMP_KB" -lt 0 ] && DISK_SAFE_TEMP_KB=0

if [ "$RAM_SAFE_TEMP_KB" -ge "$REQ_TEMP_KB" ]; then
    WORK_DIR="$DIR_RAM"
    ui_kv "Временное хранилище" "/tmp · безопасно доступно ~$((RAM_SAFE_TEMP_KB / 1024)) МБ"
elif [ "$DISK_SAFE_TEMP_KB" -ge "$REQ_TEMP_KB" ]; then
    WORK_DIR="$DIR_DISK"
    ui_kv "Временное хранилище" "$HOME_DIR · доступно ~$((DISK_SAFE_TEMP_KB / 1024)) МБ без резервных 8 МБ"
else
    fail "Недостаточно безопасного временного места: /tmp можно использовать ~$((RAM_SAFE_TEMP_KB / 1024)) МБ с учётом RAM, $HOME_DIR ~$((DISK_SAFE_TEMP_KB / 1024)) МБ с резервом для системы."
fi

rm -rf "$WORK_DIR"
mkdir -p "$WORK_DIR" || fail "Не удалось создать $WORK_DIR."
cd "$WORK_DIR" || fail "Не удалось перейти в $WORK_DIR."

if [ "$IS_PKG_INSTALL" = "1" ]; then
    log_i "Скачиваю пакет $SELECTED_TAG…"
else
    log_i "Скачиваю $SELECTED_TAG · $BINARY_VARIANT…"
fi
download_file "$DOWNLOAD_URL" "$ARCHIVE_NAME" || fail "Не удалось скачать файл выбранного релиза."
[ ! -s "$ARCHIVE_NAME" ] && fail "Скачанный файл пустой."

if [ "$PKG_MANAGER" = "apk" ] && [ "$APK_COMPRESSED" = "1" ]; then
    log_i "Compressed (UPX) будет скачан после установки APK, чтобы не держать оба файла во временном хранилище одновременно."
fi

if [ "$NEED_OPKG_FIX" = "1" ]; then
    log_i "Заранее скачиваю штатный sing-box.ipk для исправления opkg…"
    opkg update >/dev/null 2>&1 || fail "Команда opkg update завершилась ошибкой; состояние пакетов не изменено."
    rm -f "$WORK_DIR"/sing-box_*.ipk 2>/dev/null || true
    (
        cd "$WORK_DIR" || exit 1
        opkg download sing-box >/dev/null 2>&1
    ) || fail "Не удалось заранее скачать штатный пакет sing-box. Ничего не удалено."

    STOCK_IPK=$(find "$WORK_DIR" -type f -name 'sing-box_*.ipk' | head -n 1)
    [ -z "$STOCK_IPK" ] && fail "opkg download sing-box не создал IPK. Ничего не удалено."
    [ ! -s "$STOCK_IPK" ] && fail "Штатный sing-box.ipk пустой. Ничего не удалено."
fi

if [ "$IS_PKG_INSTALL" = "0" ]; then
    BINARY_MEMBER=$(tar -tzf "$ARCHIVE_NAME" 2>/dev/null | awk '/(^|\/)sing-box$/ {print; exit}')
    [ -z "$BINARY_MEMBER" ] && fail "В tar.gz не найден файл sing-box."

    NEW_FILE="$DEST_DIR/.sing-box.new.$$"
    rm -f "$NEW_FILE"

    log_i "Извлекаю новый бинарник рядом с /usr/bin/sing-box…"
    if ! tar -xOzf "$ARCHIVE_NAME" "$BINARY_MEMBER" > "$NEW_FILE" 2>/dev/null; then
        rm -f "$NEW_FILE"
        fail "Не удалось извлечь новый бинарник в $DEST_DIR. Проверьте свободное место во flash-памяти."
    fi
    [ ! -s "$NEW_FILE" ] && fail "Извлечённый бинарник пустой."
    chmod 755 "$NEW_FILE" || fail "Не удалось сделать новый бинарник исполняемым."
    rm -f "$ARCHIVE_NAME"
    ARCHIVE_NAME=""
fi

if [ "$IS_PKG_INSTALL" = "0" ]; then
    if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        ui_section "Проверка перед заменой"
        log_i "Останавливаю $SERVICE_NAME, чтобы освободить RAM и проверить новый бинарник…"
        stop_managed_service
    fi

    if [ "$PODKOP_PRESENT" = "1" ] && [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    fi

    if [ "$SERVICE_WAS_RUNNING" = "1" ] || pidof sing-box >/dev/null 2>&1; then
        _stop_n=0
        while pidof sing-box >/dev/null 2>&1 && [ "$_stop_n" -lt 8 ]; do
            sleep 1
            _stop_n=$((_stop_n + 1))
        done
        if pidof sing-box >/dev/null 2>&1; then
            fail "Старый процесс sing-box не остановился. Не запускаю второй Go-бинарник и не продолжаю замену."
        fi
    fi

    if [ "$DEFER_CURRENT_VER" = "1" ] && [ -x "$DEST_FILE" ]; then
        CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
        ui_kv "Текущая версия" "${CURRENT_VER:-не определена}"
    fi

    NEW_VERSION=$("$NEW_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
    [ -z "$NEW_VERSION" ] && fail "Новый бинарник не запускается или не сообщает версию."
    log_ok "Новый бинарник запускается корректно · версия $NEW_VERSION"

    CONFIG_PATH="/etc/sing-box/config.json"
    if [ "$PODKOP_PRESENT" = "1" ] && command -v uci >/dev/null 2>&1; then
        _uci_config=$(uci -q get podkop.settings.config_path 2>/dev/null || true)
        [ -n "$_uci_config" ] && CONFIG_PATH="$_uci_config"
    fi

    if [ "$SERVICE_WAS_RUNNING" = "1" ] && [ -s "$CONFIG_PATH" ]; then
        if [ "$PODKOP_PRESENT" = "1" ]; then
            log_i "Проверку конфигурации выполнит Podkop при запуске после создания временных ruleset-файлов."
        else
            log_i "Проверяю текущую конфигурацию новым бинарником…"
            if ! "$NEW_FILE" check -c "$CONFIG_PATH" >"$WORK_DIR/sing-box-check.log" 2>&1; then
                tail -n 20 "$WORK_DIR/sing-box-check.log" 2>/dev/null || true
                fail "Новый sing-box не принимает текущую конфигурацию: $CONFIG_PATH. Рабочий бинарник не заменён."
            fi
            log_ok "Конфигурация совместима с новой версией."
        fi
    fi

    if [ "$NEED_OPKG_FIX" = "1" ]; then
        log_i "Исправляю состояние пакетов opkg…"
        SYSTEM_MODIFIED="1"

        if opkg_pkg_installed sing-box-extended; then
            if ! opkg remove --force-depends sing-box-extended >/dev/null 2>&1; then
                fail "Не удалось удалить конфликтующий sing-box-extended."
            fi
        fi

        if ! opkg install "$STOCK_IPK" >/dev/null 2>&1; then
            if ! opkg install --force-reinstall --force-overwrite "$STOCK_IPK" >/dev/null 2>&1; then
                fail "Не удалось установить штатный sing-box."
            fi
        fi

        if ! opkg_pkg_installed sing-box; then
            fail "opkg не показывает пакет sing-box как установленный после исправления."
        fi
        rm -f "$STOCK_IPK"
        STOCK_IPK=""
        log_ok "Состояние opkg исправлено: штатный пакет sing-box зарегистрирован."
    fi

    if [ "$PODKOP_PRESENT" = "1" ] && [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box stop >/dev/null 2>&1 || true
        /etc/init.d/sing-box disable >/dev/null 2>&1 || true
    fi

    ui_section "Установка"
    if ! mv -f "$NEW_FILE" "$DEST_FILE"; then
        fail "Не удалось атомарно установить новый бинарник."
    fi
    SYSTEM_MODIFIED="1"
    NEW_FILE=""
    chmod 755 "$DEST_FILE" || true
    log_ok "Новый бинарник установлен в $DEST_FILE."
else
    ui_section "Установка"

    if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
        log_i "Останавливаю $SERVICE_NAME перед установкой пакета…"
        stop_managed_service
    fi

    if [ "$PODKOP_PRESENT" = "1" ] && [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box stop >/dev/null 2>&1 || true
    fi

    if [ "$SERVICE_WAS_RUNNING" = "1" ] || pidof sing-box >/dev/null 2>&1; then
        _stop_n=0
        while pidof sing-box >/dev/null 2>&1 && [ "$_stop_n" -lt 8 ]; do
            sleep 1
            _stop_n=$((_stop_n + 1))
        done
        if pidof sing-box >/dev/null 2>&1; then
            fail "Старый процесс sing-box не остановился. Установка пакета не начата."
        fi
    fi

    if [ "$DEFER_CURRENT_VER" = "1" ] && [ -x "$DEST_FILE" ]; then
        CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
        ui_kv "Текущая версия" "${CURRENT_VER:-не определена}"
    fi

    log_i "Устанавливаю пакет $ARCHIVE_NAME…"
    if [ "$PKG_MANAGER" = "apk" ]; then
        _package_path="$WORK_DIR/$ARCHIVE_NAME"
        SYSTEM_MODIFIED="1"
        apk del sing-box >/dev/null 2>&1 || true
        apk del sing-box-extended >/dev/null 2>&1 || true
        apk add --allow-untrusted "$_package_path" || fail "Не удалось установить APK-пакет."
    else
        SYSTEM_MODIFIED="1"
        opkg remove sing-box >/dev/null 2>&1 || true
        opkg install --force-reinstall --force-overwrite "$WORK_DIR/$ARCHIVE_NAME" || fail "Не удалось установить IPK-пакет."
    fi

    rm -f "$WORK_DIR/$ARCHIVE_NAME"
    ARCHIVE_NAME=""

    APK_NORMAL_VERSION=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
    [ -z "$APK_NORMAL_VERSION" ] && fail "После установки пакета /usr/bin/sing-box не запускается или не сообщает версию."
    NEW_VERSION="$APK_NORMAL_VERSION"
    log_ok "Пакет установлен · версия $APK_NORMAL_VERSION"

    if [ "$PKG_MANAGER" = "apk" ] && [ "$APK_COMPRESSED" = "1" ]; then
        ui_section "Установка Compressed (UPX)"
        NEW_FILE="$DEST_DIR/.sing-box.new.$$"
        rm -f "$NEW_FILE"
        _compressed_ok="1"

        MEM_AVAILABLE_KB=$(get_mem_available_kb)
        MEM_AVAILABLE_KB=${MEM_AVAILABLE_KB:-0}
        _work_parent=$(dirname "$WORK_DIR")
        _work_free_kb=$(get_free_space_kb "$_work_parent")
        if [ "$_work_parent" = "/tmp" ]; then
            _safe_now_kb=$((MEM_AVAILABLE_KB - 32768))
            [ "$_safe_now_kb" -lt 0 ] && _safe_now_kb=0
            [ "$_safe_now_kb" -gt "$_work_free_kb" ] && _safe_now_kb="$_work_free_kb"
        else
            _safe_now_kb=$((_work_free_kb - 8192))
            [ "$_safe_now_kb" -lt 0 ] && _safe_now_kb=0
        fi

        if [ "$_safe_now_kb" -lt 16384 ]; then
            _compressed_ok="0"
            log_w "После установки APK осталось слишком мало безопасного временного места для Compressed. Оставляю обычный бинарник из APK."
        fi

        if [ "$_compressed_ok" = "1" ]; then
            log_i "Скачиваю Compressed (UPX) $SELECTED_TAG…"
            if ! download_file "$COMPRESSED_DOWNLOAD_URL" "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME"; then
                _compressed_ok="0"
                rm -f "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" 2>/dev/null || true
                log_w "Не удалось скачать Compressed (UPX). Оставляю обычный бинарник из APK."
            elif [ ! -s "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" ]; then
                _compressed_ok="0"
                rm -f "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" 2>/dev/null || true
                log_w "Скачанный Compressed-архив пустой. Оставляю обычный бинарник из APK."
            fi
        fi

        if [ "$_compressed_ok" = "1" ]; then
            COMPRESSED_BINARY_MEMBER=$(tar -tzf "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" 2>/dev/null | awk '/(^|\/)sing-box$/ {print; exit}')
            if [ -z "$COMPRESSED_BINARY_MEMBER" ]; then
                _compressed_ok="0"
                log_w "В Compressed-архиве не найден файл sing-box. Оставляю обычный бинарник из APK."
            fi
        fi

        if [ "$_compressed_ok" = "1" ]; then
            log_i "Извлекаю Compressed-бинарник рядом с /usr/bin/sing-box…"
            if ! tar -xOzf "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" "$COMPRESSED_BINARY_MEMBER" > "$NEW_FILE" 2>/dev/null; then
                _compressed_ok="0"
                log_w "Не удалось извлечь Compressed-бинарник. Оставляю обычный бинарник из APK."
            fi
        fi
        rm -f "$WORK_DIR/$COMPRESSED_ARCHIVE_NAME" 2>/dev/null || true
        COMPRESSED_ARCHIVE_NAME=""

        if [ "$_compressed_ok" = "1" ]; then
            if [ ! -s "$NEW_FILE" ] || ! chmod 755 "$NEW_FILE" 2>/dev/null; then
                _compressed_ok="0"
                log_w "Compressed-бинарник повреждён или не удалось сделать его исполняемым. Оставляю обычный бинарник из APK."
            fi
        fi

        if [ "$_compressed_ok" = "1" ]; then
            _compressed_version=$("$NEW_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
            if [ -z "$_compressed_version" ]; then
                _compressed_ok="0"
                log_w "Compressed-бинарник не запускается или не сообщает версию. Оставляю обычный бинарник из APK."
            else
                log_ok "Compressed-бинарник запускается корректно · версия $_compressed_version"
            fi
        fi

        if [ "$_compressed_ok" = "1" ]; then
            log_i "Проверку конфигурации выполнит Podkop при запуске после создания временных ruleset-файлов."
        fi

        if [ "$_compressed_ok" = "1" ]; then
            if mv -f "$NEW_FILE" "$DEST_FILE"; then
                NEW_FILE=""
                chmod 755 "$DEST_FILE" >/dev/null 2>&1 || true
                APK_COMPRESSED_APPLIED="1"
                NEW_VERSION="$_compressed_version"
                log_ok "Compressed (UPX) установлен поверх APK-пакета."
            else
                log_w "Не удалось заменить /usr/bin/sing-box. Оставляю обычный бинарник из APK."
                rm -f "$NEW_FILE" 2>/dev/null || true
                NEW_FILE=""
            fi
        else
            rm -f "$NEW_FILE" 2>/dev/null || true
            NEW_FILE=""
        fi

        if [ "$APK_COMPRESSED_APPLIED" != "1" ]; then
            BINARY_VARIANT="normal"
            NEW_VERSION="$APK_NORMAL_VERSION"
            log_i "Установка продолжится с обычным бинарником из APK-пакета."
        fi
    fi

    if [ "$PODKOP_PRESENT" = "1" ] && [ -x /etc/init.d/sing-box ]; then
        /etc/init.d/sing-box stop >/dev/null 2>&1 || true
        /etc/init.d/sing-box disable >/dev/null 2>&1 || true
    fi
fi

sync

if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
    ui_section "Запуск и проверка"
    log_i "Запускаю $SERVICE_NAME…"
    if ! start_managed_service_if_needed; then
        fail "Сервис '$SERVICE_NAME' не запустился после установки."
    fi

    _running="0"
    _seen="0"
    _stable=0
    _n=0
    while [ "$_n" -lt 60 ]; do
        if pidof sing-box >/dev/null 2>&1; then
            _seen="1"
            if [ "$_n" -ge 10 ]; then
                _stable=$((_stable + 1))
                if [ "$_stable" -ge 5 ]; then
                    _running="1"
                    break
                fi
            else
                _stable=0
            fi
        else
            _stable=0
        fi
        sleep 1
        _n=$((_n + 1))
    done

    if [ "$_running" != "1" ]; then
        SERVICE_STOPPED="0"
        if [ "$_seen" = "1" ]; then
            fail "Во время запуска Podkop процесс sing-box перезапускался и не стабилизировался за 60 секунд. Проверьте системный журнал."
        fi
        fail "После обновления процесс sing-box не появился за 60 секунд. Проверьте системный журнал."
    fi
    log_ok "sing-box работает стабильно."
else
    ui_section "Запуск и проверка"
    log_i "До установки сервис был остановлен — оставляю его остановленным."
fi

FINAL_VERSION="$NEW_VERSION"
[ -z "$FINAL_VERSION" ] && fail "Не удалось определить установленную версию sing-box."

cd / 2>/dev/null || true
cleanup_files
WORK_DIR=""

printf "\n"
ui_line
printf "${G}${B}  ✓ Установка завершена успешно${N}\n"
ui_line
ui_kv "Версия" "${CURRENT_VER:-не определена} → $FINAL_VERSION"
if [ "$IS_PKG_INSTALL" = "1" ]; then
    if [ "$PKG_MANAGER" = "apk" ]; then
        if [ "$APK_COMPRESSED_APPLIED" = "1" ]; then
            ui_kv "Установка" "APK + Compressed (UPX)"
        else
            ui_kv "Установка" "APK-пакет"
        fi
    else
        ui_kv "Установка" "IPK-пакет"
    fi
else
    ui_kv "Сборка" "$BINARY_VARIANT"
fi
ui_kv "Архитектура" "$ARCH_SUFFIX"
ui_kv "Бинарник" "$DEST_FILE"
if [ "$SERVICE_WAS_RUNNING" = "1" ]; then
    ui_kv "Сервис" "$SERVICE_NAME · запущен"
else
    ui_kv "Сервис" "$SERVICE_NAME · оставлен остановленным"
fi
if [ "$PODKOP_PRESENT" = "1" ] && [ "$PKG_MANAGER" = "opkg" ]; then
    if opkg_pkg_installed sing-box; then
        ui_kv "Podkop / opkg" "пакет sing-box зарегистрирован в opkg"
    else
        log_w "opkg не показывает штатный пакет sing-box. Проверьте состояние пакетов вручную."
    fi
fi
if [ "$APK_COMPRESSED_APPLIED" = "1" ]; then
    log_w "apk upgrade или apk fix может восстановить обычный бинарник из пакета; при необходимости повторно запустите установщик."
fi
ui_line
printf "${D}  Готово. Можно закрывать установщик.${N}\n\n"
