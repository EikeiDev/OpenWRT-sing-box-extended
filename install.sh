#!/bin/sh

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
DEST_FILE="/usr/bin/sing-box"

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

trap 'stty echo 2>/dev/null; printf "\n${R}[!] Установка прервана.${N}\n"; [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"; [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start >/dev/null 2>&1; exit 1' INT TERM

fail() {
    stty echo 2>/dev/null || true
    printf "${R}[!] Ошибка: %s${N}\n" "$1"
    [ -n "$WORK_DIR" ] && rm -rf "$WORK_DIR"
    [ "$SERVICE_STOPPED" = "1" ] && service "$SERVICE_NAME" start >/dev/null 2>&1
    exit 1
}

READ_TIMEOUT_SUPPORTED="1"
_READ_TIMEOUT_TEST=$( (read -r -t 0 _read_timeout_test) 2>&1 </dev/null )
case "$_READ_TIMEOUT_TEST" in
    *"Illegal option"*|*"illegal option"*|*"invalid option"*|*"Invalid option"*|*"bad option"*|*"Bad option"*)
        READ_TIMEOUT_SUPPORTED="0"
        ;;
esac
unset _READ_TIMEOUT_TEST

read_input() {
    READ_VALUE=""
    if [ "$READ_TIMEOUT_SUPPORTED" = "1" ]; then
        read -r -t "$1" READ_VALUE || READ_VALUE=""
    else
        read -r READ_VALUE || READ_VALUE=""
    fi
}

openwrt_version_class() {
    local _release="$1" _major _rest _minor

    _major=${_release%%.*}
    _rest=${_release#*.}
    if [ "$_rest" = "$_release" ]; then
        _minor=0
    else
        _minor=${_rest%%.*}
    fi

    case "$_major" in
        ''|*[!0-9]*) echo "unknown"; return 0 ;;
    esac
    case "$_minor" in
        ''|*[!0-9]*) echo "unknown"; return 0 ;;
    esac

    if [ "$_major" -gt 25 ] || { [ "$_major" -eq 25 ] && [ "$_minor" -ge 12 ]; }; then
        echo "new"
    else
        echo "old"
    fi
}

if command -v curl >/dev/null 2>&1; then
    FETCH_TYPE="curl"
    FETCH="curl -sSL --insecure --connect-timeout 15"
    DOWNLOAD="curl -fsSL --insecure --connect-timeout 15 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH_TYPE="wget"
    FETCH="wget -qO- --no-check-certificate --timeout=15"
    DOWNLOAD="wget -q --no-check-certificate --timeout=15 -O"
else
    printf "${R}[!] Ошибка: не найден curl или wget.${N}\n"
    exit 1
fi

api_get() {
    if [ -n "$GITHUB_TOKEN" ]; then
        case "$FETCH_TYPE" in
            curl) curl -sSL --insecure --connect-timeout 15 \
                    -H "Authorization: token $GITHUB_TOKEN" "$1" 2>/dev/null ;;
            wget) wget -qO- --no-check-certificate --timeout=15 \
                    --header="Authorization: token $GITHUB_TOKEN" "$1" 2>/dev/null ;;
        esac
    else
        $FETCH "$1" 2>/dev/null
    fi
}

read_token() {
    if stty -echo 2>/dev/null; then
        printf "${C}%s (ввод скрыт): ${N}" "$1"
        read_input 30
        GITHUB_TOKEN="$READ_VALUE"
        stty echo 2>/dev/null
        printf "\n"
    else
        printf "${C}%s (ввод будет виден): ${N}" "$1"
        read_input 30
        GITHUB_TOKEN="$READ_VALUE"
    fi
    GITHUB_TOKEN=$(printf '%s' "$GITHUB_TOKEN" | tr -d ' \t\n\r')
}

if [ -f "/opt/etc/init.d/podkop" ] || [ -f "/etc/init.d/podkop" ]; then
    SERVICE_NAME="podkop"
else
    SERVICE_NAME="sing-box"
fi

