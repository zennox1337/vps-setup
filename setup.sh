#!/bin/bash
set -euo pipefail

# ─────────────────────────────────────────────────────────────────
#  VPS Setup Script
#  Xray VLESS+REALITY + MTProxy (telemt) + Monitoring stack
#  Ubuntu 22.04 / 24.04
# ─────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

DEPLOY_DIR="/home/deploy"
XRAY_IMAGE="ghcr.io/xtls/xray-core:latest"
MTPROXY_SECRET=""  # будет заполнено если найден telemt

log()     { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
info()    { echo -e "${CYAN}[i]${NC} $1"; }
section() { echo -e "\n${BOLD}${CYAN}━━━ $1 ━━━${NC}"; }

error() {
  echo -e "${RED}[✗] ОШИБКА: $1${NC}"
  echo -e "${RED}    Установка прервана на этом шаге.${NC}"
  exit 1
}

# ─── trap для читаемых ошибок ────────────────
trap 'error "Непредвиденная ошибка в строке $LINENO. Команда: $BASH_COMMAND"' ERR

# ═══════════════════════════════════════════════
#  ПРЕДВАРИТЕЛЬНЫЕ ПРОВЕРКИ
# ═══════════════════════════════════════════════
section "Предварительные проверки"

# Root
[ "$EUID" -ne 0 ] && error "Запусти от root: sudo bash setup.sh"

# Ubuntu
if ! grep -qi "ubuntu" /etc/os-release; then
  error "Скрипт поддерживает только Ubuntu"
fi
UBUNTU_VERSION=$(grep VERSION_ID /etc/os-release | cut -d'"' -f2)
if [[ "$UBUNTU_VERSION" != "22.04" && "$UBUNTU_VERSION" != "24.04" ]]; then
  warn "Версия Ubuntu ${UBUNTU_VERSION} не тестировалась. Рекомендуется 22.04 или 24.04."
fi
log "Ubuntu ${UBUNTU_VERSION} — OK"

# Определяем текущий SSH порт до любых изменений
CURRENT_SSH_PORT=$(ss -tlnp | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1)
CURRENT_SSH_PORT=${CURRENT_SSH_PORT:-22}
TARGET_SSH_PORT=2222
info "Текущий SSH порт: ${CURRENT_SSH_PORT}"

# Проверяем что SSH ключи есть ПЕРЕД отключением пароля
HAS_SSH_KEYS=false
if [ -s /home/deploy/.ssh/authorized_keys ] || [ -s /root/.ssh/authorized_keys ]; then
  HAS_SSH_KEYS=true
  log "SSH ключи найдены — парольный вход будет отключён"
else
  warn "SSH ключи НЕ найдены — парольный вход оставлен (добавь ключ потом!)"
fi

# ═══════════════════════════════════════════════
#  СИСТЕМНЫЕ ПАКЕТЫ
# ═══════════════════════════════════════════════
section "Системные пакеты"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq \
  curl wget ufw \
  htop ncdu tmux jq \
  openssl uuid-runtime \
  unattended-upgrades apt-transport-https \
  earlyoom \
  net-tools \
  mtr iotop \
  lsb-release gnupg2 \
  > /dev/null
log "Базовые пакеты установлены"

# ripgrep и bat — могут отсутствовать в старых репо
apt-get install -y -qq ripgrep bat 2>/dev/null || \
  warn "ripgrep/bat недоступны в репо — пропускаем"

# ═══════════════════════════════════════════════
#  DOCKER
# ═══════════════════════════════════════════════
section "Docker"
if ! command -v docker &>/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install -y -qq docker-ce docker-ce-cli containerd.io > /dev/null
  systemctl enable --now docker
  log "Docker установлен"
else
  log "Docker уже установлен: $(docker --version | cut -d' ' -f3 | tr -d ',')"
fi

# docker-compose
if ! command -v docker-compose &>/dev/null; then
  COMPOSE_URL="https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)"
  curl -fsSL "$COMPOSE_URL" -o /usr/local/bin/docker-compose
  chmod +x /usr/local/bin/docker-compose
  log "docker-compose установлен: $(docker-compose --version | cut -d' ' -f4)"
else
  log "docker-compose уже установлен"
fi

# ═══════════════════════════════════════════════
#  ПОЛЬЗОВАТЕЛЬ DEPLOY
# ═══════════════════════════════════════════════
section "Пользователь deploy"
if ! id deploy &>/dev/null; then
  useradd -m -s /bin/bash deploy
  usermod -aG sudo,docker deploy
  log "Пользователь deploy создан"
else
  usermod -aG docker deploy 2>/dev/null || true
  log "Пользователь deploy уже существует"
fi

# Копируем SSH ключи root → deploy если нужно
if [ -s /root/.ssh/authorized_keys ] && [ ! -s /home/deploy/.ssh/authorized_keys ]; then
  mkdir -p /home/deploy/.ssh
  cp /root/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
  chown -R deploy:deploy /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  chmod 600 /home/deploy/.ssh/authorized_keys
  log "SSH ключи скопированы root → deploy"
fi

# ═══════════════════════════════════════════════
#  СТРУКТУРА ПАПОК
# ═══════════════════════════════════════════════
section "Структура папок"
mkdir -p "${DEPLOY_DIR}"/{xray,monitoring,mtproxy/config}
# o+x нужен чтобы пользователь telemt мог входить в /home/deploy
chmod o+x "${DEPLOY_DIR}"
chown -R deploy:deploy "${DEPLOY_DIR}"
log "Структура создана: ${DEPLOY_DIR}/{xray,monitoring,mtproxy}"

# ═══════════════════════════════════════════════
#  ГЕНЕРАЦИЯ КЛЮЧЕЙ XRAY
# ═══════════════════════════════════════════════
section "Генерация ключей Xray"

# Тянем образ заранее чтобы отделить pull от генерации
docker pull -q "${XRAY_IMAGE}"

XRAY_KEYS=$(docker run --rm "${XRAY_IMAGE}" x25519)
PRIVATE_KEY=$(echo "$XRAY_KEYS" | grep -i "privatekey\|private key" | awk '{print $NF}')
PUBLIC_KEY=$(echo "$XRAY_KEYS"  | grep -i "password\|public key"    | awk '{print $NF}')

[ -z "$PRIVATE_KEY" ] && error "Не удалось сгенерировать приватный ключ Xray"
[ -z "$PUBLIC_KEY"  ] && error "Не удалось сгенерировать публичный ключ Xray"

UUID1=$(cat /proc/sys/kernel/random/uuid)
UUID2=$(cat /proc/sys/kernel/random/uuid)
SHORT_ID1=$(openssl rand -hex 4)
SHORT_ID2=$(openssl rand -hex 8)

log "Ключи сгенерированы"
log "UUID user1: ${UUID1}"
log "UUID user2: ${UUID2}"

# ═══════════════════════════════════════════════
#  КОНФИГ XRAY
# ═══════════════════════════════════════════════
section "Конфиг Xray"
cat > "${DEPLOY_DIR}/xray/config.json" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log"
  },
  "stats": {},
  "api": {
    "tag": "api",
    "services": ["StatsService"]
  },
  "dns": {
    "servers": ["1.1.1.1", "8.8.8.8"],
    "queryStrategy": "UseIPv4",
    "disableCache": false
  },
  "inbounds": [
    {
      "listen": "0.0.0.0",
      "port": 8443,
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID1}", "email": "user1" },
          { "id": "${UUID2}", "email": "user2" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.microsoft.com:443",
          "serverNames": ["www.microsoft.com", "microsoft.com"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID1}", "${SHORT_ID2}"],
          "maxTimeDiff": 60000
        },
        "xhttpSettings": {
          "path": "/api/v1/data",
          "mode": "auto",
          "extra": { "xPaddingBytes": "100-1000" }
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": 10085,
      "protocol": "dokodemo-door",
      "settings": { "address": "127.0.0.1" },
      "tag": "api"
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": { "domainStrategy": "UseIPv4" }
    },
    {
      "protocol": "blackhole",
      "tag": "block",
      "settings": { "response": { "type": "http" } }
    },
    { "protocol": "dns", "tag": "dns-out" }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "outboundTag": "dns-out", "network": "udp", "port": 53 },
      { "type": "field", "outboundTag": "block", "protocol": ["bittorrent"] },
      { "type": "field", "outboundTag": "block", "ip": ["geoip:private"] },
      { "type": "field", "outboundTag": "block", "domain": ["geosite:category-ads-all"] }
    ]
  },
  "policy": {
    "levels": {
      "0": {
        "handshake": 3,
        "connIdle": 180,
        "uplinkOnly": 2,
        "downlinkOnly": 5,
        "bufferSize": 512,
        "statsUserUplink": true,
        "statsUserDownlink": true
      }
    },
    "system": {
      "statsInboundUplink": true,
      "statsInboundDownlink": true,
      "statsOutboundUplink": true,
      "statsOutboundDownlink": true
    }
  }
}
EOF
log "xray/config.json создан"

