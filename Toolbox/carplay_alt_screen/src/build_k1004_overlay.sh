#!/bin/sh
# Build a measured K1004 (default) or P1404 overlay without LD_PRELOAD.
set -eu
export LC_ALL=C
SRC="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
ROOT="$(CDPATH= cd -- "$SRC/../../.." && pwd)"
OUT="${1:-$SRC/../build-k1004-overlay}"
PROFILE="${2:-K1004}"
case "$PROFILE" in
  K1004) OFFSET_DELTA=24; IS_P1404=0; NME_PATCH_MODE=DYNSYM_NAMES_ONLY ;;
  P1404) OFFSET_DELTA=0; IS_P1404=1; NME_PATCH_MODE=RELOCATED_DYNSTR_UNDEFINED_NAMES_ONLY ;;
  *) echo "unsupported firmware profile: $PROFILE" >&2; exit 1 ;;
esac
IMAGE="$ROOT/CarFirmware/MHI2Q_CN_AUG22_K1004_MU1003_4M0906961EG/MMX2QC/app/10/default/app.img"
STUBS="$OUT/stubs"
INCLUDE_SRC="$OUT/source_include"
TARGET=armv7-linux-gnueabi
CLANG_INCLUDE=$(clang -print-file-name=include)
fail(){ echo "${PROFILE}_OVERLAY_BUILD_FAIL $*" >&2; exit 1; }
compile_c(){
  clang -target "$TARGET" -march=armv7-a -marm -mfloat-abi=softfp -fPIC -O2 \
    -ffreestanding -fno-stack-protector -fno-builtin -nostdinc -Wall -Wextra \
    -Werror -DALTSCREEN_DIRECT_PROXY=1 -DALTSCREEN_STOCK_OFFSET_DELTA="$OFFSET_DELTA" -DALTSCREEN_PROFILE_P1404="$IS_P1404" -isystem "$CLANG_INCLUDE" \
    -I"$INCLUDE_SRC" -I"$INCLUDE_SRC/qnxshim" "$@"
}
[ "$PROFILE" != K1004 ] || [ -f "$IMAGE" ] || fail "missing exact K1004 app.img"
# Never recursively clear an unchecked caller-selected directory.
[ ! -e "$OUT" ] || { echo "output already exists: $OUT" >&2; exit 1; }
mkdir -p "$OUT" "$STUBS"
ln -s "$SRC" "$INCLUDE_SRC"
python3 "$ROOT/Toolbox/carplay_alt_screen/tests/firmware_profiles.py" "$PROFILE" "$OUT/originals"

# Extract and minimally rename the exact stock library. No code byte changes.
python3 - "$OUT/originals/libairplay.so" "$OUT/libairplax.so" <<'PY'
import struct, sys
from pathlib import Path
from elftools.elf.elffile import ELFFile
image, out = map(Path, sys.argv[1:])
data=bytearray(image.read_bytes())
original=bytes(data)
out.write_bytes(data)
with out.open('rb') as f:
    elf=ELFFile(f); dynstr=elf.get_section_by_name('.dynstr'); dynsym=elf.get_section_by_name('.dynsym'); dynamic=elf.get_section_by_name('.dynamic')
    ds_off=dynstr['sh_offset']; ds_size=dynstr['sh_size']; sym_off=dynsym['sh_offset']; sym_ent=dynsym['sh_entsize']
    soname_idx=rpath_idx=None
    for tag in dynamic.iter_tags():
        if tag.entry.d_tag == 'DT_SONAME': soname_idx=tag.entry.d_val
        if tag.entry.d_tag == 'DT_RPATH': rpath_idx=tag.entry.d_val
    symbols=[(i,s.name,s['st_shndx']) for i,s in enumerate(dynsym.iter_symbols())]
