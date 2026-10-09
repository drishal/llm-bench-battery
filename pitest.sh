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

# Optional explicit reasoning level for pi. MEASURED 2026-09-04: settings.json
# `defaultThinkingLevel` does NOT reach `pi -p` -- it kept sending high (which unsloth's
# Qwen3.8 template silently escalates to xhigh). The `--thinking` FLAG is the control that
# works. Leave PI_THINKING unset to preserve the historical default for comparability.
THINKARG=""; [ -n "${PI_THINKING:-}" ] && THINKARG="--thinking ${PI_THINKING}"
export THINKARG
WORK="$(mktemp -d)"; cd "$WORK"
clean(){ sed 's/\x1b\[[0-9;?]*[a-zA-Z]//g; s/\x1b\][^\a]*\a//g; s/\r//g'; }

# --- transcript recovery -----------------------------------------------------------
# pi BUFFERS its output and prints only on completion, so `script` captures NOTHING until
# the run ends: a 500, a kill, or a context-wall runaway leaves an EMPTY typescript and the
# EXIT trap then deleted the workdir. MEASURED 2026-09-04: a 46.7-min runaway left a 2047-byte
# _pi.txt containing only two warnings, and the reasoning was recoverable ONLY from pi's
# GLOBAL stream log. So: (a) archive the workdir instead of deleting it, (b) slice that
# global log per test so the thinking survives every failure mode.
PISTREAM="${PI_STREAM_LOG:-$HOME/.pi/agent/stream/pi-stream.log}"
ARCHIVE="$RESDIR/${LABEL}_pi_work"; rm -rf "$ARCHIVE"; mkdir -p "$ARCHIVE"
TESTN=0
archive(){ # always runs: keep artifacts + the tail of the global stream log
  cp -a "$WORK/." "$ARCHIVE/" 2>/dev/null
  rm -rf "$WORK" 2>/dev/null
  echo "[pitest] artifacts + transcripts archived in $ARCHIVE" >> "$OUT"
}
trap archive EXIT INT TERM
stream_mark(){ MARK=$(wc -l < "$PISTREAM" 2>/dev/null || echo 0); TESTN=$((TESTN+1)); }
stream_slice(){ # $1 = test name; write the reasoning this test produced
  [ -f "$PISTREAM" ] || return 0
  local dst="$ARCHIVE/transcript_${TESTN}_$1.txt"
  tail -n +$((MARK+1)) "$PISTREAM" 2>/dev/null | clean > "$dst"
  local n; n=$(wc -c < "$dst" 2>/dev/null || echo 0)
  echo "[pitest] transcript: $(basename "$dst") (${n} bytes)" >> "$OUT"
}

run_pi(){ # $1 = prompt — renders live in the pane, cleaned transcript appended to $OUT
  export PI_PROMPT="$1"
  cat > "$WORK/w.sh" <<'WEOF'
pi -p --provider local-model --model local-model --no-session $THINKARG \
   -t bash,read,write,edit,ls,find,grep "$PI_PROMPT"
WEOF
  stream_mark
  script -qec "bash '$WORK/w.sh'" "$WORK/raw"          # PTY: live view + typescript
  clean < "$WORK/raw" | grep -avE '^\s*$|Script (started|done)' >> "$OUT"
  stream_slice "${PI_TEST_NAME:-test}"
}

