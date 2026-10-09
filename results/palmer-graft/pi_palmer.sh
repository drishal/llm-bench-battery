#!/usr/bin/env bash
# pi_palmer.sh — pi-hello A/B: g244 (control) vs palmer graft, interleaved, fresh server per run,
# exact `./serve bonsai-q1` path with PRISM_Q1_LLAMA_SERVER override; pi runs WITH tools (no -xt),
# so its tool grammar exercises patch 0042 like servepihello does not.
set -u
F=/home/drishal/Desktop/models/files; R=$F/bench/results/palmer-graft
OUT=$R/pihello_results.txt; LOGS=$R/logs; mkdir -p "$LOGS"
H=$F/bench/results/tuning-sweep/harness
CTRL=/home/drishal/src/llama.cpp-prism-ptq1fast/result-g244/bin/llama-server
GRAFT=/tmp/ptq1-palmer/result-palmer/bin/llama-server
log(){ echo "$*" | tee -a "$OUT"; }
stop(){ kill "$1" 2>/dev/null; for _ in $(seq 1 20); do kill -0 "$1" 2>/dev/null || break; sleep 1; done; kill -9 "$1" 2>/dev/null; sleep 4; }
one(){  # one LABEL BIN
  local label=$1 bin=$2 slog="$LOGS/pi_$1.log"
  log ""; log "===== $label  $(basename "$bin") ====="
  (cd "$F" && PRISM_Q1_LLAMA_SERVER="$bin" exec ./serve bonsai-q1 --port 8081) > "$slog" 2>&1 &
  local pid=$! t0=$SECONDS
  until curl -s -m 3 http://127.0.0.1:8081/v1/models 2>/dev/null | grep -q '"id"'; do
    kill -0 $pid 2>/dev/null || { log "  LOAD FAILED"; tail -3 "$slog" | tee -a "$OUT"; return 1; }
    [ $((SECONDS-t0)) -gt 300 ] && { log "  ABORT"; stop $pid; return 1; }; sleep 2; done
  log "  loaded in $((SECONDS-t0))s"
  python3 "$H/req2.py" "$H/prose_seed.json" 300 1 > /dev/null          # warm-up, shares nothing with pi's prompt
  local nwarm; nwarm=$(grep -c 'prompt eval time' "$slog")
  local s e rc
  s=$(date +%s.%N)
  PI_TMUX_STREAM=0 timeout --foreground 600 pi -p --provider local-model --model local-model --no-session --thinking off "hello" \
    > "$LOGS/pi_$label.pi.txt" 2>&1; rc=$?
  e=$(date +%s.%N)
  local wall; wall=$(awk -v s="$s" -v e="$e" 'BEGIN{printf "%.1f", e-s}')
  log "  rc=$rc wall=${wall}s | largest prefill: $(grep 'prompt eval time' "$slog" | tail -n +"$((nwarm+1))" | sort -t/ -k2 -n | tail -1 | sed 's/.*prompt eval time = *//')"
  log "  reply: $(grep -v '^Warning' "$LOGS/pi_$label.pi.txt" | tr -s '\n' ' ' | cut -c1-90)"
  log "RESULT $label wall=${wall}s"
  stop $pid
}
ss -ltn | grep -q ':8081 ' && { echo "!! something already listens on :8081"; exit 1; }
: > "$OUT"; log "pi-hello palmer graft A/B — $(date '+%F %T') — desktop VRAM $(awk '{print int($1/1048576)}' /sys/class/drm/card1/device/mem_info_vram_used) MiB"
log "ctrl=$CTRL"
one CTRL_a "$CTRL"
one GRAFT_a "$GRAFT"
one CTRL_b "$CTRL"
log ""; echo "=== SUMMARY ==="; grep -E '^RESULT|largest' "$OUT" | tee -a "$OUT" >/dev/null
log "PI_DONE"