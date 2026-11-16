#!/bin/sh
# ============================================================
# SOCKS5 一键安装 · gost v3 单进程版
# 支持 Alpine(OpenRC) / Debian·Ubuntu(systemd)
# 单端口同时承载 TCP 与 UDP，强制账号密码认证
# 开机自启 + 每小时自检
#
# 用法：
#   sh socks.sh              安装 / 重装（保留原账号密码）
#   sh socks.sh --rotate     安装并重置账号密码
#   sh socks.sh --status     查看当前状态与内存占用
#   PORT=1080 sh socks.sh    跳过交互，直接指定端口
# ============================================================

set -e

SCRIPT_VERSION="2.0.0"
GOST_VERSION="3.3.3"
GOST_REPO="go-gost/gost"

CONF_DIR="/etc/gost"
ENV_FILE="${CONF_DIR}/gost.env"
CONF_FILE="${CONF_DIR}/config.yaml"
GOST_BIN="/usr/local/bin/gost"
SERVICE="gost"
WATCHDOG="/usr/local/bin/socks5-watchdog.sh"
CRON_MARK="# SOCKS5_WATCHDOG"

DEFAULT_PORT="1080"
GOMEMLIMIT="64MiB"
UDP_BUFSIZE="8192"
OLD_ENV_FILE="/etc/socks5-proxy.env"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err()  { printf '[ERR ] %s\n' "$*" >&2; }
exists() { command -v "$1" >/dev/null 2>&1; }

usage() {
  cat <<EOF
SOCKS5 一键安装（gost v${GOST_VERSION} · 单端口 TCP+UDP）  v${SCRIPT_VERSION}

  sh $0              安装或重装，保留已有账号密码
  sh $0 --rotate     安装并重置账号密码
  sh $0 --status     查看服务状态、监听端口与内存占用
  sh $0 --help       显示本帮助

环境变量：
  PORT=<端口>        跳过交互提示，直接使用指定端口
  GOST_ARCH=<架构>   强制指定架构（amd64 / arm64 / amd64v3 ...）
  GOST_URL=<前缀>    使用镜像下载，前缀需能拼出
                     <前缀>/gost_${GOST_VERSION}_linux_<架构>.tar.gz

装好后记得在云厂商安全组放行该端口的 TCP 与 UDP。
EOF
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "请以 root 权限运行。"
    exit 1
  fi
}

# ========================= 环境识别 =========================
detect_os() {
  OS_FAMILY=""
  INIT_SYSTEM=""
  if [ -f /etc/os-release ]; then . /etc/os-release; fi

  case "${ID:-}" in
    alpine) OS_FAMILY="alpine" ;;
    debian|ubuntu) OS_FAMILY="debian" ;;
    *) : ;;
  esac

  if [ -z "$OS_FAMILY" ] && [ -n "${ID_LIKE:-}" ]; then
    case "$ID_LIKE" in
      *alpine*) OS_FAMILY="alpine" ;;
      *debian*|*ubuntu*) OS_FAMILY="debian" ;;
    esac
  fi

  if [ "$OS_FAMILY" = "alpine" ]; then
    INIT_SYSTEM="openrc"
  elif exists systemctl; then
    INIT_SYSTEM="systemd"
    if [ -z "$OS_FAMILY" ]; then OS_FAMILY="debian"; fi
  else
    INIT_SYSTEM="openrc"
    if [ -z "$OS_FAMILY" ]; then OS_FAMILY="alpine"; fi
    warn "未检测到 systemd，将按 OpenRC 方式处理。"
  fi
}

detect_arch() {
  if [ -n "${GOST_ARCH:-}" ]; then
    ARCH="$GOST_ARCH"
    log "使用指定架构：${ARCH}"
    return 0
  fi
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)        ARCH="amd64" ;;
    aarch64|arm64)       ARCH="arm64" ;;
    armv7l|armv7|armhf)  ARCH="armv7" ;;
    armv6l)              ARCH="armv6" ;;
    armv5l)              ARCH="armv5" ;;
    i386|i486|i586|i686) ARCH="386" ;;
    riscv64)             ARCH="riscv64" ;;
    loongarch64|loong64) ARCH="loong64" ;;
    s390x)               ARCH="s390x" ;;
    *)
      err "无法自动识别架构：$m"
      err "请手动指定，例如：GOST_ARCH=amd64v3 sh $0"
      exit 1
      ;;
  esac
  log "架构：linux_${ARCH}"
}

