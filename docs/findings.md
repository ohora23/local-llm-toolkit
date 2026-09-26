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

## 8. Bonsai-27B (ternary / 1.71-bit) — extreme low-bit that actually works

Prior verdict on extreme quantization (BitNet-style) was "no payoff on this GPU." **Bonsai-27B**
(PrismML) forces a revisit: it's **Qwen3.6-27B quantized to ternary {−1,0,+1} at 1.71 bpw**, on a
llama.cpp fork (`Q2_0_g128` hybrid-attention CUDA kernels; prebuilt binaries include `sm_120a`).
Measured on the RTX 5080:

| Metric | Bonsai-27B ternary | Ornith-35B (daily) |
|---|---|---|
| Weights on disk | **6.66 GB** | 14.4 GB |
| Decode | 82 t/s → **148 t/s** with the dspark drafter (code, temp 0, ~0.7 accept) | ~130 t/s |
| Prefill (pp512) | 2199 t/s | — |
| Hard-coding 6 (thinking-OFF) | 4/6 | 5/6 |
| Hard-coding 6 (thinking-ON) | 6/6 (~38 s/problem — slow) | 6/6 (~10 s) |
| Max context on 16 GB | **262 K** (13.4 GB, 4-bit KV) / 128 K = 10.5 GB | 224 K |
| Vision | ✅ (mmproj) | ✗ |

Published scores back the quality: HumanEval+ 93.9 (vs 95.1 FP16), LiveCodeBench 82.75 — ternary
barely dented coding. And it runs **native on Blackwell sm_120** out of the box.

