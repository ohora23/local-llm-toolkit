#!/usr/bin/env bash
# 공통 라이브러리: ExLlamaV3 + TabbyAPI 셋업 / 모델 다운로드 / 서버 기동
# 직접 실행하지 마세요. profile 스크립트 또는 디스패처에서 `source` 해서 사용.
#
# 배경:
#   Ollama(llama.cpp)는 30B-A3B를 16GB에 못 넣어 32/62 레이어만 GPU,
#   나머지는 CPU 오프로드 → 이게 속도 병목(47~61 tok/s).
#   ExLlamaV3(EXL3 sub-4bit)는 모델을 GPU에 100% 적재 → 오프로드 제거.
#
# 제공 함수:
#   preflight_exl3              # uv / CUDA / 디스크 / 포트 검증
#   ensure_tabby                # tabbyAPI clone + uv venv + torch(cu128)+exllamav3 설치
#   download_exl3_model R V D   # huggingface repo:revision → local dir
#   write_tabby_config ...      # config.yml 생성 (cache_mode / max_seq_len)
#   launch_tabby                # 서버 기동 (포그라운드)

# ── 경로 (오버라이드 가능) ───────────────────────────────────────────
# repo root = parent of lib/ ; load machine-specific config.env if present.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_REPO_ROOT="$(dirname "$_LIB_DIR")"
[ -f "$_REPO_ROOT/config.env" ] && . "$_REPO_ROOT/config.env"
EXL3_ROOT="${EXL3_ROOT:-$_REPO_ROOT/exl3}"
TABBY_DIR="${TABBY_DIR:-$EXL3_ROOT/tabbyAPI}"
MODELS_DIR="${MODELS_DIR:-$EXL3_ROOT/models}"
VENV_DIR="${VENV_DIR:-$TABBY_DIR/.venv}"
TABBY_REPO="${TABBY_REPO:-https://github.com/theroyallab/tabbyAPI}"

# 설치 extra: tabbyAPI가 torch+exllamav3+flash_attn 을 버전 매칭해 고정한 그룹.
#   cu12  = torch 2.9.0+cu128 + exllamav3(torch2.9) + flash_attn prebuilt  ← CUDA 12.8 환경(권장)
#   cu130 = torch 2.11.0+cu130 ...                                          ← CUDA 13 환경
# 직접 torch 를 깔면 버전 불일치로 flash-attn 소스빌드 실패 → 반드시 extra 사용.
TABBY_EXTRA="${TABBY_EXTRA:-cu12}"

# 서버
TABBY_HOST="${TABBY_HOST:-127.0.0.1}"
TABBY_PORT="${TABBY_PORT:-5000}"

# ── 검증 ────────────────────────────────────────────────────────────
preflight_exl3() {
  local ok=0
  if ! command -v uv >/dev/null; then
    echo "[err] uv 미설치. https://docs.astral.sh/uv/ 참고 (curl -LsSf https://astral.sh/uv/install.sh | sh)"
    ok=1
  fi
  if ! command -v git >/dev/null; then
    echo "[err] git 미설치."
    ok=1
  fi

  # CUDA 12.8 확인 (sm_120 휠 전제)
  if command -v nvcc >/dev/null; then
    local cuda_ver
    cuda_ver=$(nvcc --version | grep -oP 'release \K[0-9]+\.[0-9]+' || echo "?")
    echo "[ok] CUDA toolkit: $cuda_ver"
  else
    echo "[warn] nvcc 미발견. prebuilt 휠만 쓸 거면 무방하나 드라이버는 필요."
  fi
  nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv,noheader 2>/dev/null \
    || { echo "[err] nvidia-smi 실패 — GPU 드라이버 확인"; ok=1; }

  # 디스크 (모델 14GB + torch/cuda libs ~6GB)
  local free_gb
  free_gb=$(df -BG --output=avail "$(dirname "$EXL3_ROOT")" 2>/dev/null | tail -1 | tr -dc '0-9')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 30 ]; then
    echo "[warn] 디스크 여유 ${free_gb}GB — 모델+의존성에 빠듯할 수 있음(권장 30GB+)."
  else
    echo "[ok] 디스크 여유: ${free_gb}GB"
  fi

  # 포트 충돌
  if ss -ltn 2>/dev/null | grep -q ":$TABBY_PORT "; then
    echo "[warn] 포트 $TABBY_PORT 사용 중. TABBY_PORT 환경변수로 변경 가능."
  fi

  return $ok
}

