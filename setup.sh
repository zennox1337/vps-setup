#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  VPS Setup — Xray VLESS+Reality standalone
#  Ubuntu 22.04 / 24.04
# ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }
error()   { echo -e "${RED}[✗] $1${NC}"; exit 1; }

trap 'error "Ошибка в строке $LINENO: $BASH_COMMAND"' ERR

[ "$EUID" -ne 0 ] && error "Запусти от root: sudo bash setup.sh"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SRC="${SCRIPT_DIR}/config.json"
[ -f "$CONFIG_SRC" ] || error "config.json не найден рядом со скриптом"

# Параметры (переопределяются переменными окружения):
#   CLIENTS="egor anna petya" SNI="www.example.com" sudo -E bash setup.sh
CLIENTS="${CLIENTS:-user1}"     # имена клиентов через пробел — у каждого свой UUID и ссылка
SNI="${SNI:-}"                  # сайт-маскировка; пусто — из config.json
FP="${FP:-firefox}"             # отпечаток TLS в ссылках (chrome режут чаще)
TARGET_SSH_PORT="${SSH_PORT:-2222}"

if ss -Htln 'sport = :443' | grep -q .; then
  error "Порт 443 занят: $(ss -Htlnp 'sport = :443' | grep -o 'users:.*' | head -1). Удали старый XRay (Amnezia и т.п.)"
fi

# ═══════════════════════════════════════════════
#  DNS
# ═══════════════════════════════════════════════
# DNS от хостера бывает битым (нерабочий IPv6-сервер → таймаут ~4 с на каждый запрос,
# Reality резолвит dest на каждое соединение) — ставим свои серверы явно.
section "DNS"
if systemctl is-enabled --quiet systemd-resolved 2>/dev/null; then
  mkdir -p /etc/systemd/resolved.conf.d
  cat > /etc/systemd/resolved.conf.d/99-vps.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8
FallbackDNS=1.0.0.1 8.8.4.4
EOF
  systemctl restart systemd-resolved
fi
# Сразу после рестарта resolved первый запрос может не уложиться в таймаут — даём ~20 с
for i in 1 2 3 4; do
  timeout 5 getent ahostsv4 github.com > /dev/null && break
  [ "$i" -eq 4 ] && error "DNS не отвечает (getent github.com)"
  sleep 1
done
log "DNS: 1.1.1.1, 8.8.8.8"

# ═══════════════════════════════════════════════
#  ПАКЕТЫ
# ═══════════════════════════════════════════════
section "Системные пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl ufw jq openssl \
  earlyoom unattended-upgrades \
  fail2ban htop ncdu tmux mtr \
  > /dev/null
log "Пакеты установлены"

# ═══════════════════════════════════════════════
#  XRAY
# ═══════════════════════════════════════════════
section "Установка Xray"
bash -c "$(curl -sL https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
log "Xray $(xray version | head -1 | awk '{print $2}')"

section "Генерация ключей"
KEYPAIR=$(xray x25519)
NEW_PRIV=$(echo "$KEYPAIR" | awk '/PrivateKey:/             {print $NF}')
NEW_PUB=$(echo  "$KEYPAIR" | awk '/Password \(PublicKey\):/ {print $NF}')
[ -n "$NEW_PRIV" ] && [ -n "$NEW_PUB" ] || error "Не разобрал вывод xray x25519"
NEW_SID=$(openssl rand -hex 4)   # 8 символов, как твой первый

CLIENTS_JSON=$(for name in $CLIENTS; do
  jq -n --arg id "$(xray uuid)" --arg email "$name" '{id: $id, email: $email}'
done | jq -s .)
log "Ключевая пара и UUID для клиентов: ${CLIENTS}"

# Патчим конфиг и кладём сразу в xray
jq \
  --argjson clients "$CLIENTS_JSON" \
  --arg priv "$NEW_PRIV" \
  --arg sid  "$NEW_SID"  \
  --arg sni  "$SNI"      \
  '.inbounds[0].settings.clients                                = $clients |
   .inbounds[0].streamSettings.realitySettings.privateKey      = $priv |
   .inbounds[0].streamSettings.realitySettings.shortIds        = [$sid] |
   if $sni != "" then
     .inbounds[0].streamSettings.realitySettings.dest        = ($sni + ":443") |
     .inbounds[0].streamSettings.realitySettings.serverNames = [$sni]
   else . end' \
  "$CONFIG_SRC" > /usr/local/etc/xray/config.json
# Xray работает от пользователя xray (если он есть) — даём читать группе, остальным нет
if getent group xray > /dev/null; then
  chown root:xray /usr/local/etc/xray/config.json
  chmod 640 /usr/local/etc/xray/config.json
fi
log "config.json записан (ключи подставлены)"

