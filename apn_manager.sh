#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   apn_manager.sh — APN Rotation Manager
#   Setara ApnManager.kt dari HyperBridge
#   Rotate APN via content provider (butuh root)
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"
CONFIG="$KUYDIR/config.cfg"

cfg() { grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }
log() { echo "[$(date '+%H:%M:%S')] [APN] $*"; }

# ── Ambil SIM MCC/MNC ─────────────────────
get_sim_numeric() {
    local numeric
    numeric=$(su -c "getprop gsm.sim.operator.numeric" 2>/dev/null | tr -d '[:space:]')
    if [ -z "$numeric" ]; then
        numeric=$(su -c "getprop gsm.operator.numeric" 2>/dev/null | tr -d '[:space:]')
    fi
    echo "$numeric"
}

# ── Query semua APN operator ──────────────
get_apn_list() {
    local numeric; numeric=$(get_sim_numeric)
    if [ -n "$numeric" ]; then
        log "SIM Numeric: $numeric"
    fi

    # Query APN database
    local raw
    raw=$(su -c "content query --uri content://telephony/carriers \
        --projection _id:name:apn:type:numeric" 2>/dev/null)

    if [ -z "$raw" ]; then
        log "❌ APN query failed (perlu root)"; return 1
    fi

    # Parse dan filter berdasarkan SIM
    echo "$raw" | grep -i "_id=" | while read -r line; do
        local id name apn type num
        id=$(echo "$line" | grep -oP '_id=\K\d+')
        name=$(echo "$line" | grep -oP 'name=\K[^,]+')
        apn=$(echo "$line" | grep -oP 'apn=\K[^,]+')
        type=$(echo "$line" | grep -oP 'type=\K[^,]+' | tr '[:upper:]' '[:lower:]')
        num=$(echo "$line" | grep -oP 'numeric=\K\d+')

        # Filter: cocok dengan SIM ATAU di-skip filter kalau numeric kosong
        if [ -n "$numeric" ] && [ -n "$num" ] && [ "$num" != "$numeric" ]; then
            continue
        fi

        # Filter hanya APN yang support data (default/internet/*)
        if echo "$type" | grep -qiE 'default|internet|\*'; then
            echo "$id|$name|$apn|$type"
        fi
    done
}

# ── Ambil APN yang sedang aktif ───────────
get_current_apn_id() {
    local result
    result=$(su -c "content query --uri content://telephony/carriers/preferapn \
        --projection _id" 2>/dev/null)
    echo "$result" | grep -oP '_id=\K\d+' | head -1
}

# ── Set APN ke ID tertentu ─────────────────
set_apn() {
    local apn_id="$1"
    log "🔄 Switching to APN ID: $apn_id"
    su -c "content update \
        --uri content://telephony/carriers/preferapn \
        --bind apn_id:i:${apn_id}" 2>/dev/null
}

# ── Rotate ke APN berikutnya ──────────────
rotate_apn() {
    local apns
    mapfile -t apns < <(get_apn_list)

    if [ "${#apns[@]}" -lt 2 ]; then
        log "⚠️  Tidak cukup APN untuk rotate. Ditemukan: ${#apns[@]}"
        log "   (Perlu minimal 2 APN data aktif)"
        return 1
    fi

    log "📋 Ditemukan ${#apns[@]} APN:"
    for a in "${apns[@]}"; do
        log "   $(echo "$a" | awk -F'|' '{printf "ID=%-3s %-20s (%s)", $1, $2, $3}')"
    done

    local current_id; current_id=$(get_current_apn_id)
    log "Current APN ID: ${current_id:-unknown}"

    # Cari APN berikutnya
    local next_id=""
    local found=false
    for apn in "${apns[@]}"; do
        local id; id=$(echo "$apn" | cut -d'|' -f1)
        if [ "$found" = true ]; then
            next_id="$id"
            break
        fi
        if [ "$id" = "$current_id" ]; then
            found=true
        fi
    done

    # Kalau tidak ketemu atau sudah di akhir → kembali ke yang pertama
    if [ -z "$next_id" ]; then
        next_id=$(echo "${apns[0]}" | cut -d'|' -f1)
    fi

    if [ "$next_id" = "$current_id" ]; then
        log "⚠️  Hanya ada 1 APN valid, tidak bisa rotate"
        return 1
    fi

    local next_name; next_name=$(printf '%s\n' "${apns[@]}" | grep "^${next_id}|" | cut -d'|' -f2)
    log "👉 Rotating: ID $current_id → ID $next_id ($next_name)"

    if set_apn "$next_id"; then
        # Trigger reconnect
        su -c "svc data disable" 2>/dev/null
        sleep 2
        su -c "svc data enable" 2>/dev/null
        log "✅ APN rotated ke: $next_name"
        return 0
    else
        log "❌ Gagal switch APN"
        return 1
    fi
}

# ── List semua APN ────────────────────────
list_apns() {
    log "Querying APNs..."
    local apns
    mapfile -t apns < <(get_apn_list)
    local current_id; current_id=$(get_current_apn_id)

    echo "Current APN ID: ${current_id:-unknown}"
    echo "Available APNs:"
    for apn in "${apns[@]}"; do
        local id name apn_str type
        IFS='|' read -r id name apn_str type <<< "$apn"
        local marker=""
        [ "$id" = "$current_id" ] && marker=" ← ACTIVE"
        printf "  [%s] %-20s (%s) type=%s%s\n" "$id" "$name" "$apn_str" "$type" "$marker"
    done
}

# ── Main ─────────────────────────────────
case "${1:-help}" in
    rotate) rotate_apn ;;
    list)   list_apns ;;
    current) get_current_apn_id ;;
    *)
        echo "Usage: $0 {rotate|list|current}"
        ;;
esac
