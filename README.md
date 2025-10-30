# OpenWRT-sing-box-extended
Скрипт для установки sing-box-extended вместо стандартного sing-box (для OpenWRT и ему подобных)

Этот `sh`-скрипт предназначен для автоматического обновления бинарного файла `sing-box` на роутерах OpenWrt. Он использует форк [shtorm-7/sing-box-extended](https://github.com/shtorm-7/sing-box-extended).

Скрипт **автоматически находит последний релиз** на GitHub, выбирает архив для нужной архитектуры, скачивает его и заменяет существующий бинарный файл `/usr/bin/sing-box`.

# Установка

Для установки и обновления используем команду
```
sh <(wget -O - https://raw.githubusercontent.com/EikeiDev/OpenWRT-sing-box-extended/refs/heads/main/install.sh)
```

### Что делает скрипт

Обновляет sing-box на sing-box-extended путем замены файла.

-----

# Благодарности / Thanks

https://github.com/shtorm-7/sing-box-extended
