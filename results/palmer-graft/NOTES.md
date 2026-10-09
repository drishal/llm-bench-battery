# Palmer-graft A/B — Bonsai 2 PTQ1_0, 2026-10-09

Tweet: https://x.com/CaryPalmerr/status/2108233694360281144 → repo `professorpalmer/bonsai-ada-surgery`
(and `mirai-s-ada`, not benched here — Mirai already rejected on quality).

Graft = backend-agnostic subset of the bonsai-ada-surgery patch series, applied onto
PrismML-Eng/llama.cpp @ **adfffbe** (= the base of `~/src/llama.cpp-prism-ptq1fast`, user v9 layer).

## Recipe
- Worktree: `/tmp/ptq1-palmer` (base adfffbe + `mmq-v9-current-tree.patch` = user's live tree + Palmer subset)
- Full source snapshot: `palmer-graft-source-20261009.patch` (this dir; `git diff HEAD` from the worktree)
- Palmer patches applied, in order: 0011, 0012, 0014, 0015, 0017, 0019(non-CUDA hunks), 0021,
  0023(non-CUDA hunks), 0031, 0039, 0042. Skipped as CUDA-only: 0001-0010, 0013, 0016, 0018, 0020,
  0022, 0024-0030, 0033, 0036-0038, 0040, 0041, 0043-0045.
- What they do (per README table): server-side only —
  - 0011/0012/0015/0021/0023(+0019 spec part): MTP draft catch-up + stale-row + flush fixes (common/speculative, src/models/qwen35.cpp)
  - 0014: reject out-of-vocab token ids from backend
  - 0017: `--spec-draft-depth-max` (stop drafting once the …)
  - 0031: `--spec-draft-window` + `--spec-draft-n-max-tail` (draft window/tail limits)
  - 0039: `--spec-lookup-n-max N` — separate draft cap for lookup (ngram-*) drafters listed before the model drafter
  - 0042: grammar clone by binary search (src/llama-grammar.cpp) — tool-heavy agent requests
- Build: `nix-build build-pr.nix -o result-palmer` in the worktree (build-pr.nix copied from ptq1fast).
  Two iteration rounds: 0021 needed 0019/0023 (non-CUDA parts) for the `catchup_failed` member.

## Bookkeeping
- Control binary: `result-g244/bin/llama-server` (serve default for bonsai-q1).
- Test binary: `/tmp/ptq1-palmer/result-palmer/bin/llama-server`.
- Serve override knob (verified): `PRISM_Q1_LLAMA_SERVER=<path> ./serve bonsai-q1`.
- Model: bonsai/Ternary-Bonsai-2-27B-PTQ1_0-mtp-q4km.gguf, serve flags exactly as `--dry-run`
  (K q8_0 / V q4_0, `-ub 512`, MTP d1, temp 1.0 / top-p 0.95 / top-k 20, load-mode none, :8081).

## Arms
- A = g244, MTP d1 (control)
- B = palmer, MTP d1 (graft isolation: MTP catch-up cluster + 0042 lazy)
- C = palmer, `--spec-type ngram-mod,draft-mtp --spec-lookup-n-max 32` (his default lookup recipe)
- pi hello: CTRL / GRAFT interleaved (serve path, pi with tools)

## Results
(see results.txt / pihello_results.txt; summary appended below)

Probe matrix — decode `tg` (tok/s), server-side timings, ~9.4-23.7k-token prompts, Bonsai PTQ1_0
+ MTP d1, K q8_0/V q4_0, ub 512, temp 1.0 preset, RADV_PERFTEST=nogttspill:

| probe | A g244 | B palmer | C lookup32 (r1) | C2 lookup32 (r2) | A2 g244 |
|---|---|---:|---:|---:|---:|
| rewrite_4k (23.7k ctx, renames) | 41.1 | 41.0 | 39.8 | 41.7 | 41.0 |
| rewrite_12k (12.9k ctx, renames) | 42.9 | 42.9 | 42.0 | 44.4 | 42.9 |
| rewrite_verbatim (12.9k ctx) | 42.9 | — | — | 41.2 | — |
| tools100 forced call (grammar) | 41.7 | 42.1 | **69.6** | **70.4** | 42.2 |
| prose_control | 45.6 | 45.7 | (53.8) | 45.2 | 45.6 |

Reads:
- Graft alone (B) = exact neutral on every probe (MTP cluster + 0042 show nothing at this scale).
- **Lookup (`--spec-type ngram-mod,draft-mtp --spec-lookup-n-max 32`) = +65-68% on grammar-constrained
  tool-call decode** (69.6/70.4 vs 41.7/42.2), reproducible, same toolcall=fn_042 output both sides.
  Likely mechanism: tool-call JSON reuses schema text already in context → ngram drafts match, and
  MTP d1 drafts were largely grammar-rejected anyway.
- Rewrites (rename AND verbatim): neutral — no lookup win. Our 40+ t/s decode floor and/or the
  ngram match on renamed code = his 3-4x copy wins (at ~20 t/s on 12-16 GB Ada) do NOT transfer here.
- prose +18% on first C run did not reproduce → noise.