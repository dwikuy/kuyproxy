#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   frpc_gen.sh — Generate frpc.toml otomatis
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"
CONFIG="$KUYDIR/config.cfg"
FRPC_TOML="$KUYDIR/frpc.toml"

cfg() { grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

generate() {
    local server_host; server_host=$(cfg FRP_SERVER_HOST)
    local server_port; server_port=$(cfg FRP_SERVER_PORT)
    local token;       token=$(cfg FRP_TOKEN)
    local name;        name=$(cfg CLIENT_NAME)
    local s5_port;     s5_port=$(cfg LOCAL_SOCKS_PORT)
    local http_port;   http_port=$(cfg LOCAL_HTTP_PORT)
    local api_port;    api_port=$(cfg LOCAL_API_PORT)
    local r_s5;        r_s5=$(cfg REMOTE_SOCKS_PORT)
    local r_http;      r_http=$(cfg REMOTE_HTTP_PORT)
    local r_api;       r_api=$(cfg REMOTE_API_PORT)

    # Defaults
    server_port=${server_port:-7000}
    name=${name:-kuyproxy01}
    s5_port=${s5_port:-1080}
    http_port=${http_port:-8118}
    api_port=${api_port:-8080}
    r_s5=${r_s5:-1080}
    r_http=${r_http:-8118}
    r_api=${r_api:-8080}

    # FRP v0.47+ menggunakan format TOML
    cat > "$FRPC_TOML" << EOF
# KuyProxy FRP Client Config (TOML format — v0.47+)
serverAddr = "${server_host}"
serverPort = ${server_port}
auth.method = "token"
auth.token  = "${token}"

log.to    = "${KUYDIR}/logs/frpc.log"
log.level = "info"

# Tunnel: SOCKS5
[[proxies]]
name       = "socks5_${name}"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = ${s5_port}
remotePort = ${r_s5}

# Tunnel: HTTP Proxy
[[proxies]]
name       = "http_${name}"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = ${http_port}
remotePort = ${r_http}

# Tunnel: API Server
[[proxies]]
name       = "api_${name}"
type       = "tcp"
localIP    = "127.0.0.1"
localPort  = ${api_port}
remotePort = ${r_api}
EOF

    echo "✅ frpc.toml generated:"
    echo "   Server: ${server_host}:${server_port}"
    echo "   SOCKS5: local:${s5_port} → VPS:${r_s5}"
    echo "   HTTP  : local:${http_port} → VPS:${r_http}"
    echo "   API   : local:${api_port} → VPS:${r_api}"
}

generate