INSTALL_POLICY="auto"
PKG_MANAGER=""
PKG_EXT=""
DISTRIB_ARCH=""
DISTRIB_RELEASE=""
OPENWRT_VERSION_MODE=""
if [ -f "/etc/openwrt_release" ]; then
    DISTRIB_RELEASE=$(. /etc/openwrt_release && echo "$DISTRIB_RELEASE")
    OPENWRT_VERSION_MODE=$(openwrt_version_class "$DISTRIB_RELEASE")
    if command -v apk >/dev/null 2>&1 && [ "$(command -v apk)" != "/opt/bin/apk" ]; then
        PKG_MANAGER="apk"
        PKG_EXT="apk"
    elif command -v opkg >/dev/null 2>&1 && [ "$(command -v opkg)" != "/opt/bin/opkg" ]; then
        PKG_MANAGER="opkg"
        PKG_EXT="ipk"
    fi
fi
HOST_ARCH=$(uname -m)

if [ -f "/etc/openwrt_release" ]; then
    DISTRIB_ARCH=$(. /etc/openwrt_release && echo "$DISTRIB_ARCH")
    case "$DISTRIB_ARCH" in
        *mipsel* | *mipsle*) HOST_ARCH="mipsel" ;;
        *mips64el* | *mips64le*) HOST_ARCH="mips64el" ;;
    esac
fi

case "$OPENWRT_VERSION_MODE" in
    new)
        INSTALL_POLICY="apk"
        ;;
    old)
        INSTALL_POLICY="archive"
        ;;
    *)
        if [ "$PKG_MANAGER" = "apk" ]; then
            INSTALL_POLICY="apk"
            OPENWRT_VERSION_MODE="new"
        elif [ -n "$PKG_MANAGER" ]; then
            INSTALL_POLICY="archive"
            OPENWRT_VERSION_MODE="old"
        fi
        ;;
esac

if [ "$INSTALL_POLICY" = "apk" ] && [ "$PKG_MANAGER" != "apk" ]; then
    fail "Для OpenWrt ${DISTRIB_RELEASE:-25.12+} используется только apk, но системный apk не найден."
fi

case $HOST_ARCH in
  aarch64)                ARCH_SUFFIX="arm64" ;;
  armv7*)                 ARCH_SUFFIX="armv7" ;;
  armv6*)                 ARCH_SUFFIX="armv6" ;;
  x86_64)                 ARCH_SUFFIX="amd64" ;;
  i386 | i686)            ARCH_SUFFIX="386" ;;
  mips)                   ARCH_SUFFIX="mips-softfloat" ;;
  mipsel | mipsle)        ARCH_SUFFIX="mipsle-softfloat" ;;
  mips64)                 ARCH_SUFFIX="mips64" ;;
  mips64el | mips64le)    ARCH_SUFFIX="mips64le" ;;
  riscv64)                ARCH_SUFFIX="riscv64" ;;
  s390x)                  ARCH_SUFFIX="s390x" ;;
  *)
    printf "${R}[!] Ошибка: архитектура $HOST_ARCH не поддерживается.${N}\n"
    exit 1
    ;;
esac

case $ARCH_SUFFIX in
    mips64 | mips64le) USE_COMPRESSED="0" ;;
    *) USE_COMPRESSED="1" ;;
esac

CURRENT_VER=""
if [ -f "$DEST_FILE" ]; then
    CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
fi

if [ -z "$GITHUB_TOKEN" ]; then
    _ENC_TKN="tuc_MOSLC05dHJG0Q0V4qC31IWGDWOTHwe3MjWOD"
    GITHUB_TOKEN=$(echo "$_ENC_TKN" | tr 'a-zA-Z' 'n-za-mN-ZA-M')
fi
GITHUB_TOKEN=$(printf '%s' "$GITHUB_TOKEN" | tr -d ' \t\n\r')

printf "\n${C}========================================${N}\n"
printf "${C}  Установщик sing-box extended${N}\n"
printf "${C}========================================${N}\n"
printf "  Сервис:       ${Y}%s${N}\n" "$SERVICE_NAME"
printf "  Архитектура:  ${Y}%s${N} -> ${Y}%s${N}\n" "$HOST_ARCH" "$ARCH_SUFFIX"
if [ -n "$PKG_MANAGER" ]; then
    printf "  Пакеты:       ${Y}%s${N}\n" "$PKG_EXT"
fi
if [ -n "$DISTRIB_RELEASE" ]; then
    printf "  OpenWrt:      ${Y}%s${N}\n" "$DISTRIB_RELEASE"
fi
if [ "$OPENWRT_VERSION_MODE" = "old" ]; then
    printf "  Режим:        ${Y}архивы, ipk пропускается${N}\n"