if soname_idx is None or rpath_idx is None: raise SystemExit('missing SONAME/RPATH')
old=b'libairplay.so\0'; new=b'libairplax.so\0'
start=ds_off+soname_idx
if data[start:start+len(old)] != old: raise SystemExit('unexpected stock SONAME bytes')
data[start:start+len(new)] = new
rpath_start=ds_off+rpath_idx
rpath_end=data.index(0,rpath_start,ds_off+ds_size)
replacement=b'/mnt/app/root/lib-target\0xrite\0xlose\0'
if len(replacement) > rpath_end-rpath_start+1: raise SystemExit('RPATH scratch too short')
data[rpath_start:rpath_start+len(replacement)]=replacement
xrite_idx=rpath_idx+len(b'/mnt/app/root/lib-target')+1
xlose_idx=xrite_idx+len(b'xrite')+1
seen=set(); dynsym_name_ranges=[]
for i,name,shndx in symbols:
    if shndx != 'SHN_UNDEF' or name not in ('write','close'): continue
    value=xrite_idx if name=='write' else xlose_idx
    name_off=sym_off+i*sym_ent
    struct.pack_into('<I',data,name_off,value)
    dynsym_name_ranges.append(range(name_off,name_off+4)); seen.add(name)
if seen != {'write','close'}: raise SystemExit(f'unexpected target imports: {seen}')
allowed=set(range(start,start+len(new))) | set(range(rpath_start,rpath_start+len(replacement)))
for r in dynsym_name_ranges: allowed.update(r)
diff={i for i,(a,b) in enumerate(zip(original,data)) if a != b}
if not diff or not diff <= allowed:
    raise SystemExit(f'unexpected patched bytes count={len(diff)} outside_allowed={sorted(diff-allowed)[:8]}')
code_sections=('.text','.init','.fini','.plt')
with out.open('wb') as f: f.write(data)
with out.open('rb') as f:
    elf=ELFFile(f)
    for section_name in code_sections:
        section=elf.get_section_by_name(section_name)
        if not section: continue
        lo=section['sh_offset']; hi=lo+section['sh_size']
        if any(lo <= i < hi for i in diff):
            raise SystemExit(f'code bytes changed in {section_name}')
PY

# Extract the exact K1004 Cinemo/Nme I/O carrier and rename only its libc dynstr
# imports. dio_manager remains byte-for-byte stock; its normal libNmeSDK
# dependency loads this overlay from the existing lib-target path.
#
# QNX shares dynstr tails, so renaming `read` also rewrites `fread`. To keep that
# collateral closed and provable this rename is strictly length-preserving *and*
# byte-bounded: the patched byte set must equal exactly the union of the four
# target name regions, and the whole-dynsym name multiset must differ from the
# original only by the intended mapping. Any empty or invented symbol name fails.
python3 "$ROOT/Toolbox/carplay_alt_screen/tests/patch_nme_dynstr.py" \
  "$IMAGE" "$OUT/libNmeBaseClasses.so" "$OUT/nme_renamed_symbols.txt" --profile "$PROFILE" || \
  fail 'Nme dynstr patch refused by invariant checks'
NME_RENAMED="$(tr '\n' ',' < "$OUT/nme_renamed_symbols.txt" | sed 's/,$//')"
[ -n "$NME_RENAMED" ] || { echo 'K1004_OVERLAY_BUILD_FAIL empty Nme renamed symbol set' >&2; exit 1; }

# Empty QNX-name link stubs; libairplax forces the stock dependency edge.
echo 'int __altscreen_stub_anchor(void){return 0;}' > "$OUT/empty_stub.c"
compile_c -c "$OUT/empty_stub.c" -o "$OUT/empty_stub.o"
for lib in libc.so.3 libm.so.2 libairplax.so; do
  clang --target="$TARGET" -fuse-ld=lld -nostdlib -shared \
    -Wl,--build-id=none,-soname,"$lib",-z,max-page-size=4096 \
    "$OUT/empty_stub.o" -o "$STUBS/$lib"
done
set --
for c in altscreen_core.c altscreen_paths.c altscreen_profile.c altscreen_state.c altscreen_state_private.c p1404_private111.c p1404_private111_backend.c p1404_firewall.c p1404_cockpit_native.c p1404_setup_merge.c p1404_resolve.c p1404_iap2.c p1404_observe.c p1404_airplay_fullchain.c altscreen_hook.c; do
  compile_c -c "$SRC/$c" -o "$OUT/${c%.c}.o"
  set -- "$@" "$OUT/${c%.c}.o"
