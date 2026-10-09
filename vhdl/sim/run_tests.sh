#!/usr/bin/env bash
# Run all VHDL testbenches with GHDL (VHDL-2008).
#
# Usage: run_tests.sh [tb_name ...]     (default: all sim/tb/tb_*.vhd)
#
# Each testbench prints one line "TB <name> PASS|FAIL (...)" via tb_finish.
# Waveforms are written to sim/out/<tb>.ghw (open with view.ps1 <tb>).
# Exit code: 0 when all testbenches pass, 1 otherwise.
# Each testbench is limited to TB_TIMEOUT seconds (default 300).
# Gowin primitive models (IDES8, OSER8, TLVDS_*) are compiled from the Gowin EDA
# installation into library gw1n: GOWIN_SIMLIB = <Gowin EDA>/IDE/simlib/gw1n.

set -u
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
VHDL_DIR="$(dirname "$SIM_DIR")"
OUT="$SIM_DIR/out"
WORK="$OUT/work"
GOWIN_LIB="$OUT/gowin"
GOWIN_SIMLIB="${GOWIN_SIMLIB:-}"
if [ -z "$GOWIN_SIMLIB" ] || [ ! -f "$GOWIN_SIMLIB/prim_sim.vhd" ]; then
  echo "Set GOWIN_SIMLIB to <Gowin EDA>/IDE/simlib/gw1n (prim_sim.vhd not found: '$GOWIN_SIMLIB')"
  exit 1
fi
GHDL_FLAGS=(--std=08 --workdir="$WORK" -frelaxed -fsynopsys -P"$GOWIN_LIB")

mkdir -p "$WORK" "$GOWIN_LIB"
cd "$VHDL_DIR" || exit 1

# Gowin primitive library (recompiled when missing or older than the model)
if [ ! -f "$GOWIN_LIB/gw1n-obj08.cf" ] || [ "$GOWIN_SIMLIB/prim_sim.vhd" -nt "$GOWIN_LIB/gw1n-obj08.cf" ]; then
  rm -f "$GOWIN_LIB"/*.cf
  if ! ghdl -a --std=08 -frelaxed -fsynopsys --work=gw1n --workdir="$GOWIN_LIB"        "$GOWIN_SIMLIB/prim_sim.vhd" "$GOWIN_SIMLIB/prim_syn.vhd" 2>"$OUT/gowin.log"; then
    grep -v warning "$OUT/gowin.log" | head -20
    echo "GOWIN LIBRARY COMPILE FAILED (GOWIN_SIMLIB=$GOWIN_SIMLIB)"
    exit 1
  fi
fi

# Compile sources (sources.txt) and all testbenches
SRC=()
while IFS= read -r line; do
  line="${line%%#*}"; line="${line//[$'\r\t ']/}"
  [ -n "$line" ] && SRC+=("$line")
done < "$SIM_DIR/sources.txt"
TB_FILES=($(ls sim/tb/tb_*.vhd | grep -v '/tb_pkg.vhd$'))

rm -f "$WORK"/*.cf
if ! ghdl -a "${GHDL_FLAGS[@]}" "${SRC[@]}" "${TB_FILES[@]}" 2>"$OUT/compile.log"; then
  cat "$OUT/compile.log"
  echo "COMPILE FAILED"
  exit 1
fi
grep -i warning "$OUT/compile.log" | head -20

if [ $# -gt 0 ]; then
  TBS=("$@")
else
  TBS=()
  for f in "${TB_FILES[@]}"; do TBS+=("$(basename "$f" .vhd)"); done
fi

pass=0; fail=0; failed=()
for tb in "${TBS[@]}"; do
  log="$OUT/$tb.log"
  timeout "${TB_TIMEOUT:-300}" ghdl --elab-run "${GHDL_FLAGS[@]}" "$tb" --wave="$OUT/$tb.ghw" --assert-level=failure >"$log" 2>&1
  rc=$?
  [ $rc -eq 124 ] && echo "TB $tb FAIL (timeout ${TB_TIMEOUT:-300} s)" >>"$log"
  line="$(grep -o "TB $tb \(PASS\|FAIL\).*" "$log" | tail -1)"
  if [[ "$line" == *" PASS "* ]]; then
    pass=$((pass + 1)); echo "  PASS  $tb  ${line#*PASS }"
  else
    fail=$((fail + 1)); failed+=("$tb")
    echo "  FAIL  $tb  ${line#*FAIL }"
    grep -m 10 -E "CHECK FAILED|error|failure" "$log" | sed 's/^/        /'
  fi
done

echo "Result: $pass passed, $fail failed"
[ $fail -eq 0 ]
