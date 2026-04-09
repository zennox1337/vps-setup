# vps-setup

Минималистичный скрипт развёртывания Xray VLESS+Reality на чистом Ubuntu 22.04/24.04.

## Что делает

- Устанавливает **Xray standalone** (без Docker) через официальный скрипт
- Копирует `config.json` из репозитория
- Загружает кастомный `geosite.dat` с российскими доменами
- Выводит готовую **VLESS ссылку** для клиента
- SSH → порт **2222**, отключает парольный вход (если есть ключи)
- ufw: открыт только 443 и 2222
- fail2ban: бан SSH после 3 попыток
- sysctl: BBR, оптимизация TCP/буферов
- earlyoom, zram (на серверах < 2GB RAM), автообновления безопасности

## Структура

```
vps-setup/
├── setup.sh      # скрипт установки
├── config.json   # конфиг Xray (редактируй под себя)
└── README.md
```

## Запуск на новом сервере

```bash
curl -fsSL https://raw.githubusercontent.com/zennox1337/vps-setup/master/setup.sh -o setup.sh
curl -fsSL https://raw.githubusercontent.com/zennox1337/vps-setup/master/config.json -o config.json
sudo bash setup.sh
```

Или одной строкой (клонирует репо):

```bash
git clone https://github.com/zennox1337/vps-setup && cd vps-setup && sudo bash setup.sh
```

## Конфиг

`config.json` можно оставить как есть — UUID и ключи x25519 **генерируются автоматически** при каждом запуске `setup.sh`.

Если хочешь поменять `dest`/`serverNames` (camouflage-домен) или `shortIds` — редактируй `config.json` до запуска.

## Управление

```bash
systemctl status xray          # статус
systemctl restart xray         # перезапуск
journalctl -u xray -f          # логи
nano /usr/local/etc/xray/config.json  # редактировать конфиг
```