# vps-setup

Минималистичный скрипт развёртывания Xray VLESS+Reality на чистом Ubuntu 22.04/24.04.

## Что делает

- Ставит DNS 1.1.1.1 / 8.8.8.8 в systemd-resolved (битый DNS хостера даёт +4 с на каждое соединение)
- Устанавливает **Xray standalone** (без Docker) через официальный скрипт
- Копирует `config.json` из репозитория, проверяет, что dest отвечает TLS 1.3 + h2
- Выводит **VLESS ссылку на каждого клиента** (копия — `/root/xray-links.txt`)
- SSH → порт **2222** через `sshd_config.d/10-vps.conf` (работает и с `ssh.socket` в 24.04),
  отключает парольный вход (если есть ключи); старый порт закрывается, только если новый слушает
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

## Параметры

Переменные окружения (все необязательные):

| Переменная | По умолчанию | Что задаёт |
| --- | --- | --- |
| `CLIENTS` | `user1` | имена клиентов через пробел — у каждого свой UUID и ссылка |
| `SNI` | из `config.json` | сайт-маскировка (dest и serverNames) |
| `FP` | `firefox` | отпечаток TLS в ссылках (`chrome` режут чаще) |
| `SSH_PORT` | `2222` | порт SSH |

```bash
CLIENTS="egor anna petya" SNI="www.example.com" bash setup.sh
```

Порт 443 должен быть свободен — старый XRay (Amnezia и т.п.) удалить заранее.

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