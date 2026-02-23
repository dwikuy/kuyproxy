#!/usr/bin/env python3
"""
proxy_server.py — KuyProxy Unified Proxy Daemon
================================================
Menjalankan DUA server sekaligus dalam satu proses:
  1. SOCKS5 Server (port 1080) — sticky IP via username
  2. HTTP Proxy   (port 8118) — sticky IP via Proxy-Authorization header

Sticky IP Mapping:
  user1 → IPv6 pool[0]
  user2 → IPv6 pool[1]
  user3 → IPv6 pool[2]  ...dst

Semua traffic outbound di-bind dari IPv6 spesifik sesuai user,
sehingga setiap user punya IP publik berbeda.
"""

import socket, threading, select, struct, os, sys, base64
import logging, time, json, signal
from concurrent.futures import ThreadPoolExecutor

# ── Config ────────────────────────────────────────────────────
KUYDIR   = os.path.expanduser("~/kuyproxy")
CONFIG   = os.path.join(KUYDIR, "config.cfg")
IP_LIST  = os.path.join(KUYDIR, "added_ips.txt")
LOG_FILE = os.path.join(KUYDIR, "logs", "proxy.log")

os.makedirs(os.path.join(KUYDIR, "logs"), exist_ok=True)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(name)s] %(message)s",
    datefmt="%H:%M:%S",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler(LOG_FILE, encoding="utf-8"),
    ]
)

s5_log  = logging.getLogger("SOCKS5")
http_log = logging.getLogger("HTTP  ")

# ── Stats ─────────────────────────────────────────────────────
stats = {"connections": 0, "bytes_up": 0, "bytes_down": 0}
stats_lock = threading.Lock()

# ── Load Config ───────────────────────────────────────────────
def load_cfg():
    cfg = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    cfg[k.strip()] = v.strip().strip('"')
    except FileNotFoundError:
        pass
    return cfg

def get_ip_pool():
    try:
        with open(IP_LIST) as f:
            return [l.strip() for l in f if l.strip()]
    except FileNotFoundError:
        return []

def resolve_user_ip(username: str, base_user: str, pool: list):
    """Sticky IP: user1→pool[0], user2→pool[1], etc."""
    if not pool or not username:
        return None
    try:
        if username.startswith(base_user) and username != base_user:
            suffix = username[len(base_user):]
            idx = int(suffix) - 1
            if 0 <= idx < len(pool):
                return pool[idx]
        elif username == base_user:
            # Exact match base user → first IP
            return pool[0] if pool else None
    except (ValueError, IndexError):
        pass
    return None

# ── Socket Helpers ────────────────────────────────────────────
def recv_exact(sock, n):
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("connection closed")
        data += chunk
    return data

