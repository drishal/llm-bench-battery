#!/usr/bin/env python3
"""palmer_ab.py — one arm of the Palmer-graft A/B on Bonsai 2 PTQ1_0 (RDNA2/Vulkan).

Usage: palmer_ab.py LABEL BIN [--spec-extra "ARGS..."]
Starts llama-server on :8081 with the exact `./serve bonsai-q1` flags, warms up,
runs 4 probes (rewrite_4k, rewrite_12k, tools100, prose_control), prints a
one-line summary per probe (server-side timings, fresh nonce, cache off),
then kills the server. Stdlib only.

Probes:
  rewrite_4k/12k  — copy-heavy file-rewrite requests (the lookup-drafting win case)
  tools100        — 100-tool payload with a forced tool call (patch 0042: grammar clone)
  prose_control   — plain text, no tools (lookup should be neutral here)
"""
import json, os, signal, subprocess, sys, time, urllib.request, urllib.error

HOST = "http://127.0.0.1:8081"
PORT = 8081
REPO = "/home/drishal/src/llama.cpp-prism-ptq1fast"
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "results.txt")

BASE_FLAGS = [
    "-m", "/home/drishal/Desktop/models/files/bonsai/Ternary-Bonsai-2-27B-PTQ1_0-mtp-q4km.gguf",
    "--device", "Vulkan0", "-ngl", "999",
    "--mmproj", "/home/drishal/Desktop/models/files/bonsai/Ternary-Bonsai-2-27B-mmproj-Q8_0.gguf",
    "--chat-template-kwargs", '{"preserve_thinking":true}',
    "-c", "131072", "--flash-attn", "on", "--cache-type-k", "q8_0", "--cache-type-v", "q4_0",
    "-b", "2048", "-ub", "512", "--temp", "1.0", "--top-p", "0.95", "--top-k", "20",
    "--load-mode", "none", "--fit", "off", "-np", "1", "--min-p", "0",
    "--port", str(PORT),
]

def llm_req(messages, max_tokens, tools=None, tool_choice=None, label=""):
    body = {"messages": messages, "max_tokens": max_tokens, "stream": False,
            "cache_prompt": False, "seed": None}
    if tools is not None:
        body["tools"] = tools
        if tool_choice is not None:
            body["tool_choice"] = tool_choice
    data = json.dumps(body).encode()
    for attempt in range(3):
        try:
            r = urllib.request.urlopen(urllib.request.Request(
                HOST + "/v1/chat/completions", data=data,
                headers={"Content-Type": "application/json"}), timeout=600)
            return json.loads(r.read())
        except urllib.error.HTTPError as e:
            err = e.read().decode()[:300]
            if e.code == 400 and tool_choice is not None:
                return {"http_error": e.code, "detail": err}
            print(f"  [probe {label}] HTTP {e.code}: {err}", flush=True)
            if attempt == 2:
                return {"http_error": e.code, "detail": err}
            time.sleep(3)
    return {}

def report(tag, resp):
    if "timings" not in resp:
        print(f"PROBE {tag}: no timings ({resp.get('http_error','?')} {resp.get('detail','')[:120]})", flush=True)
        return
    t = resp["timings"]
    u = resp.get("usage", {})
    p = t.get("prompt_n", u.get("prompt_tokens", 0))
    g = t.get("predicted_n", u.get("completion_tokens", 0))
    pt = t.get("prompt_ms", 0); gt = t.get("predicted_ms", 0)
    out = (f"PROBE {tag} in={p} out={g} pp={t.get('prompt_per_second',0):.0f} "
           f"tg={t.get('predicted_per_second',0):.1f} "
           f"pp_ms={pt:.0f} tg_ms={gt:.0f}")
    for k in ("draft_n", "draft_n_accept", "draft_acceptance_rate", "n_accept", "eval_count"):
        if k in t:
            out += f" {k}={t[k]}"
    ch = resp.get("choices", [{}])[0].get("message", {})
    tc = ch.get("tool_calls")
    if tc:
        out += f" toolcall={tc[0].get('function',{}).get('name','?')}"
    else:
        out += f" head=\"{str(ch.get('content'))[:48]}\""
    print(out, flush=True)
    with open(OUT, "a") as f:
        f.write(out + "\n")