# Маскировка работает, только если dest отвечает TLS 1.3 + HTTP/2
DEST=$(jq -r  '.inbounds[0].streamSettings.realitySettings.dest'           /usr/local/etc/xray/config.json)
SNI0=$(jq -r  '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
if timeout 10 openssl s_client -connect "$DEST" -servername "$SNI0" -tls1_3 -alpn h2 </dev/null 2>/dev/null \
     | grep -q 'ALPN protocol: h2'; then
  log "dest ${DEST}: TLS 1.3 + h2"
else
  warn "dest ${DEST} не отвечает TLS 1.3 + h2 — выбери другой SNI"
fi

systemctl enable xray
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && log "Xray запущен" || error "Xray не запустился"

# ═══════════════════════════════════════════════
#  SSH HARDENING
# ═══════════════════════════════════════════════
section "SSH hardening"
# awk дочитывает до конца: ранний exit даёт SIGPIPE у sshd и падение по pipefail
CURRENT_SSH_PORT=$(sshd -T 2>/dev/null | awk '/^port / && !p {p = $2} END {print p}' || true)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}

# Свой drop-in: sshd берёт первое значение, а sshd_config.d/*.conf читается раньше
# основного конфига, 10-* — раньше 50-cloud-init.conf. Port — исключение (копится),
# поэтому Port в основном конфиге комментируем.
SSH_CONFIG="/etc/ssh/sshd_config"
SSH_DROPIN="/etc/ssh/sshd_config.d/10-vps.conf"
sed -i 's/^Port /#Port /' "$SSH_CONFIG"
cat > "$SSH_DROPIN" <<EOF
Port ${TARGET_SSH_PORT}
MaxAuthTries 3
LoginGraceTime 20
X11Forwarding no
AllowAgentForwarding no
EOF

if [ -s /root/.ssh/authorized_keys ] || [ -s /home/deploy/.ssh/authorized_keys ]; then
  printf 'PasswordAuthentication no\nPermitRootLogin prohibit-password\n' >> "$SSH_DROPIN"
  log "Парольный вход отключён (SSH ключи найдены)"
else
  warn "SSH ключи не найдены — парольный вход оставлен"
fi

sshd -t || error "sshd -t: ошибка в конфиге SSH"

# Ubuntu 24.04: порт слушает ssh.socket (строится из sshd_config), 22.04 — сам sshd.
# Текущие сессии при перезапуске не рвутся.
if systemctl is-active --quiet ssh.socket 2>/dev/null; then
  systemctl daemon-reload
  systemctl restart ssh.socket
else
  systemctl restart ssh 2>/dev/null || systemctl restart sshd
fi
sleep 1
[ -n "$(ss -Htln "sport = :${TARGET_SSH_PORT}")" ] || error "SSH не слушает :${TARGET_SSH_PORT} — старый порт не закрываю"
log "SSH порт → ${TARGET_SSH_PORT}"

# ═══════════════════════════════════════════════
#  FIREWALL
# ═══════════════════════════════════════════════
section "Firewall (ufw)"
ufw --force reset > /dev/null
ufw default deny incoming  > /dev/null
ufw default allow outgoing > /dev/null
[ "$CURRENT_SSH_PORT" != "$TARGET_SSH_PORT" ] && \
  ufw allow "${CURRENT_SSH_PORT}/tcp" comment "SSH (старый, временно)" > /dev/null
ufw allow "${TARGET_SSH_PORT}/tcp" comment "SSH"  > /dev/null
ufw allow 443/tcp              comment "Xray"     > /dev/null
ufw --force enable > /dev/null
[ "$CURRENT_SSH_PORT" != "$TARGET_SSH_PORT" ] && \
  ufw delete allow "${CURRENT_SSH_PORT}/tcp" > /dev/null 2>&1 || true
log "ufw включён (SSH :${TARGET_SSH_PORT}, Xray :443)"

# ═══════════════════════════════════════════════
#  FAIL2BAN
# ═══════════════════════════════════════════════
section "fail2ban"
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 24h
findtime = 10m
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ${TARGET_SSH_PORT}
logpath  = %(sshd_log)s
EOF
systemctl enable --now fail2ban > /dev/null
log "fail2ban настроен (SSH :${TARGET_SSH_PORT}, бан 24h)"

# ═══════════════════════════════════════════════
#  SYSCTL
# ═══════════════════════════════════════════════
section "Оптимизация ядра (sysctl)"
cat > /etc/sysctl.d/99-vps.conf <<'EOF'
# BBR
net.core.default_qdisc          = fq
net.ipv4.tcp_congestion_control = bbr

# Очереди и порты
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn           = 65535
net.core.netdev_max_backlog  = 16384

