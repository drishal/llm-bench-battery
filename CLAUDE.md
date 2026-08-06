# Local-LLM Benchmark Battery

A small, dependency-light harness to grade a locally-served LLM on **reasoning + coding +
knowledge**, plus optional **agentic tool-use** (via `pi`). It talks to any
**OpenAI-compatible `/v1/chat/completions` endpoint**, so it works with llama.cpp,
Ollama, vLLM, LM Studio, TGI, etc. — on any machine, with any model.

The default runner streams the run **live in tmux** and runs both the graded battery
**and** the pi agentic tests.

---

## What it tests

Graded battery (`battery.py`) — 6 probes, auto-graded except R1:

| ID | Test | Grading |
|----|------|---------|
| **R1** | 12-ball weighing puzzle (hard reasoning) | **MANUAL** — inspect the decision tree in the transcript |
| **R2** | Einstein/zebra 5-house puzzle | auto — correct answer = **German** owns the fish |
| **C1** | thread-safe token-bucket rate limiter | auto — runs a real **20-thread race** (`TOTAL_GRANTED==100`) |
| **C2** | `word_break` DP | auto — hidden test cases |
| **K_cold** | fictional `zephyrdb` API, no context | auto — `/6` (parametric recall — should be low; that's the point) |
| **K_ctx** | same, **with the API doc in context** | auto — `/6` (RAG-style; should be ~6/6) |

Result line per model: `SCORECARD [label]: {"R1_12ball":"MANUAL","R2_zebra":"PASS",...}`

Agentic tests (`pitest.sh`, optional — needs `pi`):
- **Tool-use probe** — find the largest `.gguf` under a dir and extract its `general.architecture` (exercises bash/find/grep tool calls).
- **Write/run/self-correct** — write `primes.py`, run it, fix if wrong.

---

## Requirements

- **`python3`** (3.8+). **No pip packages** — standard library only.
- **A running OpenAI-compatible server** for your model (see below).
- **`curl`** (health checks), **`tmux`** (for the default live view).
- Optional: **`pi`** + util-linux **`script`** for the agentic tests. If `pi` is missing they're skipped and the battery still runs.
- ⚠️ **C1/C2 execute the model's generated Python locally** in a temp file. That's the grading mechanism — run only models/output you're OK executing (it's sandboxed only by your OS user).

---

## Quick start

### Option A — portable (any server, any machine) ✅ recommended for other PCs

1. Serve your model on a port, e.g. with llama.cpp:
   ```bash
   llama-server -m your-model.gguf -c 32768 -fa on --port 8081 --jinja
   ```
   (or Ollama / vLLM / LM Studio — anything exposing `/v1/chat/completions` + `/health`)

2. Run the battery against it (no launcher needed):
   ```bash
   PORT=8081 python3 battery.py mymodel        # writes results/mymodel_battery.txt
   ```

3. Or run the **full live default** (battery + pi, in tmux) by *attaching* to that server:
   ```bash
   LAUNCHER=none PORT=8081 ./bench.sh mymodel
   tmux attach -r -t bench                      # watch live
   ```

### Option B — auto-launch via a launcher

`bench.sh` / `runbench.sh` can launch the model for you if you give them a `$LAUNCHER`
script that accepts `<model-alias-or-path> --port <N>` and exposes `/health` +
`/v1/chat/completions`. Default `$LAUNCHER` is `../serve` (the author's launcher — **not
included**, it's machine/hardware-specific). To use your own:

```bash
LAUNCHER=/path/to/mylaunch ./bench.sh model-a model-b
```

---

## The default runner: `bench.sh`

```bash
./bench.sh qwen35 gemma           # bench several models (via $LAUNCHER)
./bench.sh /path/to/Model.gguf    # a raw path works too
LAUNCHER=none ./bench.sh mymodel  # attach to a server already on :$PORT
```
For each model it: launches (or attaches) → health-waits → runs the **streaming** battery
→ runs **pi** tests → tears down. Everything runs in a detached tmux session `bench`:
- watch: `tmux attach -r -t bench`  · detach: `Ctrl-b` then `d`  · stop: `tmux kill-session -t bench`

Env knobs (all optional):
| var | default | meaning |
|-----|---------|---------|
| `PORT` | `8081` | port to serve/attach on — **pi's provider must point at the same port** |
| `LAUNCHER` | `../serve` | launcher `<model> --port <N>`; `none` = attach to an existing server |
| `SUFFIX` | `-run` | appended to result labels |
| `PI_PROBE_DIR` | `$HOME` | dir the pi tool-use probe searches for a `.gguf` |
| `SERVE_EXTRA` | – | extra args forwarded to the launcher |
| `BENCH_TEMP` / `BENCH_TOP_P` / `BENCH_TOP_K` / `BENCH_PRESENCE` / `BENCH_MIN_P` | – | per-run sampling overrides |

`runbench.sh <model> [label]` is a minimal **non-tmux** variant (battery only) for
headless/CI use.

---

## Sampling

By default the battery sends **no** temperature/top_p/etc., so **the running server's own
sampling applies** — i.e. whatever the launcher configured for that model. This is
deliberate: forcing a temperature on the wire (an earlier bug forced 0.3) produces
low-temp artifacts. To override for an experiment, set the `BENCH_*` env vars, e.g.:
```bash
BENCH_TEMP=1.0 BENCH_TOP_K=64 ./bench.sh gemma      # Gemma-4 wants temp 1.0
```

Whatever samples you want per model, set them on the **server** (recommended) so both the
battery and pi see identical settings.

---

## pi agentic tests — setup

`pi` is a local agentic coder CLI. It needs a `local-model` provider pointing at your
server. In `~/.pi/agent/models.json` (or your pi config), define a provider whose base URL
is `http://localhost:<PORT>/v1` and model id `local-model`, OpenAI-completions style.
**The PORT there must match the `PORT` you run the bench on.** If `pi` isn't installed the
agentic tests are skipped automatically (the battery still runs).

pi renders only to a TTY, so `pitest.sh` captures it through util-linux `script` (a real
PTY) — that's why output both shows live and lands in `results/<label>_pi.txt`.

---

## Interpreting results

- **R1 is manual**: open `results/<label>_battery.txt`, read the 12-ball decision tree.
  A correct answer opens with a 4-vs-4 first weighing and resolves all 24 cases (both which
  ball and heavier/lighter). Common failure = a scrambled/mirror branch.
- Everything else is in the `SCORECARD` line. Compare models:
  ```bash
  grep -H SCORECARD results/*_battery.txt | sed 's#.*/##'
  ```
- Timing/speed per test is in each test header (`… tok/s, finish=…`).

## Files
- `battery.py` — the graded battery (portable core; edit tests/prompts here).
- `pitest.sh` — pi agentic tests.
- `bench.sh` + `_bench_run.sh` — default tmux runner (battery + pi).
- `runbench.sh` — minimal non-tmux single-model runner (battery only).
- `results/` — all outputs (**git-ignored**, never pushed).
