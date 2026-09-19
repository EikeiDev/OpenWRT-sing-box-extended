#!/bin/sh

[ -f "/etc/openwrt_release" ] || { echo -e "\033[1;31m[!] Ошибка: Эта система не OpenWrt.\033[0m"; exit 1; }
. /etc/openwrt_release

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases?per_page=30"
PROXY_PREFIX="https://ghproxy.net/"
DEST_FILE="/usr/bin/sing-box"
REAL_BIN="/usr/libexec/sing-box-core"
VERSION_CACHE="/etc/sing-box-version.cache"
WORK_DIR="/tmp/sing-box-install"
SERVICE_STOPPED=0
ZB_STOPPED=0

R="\033[1;31m"
G="\033[1;32m"
Y="\033[1;33m"
C="\033[1;36m"
N="\033[0m"

trap 'printf "\n${R}[!] Установка прервана.${N}\n"; rm -rf "$WORK_DIR"; [ "$SERVICE_STOPPED" = "1" ] && /etc/init.d/"$SERVICE_NAME" start >/dev/null 2>&1; [ "$ZB_STOPPED" = "1" ] && /etc/init.d/zeroblock start >/dev/null 2>&1; exit 1' INT TERM

fail() {
    printf "${R}[!] Ошибка: %s${N}\n" "$1"
    rm -rf "$WORK_DIR"
    [ "$SERVICE_STOPPED" = "1" ] && /etc/init.d/"$SERVICE_NAME" start >/dev/null 2>&1
    [ "$ZB_STOPPED" = "1" ] && /etc/init.d/zeroblock start >/dev/null 2>&1
    exit 1
}

if command -v curl >/dev/null 2>&1; then
    FETCH="curl -sSL --insecure --connect-timeout 10"
    DOWNLOAD="curl -fsSL --insecure --connect-timeout 30 -o"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO- --no-check-certificate --timeout=10"
    DOWNLOAD="wget -q --no-check-certificate --timeout=30 -O"
elif command -v uclient-fetch >/dev/null 2>&1; then
    FETCH="uclient-fetch -qO- --no-check-certificate --timeout=10"
    DOWNLOAD="uclient-fetch -q --no-check-certificate --timeout=30 -O"
else
    fail "Не найден curl, wget или uclient-fetch."
fi

case "$DISTRIB_ARCH" in
    aarch64*) ARCH_SUFFIX="arm64" ;;
    arm_cortex-a7* | arm_cortex-a15*) ARCH_SUFFIX="armv7" ;;
    arm_*) ARCH_SUFFIX="armv6" ;;
    x86_64) ARCH_SUFFIX="amd64" ;;
    i386*) ARCH_SUFFIX="386" ;;
    mipsel_24kc) ARCH_SUFFIX="mipsle-softfloat" ;;
    mips_24kc) ARCH_SUFFIX="mips-softfloat" ;;
    *) fail "Архитектура $DISTRIB_ARCH не поддерживается." ;;
esac

if command -v apk >/dev/null 2>&1; then
    PKG_MANAGER="apk"
    PKG_EXT="apk"
elif command -v opkg >/dev/null 2>&1; then
    PKG_MANAGER="opkg"
    PKG_EXT="ipk"
else
    PKG_MANAGER="none"
fi

if [ -f "/etc/init.d/podkop" ]; then
    SERVICE_NAME="podkop"
else
    SERVICE_NAME="sing-box"
fi

_ENC_TKN="tuc_MOSLC05dHJG0Q0V4qC31IWGDWOTHwe3MjWOD"
GITHUB_TOKEN=$(echo "$_ENC_TKN" | tr 'a-zA-Z' 'n-za-mN-ZA-M' | tr -d ' \t\n\r')
AUTH_HEADER="Authorization: token $GITHUB_TOKEN"

CURRENT_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}')