elif [ "$OPENWRT_VERSION_MODE" = "new" ]; then
    printf "  Режим:        ${Y}только apk${N}\n"
fi
printf "  Бинарник:     ${Y}%s${N}\n\n" "$DEST_FILE"

printf "${C}[*] Запрашиваю список релизов...${N}\n"
API_RESPONSE=$(api_get "$API_URL") || true

if [ -z "$API_RESPONSE" ]; then
    fail "Не удалось подключиться к GitHub API. Проверьте соединение."
fi

if ! printf '%s' "$API_RESPONSE" | grep -q '"tag_name"'; then
    if printf '%s' "$API_RESPONSE" | grep -qi "bad credentials\|401\|rate limit"; then
        printf "${Y}[!] Встроенный токен недоступен или исчерпал лимит.${N}\n"
        GITHUB_TOKEN=""
    else
        printf "${R}[!] Неожиданный ответ от GitHub API.${N}\n"
    fi
    if [ -z "$GITHUB_TOKEN" ]; then
        read_token "[>] Введите личный GitHub токен для продолжения"
    fi
    [ -z "$GITHUB_TOKEN" ] && fail "Токен не введён. Установка прервана."
    printf "${C}[*] Повторяю запрос с указанным токеном...${N}\n"
    API_RESPONSE=$(api_get "$API_URL") || true
    if [ -z "$API_RESPONSE" ] || ! printf '%s' "$API_RESPONSE" | grep -q '"tag_name"'; then
        fail "Не удалось получить список релизов. Проверьте токен или попробуйте позже."
    fi
fi

RELEASES=$(echo "$API_RESPONSE" \
  | tr ',' '\n' \
  | grep '"tag_name"' \
  | awk -F '"' '{print $4}' \
  | grep -v -i "rc" \
  | grep -v -i "beta" \
  | grep -v -i "alpha" \
  | head -n 3)

ALL_RELEASES=$(echo "$API_RESPONSE" \
  | tr ',' '\n' \
  | grep '"tag_name"' \
  | awk -F '"' '{print $4}' \
  | grep -v -i "rc" \
  | grep -v -i "beta" \
  | grep -v -i "alpha")

if [ -z "$RELEASES" ]; then
    fail "Не удалось получить список стабильных релизов из API."
fi

printf "\n${C}Доступные стабильные версии:${N}\n"
i=1
for tag in $RELEASES; do
    printf "  ${Y}%d)${N} %s\n" "$i" "$tag"
    i=$((i+1))
done
printf "  ${Y}0)${N} Отмена\n"

printf "\n${C}[>] Введите номер версии (0-$((i-1))): ${N}"
read_input 60
choice="$READ_VALUE"

if [ "$choice" = "0" ]; then
    printf "${G}[*] Отменено.${N}\n"
    exit 0
fi

SELECTED_TAG=""
i=1
for tag in $RELEASES; do
    if [ "$choice" = "$i" ]; then
        SELECTED_TAG="$tag"
        break
    fi
    i=$((i+1))
done

if [ -z "$SELECTED_TAG" ]; then
    fail "Неверный выбор. Пожалуйста, введите корректный номер из списка."
fi

SELECTED_VER=$(echo "$SELECTED_TAG" | sed 's/^v//')

printf "\n${C}Выбор:${N}\n"
printf "  Текущая версия:  ${Y}%s${N}\n" "${CURRENT_VER:-не установлена}"
printf "  Новая версия:    ${Y}%s${N}\n" "$SELECTED_VER"

if [ -n "$CURRENT_VER" ] && [ "$CURRENT_VER" = "$SELECTED_VER" ]; then
    printf "${Y}[!] Эта версия уже установлена. Будет выполнена переустановка.${N}\n"
fi

get_compressed_url_from_assets() {
    local _al="$1" _url=""
    _url=$(echo "$_al" | grep "browser_download_url" \
      | grep "linux-$ARCH_SUFFIX-compressed\.tar\.gz" \
      | head -n 1 | awk -F '"' '{print $4}')
    echo "$_url"
    [ -n "$_url" ]
}

get_pkg_url_from_assets() {
    local _al="$1" _url=""
    if [ "$INSTALL_POLICY" = "apk" ]; then
        _url=$(echo "$_al" | grep "browser_download_url" \
          | grep "sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.${PKG_EXT}" \
          | head -n 1 | awk -F '"' '{print $4}')
    fi
    echo "$_url"
    [ -n "$_url" ]
}

