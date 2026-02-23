#!/data/data/com.termux/files/usr/bin/bash
# ════════════════════════════════════════════
#   autostart.sh — Termux:Boot Auto-Start
#   Letakkan di: ~/.termux/boot/autostart.sh
# ════════════════════════════════════════════

KUYDIR="$HOME/kuyproxy"

# Tunggu network tersedia (max 60 detik)
wait_for_network() {
    local i=0
    while [ $i -lt 30 ]; do
        if ping -c1 -W2 8.8.8.8 &>/dev/null; then
            return 0
        fi
        sleep 2
        ((i++))
    done
    return 1
}

sleep 5  # Beri waktu Termux fully loaded

# Acquire wakelock agar Termux tidak tertidur
termux-wake-lock 2>/dev/null

echo "[$(date '+%H:%M:%S')] KuyProxy autostart..."

if wait_for_network; then
    echo "[$(date '+%H:%M:%S')] Network OK, starting KuyProxy..."
    bash "$KUYDIR/kuyproxy.sh" start
else
    echo "[$(date '+%H:%M:%S')] Network timeout, starting anyway..."
    bash "$KUYDIR/kuyproxy.sh" start
fi