install_deps() {
  if exists curl && exists tar && exists sha256sum; then
    return 0
  fi
  log "安装基础工具（curl, ca-certificates）..."
  if [ "$OS_FAMILY" = "alpine" ]; then
    apk update >/dev/null 2>&1 || true
    apk add --no-cache curl ca-certificates >/dev/null 2>&1 || true
  else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update >/dev/null 2>&1 || true
    apt-get install -y curl ca-certificates >/dev/null 2>&1 || true
  fi
  if ! exists curl; then
    err "curl 安装失败，无法继续。"
    exit 1
  fi
}

# ========================= 端口 =========================
prompt_port() {
  def="$DEFAULT_PORT"
  if [ -f "$ENV_FILE" ]; then
    old="$(sed -n 's/^PORT=//p' "$ENV_FILE" | head -n1)"
    if [ -n "$old" ]; then def="$old"; fi
  fi

  if [ -n "${PORT:-}" ]; then
    log "使用环境变量指定端口：${PORT}"
  else
    printf "请输入监听端口 [默认 %s]: " "$def"
    if [ -t 0 ]; then
      read -r PORT || PORT=""
    else
      PORT=""
    fi
    PORT="${PORT:-$def}"
  fi

  case "$PORT" in
    ''|*[!0-9]*) err "端口无效：$PORT"; exit 1;;
  esac
  if [ "$PORT" -lt 1 ] || [ "$PORT" -gt 65535 ]; then
    err "端口无效：$PORT"
    exit 1
  fi
}

port_occupied() {
  if exists ss; then
    ss -lntu 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  elif exists netstat; then
    netstat -lntu 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  else
    return 1
  fi
}

# ========================= 账号密码 =========================
gen_random() {
  LC_ALL=C tr -dc "$1" < /dev/urandom 2>/dev/null | head -c "$2" || true
}

load_credentials() {
  PROXY_USER=""
  PROXY_PASS=""
  if [ "${ROTATE:-0}" = "1" ]; then
    return 0
  fi
  if [ -f "$ENV_FILE" ]; then
    PROXY_USER="$(sed -n 's/^PROXY_USER=//p' "$ENV_FILE" | head -n1)"
    PROXY_PASS="$(sed -n 's/^PROXY_PASS=//p' "$ENV_FILE" | head -n1)"
    if [ -n "$PROXY_USER" ] && [ -n "$PROXY_PASS" ]; then
      log "复用已有账号：${PROXY_USER}"
      return 0
    fi
  fi
  PROXY_USER=""
  PROXY_PASS=""
}

gen_credentials() {
  if [ -n "${PROXY_USER:-}" ] && [ -n "${PROXY_PASS:-}" ]; then
    return 0
  fi

  i=0
  PROXY_USER=""
  while [ "$i" -lt 20 ]; do
    PROXY_USER="socks$(gen_random 'a-z0-9' 6)"
    if [ -n "$PROXY_USER" ]; then break; fi
    i=$((i + 1))
  done
  if [ -z "$PROXY_USER" ]; then
    err "生成用户名失败，请重试。"
    exit 1
  fi

  PROXY_PASS="$(gen_random 'A-Za-z0-9' 16)"
  if [ -z "$PROXY_PASS" ]; then
    err "生成密码失败，请重试。"
    exit 1
  fi
  log "已生成新账号：${PROXY_USER}"
}

# ========================= 下载 gost =========================
gost_version_now() {
  if [ ! -x "$GOST_BIN" ]; then
    printf ''
    return 0
  fi
  "$GOST_BIN" -V 2>/dev/null \
    | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' \
    | head -n1
}

