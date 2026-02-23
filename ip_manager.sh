#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   ip_manager.sh — IPv6 Pool Manager
#   Setara MultiIpManager.kt dari HyperBridge
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"
CONFIG="$KUYDIR/config.cfg"
IP_LIST="$KUYDIR/added_ips.txt"
IFACE_FILE="$KUYDIR/interface.txt"

# ── Load config ──────────────────────────
cfg() { grep -m1 "^$1=" "$CONFIG" 2>/dev/null | cut -d= -f2- | tr -d '"'; }

log() { echo "[$(date '+%H:%M:%S')] [IP] $*"; }

# ── Detect interface IPv6 aktif ──────────
detect_interface() {
    local forced; forced=$(cfg NETWORK_INTERFACE)
    if [ -n "$forced" ]; then
        echo "$forced"; return
    fi
    # Scan semua interface, cari yang punya global IPv6
    for iface in $(ip -6 addr show scope global 2>/dev/null | grep -oP '(?<=\d: )\w+' | sort -u); do
        if ip -6 addr show dev "$iface" scope global 2>/dev/null | grep -q "inet6"; then
            echo "$iface"; return
        fi
    done
    # Fallback: cari rmnet atau wlan
    for iface in rmnet_data2 rmnet_data1 rmnet_data0 wlan0; do
        if ip link show "$iface" &>/dev/null; then
            echo "$iface"; return
        fi
    done
    echo ""
}

# ── Detect prefix IPv6 dari interface ────
detect_prefix() {
    local iface="$1"
    ip -6 addr show dev "$iface" scope global 2>/dev/null \
        | grep "inet6" \
        | awk '{print $2}' \
        | head -1 \
        | sed 's|/.*||' \
        | sed 's|[0-9a-f]*:[0-9a-f]*$|:|'
}

# ── Generate 1 IPv6 acak dari prefix ─────
gen_ipv6() {
    local prefix="$1"
    printf "%s%04x:%04x:%04x:%04x" \
        "$prefix" \
        $((RANDOM % 65535 + 1)) \
        $((RANDOM % 65535 + 1)) \
        $((RANDOM % 65535 + 1)) \
        $((RANDOM % 65535 + 1))
}

# ── Setup IP Pool ─────────────────────────
setup_pool() {
    local count; count=$(cfg IP_POOL_COUNT)
    count=${count:-10}

    log "Setting up IPv6 pool ($count IPs)..."

    local iface; iface=$(detect_interface)
    if [ -z "$iface" ]; then
        log "❌ No IPv6 interface found"
        return 1
    fi
    log "Using interface: $iface"
    echo "$iface" > "$IFACE_FILE"

    local prefix; prefix=$(detect_prefix "$iface")
    if [ -z "$prefix" ]; then
        log "❌ Cannot detect IPv6 prefix"
        return 1
    fi
    log "Prefix: $prefix"

    # Bersihkan pool lama
    remove_pool 2>/dev/null

    mkdir -p "$KUYDIR/logs"
    > "$IP_LIST"

    local added=0
    for i in $(seq 1 "$count"); do
        local ip; ip=$(gen_ipv6 "$prefix")
        if su -c "ip -6 addr add ${ip}/64 dev $iface" 2>/dev/null; then
            echo "$ip" >> "$IP_LIST"
            ((added++))
            if [ $((added % 10)) -eq 0 ]; then
                log "  Added $added/$count IPs..."
            fi
        fi
    done

    log "✅ Pool ready: $added IPs added to $iface"
    return 0
}

# ── Remove seluruh pool ───────────────────
remove_pool() {
    if [ ! -f "$IP_LIST" ]; then return; fi
    local iface; iface=$(cat "$IFACE_FILE" 2>/dev/null)
    iface=${iface:-$(detect_interface)}

    log "Removing IP pool..."
    local count=0
    while read -r ip; do
        su -c "ip -6 addr del ${ip}/64 dev $iface" 2>/dev/null && ((count++))
    done < "$IP_LIST"
    > "$IP_LIST"
    log "✅ Removed $count IPs"
}

# ── Rotate IP user tertentu (index 0-based) ──
rotate_user() {
    local idx="$1"
    local iface; iface=$(cat "$IFACE_FILE" 2>/dev/null)
    iface=${iface:-$(detect_interface)}

    if [ ! -f "$IP_LIST" ]; then
        log "❌ IP list not found"; return 1
    fi

    local old_ip; old_ip=$(sed -n "$((idx+1))p" "$IP_LIST")
    if [ -z "$old_ip" ]; then
        log "❌ User index $idx out of range"; return 1
    fi

    local prefix; prefix=$(detect_prefix "$iface")
    local new_ip; new_ip=$(gen_ipv6 "$prefix")

    log "Rotating user $((idx+1)): $old_ip → $new_ip"

    # Hapus IP lama, tambah baru
    su -c "ip -6 addr del ${old_ip}/64 dev $iface" 2>/dev/null
    if su -c "ip -6 addr add ${new_ip}/64 dev $iface" 2>/dev/null; then
        # Update file
        local tmp; tmp=$(mktemp)
        awk -v idx="$((idx+1))" -v new="$new_ip" 'NR==idx{print new; next} {print}' "$IP_LIST" > "$tmp"
        mv "$tmp" "$IP_LIST"
        log "✅ user$((idx+1)) now → $new_ip"
        return 0
    else
        # Rollback
        su -c "ip -6 addr add ${old_ip}/64 dev $iface" 2>/dev/null
        log "❌ Rotate failed, rolled back"
        return 1
    fi
}

# ── Tampilkan IP pool saat ini ────────────
list_ips() {
    if [ ! -f "$IP_LIST" ]; then
        echo "No IP pool found"; return
    fi
    local n=1
    while read -r ip; do
        printf "user%-3d → %s\n" "$n" "$ip"
        ((n++))
    done < "$IP_LIST"
}

# ── Status ───────────────────────────────
show_status() {
    local iface; iface=$(cat "$IFACE_FILE" 2>/dev/null || detect_interface)
    local count=0
    [ -f "$IP_LIST" ] && count=$(wc -l < "$IP_LIST")
    echo "Interface : ${iface:-unknown}"
    echo "IP Pool   : $count IPs"
    echo "IP File   : $IP_LIST"
}

# ── Main ─────────────────────────────────
case "${1:-help}" in
    setup)   setup_pool ;;
    remove)  remove_pool ;;
    rotate)  rotate_user "${2:-0}" ;;
    list)    list_ips ;;
    status)  show_status ;;
    detect)  detect_interface ;;
    *)
        echo "Usage: $0 {setup|remove|rotate <idx>|list|status|detect}"
        ;;
esac