# ═══════════════════════════════════════════════
#  PROMETHEUS CONFIG
# ═══════════════════════════════════════════════
section "Конфиг Prometheus"
cat > "${DEPLOY_DIR}/monitoring/prometheus.yml" <<'EOF'
global:
  scrape_interval: 15s
  scrape_timeout: 5s

scrape_configs:
  - job_name: 'xray'
    metrics_path: '/scrape'
    static_configs:
      - targets: ['localhost:9550']

  - job_name: 'node'
    static_configs:
      - targets: ['localhost:9100']
EOF
log "monitoring/prometheus.yml создан"

# ═══════════════════════════════════════════════
#  GRAFANA PASSWORD
# ═══════════════════════════════════════════════
GRAFANA_PASSWORD=$(openssl rand -base64 16 | tr -d '/+=')

# ═══════════════════════════════════════════════
#  DOCKER-COMPOSE
# ═══════════════════════════════════════════════
section "docker-compose.yml"
cat > "${DEPLOY_DIR}/docker-compose.yml" <<EOF
services:

  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray
    restart: unless-stopped
    user: "65532"
    command: ["-confdir", "/usr/local/etc/xray/"]
    ports:
      - "0.0.0.0:8443:8443"
      - "127.0.0.1:10085:10085"
    volumes:
      - ./xray:/usr/local/etc/xray
      - xray_logs:/var/log/xray
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

  xray-exporter:
    image: anatolykopyl/xray-exporter:latest
    container_name: xray-exporter
    restart: always
    command: ["-e", "127.0.0.1:10085"]
    network_mode: "host"
    depends_on:
      - xray

  prometheus:
    image: prom/prometheus:latest
    container_name: prometheus
    restart: always
    network_mode: "host"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml
      - prometheus_data:/prometheus
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.retention.time=30d'

  node-exporter:
    image: prom/node-exporter:latest
    container_name: node-exporter
    restart: always
    network_mode: "host"
    pid: "host"
    volumes:
      - /proc:/host/proc:ro
      - /sys:/host/sys:ro
      - /:/rootfs:ro
    command:
      - '--path.procfs=/host/proc'
      - '--path.sysfs=/host/sys'
      - '--collector.filesystem.mount-points-exclude=^/(sys|proc|dev|host|etc)(\$\$|/)'

  grafana:
    image: grafana/grafana:latest
    container_name: grafana
    restart: always
    network_mode: "host"
    environment:
      - GF_SERVER_HTTP_PORT=3000
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
    volumes:
      - grafana_data:/var/lib/grafana

