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

## Grading reference (for humans **and** AI agents)

Most tests grade themselves — the "answer key" is embedded as executable checks, not a
text to diff:

- **R2** — correct final answer is hardcoded: **German owns the fish**. Auto-graded by
  extracting the model's `ANSWER:` line. PASS iff `german`.
- **C1** — no reference solution; the harness **executes the model's code** against a real
  20-thread race and requires `TOTAL_GRANTED == 100` (no over-granting / no race).
- **C2** — **executed** against hidden cases: `leetcode/leet,code→True`,
  `applepenapple/apple,pen→True`, `catsandog/cats,dog,sand,and,cat→False`,
  `cars/car,ca,rs→True`, `abcd/a,abc,b,d→True`, `abcd/a,abc,bd→False`,
  `aaaaaaaaab/a,aa,aaa→False`. All must match.
- **K_cold / K_ctx** — a 6-point regex rubric on the generated code: `pool_size=8`,
  `Isolation.SERIALIZABLE` transaction, `timeout_ms=5000`, executes the SELECT, returns
  `len(.rows)`/`.affected`, closes (ctx-mgr or `.close()`). Score `/6`. `zephyrdb` is
  **fictional** — K_cold (no context) probes parametric confabulation and is *expected* to
  be low; K_ctx provides the API doc and should be ~6/6.

### R1 is the only MANUAL grade — here is the reference to grade it against

The harness prints the model's 12-ball decision tree but does **not** score it. To grade:
the answer is correct iff it gives a 3-weighing strategy that, for **all 24 cases**
(each of 12 balls being heavy or light), identifies **both which ball and whether it's
heavy or light**. A canonical correct solution (any equivalent tree is fine):

```
W1: {1,2,3,4} vs {5,6,7,8}
├─ BALANCE → odd ∈ {9,10,11,12}, and 1–8 are known-good (G)
│   W2: {9,10,11} vs {1,2,3}(G)
│   ├─ balance      → odd=12;  W3: 12 vs G → heavier/lighter tells H or L
│   ├─ left heavy   → odd ∈{9,10,11}, HEAVY;  W3: 9 vs 10 (>=→that one H, bal→11H)
│   └─ right heavy  → odd ∈{9,10,11}, LIGHT;  W3: 9 vs 10 (analogous, lighter side)
├─ LEFT HEAVY → {1,2,3,4} maybe-H OR {5,6,7,8} maybe-L; 9–12 good
│   W2: {1,2,5} vs {3,4,6}   (set aside 7,8)
│   ├─ balance      → odd ∈{7,8}, LIGHT;  W3: 7 vs 8 → lighter one
│   ├─ left heavy   → odd ∈{1H,2H,6L};    W3: 1 vs 2 (>→1H, <→2H, bal→6L)
│   └─ right heavy  → odd ∈{3H,4H,5L};    W3: 3 vs 4 (>→3H, <→4H, bal→5L)
└─ RIGHT HEAVY → mirror of LEFT HEAVY with H/L swapped
    W2: {1,2,5} vs {3,4,6}
    ├─ balance      → odd ∈{7,8}, HEAVY;  W3: 7 vs 8 → heavier one
    ├─ left heavy   → odd ∈{3L,4L,5H};    W3: 3 vs 4 (>→4L? use: bal→5H, else lighter)
    └─ right heavy  → odd ∈{1L,2L,6H};    W3: 1 vs 2 (bal→6H, else lighter one)
```

Grade **PASS** if the model's tree is logically equivalent (opens with a 4-vs-4, uses a
known-good ball as filler in later weighings, and every leaf names a specific ball + H/L).
Grade **FAIL** for the usual errors: a wrong first split, a branch that can't distinguish
H from L, or a scrambled/mirror branch (a ball assigned to the wrong bucket) — this is the
most common failure and worth checking carefully in the LEFT/RIGHT-heavy branches.

### If you are Claude / an agent handed this repo

1. Start (or confirm) an OpenAI-compatible server for the target model on a port.
2. Run `LAUNCHER=none PORT=<port> ./bench.sh <label>` (or `PORT=<port> python3 battery.py
   <label>` for battery-only). pi tests auto-skip if `pi` isn't installed.
3. Read `results/<label>_battery.txt`. The `SCORECARD` line has the auto-graded results;
   **manually grade R1** using the reference tree above and report it alongside.