download_gost() {
  cur="$(gost_version_now)"
  if [ "$cur" = "$GOST_VERSION" ]; then
    log "已安装 gost ${cur}，跳过下载。"
    return 0
  fi

  tarball="gost_${GOST_VERSION}_linux_${ARCH}.tar.gz"
  if [ -n "${GOST_URL:-}" ]; then
    base="${GOST_URL}"
  else
    base="https://github.com/${GOST_REPO}/releases/download/v${GOST_VERSION}"
  fi

  tmp="${TMPDIR:-/tmp}/gost-dl.$$"
  mkdir -p "$tmp"

  log "下载 ${tarball} ..."
  if ! curl -fsSL --retry 3 --connect-timeout 15 -o "${tmp}/${tarball}" "${base}/${tarball}"; then
    err "下载失败。"
    err "如果服务器无法访问 GitHub，可用 GOST_URL 指定镜像前缀，或手动把"
    err "${tarball} 放到 ${tmp} 后重跑。"
    return 1
  fi

  if curl -fsSL --retry 2 --connect-timeout 10 -o "${tmp}/checksums.txt" "${base}/checksums.txt" 2>/dev/null; then
    if ( cd "$tmp" && grep -F "$tarball" checksums.txt > sel.txt 2>/dev/null && sha256sum -c sel.txt >/dev/null 2>&1 ); then
      log "sha256 校验通过。"
    else
      err "sha256 校验失败，文件可能损坏或被篡改，已中止安装。"
      return 1
    fi
  else
    warn "未取到官方 checksums.txt，跳过校验（仅依靠 HTTPS 传输）。"
  fi

  if ! tar -xzf "${tmp}/${tarball}" -C "$tmp"; then
    err "解压失败。"
    return 1
  fi
  if [ ! -f "${tmp}/gost" ]; then
    err "压缩包内未找到 gost 可执行文件。"
    return 1
  fi

  install -m 0755 "${tmp}/gost" "$GOST_BIN"
  rm -rf "$tmp"
  log "已安装 ${GOST_BIN}（$("$GOST_BIN" -V 2>/dev/null | head -n1)）"
}

# ========================= 配置文件 =========================
write_config() {
  umask 077
  mkdir -p "$CONF_DIR"

  cat > "$CONF_FILE" <<EOF
log:
  level: warn

services:
  - name: socks5
    addr: ":${PORT}"
    handler:
      type: socks5
      auth:
        username: ${PROXY_USER}
        password: ${PROXY_PASS}
      metadata:
        udp: true
        udpBufferSize: ${UDP_BUFSIZE}
    listener:
      type: tcp
EOF
  chmod 600 "$CONF_FILE"

  cat > "$ENV_FILE" <<EOF
PORT=${PORT}
PROXY_USER=${PROXY_USER}
PROXY_PASS=${PROXY_PASS}
SERVICE_NAME=${SERVICE}
GOST_VERSION=${GOST_VERSION}
SCRIPT_VERSION=${SCRIPT_VERSION}
EOF
  chmod 600 "$ENV_FILE"
  umask 022

  log "配置已写入 ${CONF_FILE}（权限 600，仅 root 可读）。"
}

# ========================= 服务单元 =========================
write_unit_systemd() {
  cat > "/etc/systemd/system/${SERVICE}.service" <<EOF
[Unit]
Description=gost SOCKS5 proxy (TCP+UDP)
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
ExecStart=${GOST_BIN} -C ${CONF_FILE}
Environment=GOMEMLIMIT=${GOMEMLIMIT}
Restart=always
RestartSec=3
LimitNOFILE=65535
NoNewPrivileges=true
ProtectHome=true
PrivateTmp=true
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable "$SERVICE" >/dev/null 2>&1 || true
}

write_unit_openrc() {
  cat > "/etc/init.d/${SERVICE}" <<EOF
#!/sbin/openrc-run
description="gost SOCKS5 proxy (TCP+UDP)"
command="${GOST_BIN}"
command_args="-C ${CONF_FILE}"
command_background="yes"
pidfile="/run/${SERVICE}.pid"
command_user="root"
rc_ulimit="-n 65535"

export GOMEMLIMIT="${GOMEMLIMIT}"

depend() {
  need net
  after firewall
}
EOF
  chmod 0755 "/etc/init.d/${SERVICE}"
  rc-update add "$SERVICE" default >/dev/null 2>&1 || true
}

