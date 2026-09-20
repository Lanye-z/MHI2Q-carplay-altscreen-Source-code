#!/bin/sh
# Independent boot observer: never loads, restarts, or arms CarPlay.
set -u

# QNX compatibility: some vehicle mkdir implementations return EEXIST for
# `mkdir -p` when the final directory already exists. Idempotent directory
# creation must therefore test first; lock acquisition still uses bare mkdir.
ensure_dirs() {
    for dir in "$@"; do
        [ -d "$dir" ] && continue
        mkdir -p "$dir" || return 1
    done
    return 0
}
# The boot block runs before OEM startup exports its application environment.
# A background child cannot inherit exports performed later by its parent.
PATH=${PATH:-/bin:/usr/bin}:/proc/boot:/armle/bin:/armle/scripts:/bin:/usr/bin:/usr/sbin:/sbin:/mnt/app/armle/bin:/mnt/app/armle/sbin:/mnt/app/armle/usr/bin:/mnt/app/armle/usr/sbin:/eso/bin:/eso/bin/apps
LD_LIBRARY_PATH=${LD_LIBRARY_PATH:-}:/proc/boot:/usr/lib:/armle/lib:/armle/lib/dll:/lib:/mnt/app/root/carplay-altscreen/lib:/eso/lib:/mnt/app/usr/lib:/mnt/app/armle/lib:/mnt/app/armle/lib/dll:/mnt/app/armle/usr/lib:/lib/dll
export PATH LD_LIBRARY_PATH
ROOT=""; INTERVAL=2; ITERATIONS=0; PROBE_SECONDS=5
if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
    ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) exit 2 ;; esac
    INTERVAL=${ALTS_DIAG_INTERVAL:-0.1}
    ITERATIONS=${ALTS_DIAG_ITERATIONS:-5}
    PROBE_SECONDS=${ALTS_DIAG_PROBE_SECONDS:-1}
fi
BASE="$ROOT/tmp/MMI-Cockpit-Carplay/diagnostics"
ENABLED="$ROOT/mnt/app/root/carplay-altscreen/state/diagnostics.enabled"
[ -f "$ENABLED" ] || exit 0
# Probe execution, not just command presence: mounted commands can still lack
# their shared libraries early in boot. This observer is already asynchronous.
ready_wait=0
while ! (date +%Y >/dev/null && printf '%s' ready | wc -c >/dev/null &&
         printf '%s' ready | tail -c 1 >/dev/null &&
         printf '%s' ready | cksum >/dev/null) 2>/dev/null; do
    echo "BOOT_ENV_WAIT step=$ready_wait"
    ready_wait=$((ready_wait + 1))
    [ "$ready_wait" -lt 60 ] || { echo "BOOT_ENV_UNAVAILABLE"; exit 1; }
    sleep 2 || exit 1
