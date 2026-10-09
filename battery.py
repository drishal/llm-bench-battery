#!/usr/bin/env python3
"""Graded reasoning + coding battery against whatever GGUF is serving on :$PORT.

Usage:  python3 battery.py <label>          # label names the output file
        PORT=8099 python3 battery.py qwopus

Talks to an OpenAI-compatible /v1/chat/completions endpoint (llama-server).
Start a model first, e.g.:  ./serve qwopus      (from the parent dir)
or just use runbench.sh / streambench.sh which do launch + wait + run + cleanup.

SAMPLING: by default this sends NO temperature/top_p/top_k, so the RUNNING SERVER's
sampling applies — i.e. exactly the per-model recommended settings that serve launched
(Qwopus 0.6, Bonsai 0.7 + presence 1.0, gemma4 0.7, …). This is deliberate: earlier the
battery forced temp 0.3 on the wire, which is BELOW Qwen's recommended 0.6 and produced
low-temp artifacts (runaways, sign errors). To force a temp for an experiment, set
BENCH_TEMP=0.6. Set BENCH_STREAM=1 for live, colored token streaming (used by the tmux view).

Tests (auto-graded except R1):
  R1  12-ball weighing puzzle        (hard reasoning; MANUAL grade — inspect the tree)
  R2  Einstein/zebra 5-house puzzle  (auto; correct answer = German owns the fish)
  C1  thread-safe token-bucket       (auto; runs a real 20-thread race test)
  C2  word_break DP                  (auto; hidden test cases)
  K   fictional 'zephyrdb' API       (cold parametric vs. with-doc-in-context, /6 each)
Results + full transcript saved to  bench/results/<label>_battery.txt
"""
import json, sys, re, time, subprocess, tempfile, os, urllib.request, textwrap
from pathlib import Path

LABEL = sys.argv[1] if len(sys.argv) > 1 else "run"
PORT  = os.environ.get("PORT", "8099")
URL   = f"http://127.0.0.1:{PORT}/v1/chat/completions"
HERE  = Path(__file__).resolve().parent
OUT   = HERE / "results"; OUT.mkdir(exist_ok=True)
RES   = open(OUT / f"{LABEL}_battery.txt", "w")

STREAM        = os.environ.get("BENCH_STREAM") == "1"
TEMP_OVERRIDE = os.environ.get("BENCH_TEMP")     # None -> defer to the server (recommended)
# Optional per-run sampling overrides for models whose recommended settings differ from
# serve's arch default (e.g. KAT-Coder wants temp 1.0 + presence 1.5). Unset -> server decides.
TOPP_OVERRIDE = os.environ.get("BENCH_TOP_P")
TOPK_OVERRIDE = os.environ.get("BENCH_TOP_K")
PRES_OVERRIDE = os.environ.get("BENCH_PRESENCE")
MINP_OVERRIDE = os.environ.get("BENCH_MIN_P")
SEED_OVERRIDE = os.environ.get("BENCH_SEED")   # fixed seed -> reproducible even at temp>0;
                                              # REQUIRED for A/B: without it, run-to-run spiral
                                              # variance (measured up to ~4x on think length)
                                              # swamps any config effect.
REFF_OVERRIDE = os.environ.get("BENCH_REASONING_EFFORT")   # e.g. xhigh|high|medium|low (Qwen3.8 top-level field); None -> model default
# ⚠ was hardcoded 1200 s. A slow backend (PQ2_0 on ROCm: 13-19 tok/s deep in a 65k ctx)
# blows through that on R1 alone and the TimeoutError kills the WHOLE run at the first test,
# leaving a 2-line results file and no scorecard. Raise it for slow arms.
HTTP_TIMEOUT  = int(os.environ.get("BENCH_TIMEOUT", "1200"))
R1_MAXTOK     = int(os.environ.get("BENCH_R1_MAXTOK", "32000"))  # high-effort reasoners (e.g. Qwen3.8 xhigh) need room; models that don't stop early via finish=stop. Raise near ctx (e.g. 63000) for very deep reasoning
# BENCH_ONLY=R1  (or "R1,C1") runs just those tests, reusing the same live server. Empty -> all.
ONLY = {t.strip().upper() for t in os.environ.get("BENCH_ONLY", "").split(",") if t.strip()}
def sel(k): return (not ONLY) or k.upper() in ONLY
_NOCOL        = bool(os.environ.get("NO_COLOR"))