get_asset_lines_for_tag() {
    local _tag="$1" _lines _resp
    _lines=$(echo "$API_RESPONSE" | tr ',' '\n' | awk -v tag="\"$_tag\"" '
        /"tag_name":/ { in_rel = (index($0, tag) > 0) }
        in_rel && /browser_download_url/ { print }
    ')
    if [ -z "$_lines" ]; then
        _resp=$(api_get "https://api.github.com/repos/shtorm-7/sing-box-extended/releases/tags/$_tag") || true
        [ -z "$_resp" ] && return 1
        _lines=$(echo "$_resp" | tr ',' '\n')
    fi
    echo "$_lines"
}

get_url_from_assets() {
    local _al="$1" _url=""
    if [ "$PREFER_COMPRESSED" = "1" ]; then
        _url=$(get_compressed_url_from_assets "$_al") || true
        [ -n "$_url" ] && { echo "0:$_url"; return 0; }
    fi
    if [ "$INSTALL_POLICY" = "apk" ]; then
        _url=$(get_pkg_url_from_assets "$_al") || true
        [ -n "$_url" ] && { echo "1:$_url"; return 0; }
        echo "0:"
        return 1
    fi
    if [ -z "$_url" ]; then
        _url=$(echo "$_al" | grep "browser_download_url" \
          | grep "linux-$ARCH_SUFFIX\.tar\.gz" \
          | grep -v "compressed" \
          | head -n 1 | awk -F '"' '{print $4}')
    fi
    echo "0:$_url"
    [ -n "$_url" ]
}

get_url_for_tag() {
    local _tag="$1" _lines
    _lines=$(get_asset_lines_for_tag "$_tag") || { echo "0:"; return 1; }
    get_url_from_assets "$_lines"
}

get_compressed_url_for_tag() {
    local _tag="$1" _lines
    _lines=$(get_asset_lines_for_tag "$_tag") || return 1
    get_compressed_url_from_assets "$_lines"
}

stop_service_for_install() {
    [ "$SERVICE_STOPPED" = "1" ] && return 0

    printf "${C}[*] Останавливаю сервис ${SERVICE_NAME}...${N}\n"
    SERVICE_STOPPED="1"
    service "$SERVICE_NAME" stop >/dev/null 2>&1 || true
    sleep 2
}

install_package_file() {
    [ "$PKG_MANAGER" = "apk" ] || return 1
    apk add --allow-untrusted "$1"
}
PREFER_COMPRESSED="0"
COMPRESSED_URL_FOR_SELECTED=""
if [ "$USE_COMPRESSED" = "1" ] && [ "$INSTALL_POLICY" != "apk" ]; then
    COMPRESSED_URL_FOR_SELECTED=$(get_compressed_url_for_tag "$SELECTED_TAG") || true
fi

if [ "$INSTALL_POLICY" = "apk" ]; then
    PREFER_COMPRESSED="0"
elif [ "$OPENWRT_VERSION_MODE" = "old" ] && [ -n "$COMPRESSED_URL_FOR_SELECTED" ]; then
    printf "\n${C}[>] Установить сжатую версию? [Y/n]: ${N}"
    read_input 60
    compressed_choice="$READ_VALUE"
    case "$compressed_choice" in
        ''|y|Y|yes|Yes|YES|д|Д|да|Да|ДА)
            PREFER_COMPRESSED="1"
            ;;
        n|N|no|No|NO|н|Н|нет|Нет|НЕТ)
            PREFER_COMPRESSED="0"
            ;;
        *)
            printf "${Y}[!] Не понял ответ, выбираю сжатую версию по умолчанию.${N}\n"
            PREFER_COMPRESSED="1"
            ;;
    esac
elif [ -n "$COMPRESSED_URL_FOR_SELECTED" ] && [ "$INSTALL_POLICY" != "apk" ]; then
    PREFER_COMPRESSED="1"
fi
USER_WANTS_COMPRESSED="$PREFER_COMPRESSED"

parse_url_result() {
    IS_PKG_INSTALL="${1%%:*}"
    DOWNLOAD_URL="${1#*:}"
}

printf "${C}[*] Подбираю файл для версии $SELECTED_TAG...${N}\n"