run_pi_sess(){ # like run_pi but keeps the session jsonl so we can count tool calls
  export PI_PROMPT="$1"
  cat > "$WORK/ws.sh" <<'WEOF'
pi -p --provider local-model --model local-model $THINKARG   --session-dir "$PI_SESSDIR" --session-id pagoda    --mcp-config "$HERE/mcp-playwright-only.json" "$PI_PROMPT"
WEOF
  export PI_SESSDIR="$WORK/sess"; mkdir -p "$PI_SESSDIR"
  stream_mark
  script -qec "bash '$WORK/ws.sh'" "$WORK/raws"
  clean < "$WORK/raws" | grep -avE '^\s*$|Script (started|done)' >> "$OUT"
  stream_slice "${PI_TEST_NAME:-pagoda}"
}
# ⚠ PROMPT CHANGED 2026-09-04 (backup: pitest.sh.pre-hint.bak). The old wording ended with
# "extractable with strings/grep", which actively STEERED models into full-file scans: Heretic
# I-Compact spent 159s on `grep -a` over a 29 GB GGUF, then escalated to an even slower
# `strings -a` full pass (measured mid-run at 172 MB/s, ~170s per pass, twice). Worse, it piped
# `strings | grep -A1 | head`, and since grep emits only ~2 lines head never closes the pipe
# early -- so the scan ran to completion for data that was in the first millisecond of the file.
# The prompt now states the header is at the start and forbids whole-file passes.
# ⚠ COMPARABILITY: pi-test-1 results before this date were produced under the old wording.
# PI_ONLY=pagoda (or "gguf_probe,primes") runs just those pi tests against the same live
# server; empty -> all three, so every historical invocation is unchanged. Added 2026-09-05
# to re-run one agentic test under a changed KV/serve config without paying for the others.
pi_sel(){ [ -z "${PI_ONLY:-}" ] && return 0
  case ",${PI_ONLY}," in *",$1,"*) return 0;; esac; return 1; }

echo "== PI TEST 1 — agentic tool-use GGUF probe ==" | tee -a "$OUT"
export PI_TEST_NAME=gguf_probe
pi_sel gguf_probe && run_pi "Using your bash tool: find the single largest .gguf file under $PROBE_DIR. Then report (1) its filename, (2) its size in GB, and (3) the model architecture string in its GGUF metadata header (the general.architecture key). IMPORTANT: the file is tens of GB and the metadata header sits at the very START of it, so read only the first few MB -- do NOT scan, stream, or load the whole file (a full pass takes minutes and is the wrong approach). Show the commands you ran, then finish with one line: SUMMARY: <file> | <sizeGB> | <arch>."

echo "== PI TEST 2 — write/run/self-correct ==" | tee -a "$OUT"
export PI_TEST_NAME=primes
pi_sel primes && run_pi 'Write a Python file called primes.py in the current directory that prints every prime below 50 on one line, space-separated. Then run it with python3 primes.py using your bash tool and show the output. If it errors or is wrong, fix the file and re-run until correct. Finish with a line: DONE: <the printed primes>.'

echo "== PI TEST 3 — creative/coherence: voxel pagoda garden ==" | tee -a "$OUT"
export PI_TEST_NAME=pagoda
# The ONLY test in this battery that exercises long-form creative code coherence.
# Graded by EXECUTING the scene against real three.js (bench/pagoda_grade.mjs), not by
# linting: every observed failure so far passed `node --check` and then threw at runtime
# (ornith15-APEX via hermes -> `THREE.OrbitControls` undefined; official Q6_K via pi ->
# `ReferenceError: z is not defined` in buildPagoda). A syntax-only grader scores both PASS.
# PROMPT v2 (2026-09-12). v1 stated NONE of the requirements the field states
# explicitly, so a model could satisfy it with a static 2D canvas illustration and
# score FAIL for an unwritten rule (GSQ-RCO-IQ3_XXS did exactly that). Rebuilt from
# three published evals: numbered requirements (github.com/boodballs/Threejs),
# supplied boilerplate so we test SCENE BUILDING not CDN-path recall (VoxelCodeBench,
# arXiv 2604.02580 -- "minimal API documentation + minimal working examples"), and
# counted thresholds that degrade gradually instead of pass/fail (murailabs Shore
# Temple gates). ⚠ NOT comparable to v1 scores -- grader emits promptVersion:2.
# ⚠ 2026-09-18: the pagoda run now gets Playwright MCP browser tools and is TOLD to
# verify its own render. This deliberately breaks comparability with every pagoda score
# before this date -- earlier models had no way to see their output, so "wrote once and
# stopped" was partly a missing capability, not only a behaviour. MEASURED: the same task
# via shell-Playwright took 30+ min / 34.7k ctx / 4 failed scripts / no screenshot; via
# MCP it took 3.5 min first try.
PAGODA_PROMPT="$(cat <<'PGEOF'
Create a voxel art scene of a pagoda in a garden with cherry blossom trees.
Write it to pagoda.html in this directory.