class Cx:
    dim = "\033[2m";     red = "\033[1;31m"; grn = "\033[1;32m"
    yel = "\033[1;33m";  cyn = "\033[1;36m"; mag = "\033[35m"; rst = "\033[0m"
_ANSI = re.compile(r"\033\[[0-9;]*m")
def col(s, c): return s if _NOCOL else f"{c}{s}{Cx.rst}"

def log(*a, c=None):
    s = " ".join(str(x) for x in a)
    print(col(s, c) if (c and not _NOCOL) else s)
    print(_ANSI.sub("", s), file=RES); RES.flush()

def phase(name):
    log(f"\n▶▶▶ {name} …", c=Cx.cyn)

def _body(messages, mt):
    b = {"model": "local-model", "max_tokens": mt, "messages": messages}
    if TEMP_OVERRIDE is not None:            # experiment override; else server decides
        b["temperature"] = float(TEMP_OVERRIDE)
    if TOPP_OVERRIDE is not None: b["top_p"] = float(TOPP_OVERRIDE)
    if TOPK_OVERRIDE is not None: b["top_k"] = int(TOPK_OVERRIDE)
    if PRES_OVERRIDE is not None: b["presence_penalty"] = float(PRES_OVERRIDE)
    if MINP_OVERRIDE is not None: b["min_p"] = float(MINP_OVERRIDE)
    if REFF_OVERRIDE:             b["reasoning_effort"] = REFF_OVERRIDE
    if SEED_OVERRIDE is not None: b["seed"] = int(SEED_OVERRIDE)
    return b

def ask(messages, mt=14000):
    return ask_stream(messages, mt) if STREAM else ask_block(messages, mt)

def ask_block(messages, mt):
    b = json.dumps(_body(messages, mt)).encode()
    t = time.time()
    r = urllib.request.urlopen(
        urllib.request.Request(URL, b, {"Content-Type": "application/json"}), timeout=HTTP_TIMEOUT)
    d = json.load(r); dt = time.time() - t
    m = d["choices"][0]["message"]; u = d.get("usage", {})
    return (m.get("content", "") or "", m.get("reasoning_content", "") or "",
            u.get("completion_tokens", 0), dt, d["choices"][0].get("finish_reason"))

def ask_stream(messages, mt):
    body = _body(messages, mt); body["stream"] = True
    body["stream_options"] = {"include_usage": True}
    b = json.dumps(body).encode()
    t = time.time()
    r = urllib.request.urlopen(
        urllib.request.Request(URL, b, {"Content-Type": "application/json"}), timeout=HTTP_TIMEOUT)
    content, reasoning, tok, fr, mode = [], [], 0, None, None
    for raw in r:
        line = raw.decode("utf-8", "replace").strip()
        if not line.startswith("data:"):
            continue
        payload = line[5:].strip()
        if payload == "[DONE]":
            break
        try:
            j = json.loads(payload)
        except json.JSONDecodeError:
            continue
        for choice in j.get("choices", []):
            d = choice.get("delta", {})
            rc, cc = d.get("reasoning_content"), d.get("content")
            if rc:
                if mode != "t":
                    sys.stdout.write(col("\n  ┄┄ thinking ┄┄\n", Cx.mag)); mode = "t"
                reasoning.append(rc)
                sys.stdout.write(rc if _NOCOL else Cx.dim + rc + Cx.rst)
            if cc:
                if mode != "a":
                    sys.stdout.write(col("\n  ▶ answer\n", Cx.grn)); mode = "a"
                content.append(cc); sys.stdout.write(cc)
            if choice.get("finish_reason"):
                fr = choice["finish_reason"]
            sys.stdout.flush()
        u = j.get("usage")
        if u:
            tok = u.get("completion_tokens", tok) or tok
    sys.stdout.write("\n"); sys.stdout.flush()
    return ("".join(content), "".join(reasoning), tok, time.time() - t, fr)

