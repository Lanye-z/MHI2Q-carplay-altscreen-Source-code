#!/bin/sh
# AltScreen controller router.
#
# Active installation policy (2026-09-17): UNIVERSAL ONLY.
#   1. every supported AUG22 installation routes to the standalone universal
#      LD_PRELOAD controller;
#   2. K1004/P1404 profile artifacts and the known controller remain in the
#      repository only as historical/reference material;
#   3. the known controller may still be invoked for RESTORE only when a vehicle
#      was installed by an older profile-based package;
#   4. anything outside the supported AUG22 train is refused before mutation.
#
# Direct-display integrates the proven MMI displayable3 GLES backend as a SHM sidecar.
# It is staged transactionally with the AUG22 runtime; Java/HMI remains the sole
# terminal/context owner.
#
# Companion scripts are staged only below /mnt/app/root/carplay-altscreen.  The
# installer never writes /eso/hmi/engdefs/scripts/mqb, because that mount is not
# consistently writable across AUG22 vehicles.
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


TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
FIXED_ROOT=""
VOLUME=""
BASE="$0"
RESOLVED=$(command -v -- "$BASE" 2>/dev/null)
[ -n "$RESOLVED" ] || RESOLVED="$BASE"
SCRIPTDIR=$(CDPATH='' cd -P -- "$(dirname -- "$RESOLVED")" 2>/dev/null && pwd -P)
[ -n "$SCRIPTDIR" ] || { echo "FAIL: cannot resolve controller directory" >&2; exit 126; }
KNOWN="$SCRIPTDIR/altscreen_chain_test_known.sh"
UNIVERSAL="$SCRIPTDIR/altscreen_chain_test_universal.sh"

fail(){ echo "FAIL: $1" >&2; exit 1; }
p(){ printf '%s%s\n' "$FIXED_ROOT" "$1"; }

