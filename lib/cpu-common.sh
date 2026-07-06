#!/usr/bin/env bash
# 공통 라이브러리: llama.cpp CPU 전용 추론 서버 (두 번째 에이전트용)
# 직접 실행하지 마세요. profile 스크립트 또는 디스패처에서 `source` 해서 사용.
#
# 배경 / 설계:
#   GPU(RTX 5080 16GB)는 EXL3 Qwen3-Coder-30B(13.8GB, 포트 5000)로 이미 포화.
#   반면 CPU(Ryzen 9800X3D 8C/16T, AVX-512 풀세트)+78GB RAM 은 거의 놀고 있음.
#   EXL3(GPU)는 CPU를 거의 안 쓰므로, CPU 전용 llama-server 를 포트 5001 에 별도로
#   띄우면 두 에이전트(GPU 코더 + CPU 보조)를 진짜 병렬로 돌릴 수 있다.
#   핵심: -ngl 0 으로 VRAM 을 0 사용 → GPU 모델과 충돌하지 않음.
#   MoE(활성 3~4B)는 CPU 메모리대역폭 병목에 강해 CPU에서도 쓸 만한 속도가 나온다.
#
# 제공 함수:
#   preflight_cpu                      # llama-server / RAM / 포트 / AVX512 검증
#   resolve_gguf REPO FILE [SUBDIR]    # 로컬 탐색(없으면 HF 다운로드) → CPU_RESOLVED_GGUF 설정
#   write_cpu_config PATH ALIAS CTX [EXTRA]   # active.env 작성
#   launch_cpu_server                  # llama-server 기동 (포그라운드, CPU 전용)

# ── 경로 (오버라이드 가능) ───────────────────────────────────────────
# repo root = parent of lib/ ; load machine-specific config.env if present.
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOCAL_LLM_ROOT="${LOCAL_LLM_ROOT:-$(dirname "$_LIB_DIR")}"
[ -f "$LOCAL_LLM_ROOT/config.env" ] && . "$LOCAL_LLM_ROOT/config.env"
CPU_ROOT="${CPU_ROOT:-$LOCAL_LLM_ROOT/cpu}"
MODELS_DIR="${CPU_MODELS_DIR:-$CPU_ROOT/models}"
ACTIVE_CONF="${ACTIVE_CONF:-$CPU_ROOT/active.env}"
# llama-server 바이너리 선택:
#   CUDA 빌드(build/)는 -ngl 0 이어도 cuBLAS 로드만으로 VRAM ~450MB 를 잡는다(환경변수로 못 막음).
#   → VRAM 진짜 0 을 위해 CPU 전용 빌드(build-cpu/)를 우선 사용. 없으면 CUDA 빌드로 폴백.
_LLAMA_DIR="${LLAMA_DIR:-$HOME/0_AI/llama.cpp}"
_LLAMA_CPU_BIN="$_LLAMA_DIR/build-cpu/bin/llama-server"
_LLAMA_CUDA_BIN="$_LLAMA_DIR/build/bin/llama-server"
if [ -n "${LLAMA_BIN:-}" ]; then :   # 사용자 지정 우선
elif [ -x "$_LLAMA_CPU_BIN" ]; then LLAMA_BIN="$_LLAMA_CPU_BIN"
else LLAMA_BIN="$_LLAMA_CUDA_BIN"; fi
# 이미 받아둔 GGUF 들이 있는 곳(다운로드 회피용 탐색 경로)
EXTRA_MODEL_DIRS="${EXTRA_MODEL_DIRS:-${MODEL_STORE:-$HOME/b_Models}}"

# ── 서버 / 실행 파라미터 (오버라이드 가능) ───────────────────────────
CPU_HOST="${CPU_HOST:-127.0.0.1}"
CPU_PORT="${CPU_PORT:-5001}"          # EXL3=5000, Ollama=11434 와 분리
# 9800X3D = 물리 8코어. SMT(16스레드)는 llama.cpp 에서 보통 역효과 → 물리코어 수 권장.
# GPU 모델과 동시 구동 + 데스크톱 반응성을 위해 1코어 양보하려면 CPU_THREADS=7.
CPU_THREADS="${CPU_THREADS:-8}"