def extract_code(txt):
    m = re.search(r"```(?:python)?\s*\n(.*?)```", txt, re.S)
    return m.group(1) if m else txt

def run_py(code, test, timeout=20):
    src = code + "\n\n" + test
    with tempfile.NamedTemporaryFile("w", suffix=".py", dir=OUT, delete=False) as f:
        f.write(src); path = f.name
    try:
        p = subprocess.run([sys.executable, path], capture_output=True, text=True, timeout=timeout)
        out = (p.stdout + p.stderr).strip()
        return ("ALLPASS" in out and p.returncode == 0), out[-1500:]
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT (possible deadlock / blocking impl)"
    finally:
        try: os.unlink(path)
        except OSError: pass

results = {}
# BENCH_SAVE_TRACES=1 -> persist each phase's raw reasoning_content to
# results/<label>_traces/<tag>.txt so quant-to-quant trace diffs are possible.
# Off by default: traces are large and most runs don't need them.
SAVE_TRACES = os.environ.get("BENCH_SAVE_TRACES") == "1"
TRACEDIR = OUT / f"{LABEL}_traces"
if SAVE_TRACES: TRACEDIR.mkdir(exist_ok=True)

def header(tag, c, rc, tok, dt, fr):
    log(f"\n{'='*70}\n{tag}  ({dt:.1f}s, think={len(rc)}c, out={tok}tok, "
        f"{(tok/dt if dt else 0):.1f} tok/s, finish={fr})\n{'='*70}", c=Cx.yel)
    if SAVE_TRACES:
        slug = re.sub(r"[^A-Za-z0-9]+", "_", tag.split("(")[0].strip())[:40] or "phase"
        meta = (f"# label={LABEL} tag={tag}\n# dt={dt:.1f}s think_chars={len(rc)} "
                f"out_tok={tok} finish={fr}\n{'-'*70}\n")
        (TRACEDIR / f"{slug}.think.txt").write_text(meta + (rc or ""))
        (TRACEDIR / f"{slug}.answer.txt").write_text(meta + (c or ""))
def grade(key, val, ok):
    results[key] = val
    log(f">>> {key} GRADE: {val}", c=(Cx.grn if ok else Cx.red))

# ---------------- R1: 12-ball weighing (manual grade) ----------------
P = """You have 12 identical-looking balls. Exactly ONE is a different weight - it may be
heavier OR lighter, and you do not know which. Using a balance scale at most 3 times,
give a complete strategy that ALWAYS identifies which ball is the odd one AND whether
it is heavier or lighter, for every one of the 24 possible cases. Present the full
decision tree concisely."""
if sel("R1"):
    phase("R1 12-ball weighing (reasoning; manual grade)")
    c, rc, tok, dt, fr = ask([{"role": "user", "content": P}], mt=R1_MAXTOK)
    header("R1 12-BALL (reasoning; manual grade)", c, rc, tok, dt, fr)
    log(c.strip()[:2600])
    results["R1_12ball"] = "MANUAL"