4. Compare models with `grep -H SCORECARD results/*_battery.txt`.
5. Don't commit `results/` (git-ignored). Don't force a temperature unless experimenting
   (`BENCH_TEMP=…`) — otherwise the server's per-model sampling is used.

## Files
- `battery.py` — the graded battery (portable core; edit tests/prompts here).
- `pitest.sh` — pi agentic tests.
- `bench.sh` + `_bench_run.sh` — default tmux runner (battery + pi).
- `runbench.sh` — minimal non-tmux single-model runner (battery only).
- `results/` — all outputs (**git-ignored**, never pushed).

---

# Footguns & operational notes (hard-won — read before benching a new model)

These are lessons from real runs. Some are **universal**; some are specific to the
author's box (**AMD RX 6800 XT, RDNA2, Vulkan/RADV**) and are flagged `[RDNA2/Vulkan]` —
on other hardware/backends verify rather than assume.

## Researching settings for a NEW model (do this FIRST)
Before benching an unfamiliar model, find its **recommended sampling + chat template** —
defaults are often wrong and silently tank scores:
1. **Sampling** — check the model card + the *base* model's docs. Web-search
   "`<model>` recommended sampling temperature top_p top_k". Unsloth docs are reliable.
   Set these **on the server**, not on the wire (the battery defers to the server).
2. **Chat template** — models with custom/tool templates need `--jinja`. Prefer the
   model's **own baked template**; for versioned families (esp. Gemma) grab the
   **official** `chat_template.jinja` from the base repo if llama.cpp warns the baked one
   is outdated. Different size variants can need different templates.
3. **Architecture** — dense vs MoE (affects prefill speed + VRAM strategy), and whether it
   has an **MTP/nextn head** (baked) or a **separate drafter** file.
4. **Runtime** — does it load on mainline llama.cpp, or need a fork / custom kernels? Some
   models (custom `fuse3`, QTIP/"trellis" quants, ternary Q2_0) need special builds or are
   effectively CUDA-only — check for a GGUF **and** backend kernel support before pulling.