# ── 설치 ────────────────────────────────────────────────────────────
ensure_tabby() {
  mkdir -p "$EXL3_ROOT" "$MODELS_DIR"

  if [ ! -d "$TABBY_DIR/.git" ]; then
    echo "[setup] tabbyAPI clone → $TABBY_DIR"
    git clone --depth 1 "$TABBY_REPO" "$TABBY_DIR"
  else
    echo "[ok] tabbyAPI 이미 존재: $TABBY_DIR"
  fi

  # 멱등성: venv 가 이미 torch+exllamav3 를 올바로 갖췄으면 재설치 스킵.
  if [ -x "$VENV_DIR/bin/python" ] && \
     "$VENV_DIR/bin/python" -c "import torch,exllamav3,flash_attn" >/dev/null 2>&1; then
    echo "[ok] venv 의존성 이미 설치됨 — 재설치 스킵"
  else
    # 버전 불일치 잔재 방지: venv 새로 생성
    [ -d "$VENV_DIR" ] && { echo "[setup] 불완전 venv 제거 → $VENV_DIR"; rm -rf "$VENV_DIR"; }
    echo "[setup] uv venv 생성 (python 3.12) → $VENV_DIR"
    uv venv --python 3.12 "$VENV_DIR"

    echo "[setup] tabbyAPI + [$TABBY_EXTRA] extra 설치 (torch+exllamav3+flash_attn 전부 prebuilt, 컴파일 없음)"
    # extra 가 torch 2.9.0+cu128 / exllamav3(torch2.9) / flash_attn prebuilt 를 버전 매칭해 끌어옴.
    uv pip install --python "$VENV_DIR/bin/python" -e "${TABBY_DIR}[${TABBY_EXTRA}]"

    echo "[setup] huggingface_hub (모델 다운로드용) 설치"
    uv pip install --python "$VENV_DIR/bin/python" -U "huggingface_hub"
  fi

  # 검증: torch sm_120 커널 + exllamav3 import
  "$VENV_DIR/bin/python" - <<'PY'
import torch
print(f"[verify] torch {torch.__version__}  cuda={torch.version.cuda}  avail={torch.cuda.is_available()}")
if torch.cuda.is_available():
    cap = torch.cuda.get_device_capability(0)
    print(f"[verify] GPU cap sm_{cap[0]}{cap[1]}  ({torch.cuda.get_device_name(0)})")
    assert cap >= (12, 0), "sm_120 미만 — torch 버전 불일치 가능"
try:
    import exllamav3
    print(f"[verify] exllamav3 import OK: {getattr(exllamav3,'__version__','?')}")
except Exception as e:
    print(f"[verify][warn] exllamav3 import 실패: {e}")
PY
}

# ── 모델 다운로드 ────────────────────────────────────────────────────
# download_exl3_model REPO REVISION LOCAL_SUBDIR
download_exl3_model() {
  local repo="$1" rev="$2" subdir="$3"
  local dest="$MODELS_DIR/$subdir"
  if [ -f "$dest/config.json" ]; then
    echo "[ok] 모델 이미 존재: $dest"
    return 0
  fi
  echo "[download] $repo @ $rev → $dest"
  # hf_hub 1.x: `huggingface-cli` 폐기됨 → `hf download` 사용.
  local hf_bin
  if [ -x "$VENV_DIR/bin/hf" ]; then hf_bin="$VENV_DIR/bin/hf"
  else hf_bin="$VENV_DIR/bin/huggingface-cli"; fi
  "$hf_bin" download "$repo" --revision "$rev" --local-dir "$dest"
  [ -f "$dest/config.json" ] || { echo "[err] 다운로드 실패: config.json 없음"; return 1; }
}

# ── config.yml 생성 ─────────────────────────────────────────────────
# write_tabby_config MODEL_SUBDIR MAX_SEQ_LEN CACHE_MODE
write_tabby_config() {
  local model_subdir="$1" max_seq_len="$2" cache_mode="$3" sampler_preset="${4:-}"
  local cfg="$TABBY_DIR/config.yml"

  cat > "$cfg" <<EOF
# 자동 생성 (lib/exl3-common.sh). 수정해도 되지만 재셋업 시 덮어써짐.
network:
  host: $TABBY_HOST
  port: $TABBY_PORT
  disable_auth: true        # 로컬 단일 사용자 — 토큰 인증 비활성
  disable_request_logging: false

model:
  model_dir: $MODELS_DIR
  model_name: $model_subdir
  max_seq_len: $max_seq_len
  cache_mode: $cache_mode    # FP16 | Q8 | Q6 | Q4  (낮을수록 VRAM↓)
  # cache_size: $max_seq_len # 생략 시 max_seq_len
  tool_format: qwen3_coder   # Qwen3-Coder 툴콜(<tool_call><function=…>)을 OpenAI tool_calls로 파싱 → Goose 등 에이전트 동작

sampling:
  override_preset: $sampler_preset

developer:
  unsafe_launch: false
EOF
  echo "[setup] config.yml 작성: $cfg"
  echo "        model=$model_subdir  ctx=$max_seq_len  cache=$cache_mode${sampler_preset:+  sampler=$sampler_preset}"
}

# ── 서버 기동 ───────────────────────────────────────────────────────
launch_tabby() {
  echo "[run] TabbyAPI 기동: http://$TABBY_HOST:$TABBY_PORT  (Ctrl-C 종료)"
  echo "      OpenAI 호환: http://$TABBY_HOST:$TABBY_PORT/v1"
  cd "$TABBY_DIR"
  exec "$VENV_DIR/bin/python" main.py
}
