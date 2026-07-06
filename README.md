# local-llm-toolkit

A single-command control layer for running **multiple local LLMs on one consumer GPU** —
built and tuned on an **RTX 5080 (16 GB, Blackwell) + Ryzen 9800X3D + 78 GB RAM**.

It wraps a pile of engines (ExLlamaV3/TabbyAPI, llama.cpp, ik_llama.cpp, Ollama) behind one
`llm` CLI and a lightweight native GUI panel, with ready-made serving **profiles**, **benchmark**
scripts, and **evaluation harnesses**. The design goal throughout: squeeze strong models into
16 GB VRAM and run a **GPU coder + a CPU helper in parallel**, then swap/compare models with one
command.

> **Not one-click.** This repo ships *orchestration + recipes*, not binaries. You build/install the
> engines yourself (see [`docs/setup.md`](docs/setup.md)); the toolkit then drives them.

---

## What's in the box

| Layer | Piece | What it does |
|---|---|---|
| **Control** | `llm` (bash CLI) | one front-door: `up/down/status/ask/chat/switch/bench/logs/webui` for every endpoint, with VRAM mutual-exclusion |
| | `llm-panel-rs/` (Rust + FLTK GUI) | ~10 MB borderless panel: live status LEDs, CPU/RAM/**VRAM gauges + history graph**, one-click controls |
| **Serving** | `start-*.sh` + `profiles/**` | per-engine start scripts + tuned model profiles (bpw, KV, ctx, CPU-offload) |
| **Setup** | `setup-*.sh` + `lib/*.sh` | install/build dispatchers (TabbyAPI venv, CPU-only llama.cpp, Ollama) |
| **Benchmark** | `bench-*.sh` | token/s measurement per engine |
| **Evaluation** | `eval-*.py`, `refactor-eval.py`, `agent-loop-test.py`, `compare-*.sh` | objective coding-quality + speed head-to-heads (generate code → run it → pass/fail) |
| **Agent** | `agent/` | Goose web agent wired to the local endpoints + SearXNG/Playwright MCP |

## The four endpoints

All OpenAI-compatible on `127.0.0.1`. GPU-heavy ones are mutually exclusive (they share the 16 GB);
`gpu`+`cpu` run in parallel.

| Alias | Port | Engine | Default model | Role |
|---|---|---|---|---|
| `gpu` | 5000 | ExLlamaV3 / TabbyAPI | Qwen3-Coder-30B-A3B (EXL3 3.0bpw) | fast coding (~115 tok/s), agent tool-calls |
| `cpu` | 5001 | llama.cpp (CPU-only) | Qwen3-Coder-30B-A3B (GGUF) | background helper, **VRAM 0** |
| `hyb` | 5002 | ik_llama.cpp | gpt-oss-120B (MXFP4) | big-brain, GPU+CPU MoE offload (~30 tok/s) |
| `ko` | 5003 | llama.cpp (GPU) | **Kanana-2-30B** (GGUF) | native Korean |

## Quickstart

```bash
git clone <this-repo> local-llm-toolkit && cd local-llm-toolkit
cp config.env.example config.env      # point at your model store + engine builds
# ... build the engines you need (see docs/setup.md) ...

./llm up gpu        # start the GPU coder
./llm status        # see what's running + CPU/RAM/VRAM
./llm chat --gpu    # talk to it
./llm switch b-quality   # hot-swap serving profile
./llm bench gpu     # measure tok/s
```

GUI: `cargo build --release --manifest-path llm-panel-rs/Cargo.toml` then run
`llm-panel-rs/target/release/llm-panel` (set `LLM_CLI` if the repo isn't at `~/0_AI/local-llm`).

## Docs

- **[docs/setup.md](docs/setup.md)** — prerequisites & how to build each engine (the real work).
- **[docs/how-to.md](docs/how-to.md)** — full usage: endpoints, profiles, CPU/hybrid/Korean, Ollama, troubleshooting.
- **[docs/findings.md](docs/findings.md)** — measured experiments behind the defaults: speculative
  decoding (helps dense, hurts MoE), NVFP4 on Blackwell, EXL3 low-bit model comparisons, and why
  Qwen3-Coder-30B stays the default coder.

## Models

Third-party models are downloaded by the setup scripts (not redistributed here). The one
**derived model** published alongside this repo:

- **Kanana-2-30B-A3B GGUF (Q4_K_M)** — a GGUF conversion of `kakaocorp/Kanana-2` (its MLA/MoE arch
  isn't supported by EXL3, so GGUF is the path to run it on this card). → `<HF_USER>/Kanana-2-30B-A3B-Instruct-GGUF` *(link filled on upload)*

## License

MIT (the toolkit's own scripts) — see [LICENSE](LICENSE). Orchestrated engines and models carry
their own licenses.