## Sampling footguns
- **Defer to the server.** The battery sends no temperature by default on purpose — an
  earlier version forced temp 0.3 (below Qwen's 0.6) and under-rated the whole field with
  low-temp artifacts (runaways, sign errors). Override only for experiments (`BENCH_TEMP=…`).
- **Per-family recommended sampling** (set on the server):
  - **Qwen 3.5/3.6** — temp **0.6**, top_p 0.95, top_k 20. Anti-runaway lever is
    **`presence_penalty` (~1.5 for reasoning), NOT temperature and NOT repeat_penalty** —
    temp does *not* fix runaways.
  - **Gemma 4** — temp **1.0** (intentional — it's tuned for it), top_p 0.95, top_k 64.
    *Do not lower it thinking "coding wants low temp"* — Unsloth prescribes 1.0 for all uses.
  - **KAT-Coder** — its card says temp 1.0 + presence 1.5; empirically ~0.7 + presence 1.5
    is steadier for deterministic tasks. (Card vs. measured can disagree — note both.)
  - **Bonsai 2 (ternary, Qwen3.8-based)** — card preset (thinking) is temp **1.0** / top_p 0.95 /
    top_k 20 / min_p 0 / no presence. The old 0.5 / 0.85 / 20 preset is **gen-1 Bonsai only**; the MTP
    grafts silently fell back to it until 2026-09-28. MTP depth picks flip with temp — measure at 1.0.
  - **LFM2** — temp 0.3, min_p 0.15, needs `--jinja`.
- **Runaways**: reasoning models can fail to terminate (`finish=length`, huge think, no
  answer). The battery caps at 14000 tokens; a runaway shows as `finish=length`. That's a
  real failure mode (K_cold especially), not a harness bug.

## MTP / speculative-decoding footguns
- **MTP is TEMP-GATED.** Draft acceptance collapses at high temp. Measured: Gemma-4 MTP =
  **31% accept → net LOSS** at temp 1.0, but **77% accept → +78% gen** at temp 0. Qwen at
  its 0.6 default gets **80–89%** → MTP is a clean win. So MTP helps low-temp/deterministic
  work; at a model's high recommended temp it can *slow you down*.
- **Baked head vs separate drafter.** Qwen/KAT use a baked `nextn` head (works on
  `[RDNA2/Vulkan]`). Gemma-4 ships a **separate** `mtp-*.gguf` drafter (also works on
  Vulkan, temp-gated). Bonsai's **DSpark** drafter has **no Vulkan kernels** → falls back
  ~20× slower + a ~5–6 GB draft-staging buffer that fills VRAM and lags the desktop
  (CUDA-only in practice). Always A/B plain-vs-MTP and check gen t/s + draft acceptance.
- **Dense MTP `[RDNA2/Vulkan]`**: the draft KV is f16 and ignores your `-ctk/-ctv`, so it
  raises VRAM and **crashes/spills at 128k**. Keep dense-MTP ctx ≤ 64k.

## VRAM / spill measurement footguns (very important)
- **`sysfs mem_info_vram_used` is UNRELIABLE for "does it fit"** — it includes the desktop
  compositor + browser, which fluctuate ±1 GB and produce non-monotonic garbage.
- **The true "it fits" signal is GENERATION SPEED.** If gen t/s stays near baseline it's in
  VRAM; if it drops sharply it's spilling. "It loaded / health OK" does **not** mean it fits.
- **Spill goes to GTT** (GPU-mapped system RAM over PCIe), shown in
  `mem_info_gtt_used` — **not** process RSS (RSS stays flat; it's not a heap leak). Track
  GTT-delta from an idle baseline + gen speed.
- **Dense models fully preallocate** (weights + full-ctx KV + compute buffer at load), so
  once loaded with even ~1 GB free they stay put — safe. MoE-with-CPU-offload can spill
  more dynamically during gen, so give it more headroom.
- `[RDNA2/Vulkan]` **turbo2 vs turbo3 KV**: counterintuitively **turbo3 is the LARGER /
  higher-precision** V-cache; **turbo2 is more compressed → fits MORE context**. Rule of
  thumb: K stays q8_0, drop **V** first (asymmetric — K is the sensitive tensor via softmax;
  V errors average out).
- The `llama-fit-params` auto-sizer **under-reserves for the MTP draft context** (~1 GB+
  gap seen), so "projected free" can be optimistic — verify with a real gen.
- `[RDNA2/Vulkan]` **`-ub` (ubatch) does NOT speed prefill** here (already at the compute
  ceiling, no matrix cores) — bigger just wastes VRAM. **Prefill is ~flat across ncmoe** too
  (ncmoe is a *gen-vs-headroom* dial). Quant tier rarely helps either (Compact ≈ Quality;
  "extra bits buy nothing"). QAT ≈ APEX on these graded tests (both saturate at 4-bit).

## Hardware / backend notes
- `[RDNA2/Vulkan]` **No matrix cores** (the coopmat dead-end) → dense-27B **prefill caps
  ~270 t/s**; MoE (3–4B active) prefills ~4–5× faster (~1200 t/s). For big-prompt agent
  work (hermes-style), prefer an MoE. RDNA3 (7900 XTX) has WMMA → dense prefill improves a lot.
- **Cold-prefill desktop lag**: prefill saturates the GPU, starving the compositor → the
  desktop stutters *only during the cold prefill* (decode/cached turns are smooth). Fixes:
  drive the display from the iGPU (leave the dGPU headless), use an MoE for big prompts,
  shrink the prompt, or lower `-ub`. It's contention, not a hard limit.
- **Gen-1 Bonsai (Q2_0) confabulated identifiers** (URLs, PIDs, proper nouns) even when structurally
  right. Bonsai 2 passed the same hermes probe (2026-09-27, n=1) but still has weak cold recall —
  feed it docs (K_ctx) for anything factual.

## Running-the-harness footguns
- **pi renders to a TTY only** — a piped `pi -p | …` captures nothing. Use a real PTY:
  `pitest.sh` wraps it in util-linux `script`; otherwise run it in a tmux pane and
  `capture-pane`. pi's `local-model` provider **port must equal the bench `PORT`**.
- **`[Claude Code]` GPU launches** need `dangerouslyDisableSandbox: true` (the sandbox
  blocks `/dev/dri` → llama-server exits 144), and must **not** be piped or `&`-backgrounded
  in the same call (also 144) — run them inside tmux, or blocking-foreground redirected to a
  file. `run_in_background` for the *server* can flake; prefer tmux.
- Don't confuse a **tmux false-completion**: waiting on a marker that also appears in the
  echoed command line trips early. Wait on a real artifact (a `.done` file / expected
  output line), not the command echo.
- R1 is manual — always report it explicitly (see the reference tree above); don't let the
  `SCORECARD`'s `"R1_12ball":"MANUAL"` pass as if graded.