IS_PKG_INSTALL="0"
DOWNLOAD_URL=""
parse_url_result "$(get_url_for_tag "$SELECTED_TAG")"

if [ -z "$DOWNLOAD_URL" ]; then
    printf "${Y}[!] Для '$ARCH_SUFFIX' нет файла в $SELECTED_TAG. Проверяю более старые релизы...${N}\n"
    for _fb_tag in $ALL_RELEASES; do
        [ "$_fb_tag" = "$SELECTED_TAG" ] && continue
        PREFER_COMPRESSED="0"
        if [ "$USER_WANTS_COMPRESSED" = "1" ] && [ "$USE_COMPRESSED" = "1" ] && [ -n "$(get_compressed_url_for_tag "$_fb_tag")" ]; then
            PREFER_COMPRESSED="1"
        fi
        _fb_result=$(get_url_for_tag "$_fb_tag")
        _fb_url="${_fb_result#*:}"
        if [ -n "$_fb_url" ]; then
            parse_url_result "$_fb_result"
            SELECTED_TAG="$_fb_tag"
            SELECTED_VER=$(echo "$SELECTED_TAG" | sed 's/^v//')
            printf "${Y}[!] Найден совместимый релиз: ${SELECTED_VER}${N}\n"
            break
        fi
    done
fi

if [ -z "$DOWNLOAD_URL" ]; then
    fail "Файл для архитектуры '$HOST_ARCH' ($ARCH_SUFFIX / ${DISTRIB_ARCH:-н/д}) не найден ни в одном из доступных релизов."
fi

if [ "$IS_PKG_INSTALL" = "1" ]; then
    ARCHIVE_NAME="sing-box-latest.${PKG_EXT}"
else
    ARCHIVE_NAME="sing-box-latest.tar.gz"
fi

case "$DOWNLOAD_URL" in
    *-compressed.tar.gz)
        INSTALL_MODE="сжатый архив"
        REQ_TEMP_KB=40960
        REQ_DEST_KB=25600
        ;;
    *.tar.gz)
        INSTALL_MODE="обычный архив"
        REQ_TEMP_KB=122880
        REQ_DEST_KB=81920
        ;;
    *)
        INSTALL_MODE="${PKG_EXT}-пакет"
        REQ_TEMP_KB=40960
        REQ_DEST_KB=81920
        ;;
esac

printf "\n${C}План установки:${N}\n"
printf "  Релиз:          ${Y}%s${N}\n" "$SELECTED_TAG"
printf "  Тип:            ${Y}%s${N}\n" "$INSTALL_MODE"
printf "  Нужно временно: ${Y}%s МБ${N}\n" "$((REQ_TEMP_KB / 1024))"
printf "  Нужно бинарнику:${Y} %s МБ${N}\n" "$((REQ_DEST_KB / 1024))"

get_free_space_kb() {
    local space
    space=$(df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}')
    case "$space" in
        ''|*[!0-9]*) echo 0 ;;
        *) echo "$space" ;;
    esac
}

DEST_DIR=$(dirname "$DEST_FILE")
DEST_FREE_KB=$(get_free_space_kb "$DEST_DIR")
EXISTING_SIZE_KB=0
if [ -f "$DEST_FILE" ] && [ ! -L "$DEST_FILE" ]; then
    EXISTING_SIZE_KB=$(du -k "$DEST_FILE" 2>/dev/null | awk '{print $1}')
    case "$EXISTING_SIZE_KB" in
        ''|*[!0-9]*) EXISTING_SIZE_KB=0 ;;
    esac
fi
TOTAL_DEST_AVAILABLE=$((DEST_FREE_KB + EXISTING_SIZE_KB))

if [ "$TOTAL_DEST_AVAILABLE" -lt "$REQ_DEST_KB" ]; then
    fail "Недостаточно места в $DEST_DIR. Доступно: $((TOTAL_DEST_AVAILABLE / 1024)) МБ, требуется: $((REQ_DEST_KB / 1024)) МБ."
fi

FREE_RAM_KB=$(awk '/MemFree/ {print $2}' /proc/meminfo)
case "$FREE_RAM_KB" in
    ''|*[!0-9]*) FREE_RAM_KB=0 ;;
esac

HOME_DIR="${HOME:-/root}"
DIR_RAM="/tmp/sing-box-install"
DIR_DISK="$HOME_DIR/sing-box-install_tmp"