def make_outbound_socket(bind_ip=None, target_host=None, timeout=10):
    """Buat socket outbound, optionally bound ke IPv6 tertentu."""
    if bind_ip:
        family = socket.AF_INET6
    elif target_host and ":" in target_host:
        family = socket.AF_INET6
    else:
        family = socket.AF_INET

    sock = socket.socket(family, socket.SOCK_STREAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    if bind_ip:
        try:
            sock.bind((bind_ip, 0, 0, 0))
        except OSError as e:
            s5_log.warning(f"Bind {bind_ip} failed: {e}, using default")
    sock.settimeout(timeout)
    return sock

def relay(c1, c2, log_ref, label=""):
    """Bidirectional relay antara dua socket."""
    socks = [c1, c2]
    try:
        while True:
            r, _, err = select.select(socks, [], socks, 60)
            if err:
                break
            if not r:
                break
            for s in r:
                other = c2 if s is c1 else c1
                try:
                    data = s.recv(8192)
                    if not data:
                        return
                    other.sendall(data)
                    with stats_lock:
                        if s is c1:
                            stats["bytes_up"] += len(data)
                        else:
                            stats["bytes_down"] += len(data)
                except:
                    return
    except:
        pass

# ════════════════════════════════════════════
# SOCKS5 SERVER
# ════════════════════════════════════════════
SOCKS5_VER     = 0x05
AUTH_USER_PASS = 0x02
AUTH_NONE      = 0x00
AUTH_NO_ACCEPT = 0xFF
CMD_CONNECT    = 0x01
ATYP_IPV4      = 0x01
ATYP_DOMAIN    = 0x03
ATYP_IPV6      = 0x04

def handle_socks5_client(client_sock, cfg, pool):
    try:
        _socks5_session(client_sock, cfg, pool)
    except Exception as e:
        s5_log.debug(f"Session error: {e}")
    finally:
        try: client_sock.close()
        except: pass

def _socks5_session(client, cfg, pool):
    base_user = cfg.get("SOCKS_USERNAME", "user") or "user"
    password  = cfg.get("SOCKS_PASSWORD", "")
    ipv6_only = cfg.get("IPV6_ONLY", "false").lower() == "true"
    nat64     = "64:ff9b::"

    # ── Greeting ──────────────────────────
    ver = recv_exact(client, 1)[0]
    if ver != SOCKS5_VER:
        return
    n = recv_exact(client, 1)[0]
    methods = set(recv_exact(client, n))

    if password and AUTH_USER_PASS in methods:
        client.sendall(bytes([SOCKS5_VER, AUTH_USER_PASS]))
    elif not password and AUTH_NONE in methods:
        client.sendall(bytes([SOCKS5_VER, AUTH_NONE]))
        _socks5_request(client, None, ipv6_only, nat64, "anon", cfg)
        return
    else:
        client.sendall(bytes([SOCKS5_VER, AUTH_NO_ACCEPT]))
        return

    # ── Auth ──────────────────────────────
    recv_exact(client, 1)  # sub-ver
    ulen = recv_exact(client, 1)[0]
    username = recv_exact(client, ulen).decode("utf-8", "ignore")
    plen = recv_exact(client, 1)[0]
    sent_pass = recv_exact(client, plen).decode("utf-8", "ignore")

    if sent_pass != password:
        client.sendall(bytes([0x01, 0x01]))
        s5_log.warning(f"Auth fail: {username}")
        return
    client.sendall(bytes([0x01, 0x00]))

    # ── Sticky IP ─────────────────────────
    bind_ip = resolve_user_ip(username, base_user, pool)
    s5_log.info(f"✅ {username} → {bind_ip or 'default'}")

    with stats_lock:
        stats["connections"] += 1

    _socks5_request(client, bind_ip, ipv6_only, nat64, username, cfg)

def _socks5_request(client, bind_ip, ipv6_only, nat64, username, cfg):
    hdr = recv_exact(client, 4)
    ver, cmd, _, atyp = hdr

    if ver != SOCKS5_VER or cmd != CMD_CONNECT:
        client.sendall(bytes([SOCKS5_VER, 0x07, 0x00, 0x01]) + b'\x00'*4 + b'\x00\x00')
        return

    # Parse target
    is_ipv4 = False
    if atyp == ATYP_IPV4:
        raw = recv_exact(client, 4)
        host = socket.inet_ntop(socket.AF_INET, raw)
        is_ipv4 = True
    elif atyp == ATYP_DOMAIN:
        dlen = recv_exact(client, 1)[0]
        host = recv_exact(client, dlen).decode()
    elif atyp == ATYP_IPV6:
        raw = recv_exact(client, 16)
        host = socket.inet_ntop(socket.AF_INET6, raw)
    else:
        return

    port = struct.unpack("!H", recv_exact(client, 2))[0]

    # NAT64
    if ipv6_only and is_ipv4:
        host = f"{nat64}{host}"
        s5_log.debug(f"NAT64 → {host}")

    # Connect
    try:
        remote = make_outbound_socket(bind_ip, host)
        remote.connect((host, port))
        remote.settimeout(None)

        local_addr = remote.getsockname()
        local_ip   = local_addr[0] if local_addr else "0.0.0.0"
        local_port = local_addr[1] if local_addr else 0

        if ":" in local_ip:
            addr_bytes = socket.inet_pton(socket.AF_INET6, local_ip)
            reply = bytes([SOCKS5_VER, 0x00, 0x00, ATYP_IPV6]) + addr_bytes
        else:
            addr_bytes = socket.inet_aton(local_ip)
            reply = bytes([SOCKS5_VER, 0x00, 0x00, ATYP_IPV4]) + addr_bytes

        reply += struct.pack("!H", local_port)
        client.sendall(reply)

        s5_log.info(f"► {username} {host}:{port}")
        relay(client, remote, s5_log, f"{username}→{host}:{port}")
        remote.close()
    except Exception as e:
        s5_log.debug(f"Connect {host}:{port} failed: {e}")
        err_reply = bytes([SOCKS5_VER, 0x05, 0x00, ATYP_IPV4]) + b'\x00'*4 + b'\x00\x00'
        try: client.sendall(err_reply)
        except: pass

# ════════════════════════════════════════════
# HTTP PROXY SERVER
# ════════════════════════════════════════════

def handle_http_client(client_sock, cfg, pool):
    try:
        _http_session(client_sock, cfg, pool)
    except Exception as e:
        http_log.debug(f"HTTP session error: {e}")
    finally:
        try: client_sock.close()
        except: pass

def _http_session(client, cfg, pool):
    base_user = cfg.get("SOCKS_USERNAME", "user") or "user"
    password  = cfg.get("SOCKS_PASSWORD", "")

    # Baca request pertama
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = client.recv(4096)
        if not chunk:
            return
        raw += chunk

    try:
        header_part = raw.split(b"\r\n\r\n")[0].decode("utf-8", "ignore")
    except:
        return

    lines = header_part.split("\r\n")
    if not lines:
        return

    req_line = lines[0]
    parts = req_line.split(" ")
    if len(parts) < 3:
        return

    method   = parts[0].upper()
    target   = parts[1]
    username = None
    bind_ip  = None

    # ── Parse Proxy-Authorization ─────────
    for line in lines[1:]:
        if line.lower().startswith("proxy-authorization:"):
            try:
                enc = line.split(":", 1)[1].strip()
                if enc.lower().startswith("basic "):
                    decoded = base64.b64decode(enc[6:]).decode("utf-8", "ignore")
                    u, _, p = decoded.partition(":")
                    if p != password:
                        _http_send(client, "407 Proxy Authentication Required",
                                   'Proxy-Authenticate: Basic realm="KuyProxy"\r\n')
                        http_log.warning(f"Auth fail: {u}")
                        return
                    username = u
            except:
                pass
            break

    # Auth required
    if password and username is None:
        _http_send(client, "407 Proxy Authentication Required",
                   'Proxy-Authenticate: Basic realm="KuyProxy"\r\n')
        return

    # Sticky IP
    if username:
        bind_ip = resolve_user_ip(username, base_user, pool)
    user_label = username or "anon"
    http_log.info(f"✅ {user_label} → {bind_ip or 'default'}")

    with stats_lock:
        stats["connections"] += 1

    if method == "CONNECT":
        # HTTPS tunneling
        host, _, port_str = target.partition(":")
        port = int(port_str) if port_str else 443
        try:
            remote = make_outbound_socket(bind_ip, host)
            remote.connect((host, port))
            remote.settimeout(None)
            client.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
            http_log.info(f"► {user_label} CONNECT {host}:{port}")
            relay(client, remote, http_log, f"{user_label}→{host}:{port}")
            remote.close()
        except Exception as e:
            http_log.debug(f"CONNECT {host}:{port} failed: {e}")
            _http_send(client, "502 Bad Gateway")
    else:
        # Plain HTTP (GET/POST/etc)
        from urllib.parse import urlparse
        parsed = urlparse(target)
        host   = parsed.hostname or ""
        port   = parsed.port or 80
        path   = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        # Rebuild request tanpa Proxy headers
        new_req = f"{method} {path} HTTP/1.1\r\n"
        for line in lines[1:]:
            if line.lower().startswith(("proxy-auth", "proxy-connection")):
                continue
            new_req += line + "\r\n"
        new_req += "\r\n"
        body = raw.split(b"\r\n\r\n", 1)[1] if b"\r\n\r\n" in raw else b""

        try:
            remote = make_outbound_socket(bind_ip, host)
            remote.connect((host, port))
            remote.settimeout(None)
            remote.sendall(new_req.encode() + body)
            http_log.info(f"► {user_label} {method} {host}:{port}{path}")
            relay(client, remote, http_log)
            remote.close()
        except Exception as e:
            http_log.debug(f"HTTP {host}:{port} failed: {e}")
            _http_send(client, "502 Bad Gateway")

def _http_send(client, status, extra_headers="", body=""):
    body_bytes = body.encode() if isinstance(body, str) else body
    resp = (f"HTTP/1.1 {status}\r\n"
            f"Content-Length: {len(body_bytes)}\r\n"
            f"{extra_headers}"
            f"\r\n")
    try:
        client.sendall(resp.encode() + body_bytes)
    except:
        pass

# ════════════════════════════════════════════
# MAIN — Jalankan Kedua Server
# ════════════════════════════════════════════

def start_server(host, port, handler, executor, name):
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((host, port))
    srv.listen(128)
    logging.getLogger(name).info(f"Listening on {host}:{port}")

    def _accept_loop():
        while True:
            try:
                conn, addr = srv.accept()
                conn.settimeout(30)
                cfg  = load_cfg()
                pool = get_ip_pool()
                executor.submit(handler, conn, cfg, pool)
            except OSError:
                break
            except Exception as e:
                logging.getLogger(name).error(f"Accept error: {e}")

    t = threading.Thread(target=_accept_loop, daemon=True, name=f"accept-{name}")
    t.start()
    return srv

def main():
    cfg  = load_cfg()
    pool = get_ip_pool()

    s5_port   = int(cfg.get("LOCAL_SOCKS_PORT", 1080))
    http_port = int(cfg.get("LOCAL_HTTP_PORT", 8118))

    logging.getLogger("MAIN ").info("═" * 48)
    logging.getLogger("MAIN ").info("  KuyProxy Proxy Server — Starting")
    logging.getLogger("MAIN ").info("═" * 48)
    logging.getLogger("MAIN ").info(f"  SOCKS5 → :{s5_port}")
    logging.getLogger("MAIN ").info(f"  HTTP   → :{http_port}")
    logging.getLogger("MAIN ").info(f"  Auth   → {cfg.get('SOCKS_USERNAME','user')}:{'*'*6}")
    logging.getLogger("MAIN ").info(f"  IPv6 Pool → {len(pool)} IPs")
    logging.getLogger("MAIN ").info(f"  Mode   → {'IPv6-only' if cfg.get('IPV6_ONLY')=='true' else 'Dual stack'}")

    executor = ThreadPoolExecutor(max_workers=300, thread_name_prefix="worker")

    srv5    = start_server("0.0.0.0", s5_port,   handle_socks5_client, executor, "SOCKS5")
    srv_http = start_server("0.0.0.0", http_port, handle_http_client,   executor, "HTTP  ")

    def shutdown(sig, frame):
        logging.getLogger("MAIN ").info("Shutting down...")
        srv5.close()
        srv_http.close()
        executor.shutdown(wait=False)
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)

    # Stats printer setiap 60 detik
    def print_stats():
        while True:
            time.sleep(60)
            with stats_lock:
                s = dict(stats)
            logging.getLogger("STATS").info(
                f"Connections: {s['connections']} | "
                f"↑{s['bytes_up']//1024}KB ↓{s['bytes_down']//1024}KB"
            )
    threading.Thread(target=print_stats, daemon=True).start()

    # Keep alive
    while True:
        time.sleep(1)

if __name__ == "__main__":
    main()