# ========================= 清理旧方案 =========================
migrate_old() {
  found=0
  for s in danted sockd microsocks; do
    if [ "$INIT_SYSTEM" = "systemd" ]; then
      if systemctl list-unit-files 2>/dev/null | grep -q "^${s}\.service" || [ -x "/etc/init.d/${s}" ]; then
        log "停用旧代理服务：${s}"
        systemctl disable --now "$s" >/dev/null 2>&1 || true
        found=1
      fi
    else
      if [ -x "/etc/init.d/${s}" ]; then
        log "停用旧代理服务：${s}"
        rc-service "$s" stop >/dev/null 2>&1 || true
        rc-update del "$s" default >/dev/null 2>&1 || true
        found=1
      fi
    fi
  done

  if [ -f "$OLD_ENV_FILE" ]; then
    log "移除旧版脚本的凭据文件 ${OLD_ENV_FILE}"
    rm -f "$OLD_ENV_FILE"
    found=1
  fi

  if [ "$found" -eq 1 ]; then
    warn "旧服务已停用但未卸载。确认新方案稳定后可自行清理，例如：apk del dante-server"
  fi
  return 0
}

# ========================= 启动与验证 =========================
restart_service() {
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    systemctl restart "$SERVICE" || true
  else
    rc-service "$SERVICE" restart >/dev/null 2>&1 \
      || rc-service "$SERVICE" start >/dev/null 2>&1 || true
  fi
}

tcp_listening() {
  if exists ss; then
    ss -lnt 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  elif exists netstat; then
    netstat -lnt 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  else
    return 0
  fi
}

udp_listening() {
  if exists ss; then
    ss -lnu 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  elif exists netstat; then
    netstat -lnu 2>/dev/null | grep -qE "[:.]${PORT}[[:space:]]"
  else
    return 0
  fi
}

internet_ok() {
  curl -fsS --max-time 6 -o /dev/null http://api.ipify.org 2>/dev/null
}

proxy_auth_ok() {
  curl -fsS --max-time 8 --socks5-hostname "127.0.0.1:${PORT}" \
    --proxy-user "${PROXY_USER}:${PROXY_PASS}" -o /dev/null http://api.ipify.org 2>/dev/null
}

proxy_open() {
  curl -fsS --max-time 8 --socks5-hostname "127.0.0.1:${PORT}" \
    -o /dev/null http://api.ipify.org 2>/dev/null
}

verify_proxy() {
  i=0
  while [ "$i" -lt 15 ]; do
    if tcp_listening; then break; fi
    i=$((i + 1))
    if [ "$i" -lt 15 ]; then sleep 2; fi
  done
  if ! tcp_listening; then
    err "TCP ${PORT} 没有监听，服务未正常启动。"
    err "排查：journalctl -u ${SERVICE} -n 50   或   tail -n 50 /var/log/messages"
    return 1
  fi
  log "TCP ${PORT} 已监听。"

  if udp_listening; then
    log "UDP ${PORT} 已监听，SOCKS5 UDP 中继就绪。"
  else
    warn "UDP ${PORT} 未监听 —— UDP 业务会失败，请检查配置里的 udp: true。"
  fi

  if ! exists curl; then
    warn "未找到 curl，跳过认证连通性验证。"
    return 0
  fi
  if ! internet_ok; then
    warn "服务器本身无法直连外网，跳过联网验证（端口已在监听）。请在客户端实测。"
    return 0
  fi

  ok=0
  i=0
  while [ "$i" -lt 5 ]; do
    if proxy_auth_ok; then ok=1; break; fi
    i=$((i + 1))
    if [ "$i" -lt 5 ]; then sleep 2; fi
  done
  if [ "$ok" -ne 1 ]; then
    err "带账号密码的连接测试失败。"
    return 1
  fi

  if proxy_open; then
    err "未携带账号密码的请求也成功了，认证未生效！"
    return 1
  fi

  log "验证通过：带账号密码可连通，不带账号密码被拒绝。"
  return 0
}