**Verdict: keep it as a specialist, not the daily.** Ornith still wins interactive coding (faster
thinking, 5/6 fast mode, already integrated + tool-calls solved). Bonsai's edges are **ultra-long
context (262 K on 16 GB, its 6.66 GB weights leave huge KV room) and vision** — the model to reach for
on >224 K or multimodal work. It needs the PrismML fork today; once the `Q2_0` CUDA path merges
upstream ([llama.cpp#25707](https://github.com/ggml-org/llama.cpp/pull/25707)) the fork goes away.
Run it with `./start-bonsai-server.sh` (`SPECULATIVE=1` for the 1.8× decode, `KV4=1 BONSAI_CTX=262144`
for full context).

_(Also checked, both skipped — see §11 for the re-check that corrected the original reasons:
**SuperGemma4** (uncensored Gemma-4-26B) and **Google LiteRT-LM** (edge/mobile engine).)_

## 9. "Fable" MoE-offload prefetch fork — real, but the free `-ub` knob does most of it

A llama.cpp fork ([`thecodacus/llama.cpp` @ `fable5/prefetch-experts`](https://github.com/thecodacus/llama.cpp/tree/fable5/prefetch-experts))
adds two **opt-in** env-var optimizations for MoE models whose experts are offloaded to system RAM
(`--n-cpu-moe`): `GGML_CUDA_REGISTER_HOST=1` pins the mmap'd expert pages so H2D copies go over DMA,
and `GGML_SCHED_PREFETCH_EXPERTS=1` uploads each layer's experts on a second CUDA stream to overlap
compute. Author reports **+64% prefill** on an RTX 3060. Only one endpoint here qualifies — **`ko`
(Kanana-2-30B-A3B)**; `hyb` runs ik_llama.cpp (patch doesn't apply), `gpu` is EXL3, `cpu` has no H2D.

`llama-bench`, Kanana Q4_K_M, `-ncmoe 18`, `-ub 2048`, r=3:

| Config | pp2048 (t/s) |
|---|---:|
| baseline | 2891.8 ± 77.1 |
| `REGISTER_HOST` (pinning only) | 2885.4 ± 79.1 — **no effect** |
| `PREFETCH_EXPERTS` only | 3612.4 ± 10.4 (**+24.9%**) |
| both | 3659.2 ± 54.1 (+26.5%) |

All the gain is prefetch; pinning contributes nothing measurable on this box (faster GPU/PCIe than a
3060 → less H2D stall to hide). **But it inverts on the real server**, because the fork's benchmark
uses `-ub 2048` while `llama-server` defaults to **512**. Live server, 9,125-token prefill, r=3:

| Config | prefill | VRAM |
|---|---:|---:|
| `-ub 512` (stock server default) | 6.09 s | 14,063 MiB |
| `-ub 512` + prefetch | **7.44 s — 22% *slower*** | 14,061 MiB |
| `-ub 2048` | 3.91 s (−36%) | 14,250 MiB |
| `-ub 2048` + prefetch | 3.57 s (−41%) | 14,254 MiB |

Output was token-identical across all four. **Lesson: at the default ubatch there isn't enough compute
per step to hide the upload behind, so the prefetch machinery is pure overhead.** The big, free win is
`-b/-ub 2048` on stock mainline (−36%); the fork adds only **+9%** on top of that and costs a
maintained fork build, for a non-daily endpoint. **Not adopted** — worth revisiting if it lands
upstream. (The `-ub` bump wasn't applied either, pending a decision on the `ko` profile.)

## 10. Bonsai ternary on the **CPU** endpoint — the one place it's catastrophically wrong

Bonsai-27B's 6.66 GB weights make it tempting for the CPU helper too. It's the opposite: on CPU the
cost per token is **bytes read**, and Bonsai is **dense** — every token touches all 27 B params
(~7 GB), where a low-active-param MoE touches ~3 B. Measured with one binary for all three
(the PrismML fork's `llama-bench`, `-ngl 0 -t 8`, r=2, so the comparison is apples-to-apples):

| CPU-only model | Size | pp256 (t/s) | tg32 (t/s) |
|---|---:|---:|---:|
| Qwen3-4B-Instruct Q4_K_M (current `cpu` default) | 2.32 GiB | 1635.6 ± 44.9 | 20.5 ± 0.1 |
| Qwen3-Coder-30B-A3B Q4_K_M (MoE, 3 B active) | 17.28 GiB | 341.5 ± 9.1 | **24.1 ± 0.8** |
| **Bonsai-27B ternary Q2_0** | 6.66 GiB | 414.9 ± 84.0 | **1.05 ± 0.01** |

**Bonsai decodes at 1.05 t/s — 23× slower than either alternative**, and slower than a *dense Q5_K_M
32B* on the same CPU (2.3 t/s, §1). Pure bandwidth would predict ~7 t/s, so the ternary `Q2_0` path
has **no optimized CPU kernel** — the fork ships `bin/cuda` only, and the win is GPU-kernel-bound.
**Verdict: never put Bonsai on the CPU endpoint.** Its small weights buy VRAM headroom, not CPU speed;
those are different currencies.

Side finding from the same run: **the MoE actually beats the small dense model on CPU decode**
(24.1 vs 20.5 t/s) despite being 7× larger on disk — active params, not file size, set decode speed.
Qwen3-Coder-30B-A3B costs 17 GB RAM and ~5× slower prefill, but is a far stronger model at *better*
decode. (`README.md` still lists 30B-A3B as the `cpu` default while `cpu/active.env` has drifted to
Qwen3-4B — worth reconciling deliberately rather than by accident.)

## 11. Two re-checks — where the *reason* for skipping was wrong even though the verdict held

Both were dismissed earlier on grounds that turned out to be stale or unverified. Re-checked; both
stay skipped, but for measured reasons now.

**SuperGemma4** (uncensored/abliterated Gemma-4). Original reason — "MLX-only, no GGUF → can't run on
NVIDIA" — is **no longer true**: GGUFs exist (`supergemma4-26b-uncensored-gguf-v2` Q4_K_M **16.80 GB**,
`SuperGemma4-31b-abliterated-GGUF` **18.69 GB**). It runs. It still loses:

- **Doesn't fit.** Both exceed the 15.83 GiB usable — the *weights alone* overflow, leaving no room for
  KV. Offloading experts to RAM works but trades away the speed that was the selling point.
- **The speed claim is from other hardware.** "46.2 tok/s / +8.7%" is Apple-Silicon MLX. Measured here,
  gemma-4-12b hits **74 tok/s** (§6) — already below Ornith's ~130 at a third the size. A 26B with
  offload lands lower still.
- **"+8.7% faster" is architecturally impossible.** Abliteration changes neither parameter count nor
  architecture, so a same-size finetune cannot be faster. That number is measurement error or a
  different quant. ("Quickbench 95.8" is likewise self-reported, not a standard benchmark.)
- The base is a general, non-coding Gemma-4 (already skipped in §6), and what SuperGemma4 actually
  changes — censorship — has near-zero value for a coding driver.

**Google LiteRT-LM.** Desktop support has grown (v0.11 Windows, v0.12 full CPU+GPU on Linux/macOS/
Windows), so "mobile-only" no longer holds. But **no CUDA anywhere** in the README, release notes, or
docs — the GPU path is the OpenCL/Vulkan delegate lineage, which on a 5080 means giving up the
tensor-core/`sm_120` kernels EXL3 and llama.cpp-CUDA rely on. Decisive point is weight class: the
`.litertlm` ecosystem tops out around **4 B** (functiongemma-270m, Gemma 3n E2B/E4B, gemma-4 E-series,
medgemma-4B). It cannot run a 35B-A3B at 128 K at all — there's no conversion path. It optimizes
memory, battery, NPU, and portability, not throughput. Still the right engine for a Jetson, not this box.

**Transferable rule:** three recent candidates (these two plus the §9 fork) all advertised gains
measured on *other hardware* or under *non-default flags*. Check, in order: (1) what hardware produced
the number, (2) does it fit 16 GB, (3) is the claimed improvement architecturally possible at all.

## Takeaway

For coding on a 16 GB RTX 5080: a **low-active-param MoE at EXL3 3-bit** is the sweet spot. A
coding-*specialized* model (Qwen3-Coder-30B) wins "hard + fast + first try"; a **hybrid-attention**
model (Ornith-35B) trades a hair of fast-mode accuracy for **4–5× the context (128 K+ on 16 GB)** and
equal speed — which is why it's the current default, with the specialist one command away.
