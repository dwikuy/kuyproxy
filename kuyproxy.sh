#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   kuyproxy.sh — KuyProxy Main Controller
#   Termux entry point untuk semua operasi
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"
CONFIG="$KUYDIR/config.cfg"
BINDIR="$KUYDIR/bin"
LOGDIR="$KUYDIR/logs"

PID_PROXY="$KUYDIR/proxy.pid"
PID_API="$KUYDIR/api.pid"
PID_FRP="$KUYDIR/frpc.pid"

mkdir -p "$LOGDIR" "$BINDIR"

# ── Load config ───────────────────────────
cfg() { grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }
log() { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$LOGDIR/kuyproxy.log"; }

# ── Cek apakah proses running ─────────────
is_running() {
    local pid_file="$1"
    local pid
    pid=$(cat "$pid_file" 2>/dev/null)
    [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null
}

# ── Stop 1 service ────────────────────────
stop_pid() {
    local pid_file="$1" name="$2"
    if is_running "$pid_file"; then
        local pid; pid=$(cat "$pid_file")
        kill "$pid" 2>/dev/null
        sleep 1
        kill -9 "$pid" 2>/dev/null
        log "  Stopped $name (pid $pid)"
    fi
    rm -f "$pid_file"
}

# ── START ─────────────────────────────────
cmd_start() {
    log "═════════════════════════════════"
    log "  KuyProxy Starting..."
    log "═════════════════════════════════"

    # Cek sudah running
    if is_running "$PID_PROXY"; then
        log "⚠️  Already running (pid $(cat $PID_PROXY))"
        return 1
    fi

    # Setup IPv6 pool (tidak fatal jika gagal — fallback ke Single IP mode)
    log "📡 Setting up IPv6 pool..."
    bash "$KUYDIR/ip_manager.sh" setup
    if [ $? -ne 0 ]; then
        log "⚠️  IPv6 pool not available — continuing in Single IP mode"
    fi

    # Start SOCKS5 + HTTP proxy server
    log "🧦 Starting Proxy Server (SOCKS5 + HTTP)..."
    nohup python3 "$KUYDIR/proxy_server.py" \
        >> "$LOGDIR/proxy.log" 2>&1 &
    echo $! > "$PID_PROXY"
    log "  Proxy PID: $(cat $PID_PROXY)"
    sleep 1

    # Start API server
    log "🌐 Starting API Server..."
    nohup python3 "$KUYDIR/api_server.py" \
        >> "$LOGDIR/api.log" 2>&1 &
    echo $! > "$PID_API"
    log "  API PID: $(cat $PID_API)"
    sleep 1

    # Generate frpc.ini
    log "⚙️  Generating FRP config..."
    bash "$KUYDIR/frpc_gen.sh"

    # Start frpc dengan reconnect loop
    log "🚀 Starting FRP Client..."
    (
        while true; do
            "$BINDIR/frpc" -c "$KUYDIR/frpc.toml" >> "$LOGDIR/frpc.log" 2>&1
            log "⚠️  FRP disconnected, reconnecting in $(cfg RECONNECT_DELAY)s..."
            local delay; delay=$(cfg RECONNECT_DELAY); delay=${delay:-5}
            sleep "$delay"
        done
    ) &
    echo $! > "$PID_FRP"
    log "  FRP PID: $(cat $PID_FRP)"

    sleep 2
    log "═════════════════════════════════"
    log "✅ KuyProxy is RUNNING"
    local server_host; server_host=$(cfg FRP_SERVER_HOST)
    local r_s5; r_s5=$(cfg REMOTE_SOCKS_PORT); r_s5=${r_s5:-1080}
    local r_http; r_http=$(cfg REMOTE_HTTP_PORT); r_http=${r_http:-8118}
    log "  SOCKS5 : ${server_host}:${r_s5}"
    log "  HTTP   : ${server_host}:${r_http}"
    log "  User   : $(cfg SOCKS_USERNAME)1..N / $(cfg SOCKS_PASSWORD)"
    log "═════════════════════════════════"
}

# ── STOP ──────────────────────────────────
cmd_stop() {
    log "Stopping KuyProxy..."
    stop_pid "$PID_FRP"   "frpc"
    stop_pid "$PID_API"   "api_server"
    stop_pid "$PID_PROXY" "proxy_server"
    bash "$KUYDIR/ip_manager.sh" remove
    log "✅ Stopped"
}

# ── STATUS ────────────────────────────────
cmd_status() {
    echo "══════════════════════════════════"
    echo "  KuyProxy Status"
    echo "══════════════════════════════════"

    for svc in "Proxy:$PID_PROXY" "API:$PID_API" "FRP:$PID_FRP"; do
        local name pid_file
        IFS=":" read -r name pid_file <<< "$svc"
        if is_running "$pid_file"; then
            echo "  $name : 🟢 Running ($(cat $pid_file))"
        else
            echo "  $name : 🔴 Stopped"
        fi
    done

    local pool_count=0
    [ -f "$KUYDIR/added_ips.txt" ] && pool_count=$(wc -l < "$KUYDIR/added_ips.txt")
    echo "  IPv6 Pool: $pool_count IPs"

    local server_host; server_host=$(cfg FRP_SERVER_HOST)
    local r_s5; r_s5=$(cfg REMOTE_SOCKS_PORT)
    local r_http; r_http=$(cfg REMOTE_HTTP_PORT)
    echo "  SOCKS5   : ${server_host}:${r_s5:-1080}"
    echo "  HTTP     : ${server_host}:${r_http:-8118}"
    echo "══════════════════════════════════"
}

# ── ROTATE IP (user tertentu) ─────────────
cmd_rotate() {
    local user="${1:-1}"
    local idx=$((user - 1))
    log "🔄 Rotating IP for user$user (idx=$idx)..."
    bash "$KUYDIR/ip_manager.sh" rotate "$idx"
}

# ── RESET (airplane mode) ──────────────────
cmd_reset() {
    log "✈️  Triggering airplane mode reset..."
    bash "$KUYDIR/airplane.sh" rotate
}

# ── LOGS ─────────────────────────────────
cmd_logs() {
    local n="${1:-50}"
    tail -n "$n" "$LOGDIR/kuyproxy.log" "$LOGDIR/proxy.log" 2>/dev/null
}

# ── RESTART ───────────────────────────────
cmd_restart() {
    cmd_stop
    sleep 2
    cmd_start
}

# ── IPs ───────────────────────────────────
cmd_ips() {
    bash "$KUYDIR/ip_manager.sh" list
}

# ── CONFIG ────────────────────────────────
cmd_config() {
    "${EDITOR:-nano}" "$CONFIG"
}

# ── SETUP (pertama kali) ──────────────────
cmd_setup() {
    echo "KuyProxy Setup"
    echo "══════════════"

    # Install deps
    yes | pkg install python3 curl wget openssl-tool iproute2 nano 2>/dev/null

    # Buat direktori
    mkdir -p "$KUYDIR/bin" "$KUYDIR/logs"

    # Download frpc binary
    local arch; arch=$(uname -m)
    local frpc_url frp_dir
    FRP_VER="0.67.0"
    case "$arch" in
        aarch64)
            # HP Android ARM64 — gunakan versi android_arm64 khusus
            frpc_url="https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_android_arm64.tar.gz"
            frp_dir="frp_${FRP_VER}_android_arm64"
            ;;
        armv7l)
            frpc_url="https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_arm.tar.gz"
            frp_dir="frp_${FRP_VER}_linux_arm"
            ;;
        x86_64)
            frpc_url="https://github.com/fatedier/frp/releases/download/v${FRP_VER}/frp_${FRP_VER}_linux_amd64.tar.gz"
            frp_dir="frp_${FRP_VER}_linux_amd64"
            ;;
        *)       echo "❌ Arsitektur tidak dikenal: $arch"; return 1 ;;
    esac

    echo "📥 Downloading frpc v${FRP_VER} ($arch)..."
    local tmp; tmp=$(mktemp -d)
    wget -q "$frpc_url" -O "$tmp/frp.tar.gz"
    tar -xzf "$tmp/frp.tar.gz" -C "$tmp"
    cp "$tmp/${frp_dir}/frpc" "$BINDIR/frpc"
    chmod +x "$BINDIR/frpc"
    rm -rf "$tmp"
    echo "✅ frpc installed: $($BINDIR/frpc --version 2>&1 | head -1)"

    # Beri permission ke scripts
    chmod +x "$KUYDIR"/*.sh

    echo ""
    echo "✅ Setup selesai!"
    echo "   Edit config  : nano $CONFIG"
    echo "   Start proxy  : kuyproxy start"
}

# ── Main ─────────────────────────────────
case "${1:-help}" in
    start)   cmd_start ;;
    stop)    cmd_stop ;;
    restart) cmd_restart ;;
    status)  cmd_status ;;
    rotate)  cmd_rotate "${2:-1}" ;;
    reset)   cmd_reset ;;
    logs)    cmd_logs "${2:-50}" ;;
    ips)     cmd_ips ;;
    config)  cmd_config ;;
    setup)   cmd_setup ;;
    *)
        echo "KuyProxy v1.0 — Termux Proxy Controller"
        echo ""
        echo "Usage: kuyproxy <command>"
        echo ""
        echo "Commands:"
        printf "  %-12s %s\n" "start"   "Start semua service (proxy + api + frpc)"
        printf "  %-12s %s\n" "stop"    "Stop semua service"
        printf "  %-12s %s\n" "restart" "Restart semua service"
        printf "  %-12s %s\n" "status"  "Lihat status semua service"
        printf "  %-12s %s\n" "rotate [N]" "Rotate IP user ke-N (default: 1)"
        printf "  %-12s %s\n" "reset"   "Airplane mode reset (ganti IP semua)"
        printf "  %-12s %s\n" "logs [N]" "Lihat N baris log terakhir"
        printf "  %-12s %s\n" "ips"     "List IP pool saat ini"
        printf "  %-12s %s\n" "config"  "Edit konfigurasi"
        printf "  %-12s %s\n" "setup"   "Install deps & download frpc (pertama kali)"
        ;;
esac