# ========================= Watchdog =========================
write_watchdog() {
  cat > "$WATCHDOG" <<'EOF'
#!/bin/sh
# 由 socks5-watchdog.timer / crond 调用：确保 gost 在跑
SERVICE="gost"
[ -f /etc/gost/gost.env ] && . /etc/gost/gost.env

if command -v systemctl >/dev/null 2>&1; then
  systemctl is-active --quiet "$SERVICE" || systemctl restart "$SERVICE" >/dev/null 2>&1 || true
else
  rc-service "$SERVICE" status >/dev/null 2>&1 || rc-service "$SERVICE" restart >/dev/null 2>&1 || true
fi
exit 0
EOF
  chmod 0755 "$WATCHDOG"
}

setup_watchdog_systemd() {
  cat > "/etc/systemd/system/socks5-watchdog.service" <<EOF
[Unit]
Description=SOCKS5 watchdog (ensure gost is running)

[Service]
Type=oneshot
ExecStart=${WATCHDOG}
EOF

  cat > "/etc/systemd/system/socks5-watchdog.timer" <<'EOF'
[Unit]
Description=Run SOCKS5 watchdog hourly

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now socks5-watchdog.timer >/dev/null 2>&1 || true
  log "已启用每小时自检（systemd timer）。"
}

setup_watchdog_openrc() {
  rc-update add crond default >/dev/null 2>&1 || true
  rc-service crond start >/dev/null 2>&1 || true

  CRON_FILE="/etc/crontabs/root"
  mkdir -p /etc/crontabs
  touch "$CRON_FILE"
  grep -v "$CRON_MARK" "$CRON_FILE" > "${CRON_FILE}.new" 2>/dev/null || true
  mv "${CRON_FILE}.new" "$CRON_FILE"
  echo "0 * * * * ${WATCHDOG} >/dev/null 2>&1 ${CRON_MARK}" >> "$CRON_FILE"
  chown root:root "$CRON_FILE" 2>/dev/null || true
  chmod 600 "$CRON_FILE"
  rc-service crond restart >/dev/null 2>&1 || true
  log "已启用每小时自检（crond + root crontab）。"
}

# ========================= 公网 IP =========================
get_default_iface() {
  ip -4 route show default 2>/dev/null | awk '{print $5; exit}'
}

get_public_ip() {
  ip="$(curl -fsSL --max-time 8 https://api.ipify.org 2>/dev/null || true)"
  if [ -z "$ip" ]; then
    ip="$(curl -fsSL --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  fi
  if [ -z "$ip" ] && exists dig; then
    ip="$(dig -4 +short myip.opendns.com @resolver1.opendns.com 2>/dev/null || true)"
  fi
  if [ -z "$ip" ]; then
    IFACE="$(get_default_iface)"
    if [ -n "$IFACE" ]; then
      ip="$(ip -4 -o addr show "$IFACE" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n1)"
    fi
  fi
  printf '%s' "$ip"
}

# ========================= 状态查看 =========================
show_status() {
  if [ ! -f "$ENV_FILE" ]; then
    err "未发现安装记录（${ENV_FILE} 不存在），请先运行安装。"
    exit 1
  fi
  . "$ENV_FILE"

  active="未知"
  if [ "$INIT_SYSTEM" = "systemd" ]; then
    active="$(systemctl is-active "$SERVICE" 2>/dev/null || true)"
  else
    if rc-service "$SERVICE" status >/dev/null 2>&1; then active="active"; else active="inactive"; fi
  fi
  if [ -z "$active" ]; then active="inactive"; fi

  pid=""
  if [ -f "/run/${SERVICE}.pid" ]; then
    pid="$(cat "/run/${SERVICE}.pid" 2>/dev/null || true)"
  fi
  if [ -z "$pid" ] && exists pgrep; then
    pid="$(pgrep -x gost 2>/dev/null | head -n1 || true)"
  fi

  rss="未知"
  if [ -n "$pid" ] && [ -f "/proc/${pid}/status" ]; then
    rss_kb="$(awk '/^VmRSS:/{print $2}' "/proc/${pid}/status" 2>/dev/null || true)"
    if [ -n "$rss_kb" ]; then rss="$((rss_kb / 1024)) MB"; fi
  fi

  tcp_state="未监听"
  if tcp_listening; then tcp_state="监听中"; fi
  udp_state="未监听"
  if udp_listening; then udp_state="监听中"; fi

  conns="-"
  if exists ss; then
    conns="$(ss -tn 2>/dev/null | grep -c "[:.]${PORT}[[:space:]]" || true)"
    if [ -z "$conns" ]; then conns="-"; fi
  fi

  binver="$(gost_version_now)"
  if [ -z "$binver" ]; then binver="未安装"; fi

  echo
  echo "=================================================="
  echo " SOCKS5 状态（脚本 v${SCRIPT_VERSION:-?}）"
  echo "=================================================="
  printf ' 服务      : %s\n' "$active"
  printf ' 程序      : gost %s\n' "$binver"
  printf ' 端口      : %s\n' "$PORT"
  printf ' TCP       : %s\n' "$tcp_state"
  printf ' UDP       : %s\n' "$udp_state"
  printf ' 当前连接  : %s 条\n' "$conns"
  printf ' 内存占用  : %s（RSS）\n' "$rss"
  printf ' 配置文件  : %s\n' "$CONF_FILE"
  printf ' 用户名    : %s\n' "$PROXY_USER"
  printf ' 密码      : %s\n' "$PROXY_PASS"
  printf ' 一键链接  : socks5://%s:%s@%s:%s\n' "$PROXY_USER" "$PROXY_PASS" "$(get_public_ip)" "$PORT"
  echo "=================================================="
  echo
}