if [ "$FREE_RAM_KB" -gt 81920 ]; then
    PREF_DIR="$DIR_RAM"
    PREF_PARENT="/tmp"
    ALT_DIR="$DIR_DISK"
    ALT_PARENT="$HOME_DIR"
else
    PREF_DIR="$DIR_DISK"
    PREF_PARENT="$HOME_DIR"
    ALT_DIR="$DIR_RAM"
    ALT_PARENT="/tmp"
fi

WORK_DIR=""
PREF_FREE_KB=$(get_free_space_kb "$PREF_PARENT")
if [ "$PREF_FREE_KB" -ge "$REQ_TEMP_KB" ]; then
    WORK_DIR="$PREF_DIR"
else
    ALT_FREE_KB=$(get_free_space_kb "$ALT_PARENT")
    if [ "$ALT_FREE_KB" -ge "$REQ_TEMP_KB" ]; then
        WORK_DIR="$ALT_DIR"
    fi
fi

if [ -z "$WORK_DIR" ]; then
    RAM_FREE_MB=$(( $(get_free_space_kb "/tmp") / 1024 ))
    DISK_FREE_MB=$(( $(get_free_space_kb "$HOME_DIR") / 1024 ))
    fail "Недостаточно свободного места для установки. В /tmp (ОЗУ) доступно: ${RAM_FREE_MB} МБ, в $HOME_DIR (диск) доступно: ${DISK_FREE_MB} МБ. Требуется минимум: $((REQ_TEMP_KB / 1024)) МБ."
fi

rm -rf "$WORK_DIR" || true
mkdir -p "$WORK_DIR" || fail "Не удалось создать временную директорию $WORK_DIR."
cd "$WORK_DIR" || fail "Не удалось перейти во временную директорию $WORK_DIR."

printf "  Рабочая папка:  ${Y}%s${N}\n\n" "$WORK_DIR"

printf "${C}[*] Скачиваю %s...${N}\n" "$(basename "$DOWNLOAD_URL")"
$DOWNLOAD "$ARCHIVE_NAME" "$DOWNLOAD_URL" || fail "Не удалось скачать файл."

if [ ! -s "$ARCHIVE_NAME" ]; then
    fail "Скачанный файл пустой."
fi

stop_service_for_install

if [ "$IS_PKG_INSTALL" = "1" ]; then
    printf "${C}[*] Устанавливаю ${PKG_EXT}-пакет sing-box-extended...${N}\n"
    install_package_file "$ARCHIVE_NAME" || fail "Не удалось установить ${PKG_EXT}-пакет."
    rm -f "$ARCHIVE_NAME" || true
else
    printf "${C}[*] Распаковываю архив...${N}\n"
    tar -xzf "$ARCHIVE_NAME" || fail "Не удалось распаковать архив."
    rm -f "$ARCHIVE_NAME" || true

    BINARY_PATH=$(find . -type f -name sing-box | head -n 1)
    if [ -z "$BINARY_PATH" ]; then
        fail "Бинарник не найден в архиве."
    fi

    printf "${C}[*] Устанавливаю бинарник...${N}\n"
    mv -f "$BINARY_PATH" "$DEST_FILE" || fail "Не удалось заменить файл."
    chmod +x "$DEST_FILE" || fail "Не удалось выставить права на бинарник."
fi

NEW_VERSION=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}') || true
if [ -z "$NEW_VERSION" ]; then
    fail "sing-box установлен, но версия не определяется. Проверьте работоспособность $DEST_FILE."
fi
if [ "$NEW_VERSION" != "$SELECTED_VER" ]; then
    fail "После установки ожидалась версия ${SELECTED_VER}, но получена ${NEW_VERSION}."
fi

cd /
rm -rf "$WORK_DIR" || true
WORK_DIR=""

printf "${C}[*] Запускаю сервис ${SERVICE_NAME}...${N}\n"
if ! service "$SERVICE_NAME" start >/dev/null 2>&1; then
    printf "${Y}[!] Не удалось запустить сервис '$SERVICE_NAME'. Запустите вручную.${N}\n"
fi

printf "\n${G}[+] Установка завершена:${N} ${Y}${CURRENT_VER:-н/д}${N} -> ${Y}${NEW_VERSION:-н/д}${N}\n"
