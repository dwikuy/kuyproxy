#!/usr/bin/env python3
"""
api_server.py — KuyProxy HTTP API Server
=========================================
Berjalan di port 8080 (lokal), di-tunnel ke VPS via FRP.
Digunakan oleh Web Dashboard untuk kontrol HP dari jauh.

Endpoints:
  GET  /ping          → health check
  GET  /status        → status lengkap
  GET  /start         → start proxy services
  GET  /stop          → stop proxy services
  GET  /rotate?user=N → rotate IP user ke-N
  GET  /reset         → airplane mode full reset
  GET  /logs?n=100    → ambil N baris log terakhir
  GET  /ips           → list IP pool
  GET  /stats         → traffic stats
  GET  /config        → baca config
  POST /config        → update config
"""

import os, sys, json, time, subprocess, threading, signal
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs
import logging

KUYDIR   = os.path.expanduser("~/kuyproxy")
CONFIG   = os.path.join(KUYDIR, "config.cfg")
IP_LIST  = os.path.join(KUYDIR, "added_ips.txt")
LOG_FILE = os.path.join(KUYDIR, "logs", "kuyproxy.log")
PID_PROXY = os.path.join(KUYDIR, "proxy.pid")
PID_FRP   = os.path.join(KUYDIR, "frpc.pid")

start_time = time.time()
log = logging.getLogger("API")
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s", datefmt="%H:%M:%S")

# ── Helpers ───────────────────────────────────────────────────
def cfg(key, default=""):
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if line.startswith(f"{key}="):
                    return line.split("=", 1)[1].strip().strip('"')
    except: pass
    return default

def read_all_config():
    data = {}
    try:
        with open(CONFIG) as f:
            for line in f:
                line = line.strip()
                if "=" in line and not line.startswith("#"):
                    k, _, v = line.partition("=")
                    data[k.strip()] = v.strip().strip('"')
    except: pass
    return data

def write_config(updates: dict):
    try:
        with open(CONFIG, "r") as f:
            lines = f.readlines()
        new_lines = []
        written = set()
        for line in lines:
            stripped = line.strip()
            if "=" in stripped and not stripped.startswith("#"):
                k = stripped.split("=")[0].strip()
                if k in updates:
                    new_lines.append(f"{k}={updates[k]}\n")
                    written.add(k)
                    continue
            new_lines.append(line)
        # Tambah key baru yang belum ada
        for k, v in updates.items():
            if k not in written:
                new_lines.append(f"{k}={v}\n")
        with open(CONFIG, "w") as f:
            f.writelines(new_lines)
        return True
    except Exception as e:
        log.error(f"Write config failed: {e}")
        return False

def get_ip_pool():
    try:
        with open(IP_LIST) as f:
            return [l.strip() for l in f if l.strip()]
    except: return []

def get_logs(n=100):
    try:
        with open(LOG_FILE) as f:
            lines = f.readlines()
        return [l.rstrip() for l in lines[-n:]]
    except: return []

def is_service_running(pid_file):
    try:
        pid = int(open(pid_file).read().strip())
        os.kill(pid, 0)
        return True
    except: return False

