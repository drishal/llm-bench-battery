#!/usr/bin/env bash
# _bench_run.sh <port> <label-suffix> <model...> — runs INSIDE the tmux 'bench' pane.
# For each model: launch it via $LAUNCHER, wait for health, run the streaming graded
# battery, then the pi agentic tests, then tear the server down.
# Not meant to be called directly — use bench.sh.
#
# $LAUNCHER (default: ../serve) must accept:  <model-alias-or-path> --port <N>
# and expose an OpenAI-compatible /v1/chat/completions + a /health endpoint.
# Set LAUNCHER=none to ATTACH to a server you already started on :$PORT (portable path).
set -u
HERE="$(cd "$(dirname "$0")" && echo "$PWD")"
LAUNCHER="${LAUNCHER:-$HERE/../serve}"
PORT="$1"; shift
SUFFIX="$1"; shift
export BENCH_STREAM=1 PORT

esc(){ printf '\033[%sm' "$1"; }; rst(){ printf '\033[0m'; }
banner(){ printf '\n'; esc '1;36'
  printf '╔══════════════════════════════════════════════════════════════════╗\n'
  printf '║ %-66s ║\n' "$1"
  printf '╚══════════════════════════════════════════════════════════════════╝\n'; rst; }

for M in "$@"; do
  LABEL="$(basename "${M%.gguf}")${SUFFIX}"
  LOG="$HERE/results/${LABEL}_server.log"; mkdir -p "$HERE/results"
  SRV=""
  if [ "$LAUNCHER" = none ]; then
    banner "MODEL: $LABEL   — attaching to existing server on :$PORT"
  else
    banner "MODEL: $LABEL   — launching via $LAUNCHER on :$PORT …"
    "$LAUNCHER" "$M" --port "$PORT" ${SERVE_EXTRA:-} >"$LOG" 2>&1 &
    SRV=$!
  fi
  ok=0
  for i in $(seq 1 400); do
    curl -sf "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && { ok=1; break; }
    [ -n "$SRV" ] && { kill -0 "$SRV" 2>/dev/null || break; }
    sleep 1
  done
  if [ "$ok" != 1 ]; then
    esc '1;31'; printf '  ✗ %s: server not healthy on :%s\n' "$LABEL" "$PORT"; rst
    [ -n "$SRV" ] && { tail -n 12 "$LOG"; kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
    sleep 2; continue
  fi
  [ -n "$SRV" ] && { esc '2'; grep -E ' sampling |^ model | MTP | KV | context ' "$LOG" 2>/dev/null | head -6; rst; echo; }

  # 1) graded battery (streaming, colored)
  python3 "$HERE/battery.py" "$LABEL"
  # 2) pi agentic tests (skips itself if `pi` is not installed)
  [ "${BENCH_SKIP_PI:-}" = 1 ] || PORT="$PORT" "$HERE/pitest.sh" "$LABEL"

  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
  sleep 3
done

esc '1;32'; printf '\n════════════════ ALL DONE — SCORECARDS ════════════════\n'; rst
grep -H SCORECARD "$HERE"/results/*"${SUFFIX}"_battery.txt 2>/dev/null | sed 's#.*/##'
esc '2'; printf '\n(pi transcripts: results/*%s_pi.txt.  Pane safe to detach: Ctrl-b then d.  kill: tmux kill-session -t bench)\n' "$SUFFIX"; rst
while true; do sleep 3600; done
