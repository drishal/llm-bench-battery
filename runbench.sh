#!/usr/bin/env bash
# runbench.sh <model-alias-or-path> [label]
# Launches a model via ../serve, waits for the :8081 endpoint, runs the graded
# battery against it, then stops the server. Label defaults to the alias.
#
#   ./runbench.sh quality
#   ./runbench.sh ornith ornith-compact
#   ./runbench.sh /path/to/Some-New-Model.gguf newmodel
#
# Results land in bench/results/<label>_battery.txt.  Compare SCORECARD lines
# across models with:  grep -H SCORECARD results/*_battery.txt
set -u
HERE="$(cd "$(dirname "$0")" && echo "$PWD")"
SERVE="$HERE/../serve"
PORT="${PORT:-8081}"
MODEL="${1:?usage: runbench.sh <model-alias-or-path> [label]}"
LABEL="${2:-$(basename "$MODEL" .gguf)}"
LOG="$HERE/results/${LABEL}_server.log"
mkdir -p "$HERE/results"

echo "[runbench] launching '$MODEL' via serve on :$PORT …"
"$SERVE" "$MODEL" --port "$PORT" >"$LOG" 2>&1 &
SRV=$!
cleanup(){ kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
trap cleanup EXIT INT TERM HUP

ok=0
for i in $(seq 1 300); do
  curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }
  kill -0 "$SRV" 2>/dev/null || { echo "[runbench] server died during load:"; tail -20 "$LOG"; exit 1; }
  sleep 1
done
[ "$ok" = 1 ] || { echo "[runbench] health timeout"; tail -20 "$LOG"; exit 1; }

echo "[runbench] server up (1 = $(pgrep -xc llama-server)). running battery '$LABEL' …"
PORT="$PORT" python3 "$HERE/battery.py" "$LABEL"
echo "[runbench] done. scorecard:"
grep SCORECARD "$HERE/results/${LABEL}_battery.txt"
