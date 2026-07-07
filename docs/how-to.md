# How-To — using local-llm-toolkit

Assumes the engines are built (see [setup.md](setup.md)) and `config.env` is set. Everything is
driven by the `llm` CLI; the GUI panel is a thin wrapper over it.

## The `llm` CLI

```
llm up      [gpu|cpu|hyb|ko|both]     # start endpoint(s). gpu·hyb·ko are mutually exclusive
llm down    [gpu|cpu|hyb|ko|all]      # stop
llm restart [gpu|cpu|hyb|ko|both]
llm status                            # endpoints + CPU/RAM/VRAM
llm json-status                       # machine-readable (the panel polls this)
llm models                            # /v1/models of every up endpoint
llm ask "prompt" [--gpu|--cpu|--hyb|--ko]   # one-shot (auto-targets an up endpoint)
llm chat [--gpu|--cpu|--hyb|--ko]     # interactive REPL
llm switch <profile>                  # hot-swap the GPU serving profile
llm bench [gpu|cpu|hyb]               # tok/s
llm logs [gpu|cpu|hyb|ko]             # tail a server log
llm webui up|down|status|open        # Open WebUI (:3000)
```

VRAM rule: `gpu`, `hyb`, `ko` each want most of the 16 GB → only one at a time. `gpu`+`cpu` run
together (CPU uses 0 VRAM).

## GUI panel

```bash
cargo build --release --manifest-path llm-panel-rs/Cargo.toml
LLM_CLI=$PWD/llm ./llm-panel-rs/target/release/llm-panel   # LLM_CLI optional if repo is at ~/0_AI/local-llm
```
Borderless, draggable. Per-endpoint Start/Stop/Bench/Log, live status LEDs, CPU/RAM/**VRAM gauges +
a live VRAM history graph** at the bottom, an "Open WebUI" button, and a collapsible output console.

## `gpu` — EXL3 / TabbyAPI (fast coder)

```bash
./setup-exl3.sh --list          # profiles
./setup-exl3.sh a-safe          # download + configure, then:
./llm up gpu
./llm bench gpu
```
Profiles (`profiles/qwen3-coder-30b-exl3/`):

| Profile | bpw | ctx | KV | Use |
|---|---|---|---|---|
| `a-safe` | 3.0 | 16K | Q6 | everyday, dual-monitor (default) |
| `b-quality` | 3.5 | 16K | Q6 | max quality, tight VRAM |
| `c-cline` | 3.0 | 32K | Q4 | long-context agent (Cline) |
| `d-qwen36-35b` | 2.08 | 16K | Q6 | newer MoE alternative (Qwen3.6-35B, thinking-off baked in — see findings.md) |

Hook into VS Code (Continue/Cline): point the OpenAI base URL at `http://127.0.0.1:5000/v1`.

## `cpu` — llama.cpp CPU-only (parallel helper, VRAM 0)

Runs a second LLM entirely on CPU/RAM so it never touches the GPU (uses the `build-cpu/` binary +
`-ngl 0`). Profiles (`profiles/cpu-agent/`): `a-moe` (Qwen3-Coder-30B Q4), `a-moe-q8` (Q8),
`b-light` (Qwen3-4B), `planner-32b` (Qwen3-32B dense **+ speculative draft**, see findings.md).

```bash
./setup-cpu.sh a-moe
./llm up cpu        # now gpu + cpu run in parallel
```

## `hyb` — ik_llama.cpp (Mistral-Small-4-119B, GPU+CPU MoE offload)

Runs a 119B MoE (6B active) that doesn't fit VRAM by splitting experts to RAM. Tune `N_CPU_MOE`
(lower = more on GPU = faster, until OOM; 31 is the safe sweet spot on 16 GB — ~25 tok/s at Q4).
`llm up hyb` auto-downloads the model on first use.

```bash
./llm up hyb                 # downloads Mistral-Small-4 Q4 (~74 GB) if missing, then serves
N_CPU_MOE=31 ./llm up hyb    # override the GPU/CPU split
./llm bench hyb              # speed + 4-axis quality (bench-hybrid.sh)
```

Reasoning is **off by default** (fast). Enable per request with
`chat_template_kwargs: {"reasoning_effort": "high"}` — the model then emits `[THINK]…[/THINK]` and
solves harder logic reliably (the top-level OpenAI `reasoning_effort` field is *not* forwarded to the
template, so it must go through `chat_template_kwargs`).

## `ko` — Kanana-2-30B (native Korean)

```bash
./llm up ko
./llm chat --ko
```
The GGUF is a conversion of `kakaocorp/Kanana-2` (published separately on Hugging Face — its arch
isn't EXL3-compatible).

## Ollama (optional)

```bash
./setup-ollama.sh 30b-moe-q4
sudo ./apply-systemd-override.sh     # flash-attn + KV q8 + single-model stability
```

## Evaluation & comparison

Objective, run-verified coding tests (used to pick defaults — see findings.md):

```bash
# serve a model on :5000, then:
python3 eval-coding-quality.py http://127.0.0.1:5000 <model-id>   # 6 easy problems
NOTHINK=1 python3 eval-coding-hard.py http://127.0.0.1:5000 <id>  # harder problems
python3 refactor-eval.py http://127.0.0.1:5000                    # multi-file refactor
python3 agent-loop-test.py http://127.0.0.1:5000                  # agentic tool-loop
./compare-exl3-candidates.sh    # serve-swap several EXL3 models → speed + quality
./eval-quality-run.sh           # head-to-head pass rates
```

## Web agent (optional)

```bash
./agent/start-browser-mcp.sh    # Playwright browser MCP on :8931
# (SearXNG on :8888 via docker; copy agent/searxng.example.yml → settings.yml, set secret_key)
./agent/goose-web.sh            # Goose against whichever endpoint is up
```

## Troubleshooting

| Symptom | Fix |
|---|---|
| CPU server still uses ~450 MB VRAM | use the `build-cpu/` binary (a CUDA build grabs cuBLAS even at `-ngl 0`) |
| `gpu`+`hyb`/`ko` OOM together | they're mutually exclusive by design — run one |
| Panel/CLI shows the wrong model name | the loaded model is `/v1/model` (singular); `/v1/models` lists the whole model dir |
| NVML / driver mismatch after update | reboot (kernel module vs userspace lib mismatch) |
| Qwen3.6 endpoint is slow/verbose | it's a thinking model — pass `chat_template_kwargs:{enable_thinking:false}` (baked into `d-qwen36-35b`) |

## Folder structure

```
llm                     unified CLI          profiles/            serving profiles
lib/                    shared bash/py libs  llm-panel-rs/        Rust GUI
setup-*.sh start-*.sh   install / serve      bench-*.sh           benchmarks
eval-*.py compare-*.sh  evaluation harnesses agent/               Goose web agent
config.env.example      machine config       nvfp4-poc/           experimental vLLM/NVFP4
docs/                   these docs
```