# ── 검증 ────────────────────────────────────────────────────────────
preflight_cpu() {
  local ok=0

  if [ ! -x "$LLAMA_BIN" ]; then
    echo "[err] llama-server 없음: $LLAMA_BIN"
    echo "      LLAMA_BIN 환경변수로 경로 지정하거나 llama.cpp 를 빌드하세요."
    ok=1
  else
    echo "[ok] llama-server: $("$LLAMA_BIN" --version 2>&1 | head -1)"
    case "$LLAMA_BIN" in
      *build-cpu*) echo "[ok] CPU 전용 빌드 사용 → VRAM 사용 0 (GPU EXL3와 완전 격리)" ;;
      *) echo "[warn] CUDA 빌드 사용 중 → -ngl 0 이어도 VRAM ~450MB 점유. EXL3 b-quality(여유 0.25GB)와 동시구동 시 OOM 위험. CPU 전용 빌드 권장: cmake -S ~/0_AI/llama.cpp -B ~/0_AI/llama.cpp/build-cpu -DGGML_CUDA=OFF -DGGML_NATIVE=ON && cmake --build ~/0_AI/llama.cpp/build-cpu --target llama-server -j8" ;;
    esac
  fi

  # AVX-512 빌드/CPU 지원 확인 (있으면 CPU 추론 크게 빨라짐)
  if grep -qm1 avx512f /proc/cpuinfo 2>/dev/null; then
    echo "[ok] CPU AVX-512 지원 (VNNI/BF16 포함 시 추가 가속)"
  else
    echo "[warn] AVX-512 미검출 — CPU 추론 속도 저하 가능"
  fi

  # RAM 여유 (MoE Q4 ~18GB)
  local free_gb
  free_gb=$(free -g | awk '/^Mem:/{print $7}')
  if [ -n "$free_gb" ] && [ "$free_gb" -lt 20 ]; then
    echo "[warn] 가용 RAM ${free_gb}GB — MoE Q4(~18GB)에 빠듯할 수 있음(권장 20GB+)."
  else
    echo "[ok] 가용 RAM: ${free_gb}GB"
  fi

  # 포트 충돌 (특히 EXL3 5000 과 겹치지 않게)
  if ss -ltn 2>/dev/null | grep -q ":$CPU_PORT "; then
    echo "[warn] 포트 $CPU_PORT 사용 중. CPU_PORT 환경변수로 변경 가능."
  fi
  if [ "$CPU_PORT" = "5000" ]; then
    echo "[warn] 포트 5000 은 EXL3(TabbyAPI) 기본 포트 — 충돌 주의."
  fi

  return $ok
}