# ---------------- R2: zebra puzzle (auto: German) ----------------
P = """Solve this logic puzzle. Five houses in a row (positions 1-5, left to right).
1. The Brit lives in the red house.
2. The Swede keeps dogs.
3. The Dane drinks tea.
4. The green house is immediately to the LEFT of the white house.
5. The green house's owner drinks coffee.
6. The person who smokes Pall Mall keeps birds.
7. The owner of the yellow house smokes Dunhill.
8. The man in the centre house (position 3) drinks milk.
9. The Norwegian lives in the first house.
10. The man who smokes Blend lives next to the one who keeps cats.
11. The man who keeps horses lives next to the one who smokes Dunhill.
12. The man who smokes Blue Master drinks beer.
13. The German smokes Prince.
14. The Norwegian lives next to the blue house.
15. The man who smokes Blend has a neighbour who drinks water.
Question: WHO OWNS THE FISH? Answer with the nationality on the final line as: ANSWER: <nationality>"""
if sel("R2"):
    phase("R2 zebra 5-house puzzle (reasoning; auto=German)")
    c, rc, tok, dt, fr = ask([{"role": "user", "content": P}])
    header("R2 ZEBRA (reasoning; auto, correct=German)", c, rc, tok, dt, fr)
    log(c.strip()[-1200:])
    mm = re.search(r"ANSWER:\s*([A-Za-z]+)", c)
    ans = (mm.group(1) if mm else "").lower()
    if not ans:
        ans = "german" if re.search(r"german[^.]{0,40}fish|fish[^.]{0,40}german", c, re.I) else "?"
    grade("R2_zebra", "PASS" if ans == "german" else f"FAIL(said {ans})", ans == "german")

# ---------------- C1: thread-safe token bucket ----------------
P = """Write a THREAD-SAFE token bucket rate limiter in Python with EXACTLY this API:

    class TokenBucketRateLimiter:
        def __init__(self, capacity: int, refill_rate: float): ...   # refill_rate = tokens added per second
        def try_acquire(self, n: int = 1) -> bool: ...   # non-blocking; True if n tokens taken, else False

The bucket starts FULL (capacity tokens). It must be correct under concurrent access
from many threads (no race conditions, never grant more tokens than available).
Return ONLY a fenced python code block."""
if sel("C1"):
    phase("C1 thread-safe token-bucket rate limiter (coding; 20-thread race test)")
    c, rc, tok, dt, fr = ask([{"role": "user", "content": P}])
    header("C1 RATE-LIMITER (coding; run 20-thread test)", c, rc, tok, dt, fr)
    code = extract_code(c); log(code[:1500])
    test = textwrap.dedent("""
        import threading
        rl=TokenBucketRateLimiter(capacity=100, refill_rate=0)  # no refill
        grants=[]; lock=threading.Lock()
        def worker():
            local=0
            for _ in range(50):
                if rl.try_acquire(1): local+=1
            with lock: grants.append(local)
        ts=[threading.Thread(target=worker) for _ in range(20)]
        for t in ts: t.start()
        for t in ts: t.join()
        total=sum(grants)
        print("TOTAL_GRANTED",total)
        assert total==100, f"expected 100 got {total} (race or wrong count)"
        print("ALLPASS")
    """)
    ok, out = run_py(code, test)
    log(f"[test output] {out}")
    grade("C1_ratelimiter", "PASS" if ok else "FAIL", ok)

# ---------------- C2: word_break DP ----------------
P = """Write a Python function with EXACTLY this signature:

    def word_break(s: str, words: list[str]) -> bool

Return True iff s can be segmented into a space-separated sequence of one or more
words, each of which is present in the list `words` (words may be reused). Otherwise
False. Return ONLY a fenced python code block."""
if sel("C2"):
    phase("C2 word_break DP (coding; hidden tests)")
    c, rc, tok, dt, fr = ask([{"role": "user", "content": P}])
    header("C2 WORD-BREAK (coding; hidden tests)", c, rc, tok, dt, fr)
    code = extract_code(c); log(code[:900])
    test = textwrap.dedent("""
        cases=[
          ("leetcode",["leet","code"],True),
          ("applepenapple",["apple","pen"],True),
          ("catsandog",["cats","dog","sand","and","cat"],False),
          ("cars",["car","ca","rs"],True),
          ("abcd",["a","abc","b","d"],True),
          ("abcd",["a","abc","bd"],False),
          ("aaaaaaaaab",["a","aa","aaa"],False),
        ]
        bad=[]
        for s,w,exp in cases:
            try: got=word_break(s,w)
            except Exception as e: got=f"ERR:{e}"
            if got!=exp: bad.append((s,exp,got))
        print("FAILURES",bad if bad else "none")
        assert not bad
        print("ALLPASS")
    """)
    ok, out = run_py(code, test)
    log(f"[test output] {out}")
    grade("C2_wordbreak", "PASS" if ok else "FAIL", ok)