def read_sources():
    base = REPO + "/ggml/src/ggml-vulkan/vulkan-shaders/"
    parts = []
    for name in ("mul_mmq_funcs.glsl", "mul_mm_funcs.glsl", "ptq1_0.glsl"):
        with open(base + name) as f:
            parts.append((name, f.read()))
    return parts

def tools100():
    tools = []
    for i in range(1, 101):
        tools.append({
            "type": "function",
            "function": {
                "name": f"fn_{i:03d}",
                "description": f"Synthetic tool {i}: performs operation {i}.",
                "parameters": {"type": "object", "properties": {
                    "query": {"type": "string", "description": "input string"},
                    "count": {"type": "integer", "description": "quantity"}},
                    "required": ["query", "count"]},
            }})
    return tools

def main():
    label, binary = sys.argv[1], sys.argv[2]
    extra = []
    if len(sys.argv) > 3:
        assert sys.argv[3] == "--spec-extra"
        extra = sys.argv[4].split()
    cmd = [binary] + BASE_FLAGS + extra
    env = dict(os.environ, RADV_PERFTEST="nogttspill")
    with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "logs", f"server_{label}.log"), "wb") as slog:
        proc = subprocess.Popen(cmd, stdout=slog, stderr=subprocess.STDOUT, env=env)
    t0 = time.time()
    try:
        while time.time() - t0 < 300:
            if proc.poll() is not None:
                print(f"ARM {label}: SERVER DIED rc={proc.returncode}"); sys.exit(1)
            try:
                urllib.request.urlopen(HOST + "/v1/models", timeout=3)
                break
            except Exception:
                time.sleep(2)
        print(f"ARM {label} bin={os.path.basename(binary)} extra={extra} loaded in {time.time()-t0:.0f}s", flush=True)
        # warm-up: prose that shares nothing with the probes
        llm_req([{"role": "user", "content": "Write a haiku about a train journey."}], 60, label="warm")
        # rewrite probes: copy-heavy
        files = read_sources()
        doc4 = "\n\n".join(f"### FILE {n} ###\n" + t for n, t in files)
        ins = ("Reproduce the file above in full as a single output, applying exactly these edits: "
               "rename every identifier starting with 'ggml_' to start with 'palmerx_', and add a comment "
               "`/* rewritten */` as the first line. Output ONLY the rewritten file.")
        for tag, doc in (("rewrite_4k", doc4), ("rewrite_12k", doc4[:32_000])):
            msgs = [{"role": "user", "content": doc + "\n\n" + ins}]
            report(tag, llm_req(msgs, 512, label=tag))
        # verbatim reproduction: no renames — the pure copy-heavy case ngram lookup is built for
        report("rewrite_verbatim", llm_req(
            [{"role": "user", "content": doc4[:32_000] + "\n\nReproduce the file above exactly, token for token. Output ONLY the file, nothing else."}],
            512, label="rewrite_verbatim"))
        # tools100: grammar-constrained decode (patch 0042)
        tools = tools100()
        msgs = [{"role": "user", "content": "Call fn_042 with query='palmer test' and count=3."}]
        resp = llm_req(msgs, 128, tools=tools, tool_choice="required", label="tools100")
        if "http_error" in resp:
            resp2 = llm_req(msgs, 128, tools=tools, tool_choice={"type": "function", "function": {"name": "fn_042"}}, label="tools100")
            if "http_error" in resp2:
                resp2 = llm_req(msgs, 128, tools=tools, label="tools100")
            resp = resp2
        report("tools100", resp)
        # prose control: no tools, generative
        report("prose_control", llm_req([{"role": "user", "content": "Write a 300-word essay on the printing press."}], 320, label="prose"))
    finally:
        proc.send_signal(signal.SIGINT)
        try:
            proc.wait(timeout=30)
        except subprocess.TimeoutExpired:
            proc.kill(); proc.wait()
        print(f"ARM {label} done", flush=True)

if __name__ == "__main__":
    main()