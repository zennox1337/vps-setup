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
NEW_UUID=$(xray uuid)
KEYPAIR=$(xray x25519)
NEW_PRIV=$(echo "$KEYPAIR" | awk '/PrivateKey:/             {print $NF}')
NEW_PUB=$(echo  "$KEYPAIR" | awk '/Password \(PublicKey\):/ {print $NF}')
NEW_SID=$(openssl rand -hex 4)   # 8 символов, как твой первый
log "UUID и ключевая пара сгенерированы"

# Патчим конфиг и кладём сразу в xray
jq \
  --arg uuid "$NEW_UUID" \
  --arg priv "$NEW_PRIV" \
  --arg sid  "$NEW_SID"  \
  '.inbounds[0].settings.clients[0].id                          = $uuid |
   .inbounds[0].streamSettings.realitySettings.privateKey      = $priv |
   .inbounds[0].streamSettings.realitySettings.shortIds        = [$sid]' \
  "$CONFIG_SRC" > /usr/local/etc/xray/config.json
log "config.json записан (ключи подставлены)"

curl -fsSL "https://github.com/runetfreedom/russia-v2ray-rules-dat/raw/release/geosite.dat" \
  -o /usr/local/share/xray/geosite.dat
log "geosite.dat загружен"

systemctl enable xray
systemctl restart xray
sleep 1
systemctl is-active --quiet xray && log "Xray запущен" || error "Xray не запустился"

# ═══════════════════════════════════════════════
#  SSH HARDENING
# ═══════════════════════════════════════════════
section "SSH hardening"
TARGET_SSH_PORT=2222
CURRENT_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}

SSH_CONFIG="/etc/ssh/sshd_config"
sed -i "s/^#\?Port.*/Port ${TARGET_SSH_PORT}/"                  "$SSH_CONFIG"
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'                   "$SSH_CONFIG"
sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 20/'             "$SSH_CONFIG"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'               "$SSH_CONFIG"
sed -i 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding no/' "$SSH_CONFIG"

if [ -s /root/.ssh/authorized_keys ] || [ -s /home/deploy/.ssh/authorized_keys ]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/'       "$SSH_CONFIG"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/'      "$SSH_CONFIG"
  log "Парольный вход отключён (SSH ключи найдены)"
else
  warn "SSH ключи не найдены — парольный вход оставлен"
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
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
cat >> /etc/security/limits.conf <<'EOF'

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

UUID=$(jq -r     '.inbounds[0].settings.clients[0].id'                        /usr/local/etc/xray/config.json)
PORT=$(jq -r     '.inbounds[0].port'                                           /usr/local/etc/xray/config.json)
SNI=$(jq -r      '.inbounds[0].streamSettings.realitySettings.serverNames[0]' /usr/local/etc/xray/config.json)
SID="$NEW_SID"
PATH_URL=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path'             /usr/local/etc/xray/config.json)
MODE=$(jq -r     '.inbounds[0].streamSettings.xhttpSettings.mode'             /usr/local/etc/xray/config.json)

# Публичный ключ уже вычислен выше
ENCODED_PATH=$(python3 -c "import urllib.parse; print(urllib.parse.quote('${PATH_URL}'))")

VLESS_LINK="vless://${UUID}@${SERVER_IP}:${PORT}?encryption=none&security=reality&sni=${SNI}&fp=chrome&pbk=${NEW_PUB}&sid=${SID}&type=xhttp&path=${ENCODED_PATH}&mode=${MODE}#xray-reality"

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
echo -e "  ${BOLD}VLESS ссылка:${NC}"
echo -e "  ${CYAN}${VLESS_LINK}${NC}"
echo ""
warn "Переподключись: ssh -p ${TARGET_SSH_PORT} root@${SERVER_IP}"