done
clang -target "$TARGET" -march=armv7-a -marm -c "$SRC/p1404_trampoline.s" -o "$OUT/p1404_trampoline.o"
clang --target="$TARGET" -fuse-ld=lld -nostdlib -shared \
  -Wl,--build-id=none,--no-rosegment,-z,norelro,-z,max-page-size=4096 -Wl,--hash-style=sysv,-Bsymbolic-functions \
  -Wl,--no-as-needed -L"$STUBS" -Wl,--allow-shlib-undefined \
  -Wl,-soname,libairplay.so -Wl,--version-script,"$INCLUDE_SRC/libairplay_proxy.map" \
  -Wl,-l:libairplax.so -Wl,-l:libc.so.3 -Wl,-l:libm.so.2 \
  "$@" "$OUT/p1404_trampoline.o" -o "$OUT/libairplay.so"
printf '\002\000\000\005' | dd of="$OUT/libairplay.so" bs=1 seek=36 conv=notrunc status=none
# QNX records only the first PT_LOAD as the caller's text range. LLD's
# default R/RX/RW layout loads but makes RTLD_DEFAULT/RTLD_NEXT return NULL.
python3 "$ROOT/Toolbox/carplay_alt_screen/tests/validate_qnx_load_layout.py" "$OUT/libairplay.so" > "$OUT/QNX_LOAD_LAYOUT.json"

RE=arm-linux-gnueabihf-readelf
[ "$($RE -d "$OUT/libairplax.so" | sed -n 's/.*SONAME.*\[\([^]]*\)\].*/\1/p')" = libairplax.so ] || fail 'stock SONAME patch'
UND="$($RE --dyn-syms -W "$OUT/libairplax.so" | awk '$7=="UND" {print $8}' | sort -u)"
printf '%s\n' "$UND" | grep -qx xrite || fail 'stock xrite import missing'
printf '%s\n' "$UND" | grep -qx xlose || fail 'stock xlose import missing'
printf '%s\n' "$UND" | grep -Eq '^(write|close)$' && fail 'stock global libc imports remain'
NEEDED="$($RE -d "$OUT/libairplay.so" | sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | tr '\n' ' ')"
printf '%s' "$NEEDED" | grep -q 'libairplax.so' || fail 'proxy stock dependency missing'
PROXY_UND="$($RE --dyn-syms -W "$OUT/libairplay.so" | awk '$1+0>0 && $7=="UND" {print $8}' | sort -u)"
$RE --dyn-syms -W "$OUT/libairplay.so" | awk '$1+0>0 && $7=="UND" && $8=="" {bad=1} END {exit bad?0:1}' && fail 'proxy dynsym contains a blank-name undefined entry'
printf '%s\n' "$PROXY_UND" | grep -qx CFLRetain || fail 'pre-constructor stock anchor import missing'
$RE -rW "$OUT/libairplay.so" | grep -Eq 'R_ARM_GLOB_DAT.*CFLRetain' || fail 'pre-constructor stock anchor relocation missing'
for s in open64 read write close send recv; do
  printf '%s\n' "$PROXY_UND" | grep -qx "$s" || fail "direct libc import missing: $s"
  $RE -rW "$OUT/libairplay.so" | grep -Eq "R_ARM_GLOB_DAT.*[[:space:]]$s$" || fail "direct libc relocation missing: $s"
done
NME_UND="$($RE --dyn-syms -W "$OUT/libNmeBaseClasses.so" | awk '$1+0>0 && $7=="UND" {print $8}' | sort -u)"
$RE --dyn-syms -W "$OUT/libNmeBaseClasses.so" | awk '$1+0>0 && $7=="UND" && $8=="" {bad=1} END {exit bad?0:1}' && fail 'Nme dynsym contains a blank-name undefined entry'
# The private export contract is derived from the binary, never hardcoded: every
# name the patcher produced must be exported by the proxy, and no renamed libc
# import may remain undefined under its original name.
[ -s "$OUT/nme_renamed_symbols.txt" ] || fail 'Nme private-name report is empty'
while IFS= read -r nme_name; do
  [ -n "$nme_name" ] || continue
  printf '%s\n' "$NME_UND" | grep -qx "$nme_name" || fail "Nme rewritten import missing: $nme_name"