volumes:
  xray_logs:
  prometheus_data:
  grafana_data:
EOF
chown deploy:deploy "${DEPLOY_DIR}/docker-compose.yml"
log "docker-compose.yml создан"

# ═══════════════════════════════════════════════
#  MTPROXY / TELEMT
# ═══════════════════════════════════════════════
section "MTProxy (telemt)"
if ! command -v telemt &>/dev/null; then
  warn "telemt не найден — пропускаем MTProxy"
  warn "Установи telemt вручную и перезапусти скрипт, или настрой сервис отдельно"
  warn "Релизы: https://github.com/luckytea/telemt/releases"
  MTPROXY_SECRET="(telemt не установлен)"
else
  MTPROXY_SECRET=$(openssl rand -hex 16)

  cat > "${DEPLOY_DIR}/mtproxy/config/telemt.toml" <<EOF
[general]
use_middle_proxy = false

[general.modes]
classic = false
secure = true
tls = false

[server.api]
enabled = false

[access.users]
user1 = "${MTPROXY_SECRET}"

[server]
port = 4430
EOF

  # Пользователь telemt
  if ! id telemt &>/dev/null; then
    useradd -r -s /sbin/nologin telemt
  fi
  chown -R telemt:telemt "${DEPLOY_DIR}/mtproxy"

  cat > /etc/systemd/system/telemt.service <<EOF