def run_cmd(cmd, background=False):
    try:
        if background:
            p = subprocess.Popen(cmd, shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return p.pid
        else:
            r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
            return r.returncode == 0, r.stdout + r.stderr
    except Exception as e:
        return False, str(e)

def telegram_notify(msg):
    token = cfg("TELEGRAM_BOT_TOKEN")
    chat  = cfg("TELEGRAM_CHAT_ID")
    if not token or not chat:
        return
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = json.dumps({"chat_id": chat, "text": msg, "parse_mode": "HTML"})
    subprocess.Popen(
        f'curl -s -X POST "{url}" -H "Content-Type: application/json" -d \'{data}\'',
        shell=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
    )

def json_response(data, status=200):
    body = json.dumps(data, ensure_ascii=False, indent=2).encode()
    return status, body

# ── API Actions ───────────────────────────────────────────────
def action_status():
    proxy_up = is_service_running(PID_PROXY)
    frp_up   = is_service_running(PID_FRP)
    pool     = get_ip_pool()
    uptime   = int(time.time() - start_time)

    return {
        "status":    "online",
        "proxy":     proxy_up,
        "frp":       frp_up,
        "running":   proxy_up and frp_up,
        "ip_pool":   len(pool),
        "ips":       pool,
        "uptime_s":  uptime,
        "interface": cfg("NETWORK_INTERFACE", "auto"),
        "method":    cfg("ROTATION_METHOD", "root"),
        "version":   "1.0.0",
    }

def action_start():
    log.info("Starting proxy services...")
    sh = os.path.join(KUYDIR, "kuyproxy.sh")
    run_cmd(f"bash {sh} start &", background=False)
    time.sleep(2)
    telegram_notify("🟢 KuyProxy <b>STARTED</b>")
    return {"ok": True, "msg": "Start command sent"}

def action_stop():
    log.info("Stopping proxy services...")
    sh = os.path.join(KUYDIR, "kuyproxy.sh")
    run_cmd(f"bash {sh} stop", background=False)
    telegram_notify("🔴 KuyProxy <b>STOPPED</b>")
    return {"ok": True, "msg": "Stop command sent"}

def action_rotate(user_idx: int):
    log.info(f"Rotating IP for user index {user_idx}...")
    sh = os.path.join(KUYDIR, "ip_manager.sh")
    ok, out = run_cmd(f"bash {sh} rotate {user_idx}")
    if ok:
        pool = get_ip_pool()
        new_ip = pool[user_idx] if user_idx < len(pool) else "?"
        telegram_notify(f"🔄 IP rotated: <b>user{user_idx+1}</b> → {new_ip}")
    return {"ok": ok, "msg": out.strip() if isinstance(out, str) else "", "user": user_idx+1}

def action_reset():
    log.info("Triggering airplane mode reset...")
    sh = os.path.join(KUYDIR, "airplane.sh")
    telegram_notify("✈️ Airplane mode rotation <b>started</b>")
    # Run di background karena butuh waktu
    subprocess.Popen(f"bash {sh} rotate", shell=True)
    return {"ok": True, "msg": "Airplane rotation started"}

def action_logs(n=100):
    lines = get_logs(n)
    return {"ok": True, "lines": lines, "count": len(lines)}

def action_ips():
    pool = get_ip_pool()
    result = []
    base  = cfg("SOCKS_USERNAME", "user")
    for i, ip in enumerate(pool):
        result.append({"user": f"{base}{i+1}", "idx": i, "ip": ip})
    return {"ok": True, "pool": result, "total": len(pool)}

def action_stats():
    # Baca stats dari proxy
    stats_file = os.path.join(KUYDIR, "stats.json")
    try:
        with open(stats_file) as f:
            return json.load(f)
    except:
        return {"connections": 0, "bytes_up": 0, "bytes_down": 0}

def action_get_config():
    return {"ok": True, "config": read_all_config()}

def action_post_config(body: bytes):
    try:
        updates = json.loads(body)
        if write_config(updates):
            return {"ok": True, "msg": "Config saved"}
        return {"ok": False, "msg": "Write failed"}
    except Exception as e:
        return {"ok": False, "msg": str(e)}

# ── HTTP Handler ──────────────────────────────────────────────
class APIHandler(BaseHTTPRequestHandler):

    def log_message(self, format, *args):
        log.debug(f"{self.client_address[0]} {format % args}")

    def send_json(self, data, status=200):
        body = json.dumps(data, ensure_ascii=False, indent=2).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", len(body))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")
        params = parse_qs(parsed.query)

        def p(key, default=""):
            vals = params.get(key, [default])
            return vals[0] if vals else default

        routes = {
            "/ping":   lambda: {"ok": True, "ms": int((time.time() % 1) * 1000)},
            "/status": action_status,
            "/start":  action_start,
            "/stop":   action_stop,
            "/reset":  action_reset,
            "/logs":   lambda: action_logs(int(p("n", "100"))),
            "/ips":    action_ips,
            "/stats":  action_stats,
            "/config": action_get_config,
        }

        if path == "/rotate":
            user = p("user", "1")
            try:
                idx = int(user) - 1
            except:
                idx = 0
            self.send_json(action_rotate(idx))
            return

        handler = routes.get(path)
        if handler:
            try:
                result = handler()
                self.send_json(result)
            except Exception as e:
                self.send_json({"ok": False, "error": str(e)}, 500)
        else:
            self.send_json({"ok": False, "error": "Not found"}, 404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path   = parsed.path.rstrip("/")
        length = int(self.headers.get("Content-Length", 0))
        body   = self.rfile.read(length) if length else b""

        if path == "/config":
            self.send_json(action_post_config(body))
        else:
            self.send_json({"ok": False, "error": "Not found"}, 404)

    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.end_headers()

# ── Main ─────────────────────────────────────────────────────
def main():
    port = int(cfg("LOCAL_API_PORT") or 8080)
    server = HTTPServer(("0.0.0.0", port), APIHandler)
    log.info(f"🌐 API Server listening on 0.0.0.0:{port}")

    def shutdown(sig, frame):
        log.info("API Server shutting down...")
        server.shutdown()
        sys.exit(0)

    signal.signal(signal.SIGTERM, shutdown)
    signal.signal(signal.SIGINT, shutdown)
    server.serve_forever()

if __name__ == "__main__":
    main()
