#!/usr/bin/env bash
# -----------------------------------------------------------------------------
# run_sim.sh -- self-checking regression with Icarus Verilog
#
#   scripts/run_sim.sh rtl [n_seeds]               # RTL (default 8 seeds)
#   scripts/run_sim.sh gl  <netlist.v> [n_seeds]   # post-route SKY130 netlist
#
# Each seed: the C++ golden model writes vectors, tools/check_model.py
# re-derives every expected value in Python, then the bench runs with a
# different idle-gap percentage. Exits non-zero if any seed fails.
# Gate-level runs use the sky130_fd_sc_hd functional models with unit delay
# (PDK found under $PDK_ROOT, default ~/.ciel).
# -----------------------------------------------------------------------------
set -euo pipefail
cd "$(dirname "$0")/.."

MODE=${1:-rtl}
if [[ "$MODE" == "gl" ]]; then
    NETLIST=${2:?usage: run_sim.sh gl <netlist.v> [n_seeds]}
    SEEDS=${3:-3}
else
    SEEDS=${2:-8}
fi
GAPS=(0 10 25 50 75 5 40 90)
BUILD=build/sim_$MODE
mkdir -p "$BUILD"

g++ -O2 -std=c++17 -o build/mac_model model/mac_model.cpp

if [[ "$MODE" == "gl" ]]; then
    PDK_ROOT=${PDK_ROOT:-$HOME/.ciel}
    CELLS=$(find -L "$PDK_ROOT" -path '*sky130A/libs.ref/sky130_fd_sc_hd/verilog' -type d 2>/dev/null | head -n1)
    [[ -n "$CELLS" ]] || { echo "sky130_fd_sc_hd verilog models not found under $PDK_ROOT"; exit 1; }
    echo "cell models: $CELLS"
    iverilog -g2012 -DGL -DFUNCTIONAL -DUNIT_DELAY=#1 -DCLK_PERIOD=200 \
        -o "$BUILD/sim.vvp" tb/tb_mac_gl.v \
        "$CELLS/primitives.v" "$CELLS/sky130_fd_sc_hd.v" "$NETLIST"
else
    iverilog -g2012 -o "$BUILD/sim.vvp" tb/tb_mac_gl.v rtl/mac_pipe.sv
fi

OUT=$BUILD/results.md
{
    echo "| Seed | Idle gap | Samples | Checks | Dot products | Errors | Result |"
    echo "|---|---|---|---|---|---|---|"
} > "$OUT"

FAIL=0; TOTAL=0
for ((i = 1; i <= SEEDS; i++)); do
    gap=${GAPS[$(( (i - 1) % ${#GAPS[@]} ))]}
    vec=$BUILD/vec_$i.txt
    ./build/mac_model "$i" "$vec" > /dev/null
    python3 tools/check_model.py "$vec"
    log=$BUILD/seed_$i.log
    vvp -n "$BUILD/sim.vvp" +vec="$vec" +seed="$i" +gap="$gap" > "$log" 2>&1 || true
    line=$(grep -E '^\[tb\] seed=' "$log" || echo "")
    chk=$(sed -nE 's/.*checks=([0-9]+).*/\1/p' <<< "$line"); chk=${chk:-0}
    vecs=$(sed -nE 's/.*vectors=([0-9]+).*/\1/p' <<< "$line")
    errs=$(sed -nE 's/.*errors=([0-9]+).*/\1/p' <<< "$line")
    drv=$(sed -nE 's/.*driven=([0-9]+).*/\1/p' <<< "$line")
    if grep -q '^TEST PASSED' "$log"; then res=PASS; else res=FAIL; FAIL=$((FAIL + 1)); tail -n 20 "$log"; fi
    TOTAL=$((TOTAL + chk))
    echo "| $i | ${gap}% | ${drv:-?} | $chk | ${vecs:-?} | ${errs:-?} | $res |" >> "$OUT"
    echo "[$MODE] seed $i gap ${gap}%: $res ($chk checks)"
done
echo "" >> "$OUT"
echo "**$MODE: $((SEEDS - FAIL))/$SEEDS seeds pass, $TOTAL checks**" >> "$OUT"
cat "$OUT"
[[ $FAIL -eq 0 ]]
