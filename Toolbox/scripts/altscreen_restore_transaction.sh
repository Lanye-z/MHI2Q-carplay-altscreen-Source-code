#!/bin/sh
# V3 transactional RESTORE ORIGINAL wrapper.
# Preflight first, snapshot the complete project-owned persistent state, run the
# proven restore APPLY step, verify, and roll back on any handled failure.
set -u

ensure_dirs(){ for d in "$@"; do [ -d "$d" ] || mkdir -p "$d" || return 1; done; }
TESTING=${ALTSCREEN_CHAIN_TESTING:-0}
ROOT=""; VOLUME=""; TXN_READY=0; ROLLING_BACK=0; APP_RW=0; SYS_RW=0
if [ "$TESTING" = 1 ]; then
  ROOT=${ALTSCREEN_CHAIN_ROOT:-}; VOLUME=${ALTSCREEN_CHAIN_VOLUME:-}
  case "$ROOT" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_ROOT" >&2; exit 2;; esac
  case "$VOLUME" in /tmp/*|/var/tmp/*) ;; *) echo "FAIL: invalid ALTSCREEN_CHAIN_VOLUME" >&2; exit 2;; esac
else
  for d in /net/mmx/fs/sda0 /net/mmx/fs/sda1 /net/mmx/fs/sdb0 /net/mmx/fs/sdb1 /fs/sda0 /fs/sda1 /fs/sdb0 /fs/sdb1; do
    [ -d "$d/Toolbox" ] && { VOLUME=$d; break; }
  done
fi
[ -n "$VOLUME" ] && [ -d "$VOLUME/Toolbox" ] || { echo "RESTORE=REFUSED reason=SD_NOT_FOUND production_changed=NO"; exit 1; }
p(){ printf '%s%s\n' "$ROOT" "$1"; }
mount_app_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/app; }
mount_app_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/app; }
mount_system_rw(){ [ "$TESTING" = 1 ] || mount -uw /mnt/system; }
mount_system_ro(){ [ "$TESTING" = 1 ] || mount -ur /mnt/system; }

SD="$VOLUME/MMI-Cockpit-Carplay"; STATE="$SD/state"; BACKUP="$SD/backup"
TXN="$SD/restore-transaction/active"; LOG="$SD/logs/restore-transaction.log"
CONTROLLER="$VOLUME/Toolbox/scripts/altscreen_chain_test.sh"
APPLY="$VOLUME/Toolbox/scripts/altscreen_restore_apply.sh"
INSTALL_TXN_HELPER="$VOLUME/Toolbox/scripts/altscreen_install_transaction.sh"
INSTALL_TXN="$SD/install-transaction/active"
HMI="$BACKUP/basevideo3-hmi-original"; NATIVE="$BACKUP/original"
RUNTIME="$(p /mnt/app/root/carplay-altscreen)"; STAGE="$(p /mnt/app/root/.carplay-altscreen.new)"; PREV="$(p /mnt/app/root/.carplay-altscreen.previous)"
SI="$(p /mnt/system/etc/eso/production/smartphone_integrator.json)"; DIO="$(p /mnt/system/etc/eso/production/dio_manager.json)"; PF="$(p /mnt/system/etc/pf.conf)"
JAR="$(p /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar)"; LEGACY_HOOK="$(p /mnt/app/root/hooks/libcarplay_altscreen.so)"; LIBTARGET="$(p /mnt/app/root/lib-target)"
ensure_dirs "$SD/logs" "$SD/restore-transaction" || { echo "RESTORE=REFUSED reason=SD_NOT_WRITABLE production_changed=NO"; exit 1; }
: >> "$LOG" 2>/dev/null || { echo "RESTORE=REFUSED reason=SD_LOG_NOT_WRITABLE production_changed=NO"; exit 1; }
exec 3>&1; exec >> "$LOG" 2>&1
log(){ echo "$*"; echo "$*" >&3; }

size(){ n=$(wc -c < "$1" 2>/dev/null || echo 0); set -- $n; echo "${1:-0}"; }
same(){ [ -f "$1" ] && [ -f "$2" ] && [ "$(size "$1")" = "$(size "$2")" ] && [ "$(cksum < "$1")" = "$(cksum < "$2")" ]; }
find_startup(){ for f in "$(p /mnt/system/etc/boot/startup.sh)" "$(p /etc/boot/startup.sh)"; do [ -f "$f" ] && { echo "$f"; return 0; }; done; return 1; }
dir_file_count(){ find "$1" -type f -print 2>/dev/null | wc -l | awk '{print $1}'; }
dir_kb(){ n=$(du -sk "$1" 2>/dev/null | awk 'NR==1{print $1}'); case "${n:-0}" in ''|*[!0-9]*) echo 0 ;; *) echo "$n" ;; esac; }
same_dir_hint(){ [ -d "$1" ] && [ -d "$2" ] && [ "$(dir_file_count "$1")" = "$(dir_file_count "$2")" ] && [ "$(dir_kb "$1")" = "$(dir_kb "$2")" ]; }
finish_mounts(){ r=0; sync >/dev/null 2>&1 || r=1; [ "$APP_RW" = 0 ] || { mount_app_ro >/dev/null 2>&1 || r=1; APP_RW=0; }; [ "$SYS_RW" = 0 ] || { mount_system_ro >/dev/null 2>&1 || r=1; SYS_RW=0; }; return "$r"; }

snap_file(){ src=$1; name=$2; dst="$TXN/files/$name"; if [ -f "$src" ]; then cp "$src" "$dst" && same "$src" "$dst" && touch "$dst.present"; else touch "$dst.absent"; fi; }
restore_file(){ dst=$1; name=$2; mode=$3; src="$TXN/files/$name"; if [ -f "$src.present" ]; then ensure_dirs "$(dirname -- "$dst")" || return 1; tmp="${dst}.restore.new"; rm -f "$tmp"; cp "$src" "$tmp" && chmod "$mode" "$tmp" && same "$src" "$tmp" && mv "$tmp" "$dst"; elif [ -f "$src.absent" ]; then rm -f "$dst"; else return 1; fi; }
snap_dir(){ src=$1; name=$2; dst="$TXN/dirs/$name"; if [ -d "$src" ]; then ensure_dirs "$dst" && cp -R "$src/." "$dst/" && same_dir_hint "$src" "$dst" && touch "$TXN/dirs/$name.present"; else touch "$TXN/dirs/$name.absent"; fi; }
restore_dir(){ dst=$1; name=$2; src="$TXN/dirs/$name"; rm -rf "$dst"; if [ -f "$TXN/dirs/$name.present" ]; then tmp="${dst}.restore.$$"; rm -rf "$tmp"; ensure_dirs "$tmp" && cp -R "$src/." "$tmp/" && mv "$tmp" "$dst"; elif [ -f "$TXN/dirs/$name.absent" ]; then :; else return 1; fi; }

verify_hmi(){
  [ -f "$HMI/COMPLETE" ] && [ -f "$HMI/target" ] || return 1
  [ "$(cat "$HMI/target" 2>/dev/null)" = /mnt/app/eso/hmi/lsd/jars/carplay_hook.jar ] || return 1
  if [ -f "$HMI/present" ]; then [ -s "$HMI/carplay_hook.jar" ] || return 1; [ ! -f "$HMI/cksum" ] || [ "$(cksum < "$HMI/carplay_hook.jar")" = "$(cat "$HMI/cksum")" ]; else [ -f "$HMI/absent" ]; fi
}

snapshot(){
  [ ! -e "$STAGE" ] || { log "RESTORE=REFUSED reason=RUNTIME_STAGE_PRESENT production_changed=NO"; return 1; }
  [ ! -e "$PREV" ] || { log "RESTORE=REFUSED reason=RUNTIME_PREVIOUS_PRESENT production_changed=NO"; return 1; }
  [ ! -e "$STATE/.chain_test.lock" ] || { log "RESTORE=REFUSED reason=CHAIN_LOCK_PRESENT production_changed=NO"; return 1; }
  rm -rf "$TXN"; ensure_dirs "$TXN/files" "$TXN/dirs" || return 1
  STARTUP=$(find_startup) || return 1; echo "$STARTUP" > "$TXN/startup.path" || return 1
  snap_file "$STARTUP" startup.sh || return 1; snap_file "$SI" smartphone_integrator.json || return 1; snap_file "$DIO" dio_manager.json || return 1; snap_file "$PF" pf.conf || return 1; snap_file "$JAR" carplay_hook.jar || return 1
  snap_file "$LEGACY_HOOK" legacy_hook || return 1
  if [ -d "$LIBTARGET" ]; then touch "$TXN/libtarget.dir_present" || return 1; else touch "$TXN/libtarget.dir_absent" || return 1; fi
  for n in libairplay.so libairplax.so libNmeBaseClasses.so; do snap_file "$LIBTARGET/$n" "libtarget_$n" || return 1; done
  snap_dir "$RUNTIME" runtime || return 1; snap_dir "$STATE" state || return 1
  touch "$TXN/PREPARED" || return 1; sync >/dev/null 2>&1 || true; TXN_READY=1; log "RESTORE_TRANSACTION=PREPARED"
}

rollback(){
  [ -f "$TXN/PREPARED" ] || return 1; ROLLING_BACK=1; trap - 1 2 15; log "ROLLBACK=STARTED"; r=0
  mount_system_rw >/dev/null 2>&1 && SYS_RW=1 || r=1; mount_app_rw >/dev/null 2>&1 && APP_RW=1 || r=1
  if [ "$SYS_RW" = 1 ]; then s=$(cat "$TXN/startup.path" 2>/dev/null || true); [ -n "$s" ] && restore_file "$s" startup.sh 755 || r=1; restore_file "$SI" smartphone_integrator.json 644 || r=1; restore_file "$DIO" dio_manager.json 644 || r=1; restore_file "$PF" pf.conf 644 || r=1; fi
  if [ "$APP_RW" = 1 ]; then restore_file "$JAR" carplay_hook.jar 644 || r=1; restore_file "$LEGACY_HOOK" legacy_hook 755 || r=1; ensure_dirs "$LIBTARGET" || r=1; for n in libairplay.so libairplax.so libNmeBaseClasses.so; do restore_file "$LIBTARGET/$n" "libtarget_$n" 755 || r=1; done; if [ -f "$TXN/libtarget.dir_absent" ]; then rmdir "$LIBTARGET" 2>/dev/null || true; fi; restore_dir "$RUNTIME" runtime || r=1; rm -rf "$STAGE" "$PREV" 2>/dev/null || true; fi
  finish_mounts || r=1; restore_dir "$STATE" state || r=1; sync >/dev/null 2>&1 || true
  if [ "$r" = 0 ]; then touch "$TXN/ROLLED_BACK"; rm -f "$TXN/APPLYING"; log "ROLLBACK=PASS persistent_state=PRE_RESTORE reboot_required=YES"; ROLLING_BACK=0; return 0; fi
  touch "$TXN/ROLLBACK_INCOMPLETE" 2>/dev/null || true; log "ROLLBACK=FAIL recovery_required=YES transaction_retained=$TXN"; ROLLING_BACK=0; return 1
}

recover_stale(){
  [ -d "$TXN" ] || return 0
  if [ -f "$TXN/COMMITTED" ] || [ -f "$TXN/ROLLED_BACK" ]; then rm -rf "$TXN"; return $?; fi
  if [ -f "$TXN/PREPARED" ]; then log "STALE_RESTORE_TRANSACTION=DETECTED action=ROLLBACK_FIRST"; TXN_READY=1; rollback || return 1; rm -rf "$TXN" || return 1; TXN_READY=0; log "STALE_RESTORE_TRANSACTION=RECOVERED"; return 0; fi
  # No PREPARED marker means the previous run never reached the first production
  # mutation. It is safe to discard this incomplete SD-only snapshot.
  log "STALE_RESTORE_TRANSACTION=INCOMPLETE_PREPARE action=CLEANUP production_changed=NO"
  rm -rf "$TXN" || return 1
  return 0
}

fail(){ msg=$1; log "ERROR: $msg"; finish_mounts >/dev/null 2>&1 || true; if [ "$ROLLING_BACK" = 0 ] && [ "$TXN_READY" = 1 ]; then rollback && log "RESTORE=ABORTED rollback=PASS" || log "RESTORE=FAILED rollback=INCOMPLETE recovery_required=YES"; else log "RESTORE=REFUSED production_changed=NO"; fi; exit 1; }
trap 'fail "restore interrupted by signal"' 1 2 15

log "===== V3 transactional RESTORE ORIGINAL started ====="
if [ -d "$INSTALL_TXN" ]; then
  [ -f "$INSTALL_TXN_HELPER" ] || fail "active install transaction exists but recovery helper is missing"
  log "ACTIVE_INSTALL_TRANSACTION=DETECTED action=ROLLBACK_PRE_INSTALL_BEFORE_RESTORE"
  /bin/sh "$INSTALL_TXN_HELPER" recover || fail "active install transaction could not be recovered before restore"
fi
recover_stale || fail "previous restore transaction could not be recovered"
[ -f "$CONTROLLER" ] && [ -f "$APPLY" ] || fail "restore controller/apply helper missing"
verify_hmi || fail "trusted HMI backup unavailable/damaged"
/bin/sh "$CONTROLLER" restore-precheck || fail "native restore precheck failed"
snapshot || { rm -rf "$TXN" 2>/dev/null || true; fail "pre-restore transaction snapshot failed"; }
touch "$TXN/APPLYING" || fail "cannot mark transaction APPLYING"
/bin/sh "$APPLY" || fail "restore APPLY step failed"

# Re-verify every file in the trusted native original manifest, not only the
# two JSONs. The universal restore may also restore dio_manager/libairplay/NME.
[ -f "$NATIVE/manifest.txt" ] || fail "native original manifest missing after restore"
NATIVE_COUNT=0
while IFS= read -r rel; do
  [ -n "$rel" ] || continue
  case "$rel" in
    /eso/bin/apps/dio_manager|/mnt/app/eso/bin/apps/dio_manager|/eso/lib/libairplay.so|/armle/usr/lib/libNmeBaseClasses.so|/mnt/app/armle/usr/lib/libNmeBaseClasses.so|/eso/lib/libNmeBaseClasses.so|/mnt/system/etc/eso/production/smartphone_integrator.json|/mnt/system/etc/eso/production/dio_manager.json) ;;
    *) fail "unexpected path in trusted native manifest: $rel" ;;
  esac
  src="$NATIVE/files/$(echo "$rel" | tr '/' '_')"
  dst="$(p "$rel")"
  [ -f "$src" ] && same "$src" "$dst" || fail "trusted native file verification failed: $rel"
  NATIVE_COUNT=$((NATIVE_COUNT + 1))
done < "$NATIVE/manifest.txt"
[ "$NATIVE_COUNT" = 5 ] || fail "trusted native manifest count mismatch"

[ -f "$BACKUP/firewall-original/COMPLETE" ] ||
  fail "firewall original backup missing after restore"
[ -f "$BACKUP/firewall-original/pf.conf" ] &&
  same "$BACKUP/firewall-original/pf.conf" "$PF" ||
  fail "pf.conf verification failed"

# Exact overlay baseline verification.  The original manifest records whether
# each stock overlay file existed and which directory owned that baseline.
OVERLAY_DIR=$(cat "$NATIVE/overlay_dir.txt" 2>/dev/null || true)
case "$OVERLAY_DIR" in
  /mnt/app/root/carplay-altscreen/lib|/mnt/app/root/lib-target) ;;
  *) fail "invalid overlay baseline directory" ;;
esac
for n in libairplay.so libairplax.so libNmeBaseClasses.so; do
  overlay_dst="$(p "$OVERLAY_DIR")/$n"
  if grep -q "^$n$" "$NATIVE/overlay_present.txt" 2>/dev/null; then
    [ -f "$NATIVE/files/overlay_$n" ] && same "$NATIVE/files/overlay_$n" "$overlay_dst" ||
      fail "overlay baseline verification failed: $n"
  else
    [ ! -e "$overlay_dst" ] || fail "overlay should be absent after restore: $n"
  fi
done

if [ -f "$BACKUP/universal-hook-original/COMPLETE" ]; then
  hook_present=$(cat "$BACKUP/universal-hook-original/present" 2>/dev/null || echo invalid)
  hook_rel=$(cat "$BACKUP/universal-hook-original/path" 2>/dev/null || echo /mnt/app/root/hooks/libcarplay_altscreen.so)
  case "$hook_rel" in
    /mnt/app/root/carplay-altscreen/lib/libcarplay_altscreen.so|/mnt/app/root/hooks/libcarplay_altscreen.so) ;;
    *) fail "invalid universal-hook recovery path" ;;
  esac
  hook_dst="$(p "$hook_rel")"
  case "$hook_present" in
    0) [ ! -e "$hook_dst" ] || fail "managed universal hook should be absent after restore" ;;
    1) [ -f "$BACKUP/universal-hook-original/libcarplay_altscreen.so" ] &&
       same "$BACKUP/universal-hook-original/libcarplay_altscreen.so" "$hook_dst" ||
       fail "original universal hook verification failed" ;;
    *) fail "invalid universal-hook backup state" ;;
  esac
fi
if [ -f "$HMI/present" ]; then same "$HMI/carplay_hook.jar" "$JAR" || fail "carplay_hook.jar verification failed"; else [ ! -e "$JAR" ] || fail "carplay_hook.jar should be absent"; fi
[ ! -e "$RUNTIME" ] && [ ! -e "$STAGE" ] && [ ! -e "$PREV" ] || fail "managed runtime residue remains after restore"
STARTUP=$(find_startup) || fail "startup.sh missing after restore"
! grep -E 'BEGIN ALT111 (MIRROR|BASEVIDEO3) AUTOSTART|BEGIN ALTSCREEN DIAGNOSTICS' "$STARTUP" >/dev/null 2>&1 || fail "AltScreen autostart/diagnostic block remains"
[ -f "$STATE/RESTORE_PENDING_REBOOT" ] || fail "RESTORE_PENDING_REBOOT marker missing"

sync >/dev/null 2>&1 || fail "sync failed before restore commit"
touch "$TXN/COMMITTED" || fail "cannot commit restore transaction"
TXN_READY=0
sync >/dev/null 2>&1 || log "WARN: final post-commit sync reported failure; on-disk restore was already verified and committed"
log "RESTORE_VERIFY=PASS"
log "RESTORE=PASS transaction=COMMITTED persistent_state=PRE_INSTALL reboot_required=YES"
log "IMPORTANT=DO_NOT_TEST_CARPLAY_BEFORE_FULL_MMI_REBOOT"
rm -rf "$TXN" 2>/dev/null || log "WARN: committed transaction retained; next run will clean it"
trap - 1 2 15
log "===== V3 transactional RESTORE ORIGINAL finished ====="
exit 0