printf "\n${C}========================================${N}\n"
printf "${C}  OpenWrt sing-box extended installer${N}\n"
printf "${C}========================================${N}\n"
printf "  Версия ОС:    ${Y}%s${N}\n" "${DISTRIB_RELEASE:-неизвестно}"
printf "  Архитектура:  ${Y}%s${N} -> ${Y}%s${N}\n" "$DISTRIB_ARCH" "$ARCH_SUFFIX"
printf "  Менеджер:     ${Y}%s${N}\n" "$PKG_MANAGER"
printf "  Сервис:       ${Y}%s${N}\n\n" "$SERVICE_NAME"

printf "${C}[*] Проверка подключения к сети...${N}\n"
if ! $FETCH "https://ghproxy.net/" >/dev/null 2>&1; then
    fail "Отсутствует подключение к интернету или недоступен шлюз ghproxy.net."
fi

printf "${C}[*] Запрашиваю список релизов...${N}\n"
if echo "$FETCH" | grep -q "curl"; then
    API_RESPONSE=$($FETCH -H "$AUTH_HEADER" "$API_URL" 2>/dev/null)
else
    API_RESPONSE=$($FETCH --header="$AUTH_HEADER" "$API_URL" 2>/dev/null)
fi

[ -z "$API_RESPONSE" ] && fail "Не удалось получить ответ от GitHub API."

if command -v jsonfilter >/dev/null 2>&1; then
    RELEASES=$(echo "$API_RESPONSE" | jsonfilter -e '@[*].tag_name' | grep -viE "rc|beta|alpha" | head -n 3)
else
    RELEASES=$(echo "$API_RESPONSE" | grep '"tag_name"' | awk -F'"' '{print $4}' | grep -viE "rc|beta|alpha" | head -n 3)
fi

[ -z "$RELEASES" ] && fail "Не удалось получить список стабильных релизов."

printf "\n${C}Доступные версии:${N}\n"
i=1
for tag in $RELEASES; do
    printf "  ${Y}%d)${N} %s\n" "$i" "$tag"
    i=$((i+1))
done
printf "  ${Y}0)${N} Отмена\n"

printf "\n${C}[>] Введите номер (0-$((i-1))): ${N}"
read -r choice

[ "$choice" = "0" ] && { printf "${G}[*] Отменено.${N}\n"; exit 0; }

SELECTED_TAG=$(echo "$RELEASES" | sed -n "${choice}p")
[ -z "$SELECTED_TAG" ] && fail "Неверный выбор."
SELECTED_VER=$(echo "$SELECTED_TAG" | sed 's/^v//')

if [ "$CURRENT_VER" = "$SELECTED_VER" ]; then
    printf "${Y}[!] Эта версия уже установлена. Выполняю переустановку.${N}\n"
fi

printf "${C}[*] Подбираю файл для %s...${N}\n" "$SELECTED_TAG"

