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

## Takeaway

For coding on a 16 GB RTX 5080: a **low-active-param MoE at EXL3 3-bit** is the sweet spot — fast,
fits, and (for a coding-specialized model) beats bigger/newer general models on the hardest tasks.