Start from exactly this setup - do not change the import lines:

<script type="importmap">
{"imports":{
 "three":"https://cdn.jsdelivr.net/npm/three@0.169.0/build/three.module.js",
 "three/addons/":"https://cdn.jsdelivr.net/npm/three@0.169.0/examples/jsm/"}}
</script>
<script type="module">
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
</script>

Requirements:
1. Canvas fills the browser window and resizes with it
2. OrbitControls enabled: drag to rotate, scroll to zoom
3. At least 8 visually distinct element types (roof tiers, trunks, blossoms,
   water, lanterns, path, rocks, fencing, ...)
4. At least 6 distinct colours
5. At least one animated element
6. One file, no local assets, no console errors

Make it detailed and colourful.

When the file is written, VERIFY it with the Playwright MCP browser tools:
  - browser_navigate to the file:// URL of the pagoda.html you just wrote
  - browser_wait_for a few seconds so the WebGL scene renders
  - browser_console_messages to check for errors
  - browser_take_screenshot and LOOK at it
If the console shows errors, or the screenshot is empty/blank, fix the file and
re-verify until the scene actually renders. Do not write your own browser scripts
and do not search /nix/store -- the MCP browser is already configured.
PGEOF
)"
pi_sel pagoda && run_pi_sess "$PAGODA_PROMPT"

# --- PAGODA scorecard -------------------------------------------------------------
# The graded battery (battery.py) is a plain API client with no tools, so it CANNOT run
# an agentic task. Pagoda therefore lives here, and emits its own PAGODA_SCORECARD line
# so `grep SCORECARD results/*` surfaces both halves. Added 2026-08-29 after 62 battery
# runs showed R2/C1/C2 are ~free passes and K_ctx is 6/6 for everything -- the battery
# had no long-horizon agentic axis at all, which is why it ranked models the opposite
# way round from hands-on use.
GRADE='{"verdict":"FAIL","stage":"no-file"}'
if [ -f "$WORK/pagoda.html" ]; then
  cp "$WORK/pagoda.html" "$RESDIR/${LABEL}_pagoda.html"
  if command -v node >/dev/null 2>&1 && [ -f "$HERE/fixtures/three.module.js" ]; then
    GRADE="$(timeout 180 node "$HERE/pagoda_grade.mjs" "$WORK/pagoda.html" 2>&1 | tail -1)"
  else
    GRADE='{"verdict":"SKIP","stage":"no-node-or-fixture"}'
  fi
fi
# turn economy + self-verification, parsed from the session transcript
SESS="$(ls -1 "$WORK/sess"/*.jsonl 2>/dev/null | head -1)"
python3 - "$LABEL" "$GRADE" "${SESS:-}" >> "$OUT" <<'PYEOF'
import json,sys,os
label,grade_s,sess = sys.argv[1], sys.argv[2], (sys.argv[3] if len(sys.argv)>3 else '')
try: g=json.loads(grade_s)
except Exception: g={"verdict":"FAIL","stage":"grader-error","raw":grade_s[:120]}
calls=think=0; names=[]; verified=False
if sess and os.path.exists(sess):
    wrote=False
    for line in open(sess,errors='replace'):
        try: r=json.loads(line)
        except Exception: continue
        if r.get('type')!='message': continue
        for c in (r.get('message') or {}).get('content') or []:
            if not isinstance(c,dict): continue
            if c.get('type')=='thinking': think+=len(c.get('thinking') or '')
            if c.get('type')=='toolCall':
                n=c.get('name'); calls+=1; names.append(n)
                if n in ('write','edit'): wrote=True
                # a bash/read AFTER the file exists = the model checked its own work
                elif wrote and n in ('bash','read','grep'): verified=True
g.update({"toolCalls":calls,"thinkChars":think,"selfVerified":verified,
          "tools":sorted(set(names))})
print(f"PAGODA_SCORECARD [{label}]: " + json.dumps(g))
PYEOF
