#!/usr/bin/env bash
# Run all VHDL testbenches with GHDL (VHDL-2008).
#
# Usage: run_tests.sh [tb_name ...]     (default: all sim/tb/tb_*.vhd)
#
# Each testbench prints one line "TB <name> PASS|FAIL (...)" via tb_finish.
# Waveforms are written to sim/out/<tb>.ghw (open with view.ps1 <tb>).
# Exit code: 0 when all testbenches pass, 1 otherwise.
# Each testbench is limited to TB_TIMEOUT seconds (default 300).

set -u
SIM_DIR="$(cd "$(dirname "$0")" && pwd)"
VHDL_DIR="$(dirname "$SIM_DIR")"
OUT="$SIM_DIR/out"
WORK="$OUT/work"
GHDL_FLAGS=(--std=08 --workdir="$WORK" -frelaxed)

mkdir -p "$WORK"
cd "$VHDL_DIR" || exit 1

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