done < "$OUT/nme_renamed_symbols.txt"
for s in open64 read write close fread fwrite fclose; do
  printf '%s\n' "$NME_UND" | grep -qx "$s" && fail "Nme raw libc import remains: $s"
done
NME_RELOCS="$($RE -rW "$OUT/libNmeBaseClasses.so")"
while IFS= read -r nme_name; do
  [ -n "$nme_name" ] || continue
  count=$(printf '%s\n' "$NME_RELOCS" | grep -c " $nme_name\$")
  [ "$count" -ge 1 ] || fail "Nme private name has no relocation: $nme_name"
done < "$OUT/nme_renamed_symbols.txt"
NME_DYNSYMS="$($RE --dyn-syms -W "$OUT/libNmeBaseClasses.so")"
python3 "$ROOT/Toolbox/carplay_alt_screen/tests/validate_profile_overlay.py" "$PROFILE" "$OUT" || fail 'profile ARM contract mismatch'
printf '%s\n' "$NME_DYNSYMS" | awk '$1+0>0 && $7=="UND" && $8=="" {bad=1} END {exit bad?0:1}' && fail 'Nme dynsym contains a blank-name undefined entry'
grep -q '!iap2_mutation_buffer_candidate(buf, n)' "$SRC/altscreen_hook.c" || fail 'direct write is not iAP2 scoped'
grep -q 'stock_net_write = direct_caller_in_stock' "$SRC/altscreen_hook.c" || fail 'direct write is not stock NetSocket caller scoped'
grep -q 'direct_nme_otg_fd_contains(fd)' "$SRC/altscreen_hook.c" || fail 'Nme I/O is not /dev/otg-cinemo FD scoped'
grep -q '"/dev/otg-cinemo"' "$SRC/altscreen_hook.c" || fail 'Nme open path scope missing'
grep -q '!bearer_fd_is_managed(fd)' "$SRC/altscreen_hook.c" || fail 'direct close is not iAP2 scoped'
grep -q 'direct_caller_in_stock("NetSocket_Delete"' "$SRC/altscreen_hook.c" || fail 'direct close is not stock NetSocket caller scoped'
STOCK_DYNSYMS="$($RE --dyn-syms -W "$OUT/libairplax.so")"
SURFACE="$($RE --dyn-syms -W "$OUT/libairplay.so" | awk '$5=="GLOBAL" && $7!="UND" {print $8}' | sort -u)"
for s in AirPlayReceiverServerCreate AirPlayReceiverSessionSetup AirPlayReceiverSessionStart AirPlayReceiverSessionTearDown AirPlayReceiverServerPlatformCopyProperty AirPlayReceiverSessionPlatformControl AirPlayReceiverSessionPlatformCopyProperty AirPlayReceiverSessionScreen_CopyDisplaysInfo ScreenCopyMain ScreenCreate ScreenStreamCreate ScreenStreamProcessData ScreenStreamStart screen_create_window_group screen_create_window_buffers _ZN3dio13CScreenRender6configERKNS_16st_screen_configE _ZN3dio13CScreenRender6renderEPh; do
  printf '%s\n' "$SURFACE" | grep -qx "$s" || fail "missing proxy export $s"
done
while IFS= read -r nme_name; do
  [ -n "$nme_name" ] || continue
  printf '%s\n' "$SURFACE" | grep -qx "$nme_name" || fail "proxy does not export required private name: $nme_name"
