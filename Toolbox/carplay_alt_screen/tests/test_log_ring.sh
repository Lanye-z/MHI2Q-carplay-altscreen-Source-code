#!/bin/sh
# Host fixture for the shared shell log sink; never writes to a vehicle card.
set -eu
SCRIPT=$(CDPATH= cd -- "$(dirname -- "$0")/../../scripts" && pwd)/altscreen_log_ring.sh
ROOT=$(mktemp -d)
case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) exit 2 ;; esac
trap 'rm -rf "$ROOT"' 0
CARD="$ROOT/card"
FALLBACK="$ROOT/fallback.log"
mkdir -p "$CARD/Toolbox" "$CARD/MMI-Cockpit-Carplay/state" "$CARD/MMI-Cockpit-Carplay/logs"
export ALTSCREEN_CHAIN_TESTING=1
export ALTSCREEN_CHAIN_VOLUME="$CARD"
export ALTS_LOG_SEGMENT_BYTES=4096
export ALTS_LOG_HISTORY_SLOTS=3

printf 'SD_FIRST\n' | sh "$SCRIPT" pipe mirror "$FALLBACK"
grep -Fq SD_FIRST "$CARD/MMI-Cockpit-Carplay/logs/mirror.log" || {
    echo "LOG_RING_HOST_TEST=FAIL stage=sd_first_missing" >&2
    exit 1
}
[ ! -s "$FALLBACK" ] || {
    echo "LOG_RING_HOST_TEST=FAIL stage=sd_first_unexpected_fallback bytes=$(wc -c < "$FALLBACK")" >&2
    exit 1
}

# Multiple independent producers must not race the rotation cursor or exceed
# one active file plus the declared number of fixed history slots.
for producer in 1 2 3; do
    (
        n=0
        while [ "$n" -lt 100 ]; do
            printf 'P%s:%03d\n' "$producer" "$n"
            n=$((n + 1))
        done | sh "$SCRIPT" pipe mirror "$FALLBACK"
    ) &
done
wait
for file in "$CARD"/MMI-Cockpit-Carplay/logs/mirror.log*; do
    [ -f "$file" ] || continue
    size=$(wc -c < "$file")
    [ "$size" -le 4096 ] || {
        echo "LOG_RING_HOST_TEST=FAIL stage=segment_oversize file=$file bytes=$size" >&2
        exit 1
    }
done
count=$(cat "$CARD"/MMI-Cockpit-Carplay/logs/mirror.log* "$FALLBACK" 2>/dev/null | grep -c '^P[123]:' || true)
[ "$count" -eq 300 ] || {
    echo "LOG_RING_HOST_TEST=FAIL stage=concurrent_count expected=300 actual=$count" >&2
    ls -la "$CARD/MMI-Cockpit-Carplay/logs" >&2 || true
    wc -c "$CARD"/MMI-Cockpit-Carplay/logs/mirror.log* "$FALLBACK" >&2 2>/dev/null || true
    exit 1
}

# Busy SD lock and absent card both fall back without an error exit.
mkdir "$CARD/MMI-Cockpit-Carplay/logs/.mirror.lock"
printf 'BUSY_FALLBACK\n' | sh "$SCRIPT" pipe mirror "$FALLBACK"
grep -Fq BUSY_FALLBACK "$FALLBACK" || {
    echo "LOG_RING_HOST_TEST=FAIL stage=busy_lock_fallback_missing" >&2
    exit 1
}
rmdir "$CARD/MMI-Cockpit-Carplay/logs/.mirror.lock"
ALTSCREEN_CHAIN_VOLUME="$ROOT/missing" sh "$SCRIPT" line mirror "$FALLBACK" NO_CARD_FALLBACK
grep -Fq NO_CARD_FALLBACK "$FALLBACK" || {
    echo "LOG_RING_HOST_TEST=FAIL stage=no_card_fallback_missing" >&2
    exit 1
}
ALTSCREEN_CHAIN_VOLUME="$ROOT/missing" sh "$SCRIPT" line mirror "$ROOT/no-parent/fallback.log" NO_STORAGE

# Pruning may remove archives; it must keep the bounded direct ring.
mkdir -p "$CARD/MMI-Cockpit-Carplay/logs/boots"
dd if=/dev/zero of="$CARD/MMI-Cockpit-Carplay/logs/boots/old.log" bs=1024 count=8 2>/dev/null
ALTS_LOG_PRUNE_KIB=8 sh "$SCRIPT" prune
[ -f "$CARD/MMI-Cockpit-Carplay/logs/mirror.log" ] || {
    echo "LOG_RING_HOST_TEST=FAIL stage=prune_removed_live_ring" >&2
    exit 1
}
[ ! -f "$CARD/MMI-Cockpit-Carplay/logs/boots/old.log" ] || {
    echo "LOG_RING_HOST_TEST=FAIL stage=prune_did_not_remove_archive" >&2
    du -sk "$CARD/MMI-Cockpit-Carplay/logs" >&2 || true
    find "$CARD/MMI-Cockpit-Carplay/logs" -maxdepth 2 -type f -ls >&2 || true
    exit 1
}

echo 'LOG_RING_HOST_TEST=PASS'
