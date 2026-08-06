#!/usr/bin/env bash
# bench.sh [model ...] — the default runner. For each model it launches, health-waits,
# runs the LIVE-STREAMING graded battery AND the pi agentic tests, then tears down —
# all inside a detached tmux session named 'bench' so you can watch it read-only:
#
#     ./bench.sh qwen35 gemma            # bench two models (via ../serve)
#     ./bench.sh /path/to/Model.gguf     # a raw path works too
#     LAUNCHER=none ./bench.sh mymodel   # ATTACH to a server already on :$PORT (portable)
#
#     tmux attach -r -t bench            # watch live (read-only)
#     Ctrl-b then d                      # detach       ·  tmux kill-session -t bench  # stop
#
# Env knobs (all optional):
#   PORT=8081          port to serve/attach on (pi's provider must point at the same port)
#   LAUNCHER=../serve  launcher accepting `<model> --port <N>`; `none` = attach to existing
#   SUFFIX=-run        appended to result labels (results/<model><SUFFIX>_battery.txt)
#   PI_PROBE_DIR=~     directory the pi tool-use probe searches for a .gguf
#   SERVE_EXTRA="…"    extra args forwarded to the launcher
#   BENCH_TEMP/BENCH_TOP_P/BENCH_TOP_K/BENCH_PRESENCE/BENCH_MIN_P   per-run sampling overrides
#
# Results (git-ignored): results/<label>_battery.txt (+ _server.log, _pi.txt).
# Compare:  grep -H SCORECARD results/*_battery.txt
set -u
HERE="$(cd "$(dirname "$0")" && echo "$PWD")"
SESSION="bench"
PORT="${PORT:-8081}"
SUFFIX="${SUFFIX:--run}"
MODELS=("$@")
[ "${#MODELS[@]}" -eq 0 ] && { echo "usage: ./bench.sh <model-alias-or-path> [more…]   (or LAUNCHER=none to attach)"; exit 1; }

if ss -ltn 2>/dev/null | grep -q ":$PORT " && [ "${LAUNCHER:-}" != none ]; then
  echo "! port $PORT is busy — stop that server, set PORT=<free>, or use LAUNCHER=none to attach to it"; exit 1
fi

tmux kill-session -t "$SESSION" 2>/dev/null
tmux new-session -d -s "$SESSION" -x 220 -y 52
tmux set-option -t "$SESSION" history-limit 200000 \; \
     set-option -t "$SESSION" default-terminal tmux-256color \; \
     set-option -t "$SESSION" status off

# forward optional env into the pane
ENVPASS=""
for v in LAUNCHER SERVE_EXTRA PI_PROBE_DIR SUFFIX \
         BENCH_TEMP BENCH_TOP_P BENCH_TOP_K BENCH_PRESENCE BENCH_MIN_P; do
  val="${!v:-}"; [ -n "$val" ] && ENVPASS="$ENVPASS $v=$(printf '%q' "$val")"
done
CMD="bash '$HERE/_bench_run.sh' '$PORT' '$SUFFIX' ${MODELS[*]}"
tmux send-keys -t "$SESSION" "${ENVPASS:+env$ENVPASS} $CMD" C-m

echo "tmux session '$SESSION' started on port $PORT — models: ${MODELS[*]}"
[ -n "$ENVPASS" ] && echo "  env:$ENVPASS"
echo
echo "  WATCH (read-only):   tmux attach -r -t $SESSION"
echo "  detach:              Ctrl-b then d"
echo "  stop:                tmux kill-session -t $SESSION"
echo
echo "results (git-ignored) land in: $HERE/results/<model>${SUFFIX}_{battery,pi}.txt"
