# Setup — prerequisites & building the engines

This toolkit **orchestrates** inference engines; you install/build them yourself. Below is what
each endpoint needs. Skip the ones you won't use. Paths default to a `~/0_AI/...` layout and are
overridable via `config.env` (copy from `config.env.example`).

## 0. Hardware / OS assumptions

Built and tuned on: **RTX 5080 16 GB (Blackwell, `sm_120`)**, Ryzen 9800X3D (8C/16T, AVX-512),
78 GB RAM, Ubuntu 24.04, NVIDIA driver 580+, CUDA 12.8. **Adjust for your card**: the CUDA arch
(`-DCMAKE_CUDA_ARCHITECTURES=120`), VRAM budgets in the profiles, and `-t`/thread counts are
5080-specific. Ports (5000–5003, 3000, 8888, 8931) are overridable in `config.env`.

## 1. `config.env`

```bash
cp config.env.example config.env
```
Set `MODEL_STORE` (your shared GGUF dir), `LLAMA_DIR`, `IK_DIR`. Every script sources this if present.

## 2. llama.cpp — two builds (`cpu` + `ko` + comparisons)

Clone to `$LLAMA_DIR` (default `~/0_AI/llama.cpp`) and build **both** variants:

```bash
# CUDA build (GPU serving: ko endpoint, comparisons)
cmake -S . -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DGGML_NATIVE=ON
cmake --build build --target llama-server llama-cli llama-quantize -j8

# CPU-only build (cpu endpoint) — so `-ngl 0` truly uses 0 VRAM (a CUDA build
# still grabs ~450 MB via cuBLAS, which collides with EXL3 on a 16 GB card)
cmake -S . -B build-cpu -DGGML_CUDA=OFF -DGGML_NATIVE=ON
cmake --build build-cpu --target llama-server llama-cli -j8
```

## 3. ik_llama.cpp — hybrid Mistral-Small-4 (`hyb`)

For running a 119B MoE (6B active) split across GPU+CPU. Clone to `$IK_DIR` (default `~/0_AI/ik_llama.cpp`):

```bash
cmake -B build -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES=120 -DGGML_NATIVE=ON
cmake --build build --target llama-server llama-bench llama-cli -j8
```

## 4. ExLlamaV3 / TabbyAPI — GPU coder (`gpu`)

`setup-exl3.sh` handles this: it clones TabbyAPI into `exl3/tabbyAPI/`, creates a `uv` venv, and
installs torch (cu128) + exllamav3 + flash-attn. Needs **`uv`** and an NVIDIA driver. Then:

```bash
./setup-exl3.sh a-safe        # download + configure Qwen3-Coder-30B EXL3 3.0bpw
./llm up gpu
```

## 5. Ollama (optional simple engine)

Install Ollama (systemd service). `setup-ollama.sh` + `apply-systemd-override.sh` add stability
env (flash-attn, KV q8, single-model). Optional — the EXL3/llama.cpp paths are faster.

## 6. Docker services — Open WebUI + SearXNG (optional)

- **Open WebUI** (`:3000`): a chat UI over all four endpoints. Run as a container; the `llm webui`
  subcommand + a systemd user unit manage it. See `docs/systemd/`.
- **SearXNG** (`:8888`): local metasearch for the web agent. Copy `agent/searxng.example.yml` to
  `agent/searxng/settings.yml` and **generate your own `secret_key`** (`openssl rand -hex 32`).

## 7. Web agent — Goose + MCP (optional)

`agent/goose-web.sh` drives [Goose](https://github.com/block/goose) against whichever endpoint is
up, with a Playwright browser MCP (`:8931`, `agent/start-browser-mcp.sh`) and SearXNG search MCP.
Needs Goose on `PATH`, Node/`npx`, and `google-chrome`.

## 8. GUI panel — Rust

```bash
cargo build --release --manifest-path llm-panel-rs/Cargo.toml
```
Needs Rust/cargo + FLTK system deps. The panel shells out to the `llm` CLI; set `LLM_CLI` if the
repo isn't at `~/0_AI/local-llm`.

## 9. Experimental — NVFP4 PoC (`nvfp4-poc/`)

A vLLM + NVFP4 (Blackwell FP4 tensor cores) proof-of-concept. Heavy, self-contained (`nvfp4-poc/`),
needs its own venv + a CUDA 13 toolchain. See `docs/findings.md` for the recipe and why it's a PoC.

---

### Prerequisite checklist
`git`, `uv`, `cmake`, a CUDA toolkit matching your driver, `nvidia-smi`, `python3` +
`huggingface_hub`/`psutil`, Rust/cargo, and (optional) Docker, Node, Goose, Ollama.