done < "$OUT/nme_renamed_symbols.txt"
printf '%s\n' "$SURFACE" | grep -Eq '^(open64|read|write|send|recv|close|fread|fwrite|fclose)$' && fail 'process-wide libc export leaked'
printf '%s\n' "$SURFACE" | awk '$0 ~ /^_ZN3dio13CScreenRender/ {found++} END {exit found==2?0:1}' || fail 'CScreen hook exports are not exactly config+render'
printf '%s\n' "$PROXY_UND" | grep -Eq '^p1404_hook_cscreen_(config|render)$' && fail 'internal CScreen hook remained undefined'
PROXY_RELOCS="$($RE -rW "$OUT/libairplay.so")"
printf '%s\n' "$PROXY_RELOCS" | grep -Eq 'AirPlayReceiver(ServerPlatformCopyProperty|SessionPlatform(Control|CopyProperty)|SessionScreen_CopyDisplaysInfo|ServerCreate)|Screen(CopyMain|Create|StreamStart|StreamCreate|StreamProcessData)|CScreenRender6(config|render)' && fail 'proxy wrapper address is loader-preemptible; -Bsymbolic-functions ineffective'
$RE -h "$OUT/libairplay.so" | grep -Eq 'Flags:.*0x5000002' || fail 'proxy ARM flags'
cat > "$OUT/OVERLAY_INFO.txt" <<EOF
mode=${PROFILE}_EXACT_DIO_DUAL_PATH_OVERLAY
firmware_profile=$PROFILE
stock_offset_delta=$OFFSET_DELTA
stock_sha256=$(sha256sum "$OUT/libairplax.so" | awk '{print $1}')
proxy_sha256=$(sha256sum "$OUT/libairplay.so" | awk '{print $1}')
qnx_loader_layout=RX_RW_FIRST_LOAD_CONTAINS_ALL_CODE
stock_cksum=$(cksum "$OUT/libairplax.so" | awk '{print $1" "$2}')
proxy_cksum=$(cksum "$OUT/libairplay.so" | awk '{print $1" "$2}')
proxy_needed=$NEEDED
process_wide_libc_exports=NONE
stock_targeted_imports=xrite,xlose
nme_overlay_sha256=$(sha256sum "$OUT/libNmeBaseClasses.so" | awk '{print $1}')
nme_overlay_cksum=$(cksum "$OUT/libNmeBaseClasses.so" | awk '{print $1" "$2}')
nme_original_sha256=$(sha256sum "$OUT/originals/libNmeBaseClasses.so" | awk '{print $1}')
nme_original_cksum=$(cksum < "$OUT/originals/libNmeBaseClasses.so")
nme_targeted_imports=$NME_RENAMED
nme_private_names=$NME_RENAMED
nme_export_names_and_values_preserved=1
nme_import_delta=SEVEN_PRIVATE_LIBC_NAMES
nme_patch_scope=$NME_PATCH_MODE
nme_code_bytes_changed=0
nme_runtime_callers=${PROFILE}_NMEFILE_CREATEPOSIX_WRITE_READ_DELETE_FINGERPRINTED
nme_device_scope=/dev/otg-cinemo_ONLY
stock_patch_scope=SONAME_RPATH_DYNSYM_NAMES_ONLY
stock_code_bytes_changed=0
preconstructor_stock_forwarding=CFLRetain_BASED_${PROFILE}_OFFSETS
preconstructor_libc_forwarding=RELOCATION_BACKED_OPEN64_READ_WRITE_CLOSE_SEND_RECV
pre_ready_io_path=DIRECT_LIBC_NO_PROXY_LOCKS
post_ready_io_scope=STOCK_NETSOCKET_OR_EXACT_NMEFILE_CALLER_AND_IAP2_CANDIDATE_OR_MANAGED_FD_ONLY
stream_trampoline_failopen=STOCK_TARGET_BOUND_BEFORE_OBSERVATION
qnx_internal_interposition=EXACT_STOCK_GOT_REDIRECTS_16
qnx_process_identity=READEXEFILE_SYMLINK_OR_LIBC_CMDNAME_ARGV_PROGNAME_K1004_HOST
screen_copy_main_abi=OBJECT_RETURN_OUTERR_ARG
private_screen_object=STOCK_SCREENCREATE_WITH_STOCK_MAIN_DELEGATES
EOF
cat "$OUT/OVERLAY_INFO.txt"
echo "${PROFILE}_DIRECT_OVERLAY_BUILD=PASS"