# ========================= 结果输出 =========================
print_result() {
  ip="$(get_public_ip)"
  if [ -z "$ip" ]; then
    warn "未能自动获取公网 IP，请手动替换下列结果中的 IP。"
    ip="YOUR_SERVER_IP"
  fi
  echo
  echo "=================================================="
  echo "安装完成！SOCKS5 代理（gost v${GOST_VERSION}，TCP + UDP）"
  echo "  地址     : $ip"
  echo "  端口     : $PORT"
  echo "  用户名   : $PROXY_USER"
  echo "  密码     : $PROXY_PASS"
  echo
  echo "  一键链接 : socks5://${PROXY_USER}:${PROXY_PASS}@${ip}:${PORT}"
  echo "=================================================="
  echo "账号密码保存在 ${ENV_FILE}（权限 600，仅 root 可读）。"
  echo "重跑本脚本会沿用这套凭据；要换密码请用 --rotate。"
  echo
  echo "【必做】云厂商安全组放行 TCP ${PORT} 和 UDP ${PORT}。"
  echo "        只放 TCP 的话，普通网页代理能用，但 UDP 业务会失败。"
  echo
  echo "查看状态：sh $0 --status"
}

# ========================= 主流程 =========================
ACTION="install"
ROTATE=0
for arg in "$@"; do
  case "$arg" in
    --status|-s) ACTION="status" ;;
    --rotate|-r) ROTATE=1 ;;
    --help|-h) usage; exit 0 ;;
    *) err "未知参数：$arg"; usage; exit 1 ;;
  esac
done

need_root
detect_os

if [ "$ACTION" = "status" ]; then
  show_status
  exit 0
fi

detect_arch
install_deps
prompt_port
load_credentials
gen_credentials
download_gost

# 下载成功后再停旧服务，避免中途失败导致原有代理不可用
migrate_old

if port_occupied; then
  # 旧服务刚停下时端口可能还没释放，给几秒缓冲再判一次
  w=0
  while [ "$w" -lt 5 ]; do
    sleep 1
    if ! port_occupied; then break; fi
    w=$((w + 1))
  done
fi

if port_occupied; then
  err "端口 ${PORT} 仍被占用，无法启动。"
  warn "用 ss -lntup | grep ${PORT} 查看是谁占着，换个端口或先停掉它。"
  exit 1
fi

write_config
if [ "$INIT_SYSTEM" = "systemd" ]; then
  write_unit_systemd
else
  write_unit_openrc
fi

log "启动服务 ${SERVICE} ..."
restart_service

if ! verify_proxy; then
  warn "自动验证未通过。若服务器本身没有外网出口，属正常现象，请在客户端实测。"
fi

write_watchdog
if [ "$INIT_SYSTEM" = "systemd" ]; then
  setup_watchdog_systemd
else
  setup_watchdog_openrc
fi

print_result