URLS=$(echo "$API_RESPONSE" | tr ',' '\n' | awk -v tag="\"$SELECTED_TAG\"" '
    /"tag_name":/ { in_rel = (index($0, tag) > 0) }
    in_rel && /browser_download_url/ { print }
' | awk -F'"' '{print $4}')

APK_URL=""
if [ "$PKG_MANAGER" = "apk" ]; then
    APK_URL=$(echo "$URLS" | grep -E "sing-box-extended_.*_openwrt_${DISTRIB_ARCH}\.apk" | head -n 1)
fi

COMPRESSED_URL=$(echo "$URLS" | grep "linux-$ARCH_SUFFIX-compressed\.tar\.gz" | head -n 1)
NORMAL_URL=$(echo "$URLS" | grep "linux-$ARCH_SUFFIX\.tar\.gz" | grep -v "compressed" | head -n 1)

printf "\n${C}Доступные варианты установки для $ARCH_SUFFIX:${N}\n"
OPT_NUM=1
HAS_APK=0
HAS_CMP=0
HAS_NRM=0

if [ -n "$APK_URL" ]; then
    printf "  ${Y}%d)${N} APK-пакет (Стандартная установка)\n" "$OPT_NUM"
    HAS_APK=$OPT_NUM
    OPT_NUM=$((OPT_NUM + 1))
fi
if [ -n "$COMPRESSED_URL" ]; then
    printf "  ${Y}%d)${N} Сжатая версия (Рекомендуется для слабых роутеров: экономит место и защищает от вылетов)\n" "$OPT_NUM"
    HAS_CMP=$OPT_NUM
    OPT_NUM=$((OPT_NUM + 1))
fi
if [ -n "$NORMAL_URL" ]; then
    printf "  ${Y}%d)${N} Обычная версия (Стандартный архив, если роутер мощный)\n" "$OPT_NUM"
    HAS_NRM=$OPT_NUM
    OPT_NUM=$((OPT_NUM + 1))
fi

if [ "$OPT_NUM" -eq 1 ]; then
    fail "Файлы для архитектуры $ARCH_SUFFIX не найдены в релизе $SELECTED_TAG."
fi

if [ "$OPT_NUM" -gt 2 ]; then
    printf "\n${C}[>] Выберите вариант (по умолчанию 1): ${N}"
    read -r fmt_choice
    [ -z "$fmt_choice" ] && fmt_choice=1
else
    fmt_choice=1
fi

DOWNLOAD_URL=""
IS_PKG_INSTALL=0
IS_COMPRESSED=0
REQ_KB=65000

if [ "$fmt_choice" = "$HAS_APK" ]; then
    DOWNLOAD_URL="$APK_URL"
    IS_PKG_INSTALL=1
    REQ_KB=25000
elif [ "$fmt_choice" = "$HAS_CMP" ]; then
    DOWNLOAD_URL="$COMPRESSED_URL"
    IS_COMPRESSED=1
    REQ_KB=30000
elif [ "$fmt_choice" = "$HAS_NRM" ]; then
    DOWNLOAD_URL="$NORMAL_URL"
else
    fail "Неверный выбор формата."
fi

TMP_FREE=$(df -Pk /tmp 2>/dev/null | awk 'NR==2 {print $4}')
ROOT_FREE=$(df -Pk /root 2>/dev/null | awk 'NR==2 {print $4}')
[ -z "$TMP_FREE" ] && TMP_FREE=0
[ -z "$ROOT_FREE" ] && ROOT_FREE=0

if [ "$TMP_FREE" -ge "$REQ_KB" ]; then
    WORK_DIR="/tmp/sing-box-install"
elif [ "$ROOT_FREE" -ge "$REQ_KB" ]; then
    WORK_DIR="/root/sing-box-install"
    printf "\n${Y}[!] Мало места в оперативной памяти (/tmp). Использую диск (/root) для скачивания.${N}"
else
    WORK_DIR="/tmp/sing-box-install"
    printf "\n${R}[!] Внимание: критически мало места! Возможна ошибка при скачивании или распаковке.${N}"
fi

rm -rf "$WORK_DIR" && mkdir -p "$WORK_DIR"
cd "$WORK_DIR" || fail "Не удалось перейти в $WORK_DIR."

FILE_NAME=$(basename "$DOWNLOAD_URL")
PROXIED_URL="${PROXY_PREFIX}${DOWNLOAD_URL}"

printf "\n${C}[*] Скачиваю...${N}\n"
$DOWNLOAD "$FILE_NAME" "$PROXIED_URL" || fail "Сбой при скачивании файла."
[ ! -s "$FILE_NAME" ] && fail "Скачанный файл пуст."

stop_service() {
    [ "$SERVICE_STOPPED" = "1" ] && return
    
    if [ -f "/etc/init.d/zeroblock" ]; then
        printf "${C}[*] Останавливаю Zero-Block...${N}\n"
        /etc/init.d/zeroblock stop >/dev/null 2>&1
        ZB_STOPPED=1
    fi

    printf "${C}[*] Останавливаю %s...${N}\n" "$SERVICE_NAME"
    /etc/init.d/"$SERVICE_NAME" stop >/dev/null 2>&1
    
    killall sing-box >/dev/null 2>&1
    
    SERVICE_STOPPED=1
    sleep 2
}

if [ "$IS_PKG_INSTALL" -eq 1 ]; then
    stop_service
    printf "${C}[*] Устанавливаю APK пакет...${N}\n"
    rm -f "$REAL_BIN" "$VERSION_CACHE"
    apk add --allow-untrusted "$FILE_NAME" || fail "Ошибка установки APK."
else
    printf "${C}[*] Распаковываю архив...${N}\n"
    tar -xzf "$FILE_NAME" || fail "Ошибка распаковки архива."
    BIN_PATH=$(find . -type f -name sing-box | head -n 1)
    [ -z "$BIN_PATH" ] && fail "Бинарник не найден внутри архива."
    
    stop_service
    
    if [ "$IS_COMPRESSED" -eq 1 ]; then
        printf "${C}[*] Устанавливаю сжатую версию...${N}\n"
        
        mkdir -p $(dirname "$REAL_BIN")
        cp "$BIN_PATH" "$REAL_BIN" || fail "Не удалось скопировать бинарник."
        chmod +x "$REAL_BIN"
        
        cat > "$VERSION_CACHE" <<EOF
sing-box version $SELECTED_VER
Environment: cached by OpenWRT sing-box-extended installer
Tags: unavailable for UPX-compressed build without executing sing-box
EOF
        
        DEST_DIR=$(dirname "$DEST_FILE")
        STAGE_FILE="$DEST_DIR/.sing-box.tmp.$$"
        
        cat > "$STAGE_FILE" <<EOF
#!/bin/sh
REAL_BIN="$REAL_BIN"
VERSION_CACHE="$VERSION_CACHE"

if [ "\$#" -eq 1 ] && [ "\$1" = "version" ]; then
    if [ -s "\$VERSION_CACHE" ]; then
        cat "\$VERSION_CACHE"
        exit 0
    fi
    echo "sing-box version cache is missing; reinstall sing-box-extended." >&2
    exit 1
fi

exec "\$REAL_BIN" "\$@"
EOF
        chmod +x "$STAGE_FILE"
        mv -f "$STAGE_FILE" "$DEST_FILE" || { rm -f "$STAGE_FILE"; fail "Сбой создания враппера."; }
    else
        printf "${C}[*] Устанавливаю обычную версию...${N}\n"
        rm -f "$REAL_BIN" "$VERSION_CACHE"
        
        DEST_DIR=$(dirname "$DEST_FILE")
        STAGE_FILE="$DEST_DIR/.sing-box.tmp.$$"
        
        cp "$BIN_PATH" "$STAGE_FILE" || fail "Недостаточно места на целевом диске ($DEST_DIR)."
        chmod +x "$STAGE_FILE"
        mv -f "$STAGE_FILE" "$DEST_FILE" || { rm -f "$STAGE_FILE"; fail "Сбой замены файла."; }
    fi
fi

NEW_VER=$("$DEST_FILE" version 2>/dev/null | head -n 1 | awk '{print $NF}')
[ "$NEW_VER" != "$SELECTED_VER" ] && fail "Версия после установки ($NEW_VER) не совпадает с ожидаемой ($SELECTED_VER)."

cd /
rm -rf "$WORK_DIR"

printf "${C}[*] Запускаю сервис...${N}\n"
/etc/init.d/"$SERVICE_NAME" start >/dev/null 2>&1 || printf "${Y}[!] Не удалось запустить службу. Проверьте логи.${N}\n"

if [ "$ZB_STOPPED" = "1" ]; then
    printf "${C}[*] Запускаю Zero-Block...${N}\n"
    /etc/init.d/zeroblock start >/dev/null 2>&1 || printf "${Y}[!] Не удалось запустить Zero-Block.${N}\n"
fi

printf "\n${G}[+] Установка завершена:${N} ${Y}${CURRENT_VER:-н/д}${N} -> ${Y}${NEW_VER}${N}\n"