# ── HF 다운로드 바이너리 탐색 ────────────────────────────────────────
_find_hf_bin() {
  # EXL3 venv 에 이미 설치된 hf 재사용 → 없으면 PATH 의 hf/huggingface-cli
  local cands=(
    "$LOCAL_LLM_ROOT/exl3/tabbyAPI/.venv/bin/hf"
    "$(command -v hf 2>/dev/null)"
    "$(command -v huggingface-cli 2>/dev/null)"
  )
  for c in "${cands[@]}"; do
    [ -n "$c" ] && [ -x "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

# ── 모델 탐색 / 다운로드 ─────────────────────────────────────────────
# resolve_gguf REPO FILE [SUBDIR]
#   1) GGUF_PATH(명시) → 2) MODELS_DIR/SUBDIR → 3) EXTRA_MODEL_DIRS → 4) HF 다운로드
#   결과 경로를 전역 CPU_RESOLVED_GGUF 에 설정.
resolve_gguf() {
  # subdir 기본값을 file 로. 같은 local 문에서 $file 참조 시 set -u 하에서 터지므로 분리(잠복버그 수정).
  local repo="$1" file="$2" subdir="${3:-}"
  [ -n "$subdir" ] || subdir="$file"
  CPU_RESOLVED_GGUF=""

  # 1) 명시 경로
  if [ -n "${GGUF_PATH:-}" ]; then
    [ -f "$GGUF_PATH" ] || { echo "[err] GGUF_PATH 파일 없음: $GGUF_PATH"; return 1; }
    echo "[ok] 지정 GGUF 사용: $GGUF_PATH"
    CPU_RESOLVED_GGUF="$GGUF_PATH"; return 0
  fi

  # 2) CPU models 디렉터리
  local dest="$MODELS_DIR/$subdir"
  if [ -f "$dest" ]; then
    echo "[ok] 모델 이미 존재: $dest"
    CPU_RESOLVED_GGUF="$dest"; return 0
  fi

  # 3) 기존 모델 보관 디렉터리(b_Models 등) 재사용
  local d
  for d in $EXTRA_MODEL_DIRS; do
    if [ -f "$d/$file" ]; then
      echo "[ok] 기존 모델 재사용: $d/$file (다운로드 생략)"
      CPU_RESOLVED_GGUF="$d/$file"; return 0
    fi
  done

  # 4) HF 다운로드
  local hf_bin
  hf_bin="$(_find_hf_bin)" || {
    echo "[err] hf/huggingface-cli 없음 — 모델 다운로드 불가."
    echo "      pip install -U huggingface_hub  또는  GGUF_PATH=... 로 직접 지정."
    return 1
  }
  mkdir -p "$MODELS_DIR"
  echo "[download] $repo :: $file → $dest"
  "$hf_bin" download "$repo" "$file" --local-dir "$MODELS_DIR/.hf-$subdir"
  local got="$MODELS_DIR/.hf-$subdir/$file"
  [ -f "$got" ] || { echo "[err] 다운로드 실패: $got 없음"; return 1; }
  ln -sf "$got" "$dest"
  echo "[ok] 다운로드 완료: $dest"
  CPU_RESOLVED_GGUF="$dest"; return 0
}

# ── active.env 작성 ──────────────────────────────────────────────────
# write_cpu_config MODEL_PATH ALIAS CTX [EXTRA_FLAGS]
write_cpu_config() {
  local model_path="$1" alias="$2" ctx="$3" extra="${4:-}"
  mkdir -p "$CPU_ROOT"
  cat > "$ACTIVE_CONF" <<EOF
# 자동 생성 (lib/cpu-common.sh). 재셋업 시 덮어써짐.
# start-cpu-server.sh 가 이 파일을 읽어 llama-server 를 CPU 전용으로 기동.
CPU_MODEL_PATH="$model_path"
CPU_ALIAS="$alias"
CPU_CTX="$ctx"
CPU_THREADS="$CPU_THREADS"
CPU_HOST="$CPU_HOST"
CPU_PORT="$CPU_PORT"
CPU_EXTRA="$extra"
EOF
  echo "[setup] active.env 작성: $ACTIVE_CONF"
  echo "        model=$(basename "$model_path")  alias=$alias  ctx=$ctx  threads=$CPU_THREADS  port=$CPU_PORT"
}

# ── 서버 기동 ───────────────────────────────────────────────────────
launch_cpu_server() {
  [ -f "$ACTIVE_CONF" ] || { echo "[err] $ACTIVE_CONF 없음 — 먼저 ./setup-cpu.sh <profile>"; return 1; }
  # shellcheck disable=SC1090
  source "$ACTIVE_CONF"
  [ -f "$CPU_MODEL_PATH" ] || { echo "[err] 모델 파일 없음: $CPU_MODEL_PATH"; return 1; }

  echo "[run] llama-server (CPU 전용, -ngl 0): http://$CPU_HOST:$CPU_PORT/v1  (Ctrl-C 종료)"
  echo "      model=$(basename "$CPU_MODEL_PATH")  alias=$CPU_ALIAS  ctx=$CPU_CTX  threads=$CPU_THREADS"
  echo "      GPU(EXL3 5000)와 독립 — VRAM 사용 0"
  # ⚠️ CUDA 빌드 llama.cpp 는 -ngl 0 이어도 CUDA 드라이버 로드만으로 VRAM ~450MB 를 잡는다.
  #    16GB 카드에 EXL3(13.8GB)가 떠 있으면 그 여유분을 깎아 OOM 트리거가 될 수 있어,
  #    GPU 를 드라이버에서 완전히 숨겨 VRAM 사용을 진짜 0 으로 만든다.
  #    빈 문자열("")은 드라이버 버전에 따라 '전체 표시'로 해석되기도 함 → -1(없는 인덱스)이 확실.
  export CUDA_VISIBLE_DEVICES="-1"
  # -ngl 0       : GPU 레이어 0 = 순수 CPU
  # --jinja      : GGUF 내장 chat template/tool-use 활성화 (에이전트/툴콜용)
  # -cb          : continuous batching (동시 요청 대비, 서버 기본 on)
  exec "$LLAMA_BIN" \
    -m "$CPU_MODEL_PATH" \
    -a "$CPU_ALIAS" \
    -ngl 0 \
    -t "$CPU_THREADS" \
    -c "$CPU_CTX" \
    --host "$CPU_HOST" \
    --port "$CPU_PORT" \
    --jinja \
    $CPU_EXTRA
}
