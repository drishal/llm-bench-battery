#!/usr/bin/env bash
# pitest.sh <label> — pi agentic tool-use tests against a local OpenAI-compatible
# server on :$PORT. Two tests:
#   1) agentic tool-use: find the largest .gguf under $PI_PROBE_DIR and report its
#      size + GGUF general.architecture (exercises bash/find/grep tool calls)
#   2) write/run/self-correct: write primes.py, run it, fix if wrong
#
# Requires `pi` (the local agentic coder) with its 'local-model' provider pointed at
# http://localhost:$PORT/v1  (see CLAUDE.md). Skips gracefully if pi is absent.
# pi renders only to a TTY, so we capture via util-linux `script` (a real PTY) — that
# way output shows live AND is logged to a file.
#
# Env:  PORT (default 8081) · PI_PROBE_DIR (dir to search for a .gguf; default $HOME)
# Out:  results/<label>_pi.txt
set -u
HERE="$(cd "$(dirname "$0")" && echo "$PWD")"
LABEL="${1:-run}"
PORT="${PORT:-8081}"
PROBE_DIR="${PI_PROBE_DIR:-$HOME}"
RESDIR="$HERE/results"; mkdir -p "$RESDIR"
OUT="$RESDIR/${LABEL}_pi.txt"; : > "$OUT"

if ! command -v pi >/dev/null 2>&1; then
  echo "[pitest] 'pi' not installed — skipping agentic tests (the battery still ran)." | tee "$OUT"; exit 0
fi
if ! command -v script >/dev/null 2>&1; then
  echo "[pitest] util-linux 'script' not found — can't capture pi's TTY output; skipping." | tee "$OUT"; exit 0
fi

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT; cd "$WORK"
clean(){ sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\a]*\a//g; s/\r//g'; }

run_pi(){ # $1 = prompt — renders live in the pane, cleaned transcript appended to $OUT
  export PI_PROMPT="$1"
  cat > "$WORK/w.sh" <<'WEOF'
pi -p --provider local-model --model local-model --no-session \
   -t bash,read,write,edit,ls,find,grep "$PI_PROMPT"
WEOF
  script -qec "bash '$WORK/w.sh'" "$WORK/raw"          # PTY: live view + typescript
  clean < "$WORK/raw" | grep -avE '^\s*$|Script (started|done)' >> "$OUT"
}

echo "== PI TEST 1 — agentic tool-use GGUF probe ==" | tee -a "$OUT"
run_pi "Using your bash tool: find the single largest .gguf file under $PROBE_DIR. Then report (1) its filename, (2) its size in GB, and (3) the model architecture string in its GGUF metadata header (the general.architecture key, extractable with strings/grep). Show the commands you ran, then finish with one line: SUMMARY: <file> | <sizeGB> | <arch>."

echo "== PI TEST 2 — write/run/self-correct ==" | tee -a "$OUT"
run_pi 'Write a Python file called primes.py in the current directory that prints every prime below 50 on one line, space-separated. Then run it with python3 primes.py using your bash tool and show the output. If it errors or is wrong, fix the file and re-run until correct. Finish with a line: DONE: <the printed primes>.'

echo "== PI COMPLETE ==" | tee -a "$OUT"
echo "[pitest] transcript -> $OUT"