done
select_hook_source() {
    latest=$(ls -t \
        "$VOLUME/MMI-Cockpit-Carplay/logs/altscreen_hook.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay.altscreen_hook.log" \
        "$ROOT/tmp/altscreen_hook.log" 2>/dev/null | head -n 1)
    printf '%s\n' "${latest:-$ROOT/tmp/MMI-Cockpit-Carplay/altscreen_hook.log}"
}
select_boot_entry_source() {
    for candidate in \
        "$ROOT/tmp/MMI-Cockpit-Carplay/boot_entry.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay.boot_entry.log"; do
        [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    printf '%s\n' "$ROOT/tmp/MMI-Cockpit-Carplay/boot_entry.log"
}
select_mirror_log_source() {
    latest=$(ls -t \
        "$VOLUME/MMI-Cockpit-Carplay/logs/mirror.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/mirror.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay.mirror.log" 2>/dev/null | head -n 1)
    printf '%s\n' "${latest:-$ROOT/tmp/MMI-Cockpit-Carplay/mirror/mirror.log}"
}
select_mirror_autostart_source() {
    for candidate in \
        "$VOLUME/MMI-Cockpit-Carplay/logs/mirror-autorestart.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/autostart.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay.mirror.autostart.log"; do
        [ -f "$candidate" ] && { printf '%s\n' "$candidate"; return 0; }
    done
    printf '%s\n' "$ROOT/tmp/MMI-Cockpit-Carplay/mirror/autostart.log"
}
select_controller_log_source() {
    latest=$(ls -t \
        "$VOLUME/MMI-Cockpit-Carplay/logs/mmi-mirror-controller.log" \
        "$ROOT/tmp/mmi-mirror-controller.log" \
        "$ROOT/tmp/MMI-Cockpit-Carplay/mmi-mirror-controller.log" 2>/dev/null | head -n 1)
    printf '%s\n' "${latest:-$ROOT/tmp/mmi-mirror-controller.log}"
}
select_oem_geometry_history_source() {
    printf '%s\n' "$ROOT/tmp/carplay-oem-geometry.log"
}
select_oem_displaymanager_api_source() {
    printf '%s\n' "$ROOT/tmp/carplay-oem-displaymanager-read-api.log"
}
flat_plain_append() {
    cat "$1" >> "$2" 2>/dev/null && return 0
    fallback="$ROOT/tmp/MMI-Cockpit-Carplay.flat-diagnostics.log"
    if [ -f "$fallback" ] && [ "$(wc -c < "$fallback")" -ge 16777216 ]; then
        : > "$fallback" 2>/dev/null || true
    fi
    cat "$1" >> "$fallback" 2>/dev/null
}
flat_capture_delta() {
    flat_source=$1; flat_offset=$2; flat_target=$3; flat_temp=$4
    [ -f "$flat_source" ] || { echo "$flat_offset"; return 0; }
    flat_size=$(wc -c < "$flat_source")
    [ "$flat_size" -ge "$flat_offset" ] || flat_offset=0
    if [ $((flat_size - flat_offset)) -gt 8388608 ]; then flat_offset=$((flat_size - 8388608)); fi
    if [ "$flat_size" -gt "$flat_offset" ]; then
        tail -c "+$((flat_offset + 1))" "$flat_source" > "$flat_temp" 2>/dev/null || { echo "$flat_offset"; return 0; }
        if flat_plain_append "$flat_temp" "$flat_target" 2>/dev/null; then flat_offset=$flat_size; fi
        rm -f "$flat_temp"
    fi
    echo "$flat_offset"
}
flat_probe() {
    flat_name=$1; shift
    flat_raw="${FLAT_PREFIX}_${flat_name}.raw"
    flat_out="${FLAT_PREFIX}_${flat_name}.out"
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "MISSING_COMMAND $1" > "$flat_out"
    else
        (exec "$@") > "$flat_raw" 2>&1 &
        flat_child=$!
        (sleep "$PROBE_SECONDS"; kill -KILL "$flat_child" 2>/dev/null || true) &
        flat_timer=$!
        wait "$flat_child"; flat_rc=$?
        kill "$flat_timer" 2>/dev/null || true; wait "$flat_timer" 2>/dev/null || true
        tail -c 1048576 "$flat_raw" > "$flat_out"
        echo "PROBE_RESULT status=$flat_rc command=$*" >> "$flat_out"
    fi
    flat_plain_append "$flat_out" "$FLAT_DEST/$flat_name.log" 2>/dev/null || true
    rm -f "$flat_raw" "$flat_out"
}
flat_log_event() {
    flat_event="${FLAT_PREFIX}_event"
    printf '%s %s\n' "$(date +%Y%m%d_%H%M%S)" "$*" > "$flat_event"
    flat_plain_append "$flat_event" "$FLAT_DEST/boot.log" 2>/dev/null || true
    rm -f "$flat_event"
}
run_flat_plaintext() {
    VOLUME=$1
    BOOT_ID="boot_$(date +%Y%m%d_%H%M%S)_$$"
    FLAT_DEST="$VOLUME/MMI-Cockpit-Carplay/logs/boots/$BOOT_ID"
    FLAT_PREFIX="$ROOT/tmp/altscreen_diag_$$"
    ensure_dirs "$FLAT_DEST/streams" 2>/dev/null || return 0
    flat_log_event "BOOT_BEGIN storage=FLAT_TMP_PLAINTEXT_SD volume=$VOLUME"
    flat_log_event "SD_READY volume=$VOLUME"
    flat_system="${FLAT_PREFIX}_system.raw"; flat_slog_pid=""
    if command -v sloginfo >/dev/null 2>&1; then
        (exec sloginfo -w -t) > "$flat_system" 2>&1 & flat_slog_pid=$!
    fi
    flat_hook_offset=0; flat_dio_offset=0; flat_entry_offset=0; flat_mirror_offset=0; flat_mirror_autostart_offset=0; flat_controller_offset=0; flat_oem_geometry_offset=0; flat_oem_api_offset=0; flat_system_offset=0; flat_tick=0
    while [ -f "$ENABLED" ]; do
        flat_hook_source=$(select_hook_source)
        case "$flat_hook_source" in "$VOLUME"/*) ;; *) flat_hook_offset=$(flat_capture_delta "$flat_hook_source" "$flat_hook_offset" "$FLAT_DEST/streams/hook_tmp.log" "${FLAT_PREFIX}_hook.chunk") ;; esac
        flat_dio_offset=$(flat_capture_delta "$ROOT/tmp/CinemoDioManager.log" "$flat_dio_offset" "$FLAT_DEST/streams/dio_tmp.log" "${FLAT_PREFIX}_dio.chunk")
        flat_entry_offset=$(flat_capture_delta "$(select_boot_entry_source)" "$flat_entry_offset" "$FLAT_DEST/streams/boot_entry.log" "${FLAT_PREFIX}_entry.chunk")
        flat_mirror_source=$(select_mirror_log_source)
        case "$flat_mirror_source" in "$VOLUME"/*) ;; *) flat_mirror_offset=$(flat_capture_delta "$flat_mirror_source" "$flat_mirror_offset" "$FLAT_DEST/streams/mirror.log" "${FLAT_PREFIX}_mirror.chunk") ;; esac
        flat_mirror_autostart_offset=$(flat_capture_delta "$(select_mirror_autostart_source)" "$flat_mirror_autostart_offset" "$FLAT_DEST/streams/mirror_autostart.log" "${FLAT_PREFIX}_mirror_autostart.chunk")
        flat_controller_source=$(select_controller_log_source)
        case "$flat_controller_source" in "$VOLUME"/*) ;; *) flat_controller_offset=$(flat_capture_delta "$flat_controller_source" "$flat_controller_offset" "$FLAT_DEST/streams/mmi-mirror-controller.log" "${FLAT_PREFIX}_controller.chunk") ;; esac
        flat_oem_geometry_offset=$(flat_capture_delta "$(select_oem_geometry_history_source)" "$flat_oem_geometry_offset" "$FLAT_DEST/streams/carplay-oem-geometry.log" "${FLAT_PREFIX}_oem_geometry.chunk")
        flat_oem_api_offset=$(flat_capture_delta "$(select_oem_displaymanager_api_source)" "$flat_oem_api_offset" "$FLAT_DEST/streams/carplay-oem-displaymanager-read-api.log" "${FLAT_PREFIX}_oem_api.chunk")
        if [ -f "$ROOT/tmp/carplay-oem-geometry.state" ]; then
            cp "$ROOT/tmp/carplay-oem-geometry.state" "$FLAT_DEST/streams/carplay-oem-geometry.state.new" 2>/dev/null &&
                mv "$FLAT_DEST/streams/carplay-oem-geometry.state.new" "$FLAT_DEST/streams/carplay-oem-geometry.state" 2>/dev/null || true
        fi
        if [ -f "$ROOT/tmp/mmi-mirror-displayable3.state" ]; then
            cp "$ROOT/tmp/mmi-mirror-displayable3.state" "$FLAT_DEST/streams/mmi-mirror-displayable3.state.new" 2>/dev/null &&
                mv "$FLAT_DEST/streams/mmi-mirror-displayable3.state.new" "$FLAT_DEST/streams/mmi-mirror-displayable3.state" 2>/dev/null || true
        fi
        flat_system_offset=$(flat_capture_delta "$flat_system" "$flat_system_offset" "$FLAT_DEST/streams/system.log" "${FLAT_PREFIX}_system.chunk")
        if [ -f "$flat_system" ] && [ "$(wc -c < "$flat_system")" -ge 8388608 ]; then
            flat_log_event "SYSTEM_RAW_TRIM possible_boundary_loss=1 limit_bytes=8388608"
            : > "$flat_system"
            flat_system_offset=0
        fi
        if [ "$flat_tick" = 0 ] || [ $((flat_tick % 15)) = 0 ]; then
            flat_probe processes.txt pidin arguments
            flat_probe dio_libraries.txt pidin -p dio_manager libs
            flat_probe dio_mappings.txt pidin -p dio_manager mapinfo
            flat_probe integrator_libraries.txt pidin -p smartphone_integrator libs
            flat_probe mounts.txt mount
            flat_probe network.txt netstat -an
            if [ -x "$ROOT/armle/sbin/pfctl" ]; then
                flat_probe pf_rules.txt "$ROOT/armle/sbin/pfctl" -sr
            else
                flat_probe pf_rules.txt pfctl -sr
            fi
            flat_state="${FLAT_PREFIX}_state.out"
            {
                date
                ls -la "$ROOT/mnt/app/root/carplay-altscreen/lib"
                ls -la "$ROOT/mnt/app/root/carplay-altscreen/bin/mirror"
                ls -la "$ROOT/mnt/app/root/carplay-altscreen/state"
                ls -la "$VOLUME/MMI-Cockpit-Carplay/state"
            } > "$flat_state" 2>&1
            flat_plain_append "$flat_state" "$FLAT_DEST/file_state.txt.log" 2>/dev/null || true
            rm -f "$flat_state"
        fi
        flat_tick=$((flat_tick + 1))
        /bin/sh "${0%/*}/altscreen_log_ring.sh" prune 2>/dev/null || true
        if [ "$ITERATIONS" -gt 0 ] && [ "$flat_tick" -ge "$ITERATIONS" ]; then break; fi
        sleep "$INTERVAL"
    done
    if [ -n "$flat_slog_pid" ]; then kill -KILL "$flat_slog_pid" 2>/dev/null || true; wait "$flat_slog_pid" 2>/dev/null || true; fi
    flat_log_event "DIAGNOSTICS_STOP"
    rm -f "${FLAT_PREFIX}"_* 2>/dev/null || true
    return 0
}

STORAGE_MODE=LOCAL_CACHE; LOCAL_LOCK=0
if ! ensure_dirs "$BASE/boots" 2>/dev/null; then
    echo "DIAGNOSTICS_TMP_DIRECTORY_UNAVAILABLE fallback=FLAT_TMP_PLAINTEXT_SD"
    storage_wait=0
    while [ -f "$ENABLED" ]; do
        storage_volume=""
        if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
            storage_candidate=${ALTSCREEN_CHAIN_VOLUME:-}
            if [ -n "$storage_candidate" ] && [ -d "$storage_candidate/Toolbox" ]; then
                storage_volume=$storage_candidate
            fi
        else
            for storage_candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
                if [ -d "$storage_candidate/Toolbox" ] && { [ -d "$storage_candidate/MMI-Cockpit-Carplay/backup/original" ] || [ -d "$storage_candidate/Backup/AltScreenChain/original" ]; }; then
                    storage_volume=$storage_candidate; break
                fi
            done
        fi
        if [ -n "$storage_volume" ]; then
            if [ "${ALTSCREEN_CHAIN_TESTING:-0}" != 1 ]; then
                (exec mount -uw "$storage_volume") >/dev/null 2>&1 &
                storage_mount_pid=$!
                (sleep 5; kill -KILL "$storage_mount_pid" 2>/dev/null || true) & storage_timer=$!
                wait "$storage_mount_pid" || true; kill "$storage_timer" 2>/dev/null || true; wait "$storage_timer" 2>/dev/null || true
            fi
            if ensure_dirs "$storage_volume/MMI-Cockpit-Carplay/logs/boots" 2>/dev/null; then
                run_flat_plaintext "$storage_volume"
                exit 0
            fi
        fi
        echo "SD_WAIT storage=FLAT_TMP_PLAINTEXT_SD attempt=$storage_wait"
        storage_wait=$((storage_wait + 1))
        if [ "$ITERATIONS" -gt 0 ] && [ "$storage_wait" -ge "$ITERATIONS" ]; then exit 0; fi
        sleep "$INTERVAL"
    done
    exit 0
fi
# A mkdir guard prevents duplicate observers without trusting/reusing stale PIDs.
# Never persist this guard on SD: it would survive a reboot and suppress logging.
if [ "$STORAGE_MODE" = LOCAL_CACHE ]; then
    mkdir "$BASE/observer.lock" 2>/dev/null || { echo "DIAGNOSTICS_ALREADY_RUNNING_OR_STALE_LOCK path=$BASE/observer.lock"; exit 0; }
    LOCAL_LOCK=1
fi
BOOT_ID="boot_$(date +%Y%m%d_%H%M%S)_$$"
SPOOL="$BASE/boots/$BOOT_ID"
ensure_dirs "$SPOOL" || { [ "$LOCAL_LOCK" != 1 ] || rmdir "$BASE/observer.lock"; exit 1; }
exec >> "$SPOOL/observer_console.log" 2>&1
VOLUME=""; PREVIOUS=""; TICK=0; LIVE_PID=""
event() {
    printf '%s tick=%s %s\n' "$(date +%Y%m%d_%H%M%S)" "$TICK" "$*" >> "$SPOOL/boot.log"
    # Bound the event history even if the SD keeps disconnecting all day.
    if [ "$(wc -c < "$SPOOL/boot.log")" -gt 131072 ]; then
        tail -c 65536 "$SPOOL/boot.log" > "$SPOOL/boot.trim"
        mv "$SPOOL/boot.trim" "$SPOOL/boot.log"
    fi
}
probe() (
    output=$1; shift
    if ! command -v "$1" >/dev/null 2>&1; then
        echo "MISSING_COMMAND $1" > "$output"; exit 0
    fi
    (exec "$@") > "$output.raw" 2>&1 &
    child=$!
    (
        sleep "$PROBE_SECONDS"
        if kill -0 "$child" 2>/dev/null; then
            echo "PROBE_TIMEOUT command=$*" >> "$output.raw"
            kill -KILL "$child" 2>/dev/null || true
        fi
    ) &
    timer=$!
    wait "$child"; result=$?
    kill "$timer" 2>/dev/null || true
    wait "$timer" 2>/dev/null || true
    tail -c 1048576 "$output.raw" > "$output"
    echo "PROBE_RESULT status=$result command=$*" >> "$output"
    rm -f "$output.raw"
)
discover() {
    VOLUME=""
    if [ "${ALTSCREEN_CHAIN_TESTING:-0}" = 1 ]; then
        candidate=${ALTSCREEN_CHAIN_VOLUME:-}
        [ -n "$candidate" ] && [ -d "$candidate/Toolbox" ] && VOLUME=$candidate
    else
        for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
            # Only write to a test card with an AltScreen installation/backup.
            if [ -d "$candidate/Toolbox" ] && { [ -d "$candidate/MMI-Cockpit-Carplay/backup/original" ] || [ -d "$candidate/Backup/AltScreenChain/original" ]; }; then
                VOLUME=$candidate; break
            fi
        done
    fi
    return 0
}
snapshot() {
    event "SNAPSHOT_BEGIN"
    probe "$SPOOL/processes.txt" pidin arguments
    probe "$SPOOL/dio_libraries.txt" pidin -p dio_manager libs
    probe "$SPOOL/dio_mappings.txt" pidin -p dio_manager mapinfo
    probe "$SPOOL/integrator_libraries.txt" pidin -p smartphone_integrator libs
    probe "$SPOOL/mounts.txt" mount
    probe "$SPOOL/network.txt" netstat -an
    if [ -x "$ROOT/armle/sbin/pfctl" ]; then
        probe "$SPOOL/pf_rules.txt" "$ROOT/armle/sbin/pfctl" -sr
    else
        probe "$SPOOL/pf_rules.txt" pfctl -sr
    fi
    probe "$SPOOL/system_slog.txt" sloginfo
    {
        date
        echo "VOLUME=$VOLUME"
        ls -la "$ROOT/mnt/app/root/carplay-altscreen/lib"
        ls -la "$ROOT/mnt/app/root/carplay-altscreen/bin/mirror"
        ls -la "$ROOT/mnt/app/root/carplay-altscreen/state"
        for lib in libairplay.so libairplax.so libNmeBaseClasses.so; do
            cksum "$ROOT/mnt/app/root/carplay-altscreen/lib/$lib"
        done
        if [ -n "$VOLUME" ]; then
            ls -la "$VOLUME/MMI-Cockpit-Carplay/state"
            cat "$VOLUME/MMI-Cockpit-Carplay/state/run_id" 2>/dev/null
        fi
    } > "$SPOOL/file_state.txt" 2>&1
    for name in smartphone_integrator dio_manager; do
        source="$ROOT/mnt/system/etc/eso/production/$name.json"
        if [ -f "$source" ]; then cp "$source" "$SPOOL/$name.json"; fi
    done
    event "SNAPSHOT_END"
    for source in "$SPOOL/processes.txt" "$SPOOL/dio_libraries.txt" "$SPOOL/dio_mappings.txt" "$SPOOL/integrator_libraries.txt" "$SPOOL/network.txt" "$SPOOL/pf_rules.txt" "$SPOOL/file_state.txt"; do
        {
            printf '\nSTATE_OBSERVATION time=%s tick=%s source=%s\n' "$(date +%Y%m%d_%H%M%S)" "$TICK" "${source##*/}"
            cat "$source"
        } >> "$SPOOL/state_history.log"
    done
    if [ -f "$SPOOL/state_history.log" ] && [ "$(wc -c < "$SPOOL/state_history.log")" -gt 4194304 ]; then
        tail -c 2097152 "$SPOOL/state_history.log" > "$SPOOL/state_history.trim" &&
            mv "$SPOOL/state_history.trim" "$SPOOL/state_history.log"
    fi
    # Preserve the first boot observation even after dio starts or restarts.
    if [ ! -f "$SPOOL/initial_snapshot.complete" ]; then
        for source in "$SPOOL"/*.txt "$SPOOL"/*.json; do
            [ -f "$source" ] || continue
            cp "$source" "$SPOOL/initial_${source##*/}" || return 1
        done
        touch "$SPOOL/initial_snapshot.complete"
    fi
}
runtime_logs() {
    entry_source=$(select_boot_entry_source)
    if [ -f "$entry_source" ]; then
        tail -c 131072 "$entry_source" > "$SPOOL/boot_entry.log"
    fi

    hook_source=$(select_hook_source)
    hook_output="$SPOOL/tmp_altscreen_hook.log"
    if [ -f "$hook_source" ]; then
        tail -c 1048576 "$hook_source" > "$hook_output.new" && mv "$hook_output.new" "$hook_output"
    elif [ ! -f "$hook_output" ]; then
        echo "MISSING $hook_source" > "$hook_output"
    fi

    dio_source="$ROOT/tmp/CinemoDioManager.log"
    dio_output="$SPOOL/tmp_CinemoDioManager.log"
    if [ -f "$dio_source" ]; then
        tail -c 1048576 "$dio_source" > "$dio_output.new" && mv "$dio_output.new" "$dio_output"
    elif [ ! -f "$dio_output" ]; then
        echo "MISSING $dio_source" > "$dio_output"
    fi

    mirror_source=$(select_mirror_log_source)
    mirror_output="$SPOOL/tmp_mirror.log"
    if [ -f "$mirror_source" ]; then
        tail -c 1048576 "$mirror_source" > "$mirror_output.new" && mv "$mirror_output.new" "$mirror_output"
    elif [ ! -f "$mirror_output" ]; then
        echo "MISSING $mirror_source" > "$mirror_output"
    fi

    mirror_autostart_source=$(select_mirror_autostart_source)
    mirror_autostart_output="$SPOOL/tmp_mirror_autostart.log"
    if [ -f "$mirror_autostart_source" ]; then
        tail -c 1048576 "$mirror_autostart_source" > "$mirror_autostart_output.new" &&
            mv "$mirror_autostart_output.new" "$mirror_autostart_output"
    elif [ ! -f "$mirror_autostart_output" ]; then
        echo "MISSING $mirror_autostart_source" > "$mirror_autostart_output"
    fi

    controller_source=$(select_controller_log_source)
    controller_output="$SPOOL/tmp_mmi-mirror-controller.log"
    if [ -f "$controller_source" ]; then
        tail -c 1048576 "$controller_source" > "$controller_output.new" &&
            mv "$controller_output.new" "$controller_output"
    elif [ ! -f "$controller_output" ]; then
        echo "MISSING $controller_source" > "$controller_output"
    fi

    oem_state_source="$ROOT/tmp/carplay-oem-geometry.state"
    oem_state_output="$SPOOL/tmp_carplay-oem-geometry.state"
    if [ -f "$oem_state_source" ]; then
        cp "$oem_state_source" "$oem_state_output.new" 2>/dev/null &&
            mv "$oem_state_output.new" "$oem_state_output"
    elif [ ! -f "$oem_state_output" ]; then
        echo "MISSING $oem_state_source" > "$oem_state_output"
    fi

    displayable_state_source="$ROOT/tmp/mmi-mirror-displayable3.state"
    displayable_state_output="$SPOOL/tmp_mmi-mirror-displayable3.state"
    if [ -f "$displayable_state_source" ]; then
        cp "$displayable_state_source" "$displayable_state_output.new" 2>/dev/null &&
            mv "$displayable_state_output.new" "$displayable_state_output"
    elif [ ! -f "$displayable_state_output" ]; then
        echo "MISSING $displayable_state_source" > "$displayable_state_output"
    fi

    oem_history_source=$(select_oem_geometry_history_source)
    oem_history_output="$SPOOL/tmp_carplay-oem-geometry.log"
    if [ -f "$oem_history_source" ]; then
        tail -c 1048576 "$oem_history_source" > "$oem_history_output.new" &&
            mv "$oem_history_output.new" "$oem_history_output"
    elif [ ! -f "$oem_history_output" ]; then
        echo "MISSING $oem_history_source" > "$oem_history_output"
    fi

    oem_api_source=$(select_oem_displaymanager_api_source)
    oem_api_output="$SPOOL/tmp_carplay-oem-displaymanager-read-api.log"
    if [ -f "$oem_api_source" ]; then
        tail -c 262144 "$oem_api_source" > "$oem_api_output.new" &&
            mv "$oem_api_output.new" "$oem_api_output"
    elif [ ! -f "$oem_api_output" ]; then
        echo "MISSING $oem_api_source" > "$oem_api_output"
    fi
}
copy_snapshot() {
    cp "$1" "$2"
}
flush_sd() {
    [ -n "$VOLUME" ] && [ -d "$VOLUME/Toolbox" ] || return 0
    dest="$VOLUME/MMI-Cockpit-Carplay/logs/boots/$BOOT_ID"
    if ! ensure_dirs "$dest" 2>/dev/null; then
        event "SD_WRITE_FAILED volume=$VOLUME"; return 0
    fi
    # Publish via temp names so an interrupted copy retains the previous snapshot.
    for source in "$SPOOL"/*; do
        [ -f "$source" ] || continue
        case "$source" in *.raw|*.new) continue ;; esac
        name=${source##*/}
        if ! copy_snapshot "$source" "$dest/$name.new" 2>/dev/null ||
           ! mv "$dest/$name.new" "$dest/$name" 2>/dev/null; then
            rm -f "$dest/$name.new" 2>/dev/null || true
            event "SD_WRITE_FAILED file=$name"; return 0
        fi
    done
    # Operations attempted before SD discovery remain recoverable this boot.
    if [ -d "$BASE/operations" ]; then
        ensure_dirs "$VOLUME/MMI-Cockpit-Carplay/logs/operations"
        for source in "$BASE/operations"/*.log; do
            [ -f "$source" ] || continue
            name=${source##*/}
            if copy_snapshot "$source" "$VOLUME/MMI-Cockpit-Carplay/logs/operations/$name.new" 2>/dev/null; then
                mv "$VOLUME/MMI-Cockpit-Carplay/logs/operations/$name.new" \
                   "$VOLUME/MMI-Cockpit-Carplay/logs/operations/$name" 2>/dev/null || true
            else
                rm -f "$VOLUME/MMI-Cockpit-Carplay/logs/operations/$name.new" 2>/dev/null || true
            fi
        done
    fi
    /bin/sh "$HELPER_DIR/altscreen_log_ring.sh" prune 2>/dev/null || true
}
finish() {
    trap - 0
    event "DIAGNOSTICS_STOP"
    if [ -n "$LIVE_PID" ]; then
        kill -TERM "$LIVE_PID" 2>/dev/null || true
        wait "$LIVE_PID" 2>/dev/null || true
    fi
    runtime_logs
    flush_sd
    # Diagnostics stderr is bounded as well (for example, an SD that fills up).
    if [ "$(wc -c < "$SPOOL/observer_console.log")" -gt 131072 ]; then
        tail -c 65536 "$SPOOL/observer_console.log" > "$SPOOL/observer_console.previous.log"
        : > "$SPOOL/observer_console.log"
    fi
    if [ "$LOCAL_LOCK" = 1 ]; then rmdir "$BASE/observer.lock" 2>/dev/null || true; fi
}
trap finish 0
trap 'exit 0' 1 2 15
event "BOOT_BEGIN pid=$$ script=$0 storage=$STORAGE_MODE"
if [ -n "${ALTSCREEN_WRAPPER_DIR:-}" ]; then
    HELPER_DIR=$ALTSCREEN_WRAPPER_DIR
