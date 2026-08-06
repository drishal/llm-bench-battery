# Local-LLM Benchmark Battery

Grade any locally-served LLM (OpenAI-compatible endpoint) on reasoning + coding +
knowledge, plus optional agentic tool-use via `pi`. Runs anywhere, any model.

**Default run (live tmux, battery + pi):**
```bash
LAUNCHER=none PORT=8081 ./bench.sh mymodel   # attach to a server already on :8081
tmux attach -r -t bench                      # watch live
```
**Portable one-off (no launcher):**
```bash
PORT=8081 python3 battery.py mymodel
```

📖 Full instructions, options, and pi setup: see **[CLAUDE.md](CLAUDE.md)**.