[Unit]
Description=Telemt MTProxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=telemt
Group=telemt
WorkingDirectory=${DEPLOY_DIR}/mtproxy
ExecStart=/usr/local/bin/telemt ${DEPLOY_DIR}/mtproxy/config/telemt.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now telemt
  log "telemt настроен и запущен"
fi

# ═══════════════════════════════════════════════
#  FIREWALL (UFW)
# ═══════════════════════════════════════════════
section "Firewall (ufw)"

# Сначала добавляем новый SSH порт, ПОТОМ сбрасываем и включаем
# чтобы не потерять доступ
ufw --force reset > /dev/null

ufw default deny incoming  > /dev/null
ufw default allow outgoing > /dev/null

# Открываем текущий SSH порт (на случай если уже не 22)
if [ "$CURRENT_SSH_PORT" != "$TARGET_SSH_PORT" ]; then
  ufw allow "${CURRENT_SSH_PORT}/tcp" comment "SSH (текущий, временно)" > /dev/null
fi
ufw allow "${TARGET_SSH_PORT}/tcp" comment "SSH" > /dev/null

# Xray — публичный порт
ufw allow 8443/tcp comment "Xray VLESS" > /dev/null

# MTProxy — только если telemt установлен
if command -v telemt &>/dev/null; then
  ufw allow 4430/tcp comment "MTProxy" > /dev/null
fi

# Мониторинг — только локально (через Tailscale)
ufw deny 3000  > /dev/null
ufw deny 9090  > /dev/null
ufw deny 9550  > /dev/null
ufw deny 9100  > /dev/null

ufw --force enable > /dev/null
log "ufw настроен"

# ═══════════════════════════════════════════════
#  SSH HARDENING
# ═══════════════════════════════════════════════
section "SSH hardening"
SSH_CONFIG="/etc/ssh/sshd_config"

# Порт
sed -i "s/^#\?Port.*/Port ${TARGET_SSH_PORT}/" "${SSH_CONFIG}"
log "SSH порт → ${TARGET_SSH_PORT}"

# Отключаем пароль только если есть ключи
if [ "$HAS_SSH_KEYS" = true ]; then
  sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' "${SSH_CONFIG}"
  sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' "${SSH_CONFIG}"
  log "SSH: парольный вход отключён"
fi

# Прочие параметры
sed -i 's/^#\?MaxAuthTries.*/MaxAuthTries 3/'       "${SSH_CONFIG}"
sed -i 's/^#\?LoginGraceTime.*/LoginGraceTime 20/'  "${SSH_CONFIG}"
sed -i 's/^#\?X11Forwarding.*/X11Forwarding no/'    "${SSH_CONFIG}"
sed -i 's/^#\?AllowAgentForwarding.*/AllowAgentForwarding no/' "${SSH_CONFIG}"

systemctl reload sshd
log "SSH hardening применён"

# Убираем временное правило старого порта
if [ "$CURRENT_SSH_PORT" != "$TARGET_SSH_PORT" ]; then
  ufw delete allow "${CURRENT_SSH_PORT}/tcp" > /dev/null 2>&1 || true
  log "Старый SSH порт ${CURRENT_SSH_PORT} закрыт в ufw"
fi

# ═══════════════════════════════════════════════
#  FAIL2BAN
# ═══════════════════════════════════════════════
section "fail2ban"
apt-get install -y -qq fail2ban > /dev/null

cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ${TARGET_SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

systemctl enable --now fail2ban > /dev/null
log "fail2ban настроен (SSH порт ${TARGET_SSH_PORT}, бан 24h после 3 попыток)"

# ═══════════════════════════════════════════════
#  CROWDSEC
# ═══════════════════════════════════════════════
section "CrowdSec"
if ! command -v cscli &>/dev/null; then
  curl -s https://packagecloud.io/install/repositories/crowdsec/crowdsec/script.deb.sh | bash > /dev/null 2>&1
  apt-get install -y -qq crowdsec crowdsec-firewall-bouncer-nftables > /dev/null

  # Даём CrowdSec время запуститься
  sleep 3

  # Генерируем API ключ для bouncer вручную
  BOUNCER_KEY=$(cscli bouncers add crowdsec-firewall-bouncer -o raw 2>/dev/null || echo "")
  if [ -n "$BOUNCER_KEY" ]; then
    sed -i "s/^api_key:.*/api_key: ${BOUNCER_KEY}/" \
      /etc/crowdsec/bouncers/crowdsec-firewall-bouncer.yaml
    systemctl restart crowdsec-firewall-bouncer
    log "CrowdSec установлен и bouncer настроен"
  else
    warn "CrowdSec: не удалось сгенерировать API ключ для bouncer — настрой вручную"
  fi
else
  log "CrowdSec уже установлен"
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
#  SYSCTL ОПТИМИЗАЦИЯ
# ═══════════════════════════════════════════════
section "Оптимизация ядра (sysctl)"
cat > /etc/sysctl.d/99-vps.conf <<'EOF'
# ── TCP Congestion Control (BBR) ──────────────
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# ── Порты и очереди ───────────────────────────
net.ipv4.ip_local_port_range = 1024 65535
net.core.somaxconn = 65535
net.core.netdev_max_backlog = 16384

# ── TCP оптимизация ───────────────────────────
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 10
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1

# ── Буферы ────────────────────────────────────
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# ── Защита от атак ────────────────────────────
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.log_martians = 1

# ── Память ────────────────────────────────────
vm.swappiness = 10
vm.dirty_ratio = 60
vm.dirty_background_ratio = 2
vm.overcommit_memory = 1

# ── Файловые дескрипторы ──────────────────────
fs.file-max = 1000000
fs.inotify.max_user_watches = 524288
EOF
sysctl -p /etc/sysctl.d/99-vps.conf > /dev/null
log "sysctl параметры применены"

# ═══════════════════════════════════════════════
#  LIMITS
# ═══════════════════════════════════════════════
section "Системные лимиты"
cat >> /etc/security/limits.conf <<'EOF'

# VPS Setup — open file limits
* soft nofile 1000000
* hard nofile 1000000
* soft nproc  65535
* hard nproc  65535
root soft nofile 1000000
root hard nofile 1000000
EOF
log "limits.conf обновлён"

# systemd тоже нужно
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-limits.conf <<'EOF'
[Manager]
DefaultLimitNOFILE=1000000
EOF
log "systemd лимиты обновлены"

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
log "journald лимиты настроены"

# ═══════════════════════════════════════════════
#  DOCKER DAEMON
# ═══════════════════════════════════════════════
section "Docker daemon"
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'EOF'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
EOF
systemctl restart docker
# Ждём пока docker поднимется после рестарта
sleep 2
log "Docker daemon настроен"

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
#  EARLYOOM
# ═══════════════════════════════════════════════
section "earlyoom"
cat > /etc/default/earlyoom <<'EOF'
EARLYOOM_ARGS="-r 60 -m 5 -s 5"
EOF
systemctl enable --now earlyoom > /dev/null
log "earlyoom настроен"

# ═══════════════════════════════════════════════
#  ЗАПУСК КОНТЕЙНЕРОВ
# ═══════════════════════════════════════════════
section "Запуск сервисов (Docker)"
cd "${DEPLOY_DIR}"
docker-compose pull -q
docker-compose up -d
log "Все контейнеры запущены"

# Ждём пока xray поднимется
sleep 5

# Проверяем что всё живое
FAILED=()
for svc in xray xray-exporter prometheus node-exporter grafana; do
  STATUS=$(docker inspect --format='{{.State.Status}}' "$svc" 2>/dev/null || echo "missing")
  if [ "$STATUS" != "running" ]; then
    FAILED+=("$svc")
  fi
done
if [ ${#FAILED[@]} -gt 0 ]; then
  warn "Следующие контейнеры не запустились: ${FAILED[*]}"
  warn "Проверь логи: docker logs <имя>"
else
  log "Все контейнеры работают"
fi

# ═══════════════════════════════════════════════
#  ПОЛУЧАЕМ IP
# ═══════════════════════════════════════════════
SERVER_IP=$(curl -s --max-time 5 https://ifconfig.me \
         || curl -s --max-time 5 https://api.ipify.org \
         || echo "UNKNOWN")

# ═══════════════════════════════════════════════
#  СОХРАНЯЕМ CREDENTIALS
# ═══════════════════════════════════════════════
SUMMARY_FILE="${DEPLOY_DIR}/credentials.txt"
cat > "${SUMMARY_FILE}" <<EOF
═══════════════════════════════════════════════
  VPS Setup — $(date '+%Y-%m-%d %H:%M:%S %Z')
  Ubuntu ${UBUNTU_VERSION}
═══════════════════════════════════════════════

SERVER IP:   ${SERVER_IP}
SSH PORT:    ${TARGET_SSH_PORT}

─── XRAY VLESS+REALITY ─────────────────────────
Port:        8443
Path:        /api/v1/data
SNI:         www.microsoft.com
Network:     xhttp
Security:    reality
Mode:        auto

UUID user1:  ${UUID1}
UUID user2:  ${UUID2}
Public key:  ${PUBLIC_KEY}
Private key: ${PRIVATE_KEY}
Short ID 1:  ${SHORT_ID1}
Short ID 2:  ${SHORT_ID2}

─── MTPROXY (telemt) ────────────────────────────
Port:        4430
Secret:      ${MTPROXY_SECRET}
Link:        tg://proxy?server=${SERVER_IP}&port=4430&secret=dd${MTPROXY_SECRET}

─── GRAFANA ─────────────────────────────────────
URL:         http://<tailscale-ip>:3000
Login:       admin
Password:    ${GRAFANA_PASSWORD}

─── TAILSCALE ───────────────────────────────────
Установка:
  curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
После подключения Grafana доступна по Tailscale IP.

─── УПРАВЛЕНИЕ ──────────────────────────────────
  cd ${DEPLOY_DIR}
  docker-compose ps                     # статус
  docker-compose restart xray           # перезапустить xray
  docker-compose logs xray -f           # логи xray
  docker-compose pull && docker-compose up -d  # обновить образы
  sudo systemctl restart telemt         # перезапустить MTProxy
  sudo systemctl status telemt          # статус MTProxy

═══════════════════════════════════════════════
EOF
chmod 600 "${SUMMARY_FILE}"
chown deploy:deploy "${SUMMARY_FILE}"

# ═══════════════════════════════════════════════
#  ФИНАЛЬНЫЙ ВЫВОД
# ═══════════════════════════════════════════════
echo ""
echo -e "${BOLD}${GREEN}╔══════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${GREEN}║         ✅  Установка завершена!         ║${NC}"
echo -e "${BOLD}${GREEN}╚══════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Сервер:${NC}      ${SERVER_IP}"
echo -e "  ${BOLD}SSH порт:${NC}    ${TARGET_SSH_PORT}"
echo ""
echo -e "  ${BOLD}Xray VLESS+REALITY:${NC}"
echo -e "    Port:       8443"
echo -e "    UUID 1:     ${UUID1}"
echo -e "    UUID 2:     ${UUID2}"
echo -e "    Public key: ${PUBLIC_KEY}"
echo -e "    Short ID:   ${SHORT_ID1}"
echo ""
if command -v telemt &>/dev/null; then
  echo -e "  ${BOLD}MTProxy:${NC}"
  echo -e "    ${CYAN}tg://proxy?server=${SERVER_IP}&port=4430&secret=dd${MTPROXY_SECRET}${NC}"
  echo ""
fi
echo -e "  ${BOLD}Grafana:${NC}"
echo -e "    Пароль: ${YELLOW}${GRAFANA_PASSWORD}${NC}"
echo -e "    Доступна после подключения Tailscale"
echo ""
echo -e "  ${BOLD}Следующие шаги:${NC}"
echo -e "    1. Подключи Tailscale:"
echo -e "       ${YELLOW}curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up${NC}"
echo -e "    2. Открой Grafana: http://<tailscale-ip>:3000"
echo -e "    3. Импортируй дашборды: ID ${CYAN}23145${NC} (Xray) и ${CYAN}1860${NC} (Node)"
if ! command -v telemt &>/dev/null; then
  echo -e "    4. ${YELLOW}Установи telemt для MTProxy${NC}"
  echo -e "       https://github.com/luckytea/telemt/releases"
fi
echo ""
echo -e "  📄 Все данные: ${BOLD}${SUMMARY_FILE}${NC}"
echo -e "${BOLD}${GREEN}══════════════════════════════════════════════${NC}"
echo ""
if [ "$HAS_SSH_KEYS" = false ]; then
  echo -e "${YELLOW}⚠️  ВАЖНО: добавь SSH ключ в authorized_keys!${NC}"
  echo -e "${YELLOW}   Без этого при потере пароля потеряешь доступ.${NC}"
  echo ""
fi
warn "Переподключись по SSH на порт ${TARGET_SSH_PORT}: ssh -p ${TARGET_SSH_PORT} deploy@${SERVER_IP}"