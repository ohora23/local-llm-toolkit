# Findings — measured experiments behind the defaults (RTX 5080, 16 GB)

Every default in this toolkit was chosen by measurement, not vibes. These are the head-to-heads,
all on the same 5080 with objective scoring (generate code → **run it** → pass/fail; tok/s from
streaming). Reproduce with the `eval-*.py`, `refactor-eval.py`, `agent-loop-test.py`, and
`compare-*.sh` harnesses.

## 1. Speculative decoding — helps dense, **hurts MoE**

A small draft model proposes K tokens; the target verifies them in one pass. The win assumes a
**dense** target (verify-K ≈ cost-of-1). It backfires on a low-active-param **MoE**, because
batched verification activates more experts.

| Target | Draft | Result |
|---|---|---|
| Qwen3-Coder-30B-**A3B** (MoE, 3B active) | Qwen3-0.6B | **115 → 53 tok/s** ❌ (68% accept, still slower) |
| Qwen3-**32B dense** planner (CPU) | Qwen3-0.6B | **2.3 → 4.4 tok/s** ✅ (~1.9×) |

→ Adopted for the dense CPU planner (`profiles/cpu-agent/planner-32b.sh`); **never** for the MoE coder.

## 2. NVFP4 on Blackwell — works, but not for a 30B on 16 GB

The 5080 has native FP4 tensor cores. vLLM + FlashInfer drives them (`nvfp4-poc/`).

- **Llama-3.1-8B NVFP4: 148 tok/s, 5.66 GB.** FP4 vs FP8 (same model) = **1.64× faster, 34% less VRAM**.
- **But** `Qwen3-Coder-30B` NVFP4 = **18.1 GB > 15.9 GB** usable → won't load. NVFP4 bottoms out at
  ~4.5 effective bits; **EXL3 goes to 3-bit**, which is why a 30B fits (13.8 GB) in EXL3 but not FP4.
- Getting FP4 kernels to JIT-compile on consumer `sm_120` took an **8-step toolchain fix** (align
  nvcc/ptxas/cicc/cudart to CUDA 13.2, `libcudart.so` symlink, `MAX_JOBS` to avoid an OOM-killed
  compile). Documented in `nvfp4-poc/serve-nvfp4.sh`.

→ **On a 16 GB card, EXL3 3-bit is the right tool for 30B.** NVFP4 shines at 24 GB+ or on smaller models.

## 3. Fitting a "better" model in 16 GB via EXL3 (low-bit)

EXL3's sub-4-bit lets you trade *model size ↔ quant fidelity*. Candidates vs the Qwen3-Coder-30B baseline:

| Model | Type | bpw | Speed | VRAM | Note |
|---|---|---|---|---|---|
| Qwen3-Coder-30B (default) | **MoE** | 3.0 | ~115 tok/s | ~12 GB | fast because MoE (3B active) |
| Devstral-Small-24B | dense | 4.0 | 52 tok/s | 12.7 GB | agentic-coding specialist, but ~2× slower |
| Qwen3.6-27B | dense | 3.08 | 42 tok/s | 11.3 GB | strong, but dense → slow + verbose |
| **Qwen3.6-35B-A3B** | **MoE** | 2.08 | **127 tok/s** | **9.8 GB** | only candidate that *beats* the default on speed+VRAM |

**Lesson: MoE (low active params) is why the coder is fast.** Dense 24–27B models are ~2× slower on
this card regardless of quality.

## 4. Qwen3.6-35B-A3B — full validation → kept the specialist anyway

The one MoE that beat the default on speed/VRAM got the full gauntlet (thinking disabled via
`chat_template_kwargs:{enable_thinking:false}` — see `profiles/.../d-qwen36-35b.sh`):

| Test | Qwen3.6-35B (2.08bpw) | Qwen3-Coder-30B (3.0bpw) |
|---|---|---|
| Easy coding (6 probs, run-verified) | 6/6 | 6/6 |
| Hard coding (LFU, dijkstra, edit-dist…) | 5/6 | 5/6 (same one failed both) |
| Agent tool-calls + multi-step loop | ✅ correct | ✅ |
| **Multi-file behavior-preserving refactor** | ❌ off / ✅ **only with thinking (37 s)** | ✅ **one-shot (5 s)** |

→ 2.08-bit did **not** hurt coding accuracy — but the **specialized** Qwen3-Coder nails hard
multi-file refactors in one shot, where the general Qwen3.6 needs slow thinking. **Default stays
Qwen3-Coder-30B**; Qwen3.6-35B is kept as a validated alternative (`./setup-exl3.sh d-qwen36-35b`).

## 5. Ornith-1.0-35B — hybrid attention unlocks 128K on 16 GB → promoted to daily coder

