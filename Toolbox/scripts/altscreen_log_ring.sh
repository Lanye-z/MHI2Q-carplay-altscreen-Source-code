#!/bin/sh
# SD-first, bounded text logger for the private111 sidecar. State/IPC stays in /tmp.
set -u
LC_ALL=C
export LC_ALL

SEGMENT_BYTES=20971520
HISTORY_SLOTS=15
PRUNE_KIB=917504
TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
if [ "$TESTING" = 1 ]; then
    case "${ALTS_LOG_SEGMENT_BYTES:-}" in ''|*[!0-9]*) ;; *) SEGMENT_BYTES=$ALTS_LOG_SEGMENT_BYTES ;; esac
    case "${ALTS_LOG_HISTORY_SLOTS:-}" in ''|*[!0-9]*) ;; *) HISTORY_SLOTS=$ALTS_LOG_HISTORY_SLOTS ;; esac
    case "${ALTS_LOG_PRUNE_KIB:-}" in ''|*[!0-9]*) ;; *) PRUNE_KIB=$ALTS_LOG_PRUNE_KIB ;; esac
fi
[ "$HISTORY_SLOTS" -gt 0 ] || HISTORY_SLOTS=15
[ "$SEGMENT_BYTES" -gt 0 ] || SEGMENT_BYTES=20971520

find_volume() {
    if [ "$TESTING" = 1 ]; then
        candidate=${ALTSCREEN_CHAIN_VOLUME:-}
        [ -n "$candidate" ] && [ -d "$candidate/Toolbox" ] &&
        [ -d "$candidate/MMI-Cockpit-Carplay/state" ] &&
        [ -d "$candidate/MMI-Cockpit-Carplay/logs" ] && printf '%s\n' "$candidate"
        return
    fi
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        [ -d "$candidate/Toolbox" ] &&
        [ -d "$candidate/MMI-Cockpit-Carplay/state" ] &&
        [ -d "$candidate/MMI-Cockpit-Carplay/logs" ] && {
            printf '%s\n' "$candidate"
            return
        }
    done
}

append_sd_line() (
    volume=$1
    line=$2
    root="$volume/MMI-Cockpit-Carplay/logs"
    current="$root/$STREAM.log"
    cursor="$root/.$STREAM.cursor"
    lock="$root/.$STREAM.lock"
    # Several launcher, watcher and sidecar processes share mirror.log. An
    # atomic directory makes rotation and cursor updates one transaction.
    # A busy or stale lock is an SD write failure for this line: use /tmp.
    mkdir "$lock" 2>/dev/null || exit 1
    trap 'rmdir "$lock" 2>/dev/null || true' 0
    : >> "$current" 2>/dev/null || exit 1
    size=$(wc -c < "$current" 2>/dev/null || echo 0)
    bytes=${#line}
    case "$size" in ''|*[!0-9]*) size=0 ;; esac
    if [ "$size" -gt "$SEGMENT_BYTES" ]; then
        : > "$current" 2>/dev/null || exit 1
        size=0
    fi
    if [ $((size + bytes + 1)) -gt "$SEGMENT_BYTES" ]; then
        slot=$(cat "$cursor" 2>/dev/null || echo 0)
        case "$slot" in ''|*[!0-9]*) slot=0 ;; esac
        slot=$((slot % HISTORY_SLOTS))
        history="$current.$slot"
        rm -f "$history" 2>/dev/null || exit 1
        mv "$current" "$history" 2>/dev/null || exit 1
        printf '%s\n' "$(( (slot + 1) % HISTORY_SLOTS ))" > "$cursor" 2>/dev/null || exit 1
    fi
    printf '%s\n' "$line" >> "$current" 2>/dev/null
)

append_line() {
    max_line=4096
    [ "$SEGMENT_BYTES" -gt "$max_line" ] || max_line=$((SEGMENT_BYTES - 1))
    line=$(printf "%.${max_line}s" "$1")
    volume=$(find_volume)
    if [ -n "$volume" ] && append_sd_line "$volume" "$line" 2>/dev/null; then return 0; fi
    if [ -f "$FALLBACK" ] && [ "$(wc -c < "$FALLBACK" 2>/dev/null || echo 0)" -ge 16777216 ]; then
        ( : > "$FALLBACK" ) 2>/dev/null || true
    fi
    ( printf '%s\n' "$line" >> "$FALLBACK" ) 2>/dev/null || true
}

# The three direct streams have fixed maxima (320+320+32 MiB). Retire old
# diagnostic/legacy files at 896 MiB, leaving 128 MiB for concurrent writes.
# Every candidate is constrained under the discovered test-card log root.
prune_logs() {
    volume=$(find_volume)
    [ -n "$volume" ] || return 0
    root="$volume/MMI-Cockpit-Carplay/logs"
    [ -d "$root" ] || return 0
    used=$(du -sk "$root" 2>/dev/null | awk '{print $1}')
    case "$used" in ''|*[!0-9]*) return 0 ;; esac
    [ "$used" -le "$PRUNE_KIB" ] && return 0
    # Build ls arguments without word-splitting paths, then process oldest
    # modification time first. Only files beneath this card's log root qualify.
    find "$root" -type f 2>/dev/null | (
        set --
        while IFS= read -r candidate; do set -- "$@" "$candidate"; done
        [ "$#" -gt 0 ] || exit 0
        ls -tr "$@" 2>/dev/null | while IFS= read -r candidate; do
            case "$candidate" in
              "$root"/altscreen_hook.log*|"$root"/mirror.log*|"$root"/mmi-mirror-controller.log*|"$root"/boot-entry.log*|"$root"/.*.cursor) continue ;;
              "$root"/*) ;;
              *) continue ;;
            esac
            rm -f "$candidate" 2>/dev/null || continue
            used=$(du -sk "$root" 2>/dev/null | awk '{print $1}')
            case "$used" in ''|*[!0-9]*) break ;; esac
            [ "$used" -le "$PRUNE_KIB" ] && break
        done
    )
}

case "${1:-}" in
  pipe)
    STREAM=${2:-}; FALLBACK=${3:-}
    case "$STREAM" in
      mirror) ;;
      boot-entry) SEGMENT_BYTES=1048576; HISTORY_SLOTS=2 ;;
      *) exit 2 ;;
    esac
    [ -n "$FALLBACK" ] || exit 2
    while IFS= read -r input || [ -n "$input" ]; do append_line "$input"; done
    ;;
  line)
    STREAM=${2:-}; FALLBACK=${3:-}
    [ "$STREAM" = mirror ] && [ -n "$FALLBACK" ] || exit 2
    shift 3
    append_line "$*"
    ;;
  prune) prune_logs ;;
  *) echo 'usage: altscreen_log_ring.sh pipe {mirror|boot-entry} fallback | line mirror fallback text | prune' >&2; exit 2 ;;
esac