# ---------------- K: fictional API — cold vs with-context ----------------
KQ = ("Using the zephyrdb library, write a function `count_active_users(dsn)` that: opens a "
      "connection with pool_size 8; runs `SELECT id FROM users WHERE active = true` inside a "
      "SERIALIZABLE transaction with a 5000 ms timeout; returns the number of rows; and closes "
      "resources properly. Return ONLY a fenced python code block.")
DOC = ("zephyrdb API reference:\n"
       "- zephyrdb.connect(dsn, *, pool_size=4, retry=RetryPolicy.EXPONENTIAL) -> Connection\n"
       "- Connection is a context manager; or call conn.close().\n"
       "- conn.transaction(isolation=Isolation.SERIALIZABLE) -> context manager yielding a Tx\n"
       "- Tx.execute(sql, params=None, *, timeout_ms=3000) -> ResultSet\n"
       "- ResultSet has .rows (list[dict]) and .affected (int)\n"
       "- Isolation members: READ_COMMITTED, REPEATABLE_READ, SERIALIZABLE\n")
def grade_zephyr(code):
    return {
      "connect+pool_size=8": bool(re.search(r"connect\([^)]*pool_size\s*=\s*8", code)),
      "SERIALIZABLE transaction": bool(re.search(r"transaction\([^)]*Isolation\.SERIALIZABLE", code)),
      "timeout_ms=5000": bool(re.search(r"timeout_ms\s*=\s*5000", code)),
      "execute the SELECT": bool(re.search(r"execute\(", code) and re.search(r"active", code, re.I)),
      "returns len(.rows)": bool(re.search(r"len\([^)]*\.rows", code) or re.search(r"\.affected", code)),
      "closes (ctx-mgr/close)": bool(
          re.search(r"\.close\(\)", code)
          or re.search(r"with\s+.*connect", code)
          or ((_m := re.search(r"(\w+)\s*=\s*[\w.]*connect\(", code))
              and re.search(r"\bwith\s+" + re.escape(_m.group(1)) + r"\b", code))
      ),
    }
if sel("K"):
    phase("K-cold zephyrdb (parametric knowledge of a FICTIONAL API — no context)")
    c, rc, tok, dt, fr = ask([{"role": "user", "content": KQ}])
    header("K-COLD zephyrdb (no context — parametric knowledge of a FICTIONAL API)", c, rc, tok, dt, fr)
    code = extract_code(c); ch = grade_zephyr(code)
    log(code[:700]); log(f"checks: {ch}")
    results["K_cold"] = f"{sum(ch.values())}/6"
    log(f">>> K_cold GRADE: {results['K_cold']}", c=Cx.yel)
    phase("K-ctx zephyrdb (WITH doc in context — 'harness provides knowledge')")
    c, rc, tok, dt, fr = ask([{"role": "system", "content": DOC}, {"role": "user", "content": KQ}])
    header("K-CTX zephyrdb (WITH doc in context — the 'harness provides knowledge' case)", c, rc, tok, dt, fr)
    code = extract_code(c); ch = grade_zephyr(code)
    log(code[:900]); log(f"checks: {ch}")
    results["K_ctx"] = f"{sum(ch.values())}/6"
    log(f">>> K_ctx GRADE: {results['K_ctx']}", c=Cx.grn)

log(f"\n{'#'*70}", c=Cx.cyn)
log(f"SCORECARD [{LABEL}]: " + json.dumps(results), c=Cx.cyn)
RES.close()
