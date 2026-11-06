#!/bin/bash
# Build SQIsign for Cortex-M4 through pqm4 and measure stack and instruction counts on QEMU (mps2-an386).
#
# Run from the root of the-sqisign. Needs, beforehand:
#   - build/apps/PQCgenKAT_sign_pqm4_<level> (cmake build of this repo, used by gen_pqm4_sources.sh)
#   - a pqm4 checkout (PQM4_DIR, default ~/IoT_PhD/pqm4); it is only read, never modified
#   - arm-none-eabi-gcc, qemu-system-arm and rsync on PATH
#
# Usage: scripts/m4_qemu_bench.sh [-w WORKDIR] [-l "p324_3 p500_27 p664_17"] [-i "m4f ref"]
#   -w  scratch directory (default: a new mktemp dir; an existing one is reused, so builds are incremental)
#   -l  levels, -i implementations to measure
# The script never deletes anything. To start clean, give it a new WORKDIR.
#
# Instruction counts: QEMU does not model cycles. With -icount shift=0 one instruction takes 1 ns of virtual time and
# pqm4's SysTick reads 25 MHz, so instructions = reported ticks * 40. Real M4 cycles are higher (loads, branches,
# flash wait states).
set -eu

PQM4_DIR=${PQM4_DIR:-$HOME/IoT_PhD/pqm4}
LEVELS="p324_3 p500_27 p664_17"
IMPLS="m4f ref"
WORK=""
while getopts "w:l:i:" o; do
    case $o in
        w) WORK=$OPTARG ;;
        l) LEVELS=$OPTARG ;;
        i) IMPLS=$OPTARG ;;
        *) exit 1 ;;
    esac
done
[ -f scripts/gen_pqm4_sources.sh ] || { echo "run from the root of the-sqisign"; exit 1; }
[ -d "$PQM4_DIR/crypto_sign" ] || { echo "PQM4_DIR=$PQM4_DIR is not a pqm4 checkout"; exit 1; }
for t in arm-none-eabi-gcc qemu-system-arm rsync; do
    command -v $t >/dev/null || { echo "missing $t"; exit 1; }
done
for L in $LEVELS; do
    [ -x build/apps/PQCgenKAT_sign_pqm4_$L ] || { echo "build/apps/PQCgenKAT_sign_pqm4_$L missing: build this repo first"; exit 1; }
done

WORK=${WORK:-$(mktemp -d -t sqisign-m4.XXXXXX)}
mkdir -p "$WORK"
echo "work dir: $WORK"

# 1. Generate the pqm4 scheme directories from a scratch copy of this repo, so the working tree stays clean.
#    gen_pqm4_sources.sh refuses to run if its destination exists, so this step is skipped on a reused work dir.
if [ ! -d "$WORK/gen/src/pqm4" ]; then
    mkdir -p "$WORK/gen/build"
    cp -r src include scripts "$WORK/gen/"
    cp -r build/apps "$WORK/gen/build/"
    (cd "$WORK/gen" && bash scripts/gen_pqm4_sources.sh all >/dev/null)
fi

# 2. Copy pqm4 (without .git or old build output) and overlay the generated schemes.
mkdir -p "$WORK/pqm4"
rsync -a --exclude=.git --exclude=elf --exclude=bin --exclude=obj --exclude=libopencm3 "$PQM4_DIR/" "$WORK/pqm4/"
cd "$WORK/pqm4"
for L in $LEVELS; do
    mkdir -p crypto_sign/sqisign_$L
    cp -r "$WORK/gen/src/pqm4/sqisign_$L/." crypto_sign/sqisign_$L/
done

# 3. Build.
TARGETS=""
for L in $LEVELS; do for i in $IMPLS; do
    TARGETS="$TARGETS elf/crypto_sign_sqisign_${L}_${i}_stack.elf elf/crypto_sign_sqisign_${L}_${i}_speed.elf"
done; done
make -j"$(nproc)" PLATFORM=mps2-an386 $TARGETS >"$WORK/build.log" 2>&1 || { tail -30 "$WORK/build.log"; exit 1; }

# 4. Run under QEMU and print a table.
run() { timeout 1800 qemu-system-arm -M mps2-an386 -nographic -semihosting "$@" 2>&1; }
val() { grep -A1 "$1" | tail -1 | tr -d '\r '; }
fmt="%-8s %-4s | %-9s %-9s %-9s | %-7s %-7s %-7s | %-7s %-5s %-5s\n"
printf "$fmt" level impl "kg stack" "sign stk" "ver stack" "kg Mi" "sign Mi" "ver Mi" text data bss
for L in $LEVELS; do for i in $IMPLS; do
    st=$(run -kernel elf/crypto_sign_sqisign_${L}_${i}_stack.elf)
    sp=$(run -icount shift=0 -kernel elf/crypto_sign_sqisign_${L}_${i}_speed.elf)
    echo "$st" | grep -q "Signature valid" || echo "WARNING: $L $i: signature did not verify"
    mi() { echo $(( $(echo "$sp" | val "$1") * 40 / 1000000 )); }
    read -r text data bss _ < <(arm-none-eabi-size elf/crypto_sign_sqisign_${L}_${i}_speed.elf | tail -1)
    printf "$fmt" $L $i \
        "$(echo "$st" | val keypair)" "$(echo "$st" | val "sign stack")" "$(echo "$st" | val verify)" \
        "$(mi keypair)" "$(mi "sign cycles")" "$(mi "verify cycles")" $text $data $bss
done; done
echo "(stack in bytes; Mi = millions of instructions; sizes from the speed ELF)"