else
    HELPER_DIR=${0%/*}
    [ "$HELPER_DIR" != "$0" ] || HELPER_DIR=.
fi
if [ -f "$HELPER_DIR/altscreen_live_diag.sh" ]; then
    /bin/sh "$HELPER_DIR/altscreen_live_diag.sh" "$SPOOL" "$$" &
    LIVE_PID=$!
else event "LIVE_HELPER_MISSING script=$HELPER_DIR/altscreen_live_diag.sh"; fi
while [ -f "$ENABLED" ]; do
    discover
    printf '%s\n' "$VOLUME" > "$SPOOL/volume.path.new"
    mv "$SPOOL/volume.path.new" "$SPOOL/volume.path"
    if [ "$VOLUME" != "$PREVIOUS" ] || [ "$TICK" = 0 ]; then
        if [ -n "$VOLUME" ]; then
            event "SD_READY volume=$VOLUME"
            if [ "${ALTSCREEN_CHAIN_TESTING:-0}" != 1 ]; then
                probe "$SPOOL/sd_mount.txt" mount -uw "$VOLUME"
            fi
        else event "SD_WAIT candidates=8"; fi
        PREVIOUS=$VOLUME
        snapshot
    elif [ "$TICK" -lt 30 ] && [ $((TICK % 3)) = 0 ]; then snapshot
    elif [ $((TICK % 15)) = 0 ]; then snapshot; fi
    runtime_logs
    flush_sd
    TICK=$((TICK + 1))
    if [ "$ITERATIONS" -gt 0 ] && [ "$TICK" -ge "$ITERATIONS" ]; then break; fi
    sleep "$INTERVAL"
done
