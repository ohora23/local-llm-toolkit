#!/usr/bin/env bash
# 공통 라이브러리: Ollama 모델 등록 + 환경 검증
# 직접 실행하지 마세요. profile 스크립트에서 `source` 해서 사용.
#
# 제공 함수:
#   preflight_ollama            # ollama 데몬 / systemd env 검증
#   register_ollama_model       # Modelfile 생성 후 `ollama create`

preflight_ollama() {
  if ! pgrep -x ollama >/dev/null; then
    echo "[err] ollama 데몬 미실행. 다음 중 하나로 시작하세요:"
    echo "  sudo systemctl start ollama"
    echo "  또는: ./start-ollama-server.sh"
    return 1
  fi

  local env_dump
  env_dump=$(systemctl show ollama -p Environment --value 2>/dev/null | tr ' ' '\n')

  if ! echo "$env_dump" | grep -q '^OLLAMA_FLASH_ATTENTION=1$'; then
    echo "[warn] OLLAMA_FLASH_ATTENTION 미적용. apply-systemd-override.sh 권장."
  fi
  if ! echo "$env_dump" | grep -q '^OLLAMA_KV_CACHE_TYPE=q8_0$'; then
    echo "[warn] OLLAMA_KV_CACHE_TYPE=q8_0 미적용. KV 캐시가 FP16이라 VRAM 더 씁니다."
  fi
  return 0
}

# register_ollama_model BASE_REPO NAME NUM_GPU NUM_CTX [EXTRA_PARAMS]
#   EXTRA_PARAMS: Modelfile 추가 PARAMETER 라인 (개행 포함 가능)
register_ollama_model() {
  local base_repo="$1"
  local name="$2"
  local num_gpu="$3"
  local num_ctx="$4"
  local extra_params="${5:-}"

  local modelfile
  modelfile=$(mktemp)
  # shellcheck disable=SC2064
  trap "rm -f '$modelfile'" RETURN

  cat > "$modelfile" <<EOF
FROM $base_repo

PARAMETER num_gpu $num_gpu
PARAMETER num_ctx $num_ctx
PARAMETER num_batch 512
PARAMETER num_thread 8

PARAMETER temperature 0.2
PARAMETER top_p 0.9
PARAMETER repeat_penalty 1.05

PARAMETER stop "<|im_end|>"
PARAMETER stop "<|endoftext|>"
$extra_params
EOF

  echo "[setup] Base:    $base_repo"
  echo "[setup] Name:    $name"
  echo "[setup] GPU:     $num_gpu layers"
  echo "[setup] Context: $num_ctx"

  ollama create "$name" -f "$modelfile" 2>&1 | tail -3
}
