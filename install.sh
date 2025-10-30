#!/bin/sh

set -e

API_URL="https://api.github.com/repos/shtorm-7/sing-box-extended/releases/latest"
FILE_PATTERN="linux-arm64.tar.gz"
TMP_DIR="/tmp/sing-box-install"
ARCHIVE_NAME="sing-box-latest.tar.gz"
DEST_FILE="/usr/bin/sing-box"

echo "[*] Ищу последнюю версию для $FILE_PATTERN..."

# ИСПРАВЛЕНИЕ: Разбиваем JSON на строки с помощью 'tr' 
# и используем связку grep/awk для надежного парсинга
DOWNLOAD_URL=$(wget -qO- "$API_URL" | tr ',' '\n' | grep "browser_download_url" | grep "$FILE_PATTERN" | awk -F '"' '{print $4}')

if [ -z "$DOWNLOAD_URL" ]; then
    echo "[!] ОШИБКА: Не смог найти URL для скачивания."
    echo "Проверь $FILE_PATTERN или репозиторий. Может, ГитХаб лежит?"
    exit 1
fi

echo "[+] Нашел: $DOWNLOAD_URL"

echo "[*] Готовлю место в /tmp..."
rm -rf "$TMP_DIR"
mkdir -p "$TMP_DIR"
cd "$TMP_DIR"

echo "[*] Качаю..."
wget -O "$ARCHIVE_NAME" "$DOWNLOAD_URL"

echo "[*] Гашу старый sing-box... (если он запущен)"
service sing-box stop >/dev/null 2>&1 || true
killall sing-box >/dev/null 2>&1 || true

echo "[*] Распаковываю архив (полностью)..."
tar -xzf "$ARCHIVE_NAME"

echo "[*] Ищу бинарный файл..."
BINARY_PATH=$(find . -type f -name sing-box | head -n 1)

if [ -z "$BINARY_PATH" ]; then
    echo "[!] ОШИБКА: Архив распаковался, но внутри нет файла 'sing-box'!"
    exit 1
fi

echo "[+] Файл найден: $BINARY_PATH"

echo "[*] Ставлю новый бинарник в $DEST_FILE..."
mv "$BINARY_PATH" "$DEST_FILE"

echo "[*] Даю права на запуск..."
chmod +x "$DEST_FILE"

echo "[*] Убираю за собой мусор (архив и распакованные папки)..."
cd /
rm -rf "$TMP_DIR"

echo "[+] Готово! Обновление установлено."
echo "--- Перезагружаюсь... ---"

reboot