# TCP
net.ipv4.tcp_tw_reuse              = 1
net.ipv4.tcp_fin_timeout           = 15
net.ipv4.tcp_keepalive_time        = 600
net.ipv4.tcp_keepalive_intvl       = 30
net.ipv4.tcp_keepalive_probes      = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing           = 1

# Буферы
net.core.rmem_max   = 16777216
net.core.wmem_max   = 16777216
net.ipv4.tcp_rmem   = 4096 87380 16777216
net.ipv4.tcp_wmem   = 4096 65536 16777216

# Защита
net.ipv4.tcp_syncookies              = 1
net.ipv4.tcp_max_syn_backlog         = 8192
net.ipv4.conf.all.rp_filter          = 1
net.ipv4.conf.default.rp_filter      = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects   = 0
net.ipv4.conf.all.send_redirects     = 0

# Память
vm.swappiness             = 10
vm.dirty_ratio            = 60
vm.dirty_background_ratio = 2
vm.overcommit_memory      = 1

# Дескрипторы
fs.file-max               = 1000000
fs.inotify.max_user_watches = 524288
EOF
sysctl -p /etc/sysctl.d/99-vps.conf > /dev/null
log "sysctl применён (BBR включён)"

# ═══════════════════════════════════════════════
#  LIMITS
# ═══════════════════════════════════════════════
section "Системные лимиты"
grep -q '^# vps-setup' /etc/security/limits.conf || cat >> /etc/security/limits.conf <<'EOF'

# vps-setup
* soft nofile 1000000
* hard nofile 1000000
* soft nproc  65535
* hard nproc  65535
root soft nofile 1000000
root hard nofile 1000000
EOF
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1000000
EOF
log "Лимиты обновлены"

# ═══════════════════════════════════════════════
#  JOURNALD
# ═══════════════════════════════════════════════
section "journald"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/99-limits.conf <<'EOF'
[Journal]
SystemMaxUse=200M
SystemKeepFree=500M
MaxRetentionSec=2week
RateLimitInterval=30s
RateLimitBurst=1000
EOF
systemctl restart systemd-journald
log "journald настроен"

# ═══════════════════════════════════════════════
#  EARLYOOM
# ═══════════════════════════════════════════════
section "earlyoom"
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 60 -m 5 -s 5"
EOF
systemctl enable --now earlyoom > /dev/null
log "earlyoom запущен"

# ═══════════════════════════════════════════════
#  ZRAM (только если RAM < 2GB)
# ═══════════════════════════════════════════════
section "zram"
TOTAL_RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
if [ "$TOTAL_RAM_KB" -lt 2097152 ]; then
  apt-get install -y -qq zram-config > /dev/null
  log "zram установлен (RAM < 2GB)"
else
  log "zram пропущен (RAM ≥ 2GB)"
fi

# ═══════════════════════════════════════════════
#  АВТООБНОВЛЕНИЯ
# ═══════════════════════════════════════════════
section "Автообновления безопасности"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
systemctl enable --now unattended-upgrades > /dev/null
log "Автообновления включены"

# ═══════════════════════════════════════════════
#  VLESS ССЫЛКА
# ═══════════════════════════════════════════════
section "VLESS ссылка"
SERVER_IP=$(curl -s4 --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

PORT=$(jq -r     '.inbounds[0].port'                                           /usr/local/etc/xray/config.json)
SNI=$(jq -r      '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
SID="$NEW_SID"
PATH_URL=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path'             /usr/local/etc/xray/config.json)
MODE=$(jq -r     '.inbounds[0].streamSettings.xhttpSettings.mode'             /usr/local/etc/xray/config.json)

# Публичный ключ уже вычислен выше
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PATH_URL}'))")

LINKS_FILE=/root/xray-links.txt
: > "$LINKS_FILE"; chmod 600 "$LINKS_FILE"
jq -r '.inbounds[0].settings.clients[] | "\(.email) \(.id)"' /usr/local/etc/xray/config.json |
while read -r NAME UUID; do
  echo "${NAME}: vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=${FP}&pbk=${NEW_PUB}&sid=${SID}&type=xhttp&path=${ENCODED_PATH}&mode=${MODE}#${NAME}" >> "$LINKS_FILE"
done

# ═══════════════════════════════════════════════
#  ИТОГ
# ═══════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ✅  Установка завершена!         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Сервер:${NC}    ${SERVER_IP}"
echo -e "  ${BOLD}SSH порт:${NC}  ${TARGET_SSH_PORT}"
echo ""
echo -e "  ${BOLD}VLESS ссылки (копия — ${LINKS_FILE}):${NC}"
while read -r LINE; do echo -e "  ${CYAN}${LINE}${NC}"; done < "$LINKS_FILE"
echo ""
warn "Переподключись: ssh -p ${TARGET_SSH_PORT} root@${SERVER_IP}"