if [ "$TESTING" = 1 ]; then
    FIXED_ROOT=${ALTSCREEN_CHAIN_ROOT:-}
    VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
    case "$FIXED_ROOT" in /tmp/*|/var/tmp/*) ;; *) fail "invalid ALTSCREEN_CHAIN_ROOT" ;; esac
    case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) fail "invalid ALTSCREEN_CHAIN_VOLUME" ;; esac
else
    for candidate in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
        if [ -d "$candidate/Toolbox" ]; then VOLUME=$candidate; break; fi
    done
    [ -n "$VOLUME" ] || fail "no Toolbox SD card discovered"
fi

SD_ROOT="$VOLUME/MMI-Cockpit-Carplay"
STATE_DIR="$SD_ROOT/state"
LOG_ROOT="$SD_ROOT/logs"
BACKUP_ROOT="$SD_ROOT/backup"
STAGING_ROOT="$SD_ROOT/staging"
LEGACY_STATE_DIR="$VOLUME/Log/MMI-Cockpit-Carplay/current"
ROUTE_FILE="$STATE_DIR/firmware_profile.txt"
INSTALLED_MARKER="$STATE_DIR/INSTALLED"
LEGACY_ROUTE_FILE="$LEGACY_STATE_DIR/firmware_profile.txt"
LEGACY_INSTALLED_MARKER="$LEGACY_STATE_DIR/INSTALLED"
ARTIFACT_DIR="$VOLUME/Toolbox/carplay_alt_screen"
SD_SCRIPTS="$VOLUME/Toolbox/scripts"
MIRROR_SD="$ARTIFACT_DIR/mirror_display/release"
MIRROR_OWNER=".mmi-cockpit-carplay-mirror-owner"
PERSIST_DIAG_SD="$SD_SCRIPTS/altscreen_persistent_diag.sh"
LIVE_DIO_CANDIDATES="/eso/bin/apps/dio_manager /mnt/app/eso/bin/apps/dio_manager"
LIVE_LIBAIRPLAY="/eso/lib/libairplay.so"

RUNTIME_ROOT="$(p /mnt/app/root/carplay-altscreen)"
RUNTIME_BIN="$RUNTIME_ROOT/bin"
RUNTIME_STAGE="$(p /mnt/app/root/.carplay-altscreen.new.$$)"
RUNTIME_PREV="$(p /mnt/app/root/.carplay-altscreen.previous)"
RUNTIME_OWNER=.mmi-cockpit-carplay-runtime-owner
RUNTIME_PUBLISHED=0
RUNTIME_HAD_CURRENT=0
RUNTIME_SCRIPTS="altscreen_chain_test.sh altscreen_chain_test_known.sh altscreen_chain_test_universal.sh altscreen_persistent_diag.sh altscreen_adaptive_diag.sh altscreen_boot_diag.sh altscreen_live_diag.sh altscreen_preload.awk install_mmi_cockpit_carplay_rx.sh start_mmi_cockpit_carplay_test.sh start_mmi_cockpit_carplay_rx_test.sh force_start_mmi_cockpit_carplay_rx_test.sh stop_mmi_cockpit_carplay_test.sh status_mmi_cockpit_carplay_test.sh finish_mmi_cockpit_carplay_test.sh"

mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }

locate_first(){
    for cand in $1; do [ -e "$(p "$cand")" ] && { echo "$cand"; return 0; }; done
    return 1
}

read_aug22_train(){
    for rel in /net/rcc/dev/shmem/version.txt /dev/shmem/version.txt /net/mmx/dev/shmem/version.txt; do
        path=$(p "$rel")
        [ -r "$path" ] || continue
        train=$(sed -n '/Current train/p' "$path" | head -n 1)
        [ -n "$train" ] || continue
        echo "$train"
        return 0
    done
    return 1
}

select_install_route(){
    requested=${1:-}

    # Test harness compatibility: legacy profile names are accepted only as
    # aliases for UNIVERSAL so tests cannot accidentally re-enable known install.
    if [ "$TESTING" = 1 ] && [ -n "${ALTSCREEN_TEST_FORCE_PROFILE:-}" ]; then
        case "$ALTSCREEN_TEST_FORCE_PROFILE" in
          UNIVERSAL) echo UNIVERSAL; return 0 ;;
          K1004|P1404)
            echo "LEGACY_PROFILE_FORCE_IGNORED requested=$ALTSCREEN_TEST_FORCE_PROFILE route=UNIVERSAL" >&2
            echo UNIVERSAL
            return 0
            ;;
          LEGACY_FLAT) echo LEGACY_FLAT; return 0 ;;
          *) return 1 ;;
        esac
    fi
    if [ "$TESTING" = 1 ] && [ ! -d "$ARTIFACT_DIR/profiles" ] && [ ! -d "$ARTIFACT_DIR/universal" ]; then
        echo LEGACY_FLAT
        return 0
    fi

    # A caller from an older menu/script may still pass K1004 or P1404.  Treat
    # those names as deprecated aliases, never as selectors for profile payloads.
    case "$requested" in
      ""|UNIVERSAL) ;;
      K1004|P1404)
        echo "LEGACY_PROFILE_REQUEST_IGNORED requested=$requested route=UNIVERSAL" >&2
        ;;
      *)
        echo "PROFILE_REFUSED unsupported=$requested" >&2
        return 1
        ;;
    esac

    # Universal still requires the stock inputs it will reuse.  We deliberately
    # do not fingerprint them for route selection.
    dio_rel=$(locate_first "$LIVE_DIO_CANDIDATES") || return 1
    [ -s "$(p "$LIVE_LIBAIRPLAY")" ] && [ -s "$(p "$dio_rel")" ] || return 1

    train=$(read_aug22_train || true)
    case "$train" in
      *AUG22*)
        echo "AUG22_UNIVERSAL_ROUTE train='$train' stock_reuse=YES profile_overlay=DISABLED" >&2
        echo UNIVERSAL
        return 0
        ;;
      *)
        echo "PROFILE_REFUSED aug22_proof=ABSENT train='$train' universal_only=YES" >&2
        return 1
        ;;
    esac
}

validate_runtime_sources(){
    for name in $RUNTIME_SCRIPTS; do
        src="$SD_SCRIPTS/$name"
        [ -s "$src" ] || { echo "FAIL: runtime companion missing/empty: $src" >&2; return 1; }
        case "$name" in *.sh) sh -n "$src" || { echo "FAIL: runtime companion shell syntax: $name" >&2; return 1; } ;; esac
    done
    for name in carplay-alt111-mirror-display start_vehicle.sh stop_vehicle.sh BUILD_INFO.txt; do
        [ -s "$MIRROR_SD/$name" ] || { echo "FAIL: integrated direct-display sidecar missing/empty: $MIRROR_SD/$name" >&2; return 1; }
    done
    sh -n "$MIRROR_SD/start_vehicle.sh" || return 1
    sh -n "$MIRROR_SD/stop_vehicle.sh" || return 1
    return 0
}

precheck_app_runtime(){
    parent="$(p /mnt/app/root)"
    probe="$parent/.altscreen-write-test.$$"
    token="altscreen-write-test-$$"
    mount_app_rw || { echo "FAIL: cannot mount /mnt/app writable" >&2; return 1; }
    ok=1
    ensure_dirs "$parent" || ok=0
    if [ "$ok" = 1 ]; then printf '%s\n' "$token" > "$probe" 2>/dev/null || ok=0; fi
    if [ "$ok" = 1 ]; then [ "$(cat "$probe" 2>/dev/null)" = "$token" ] || ok=0; fi
    rm -f "$probe" 2>/dev/null || true
    sync >/dev/null 2>&1 || true
    if ! mount_app_ro; then
        echo "FAIL: /mnt/app write precheck could not restore read-only mount" >&2
        return 1
    fi
    [ "$ok" = 1 ] || { echo "FAIL: /mnt/app/root is not safely writable" >&2; return 1; }
    echo "APP_RUNTIME_WRITE_PRECHECK=PASS path=/mnt/app/root"
    return 0
}

install_runtime_scripts(){
    validate_runtime_sources || return 1
    [ ! -e "$RUNTIME_ROOT" ] || [ -f "$RUNTIME_ROOT/$RUNTIME_OWNER" ] || {
        echo "FAIL: refusing to replace unowned runtime: /mnt/app/root/carplay-altscreen" >&2
        return 1
    }
    [ ! -e "$RUNTIME_PREV" ] || [ -f "$RUNTIME_PREV/$RUNTIME_OWNER" ] || {
        echo "FAIL: refusing to replace unowned previous runtime" >&2
        return 1
    }
    mount_app_rw || return 1
    rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
    ensure_dirs "$RUNTIME_STAGE/bin" "$RUNTIME_STAGE/lib" "$RUNTIME_STAGE/state" "$RUNTIME_STAGE/tmp" || { mount_app_ro >/dev/null 2>&1 || true; return 1; }
    for name in $RUNTIME_SCRIPTS; do
        src="$SD_SCRIPTS/$name"; dst="$RUNTIME_STAGE/bin/$name"
        cp "$src" "$dst" && cmp -s "$src" "$dst" || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            return 1
        }
        case "$name" in *.sh) chmod 755 "$dst" ;; *) chmod 644 "$dst" ;; esac || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            return 1
        }
    done
    ensure_dirs "$RUNTIME_STAGE/bin/mirror" || { rm -rf "$RUNTIME_STAGE" 2>/dev/null || true; mount_app_ro >/dev/null 2>&1 || true; return 1; }
    for name in carplay-alt111-mirror-display libscreen_id_bridge.so start_vehicle.sh stop_vehicle.sh BUILD_INFO.txt LICENSE.MMI-MIRROR SHA256SUMS; do
        [ -f "$MIRROR_SD/$name" ] || continue
        cp "$MIRROR_SD/$name" "$RUNTIME_STAGE/bin/mirror/$name" || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            return 1
        }
    done
    chmod 755 "$RUNTIME_STAGE/bin/mirror/carplay-alt111-mirror-display"               "$RUNTIME_STAGE/bin/mirror/start_vehicle.sh"               "$RUNTIME_STAGE/bin/mirror/stop_vehicle.sh" || {
        rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        return 1
    }
    printf '%s\n' 'owner=MMI-Cockpit-Carplay' 'mode=carplay-private111-direct-display-v1' > "$RUNTIME_STAGE/bin/mirror/$MIRROR_OWNER" || return 1
    printf '%s\n' 'owner=MMI-Cockpit-Carplay' 'runtime=carplay-altscreen' > "$RUNTIME_STAGE/$RUNTIME_OWNER" || {
        rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        return 1
    }
    # Preserve the current owned Mirror as the new transaction's rollback copy.
    # The full previous runtime still remains in RUNTIME_PREV until START, so a
    # child INSTALL failure can restore the exact pre-INSTALL tree.
    if [ -d "$RUNTIME_ROOT/bin/mirror" ]; then
        [ -f "$RUNTIME_ROOT/bin/mirror/.mmi-cockpit-carplay-mirror-owner" ] || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            echo "FAIL: current unified Mirror runtime is unowned" >&2
            return 1
        }
        cp -R "$RUNTIME_ROOT/bin/mirror" "$RUNTIME_STAGE/tmp/mirror.previous" || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            return 1
        }
    fi
    if [ -d "$RUNTIME_PREV" ]; then rm -rf "$RUNTIME_PREV" || {
        rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
        mount_app_ro >/dev/null 2>&1 || true
        return 1
    }; fi
    if [ -d "$RUNTIME_ROOT" ]; then
        mv "$RUNTIME_ROOT" "$RUNTIME_PREV" || {
            rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
            mount_app_ro >/dev/null 2>&1 || true
            return 1
        }
        RUNTIME_HAD_CURRENT=1
    fi
    if ! mv "$RUNTIME_STAGE" "$RUNTIME_ROOT"; then
        [ "$RUNTIME_HAD_CURRENT" != 1 ] || mv "$RUNTIME_PREV" "$RUNTIME_ROOT" >/dev/null 2>&1 || true
        mount_app_ro >/dev/null 2>&1 || true
        return 1
    fi
    RUNTIME_PUBLISHED=1
    sync >/dev/null 2>&1 || true
    if ! mount_app_ro; then return 1; fi
    echo "RUNTIME_SCRIPTS_INSTALLED=PASS path=/mnt/app/root/carplay-altscreen/bin no_eso_write=YES"
    return 0
}

rollback_runtime_scripts(){
    mount_app_rw >/dev/null 2>&1 || return 1
    if [ "$RUNTIME_PUBLISHED" = 1 ]; then
        if [ -d "$RUNTIME_ROOT" ] && [ -f "$RUNTIME_ROOT/$RUNTIME_OWNER" ]; then rm -rf "$RUNTIME_ROOT" || true; fi
        if [ "$RUNTIME_HAD_CURRENT" = 1 ] && [ -d "$RUNTIME_PREV" ] && [ -f "$RUNTIME_PREV/$RUNTIME_OWNER" ]; then
            mv "$RUNTIME_PREV" "$RUNTIME_ROOT" >/dev/null 2>&1 || true
        fi
    fi
    rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
    sync >/dev/null 2>&1 || true
    mount_app_ro >/dev/null 2>&1 || true
    RUNTIME_PUBLISHED=0
    RUNTIME_HAD_CURRENT=0
    return 0
}

cleanup_volatile_runtime(){
    volatile_root="$(p /tmp/MMI-Cockpit-Carplay)"
    if [ -e "$volatile_root" ]; then
        rm -rf "$volatile_root" 2>/dev/null || {
            echo "WARN: project volatile namespace could not be fully removed: /tmp/MMI-Cockpit-Carplay" >&2
            return 0
        }
    fi
    echo "VOLATILE_RUNTIME_CLEANUP=PASS path=/tmp/MMI-Cockpit-Carplay"
    return 0
}

remove_runtime_scripts(){
    [ ! -e "$RUNTIME_ROOT" ] || [ -f "$RUNTIME_ROOT/$RUNTIME_OWNER" ] || {
        echo "FAIL: refusing to remove unowned runtime: /mnt/app/root/carplay-altscreen" >&2
        return 1
    }
    [ ! -e "$RUNTIME_PREV" ] || [ -f "$RUNTIME_PREV/$RUNTIME_OWNER" ] || {
        echo "FAIL: refusing to remove unowned previous runtime" >&2
        return 1
    }
    if [ -e "$RUNTIME_ROOT" ] || [ -e "$RUNTIME_PREV" ] || [ -e "$RUNTIME_STAGE" ]; then
        mount_app_rw || return 1
        [ ! -e "$RUNTIME_ROOT" ] || rm -rf "$RUNTIME_ROOT" || { mount_app_ro >/dev/null 2>&1 || true; return 1; }
        [ ! -e "$RUNTIME_PREV" ] || rm -rf "$RUNTIME_PREV" || { mount_app_ro >/dev/null 2>&1 || true; return 1; }
        rm -rf "$RUNTIME_STAGE" 2>/dev/null || true
        sync >/dev/null 2>&1 || true
        mount_app_ro || return 1
    fi
    echo "RUNTIME_SCRIPTS_REMOVED=PASS path=/mnt/app/root/carplay-altscreen"
    return 0
}

persistent_diag_helper(){
    if [ -f "$RUNTIME_BIN/altscreen_persistent_diag.sh" ]; then
        printf '%s\n' "$RUNTIME_BIN/altscreen_persistent_diag.sh"
        return 0
    fi
    if [ -f "$PERSIST_DIAG_SD" ]; then
        printf '%s\n' "$PERSIST_DIAG_SD"
        return 0
    fi
    return 1
}

route_for_existing(){
    if [ -f "$ROUTE_FILE" ]; then cat "$ROUTE_FILE"; return 0; fi
    if [ -f "$LEGACY_ROUTE_FILE" ]; then cat "$LEGACY_ROUTE_FILE"; return 0; fi
    if [ "$TESTING" = 1 ] && [ ! -d "$ARTIFACT_DIR/profiles" ] && [ ! -d "$ARTIFACT_DIR/universal" ]; then echo LEGACY_FLAT; return 0; fi
    return 1
}

delegate(){
    route=$1; shift
    case "$route" in
      UNIVERSAL)
        [ -f "$UNIVERSAL" ] || fail "AUG22 universal controller missing: $UNIVERSAL"
        /bin/sh "$UNIVERSAL" "$@"
        ;;
      K1004|P1404)
        # Historical profile runtime is intentionally unreachable.  The sole
        # exception is restoring a vehicle that was installed by an older build.
        [ "${1:-}" = restore ] || fail "legacy profile runtime is disabled ($route); run RESTORE ORIGINAL, reboot, then INSTALL to migrate to UNIVERSAL"
        [ -f "$KNOWN" ] || fail "legacy restore controller missing: $KNOWN"
        /bin/sh "$KNOWN" restore
        ;;
      LEGACY_FLAT)
        [ "$TESTING" = 1 ] || fail "LEGACY_FLAT is test-only"
        [ -f "$KNOWN" ] || fail "legacy test controller missing: $KNOWN"
        /bin/sh "$KNOWN" "$@"
        ;;
      *) fail "invalid persisted route: $route" ;;
    esac
}

delegate_install(){
    route=$1
    ensure_dirs "$STATE_DIR" "$LOG_ROOT" "$BACKUP_ROOT" "$STAGING_ROOT" || return 1
    tmp="$STATE_DIR/.child-install.$$"
    delegate "$route" install > "$tmp" 2>&1
    rc=$?
    sed 's/^INSTALL=PASS /CHILD_INSTALL=PASS /' "$tmp"
    rm -f "$tmp"
    return "$rc"
}

CMD=${1:-}
case "$CMD" in
  install)
    route=$(select_install_route "${2:-}") || exit 1
    existing_route=""
    if [ -f "$INSTALLED_MARKER" ] && [ -f "$ROUTE_FILE" ]; then existing_route="$ROUTE_FILE";
    elif [ -f "$LEGACY_INSTALLED_MARKER" ] && [ -f "$LEGACY_ROUTE_FILE" ]; then existing_route="$LEGACY_ROUTE_FILE"; fi
    if [ -n "$existing_route" ]; then
        old=$(cat "$existing_route")
        if [ "$old" != "$route" ]; then
            case "$old" in
              K1004|P1404) fail "legacy profile $old is still installed; run RESTORE ORIGINAL, reboot, then INSTALL to migrate to UNIVERSAL" ;;
              *) fail "installed route is $old but new route is $route; RESTORE ORIGINAL before switching" ;;
            esac
        fi
    fi
    echo "ROUTER_PROFILE=$route policy=AUG22_UNIVERSAL_ONLY known_profiles=REFERENCE_RESTORE_ONLY"
    validate_runtime_sources || exit 1
    precheck_app_runtime || exit 1
    if ! install_runtime_scripts; then
        rollback_runtime_scripts >/dev/null 2>&1 || true
        echo "FAIL: persistent runtime could not be staged under /mnt/app/root; no CarPlay mutation attempted" >&2
        exit 1
    fi
    if ! delegate_install "$route"; then
        rollback_runtime_scripts >/dev/null 2>&1 || true
        exit 1
    fi
    if [ "$route" = UNIVERSAL ]; then
        diag=$(persistent_diag_helper || true)
        if [ -z "$diag" ] || ! /bin/sh "$diag" install; then
            echo "FAIL: universal persistent diagnostics could not be installed; rolling back" >&2
            [ -z "$diag" ] || /bin/sh "$diag" remove >/dev/null 2>&1 || true
            delegate "$route" restore >/dev/null 2>&1 || echo "WARN: rollback failed; use RESTORE ORIGINAL before reboot" >&2
            rollback_runtime_scripts >/dev/null 2>&1 || true
            exit 1
        fi
    fi
    ensure_dirs "$STATE_DIR" || exit 1
    echo "$route" > "$ROUTE_FILE" || exit 1
    echo "ROUTER_INSTALL=PASS profile=$route runtime=/mnt/app/root/carplay-altscreen/bin no_eso_write=YES"
    ;;
  restore)
    route=$(route_for_existing) || fail "no installed firmware route; run INSTALL first"
    echo "ROUTER_PROFILE=$route"
    if [ "$route" = UNIVERSAL ]; then
        diag=$(persistent_diag_helper || true)
        [ -n "$diag" ] || fail "universal persistent diagnostics helper is missing; refusing partial restore"
        /bin/sh "$diag" remove || fail "could not disable universal persistent diagnostics"
    fi
    delegate "$route" restore || exit $?
    remove_runtime_scripts || fail "originals restored but persistent runtime cleanup failed"
    cleanup_volatile_runtime
    ;;
  start|status|collect)
    route=$(route_for_existing) || fail "no installed firmware route; run INSTALL first"
    echo "ROUTER_PROFILE=$route"
    delegate "$route" "$CMD"
    ;;
  *) echo "usage: altscreen_chain_test.sh {install|start|status|restore|collect}" >&2; exit 2 ;;
esac
