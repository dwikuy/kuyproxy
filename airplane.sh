#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   airplane.sh — Airplane Mode Controller
#   Setara AirplaneModeController.kt HyperBridge
#   3 Metode: root | write_secure | manual
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"
CONFIG="$KUYDIR/config.cfg"

cfg() { grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }
log() { echo "[$(date '+%H:%M:%S')] [AIR] $*"; }

METHOD=$(cfg ROTATION_METHOD)
METHOD=${METHOD:-root}
IP_CHECK_URL=$(cfg IP_CHECK_URL)
IP_CHECK_URL=${IP_CHECK_URL:-https://api.ipify.org}
TIMEOUT=$(cfg ROTATION_TIMEOUT)
TIMEOUT=${TIMEOUT:-60}

# ── Cek status airplane mode ──────────────
is_airplane_on() {
    local val
    val=$(su -c "settings get global airplane_mode_on" 2>/dev/null)
    [ "$val" = "1" ]
}

# ── Nyalakan airplane mode ────────────────
airplane_on() {
    case "$METHOD" in
        root)
            su -c "settings put global airplane_mode_on 1" 2>/dev/null
            su -c "am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true" 2>/dev/null
            log "✈️  Airplane ON (root)"
            ;;
        write_secure)
            settings put global airplane_mode_on 1 2>/dev/null
            am broadcast -a android.intent.action.AIRPLANE_MODE --ez state true 2>/dev/null
            log "✈️  Airplane ON (write_secure)"
            ;;
        apn)
            log "⚡ Menggunakan APN rotation..."
            "$KUYDIR/apn_manager.sh" rotate
            return $?
            ;;
        manual)
            log "⚠️  Mode manual — nyalakan airplane mode secara manual lalu tekan Enter"
            read -r
            ;;
    esac
}

# ── Matikan airplane mode ──────────────────
airplane_off() {
    case "$METHOD" in
        root)
            su -c "settings put global airplane_mode_on 0" 2>/dev/null
            su -c "am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false" 2>/dev/null
            log "📱 Airplane OFF (root)"
            ;;
        write_secure)
            settings put global airplane_mode_on 0 2>/dev/null
            am broadcast -a android.intent.action.AIRPLANE_MODE --ez state false 2>/dev/null
            log "📱 Airplane OFF (write_secure)"
            ;;
        manual)
            log "⚠️  Matikan airplane mode manually lalu tekan Enter"
            read -r
            ;;
    esac
}

# ── Paksa airplane mode off jika masih ON ─
ensure_off() {
    local i=0
    while is_airplane_on && [ $i -lt 5 ]; do
        ((i++))
        log "⚠️  Airplane masih ON! Force OFF attempt $i/5"
        airplane_off
        sleep 2
    done
    if is_airplane_on; then
        log "❌ GAGAL matikan airplane setelah 5 percobaan"
    else
        log "✅ Airplane OFF verified"
    fi
}

# ── Ambil IP saat ini ─────────────────────
get_current_ip() {
    curl -s --max-time 5 "$IP_CHECK_URL" 2>/dev/null | tr -d '[:space:]'
}

# ── Tunggu network kembali ────────────────
wait_network() {
    local deadline=$(($(date +%s) + TIMEOUT))
    log "Waiting for network..."
    while [ "$(date +%s)" -lt "$deadline" ]; do
        if curl -s --max-time 3 "https://1.1.1.1" &>/dev/null; then
            log "✅ Network is back"
            return 0
        fi
        sleep 2
    done
    log "❌ Network timeout after ${TIMEOUT}s"
    return 1
}

# ── Rotate IP (full cycle airplane ON→OFF) ─
rotate_ip() {
    log "🔄 Starting IP rotation..."
    local old_ip; old_ip=$(get_current_ip)
    log "Current IP: ${old_ip:-unknown}"

    # Nyalakan airplane
    airplane_on
    sleep 3

    # Matikan airplane
    airplane_off

    # Tunggu network kembali
    if ! wait_network; then
        ensure_off
        return 1
    fi

    # Pastikan airplane benar-benar OFF
    ensure_off

    # Tunggu IP baru
    local deadline=$(($(date +%s) + 20))
    local new_ip
    while [ "$(date +%s)" -lt "$deadline" ]; do
        new_ip=$(get_current_ip)
        if [ -n "$new_ip" ] && [ "$new_ip" != "$old_ip" ]; then
            log "✅ IP rotated: $old_ip → $new_ip"
            return 0
        fi
        sleep 2
    done

    new_ip=$(get_current_ip)
    if [ -n "$new_ip" ]; then
        log "ℹ️  IP mungkin tidak berubah: ${new_ip}"
        return 0
    fi

    log "❌ Rotation failed"
    return 1
}

# ── Status airplane mode ──────────────────
show_status() {
    if is_airplane_on; then
        echo "Airplane: ON"
    else
        echo "Airplane: OFF"
    fi
    echo "Method  : $METHOD"
    echo "IP Now  : $(get_current_ip)"
}

# ── Main ─────────────────────────────────
case "${1:-help}" in
    on)     airplane_on ;;
    off)    airplane_off ;;
    rotate) rotate_ip ;;
    status) show_status ;;
    ensure_off) ensure_off ;;
    *)
        echo "Usage: $0 {on|off|rotate|status|ensure_off}"
        ;;
esac