The multi-agent use case kept hitting a wall: Qwen3-Coder-30B's full attention (48 layers) blows the
KV budget at ~48–96 K tokens. **Ornith-1.0-35B** (Qwen3.5-35B-A3B agentic-coding MoE, MIT) uses
**hybrid attention** — of 40 layers only 10 are full-attention, the rest linear (constant KV). We
converted it locally to EXL3 3.08 bpw (`convert-ornith-exl3.sh`; no community EXL3 exists).

| Metric (16 GB, EXL3 3 bpw, Q4 KV) | Ornith-35B | Qwen3-Coder-30B |
|---|---|---|
| Max context that loads | **~224 K** | ~48–96 K |
| Needle-recall @115 K (depths 10/50/90 %) | **3/3 PASS** | can't fit |
| Decode | 126–147 tok/s | ~115 tok/s |
| **Warm** TTFT | **0.08–0.19 s** | ~0.25 s |
| Hard-coding 6 (thinking-OFF + code system prompt) | 5/6 | 6/6 |
| Hard-coding 6 (thinking-ON) | **6/6** | — |

Two gotchas worth their own line:
- **The "3.4 s TTFT" that almost buried Ornith was a benchmark artifact** — the first inference after
  load pays a one-time cudagraph/kernel warm-up. Discard the first call (or warm it) and TTFT is
  ~0.1 s. `start-tabby-server.sh` now fires a background warm-up request after load, so the first
  *real* request is fast (helps every model, not just Ornith).
- **Don't budget the reasoning.** thinking-ON hits 6/6; telling it to "think briefly" drops it to
  4/6. It's binary (`enable_thinking` true/false) — half-thinking is worse than none.

**Decision:** Ornith is now the `gpu` default, run in **two modes** — `enable_thinking:false` for fast
interactive coding (0.1 s TTFT, 128 K context, 5/6), flip to `true` for the hard/critical ones (6/6).
Qwen3-Coder-30B stays a one-command fallback (`./setup-exl3.sh a-safe`) — it still wins "hard problem,
*fast*, first try" (6/6 with no thinking). Setup: `./setup-exl3.sh e-ornith && ./start-tabby-server.sh`.

## 6. gemma-4 NVFP4 (Unsloth) — only the 12B fits, and it's beaten here

Checked Unsloth's gemma-4 NVFP4 line for the same KV/long-context goal. On 16 GB only **gemma-4-12b**
(9.3 GB) fits — 31B (24.8 GB) and 26B-A4B (16.9 GB) don't. Measured 12B on vLLM: **128 K loads at
14.4 GB, 74 tok/s, needle-recall 3/3 @119 K** (its 5:1 sliding/global attention makes KV cheap, like
Ornith). But it's **slower (74 vs 126 tok/s), a general non-coding model, and locked to the
high-effort vLLM/sm_120 path** — and the long-context win is already banked by Ornith in the native
EXL3 stack. **Skipped** for coding; only a candidate if you specifically want a fast multimodal
long-context assistant.

## 7. Multi-agent on Ornith — context wall gone, but temperature breaks tool calls at high context

Wired Ornith (128 K) in as the driver agent (opencode/sisyphus) on a real multi-file bug-fix task.
The historical blocker — driver context blowing past the KV budget — is **gone**: the session ran at
**78 K tokens** with no context-limit errors (exactly where Qwen3-Coder died at ~48 K). But two new
failure modes showed up, both fixable:

- **High context + thinking-ON degenerates** into token salad on the 3.08 bpw quant. Fix: default
  `enable_thinking` to *off* in the chat template (explicit `true` still opts in).
- **High context + high temperature corrupts tool-call arguments** (garbled paths, wrong keys).
  Measured cleanly: at 78 K, `temp ≤ 0.4` → perfect tool calls; `temp ≥ 0.7` → breakage. It's the
  sampling randomness over a low-bit model at depth, not the KV cache or context length.

Fix that stuck: a TabbyAPI **server-side sampler override forcing `temperature: 0.2`** (`force: true`),
shipped as the `coder` preset (`e-ornith.sh` writes it, `setup-exl3.sh e-ornith` wires it). Clients can
send any temperature; the server clamps it. With that, the agent completed the task end-to-end — found
the bug, edited the source, ran the tests, all 5 passed. Low temperature is the right default for a
coding/tool-use driver anyway.

## Takeaway

For coding on a 16 GB RTX 5080: a **low-active-param MoE at EXL3 3-bit** is the sweet spot. A
coding-*specialized* model (Qwen3-Coder-30B) wins "hard + fast + first try"; a **hybrid-attention**
model (Ornith-35B) trades a hair of fast-mode accuracy for **4–5× the context (128 K+ on 16 GB)** and
equal speed — which is why it's the current default, with the specialist one command away.
