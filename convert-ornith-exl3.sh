#!/usr/bin/env bash
# Ornith-1.0-35B (Qwen3.5-35B-A3B MoE, agentic-coding) → EXL3 3.0bpw 로컬 변환.
# 데일리 드라이버(Qwen3-Coder-30B-EXL3-3.0bpw, ~12G)와 같은 비트폭으로 맞춰 16GB fit + A/B 벤치.
#
# ⚠️ GPU 필요: 실행 전 nvidia-smi 정상( 드라이버/라이브러리 불일치 없어야 함 = 재부팅 완료 ).
# 사용:  ./convert-ornith-exl3.sh            # 변환 (중단 시 자동 -resume)
#        BITS=3.0 ./convert-ornith-exl3.sh   # 비트폭 override
#        CLEAN_SRC=1 ./convert-ornith-exl3.sh # 완료 후 70G 원본 삭제(공간 회수)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
PY="$ROOT/exl3/tabbyAPI/.venv/bin/python"
SRC="${SRC:-$ROOT/exl3/_convert_src/Ornith-1.0-35B}"
WORK="${WORK:-$ROOT/exl3/_convert_work/Ornith-1.0-35B}"
BITS="${BITS:-3.0}"
HEAD_BITS="${HEAD_BITS:-6}"
OUT="${OUT:-$ROOT/exl3/models/Ornith-1.0-35B-EXL3-${BITS}bpw}"
LOG="$ROOT/logs/ornith-convert.log"

# --- preflight ---
command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 || {
  echo "[err] GPU 사용 불가(nvidia-smi 실패). 드라이버/라이브러리 불일치면 재부팅 필요."; exit 1; }
[ -f "$SRC/config.json" ] && [ -f "$SRC/model.safetensors.index.json" ] || {
  echo "[err] 원본 미완성: $SRC (다운로드 완료 확인: tail logs/ornith-src-dl.log)"; exit 1; }
# 원본 샤드 개수 == index 선언 개수 확인(부분 다운로드 방지)
need=$(grep -o '"model-[0-9]*-of-[0-9]*\.safetensors"' "$SRC/model.safetensors.index.json" | sort -u | wc -l)
have=$(ls "$SRC"/model-*-of-*.safetensors 2>/dev/null | wc -l)
[ "$need" -eq "$have" ] || { echo "[err] 샤드 부족: $have/$need. 다운로드 미완."; exit 1; }
# 디스크 가드: 산출물(~13G)+스크래치 여유 확인 (원본은 이미 존재)
free_g=$(df -BG --output=avail "$ROOT" | tail -1 | tr -dc '0-9')
[ "${free_g:-0}" -ge 16 ] || { echo "[err] 디스크 여유 ${free_g}G < 16G. 미사용 모델 정리 필요."; exit 1; }
echo "[ok] 원본 $have/$need 샤드 확인, 여유 ${free_g}G. bits=$BITS head=$HEAD_BITS"

# config 패치(멱등): ①비전 model_type ②MTP 비활성.
# ① Ornith는 vision_config.model_type=qwen3_5_moe_vision인데 exllamav3 0.0.43 허용목록에 없어 assert 실패
#    → 코딩용이라 비전 불필요, 허용값 qwen3_5_moe로 통과(문자열은 downstream 미사용).
# ② text_config.mtp_num_hidden_layers=1이면 exllamav3가 MTP 텐서를 양자화하려는데 원본에 MTP 가중치 없음
#    → mtp.pre_fc_norm_hidden.weight NotFound로 마지막에 실패. MTP=speculative라 불필요 → 0으로 끔.
[ -f "$SRC/config.json.orig-vision" ] || cp "$SRC/config.json" "$SRC/config.json.orig-vision"
"$PY" - "$SRC/config.json" <<'PYEOF'
import json,sys
p=sys.argv[1]; c=json.load(open(p)); ch=[]
if c.get("vision_config",{}).get("model_type")=="qwen3_5_moe_vision":
    c["vision_config"]["model_type"]="qwen3_5_moe"; ch.append("vision_config.model_type->qwen3_5_moe")
if c.get("text_config",{}).get("mtp_num_hidden_layers",0)!=0:
    c["text_config"]["mtp_num_hidden_layers"]=0; ch.append("text_config.mtp_num_hidden_layers->0")
if ch: json.dump(c,open(p,"w"),indent=2); print("[patch]", ", ".join(ch))
else: print("[patch] 변경 없음(이미 적용)")
PYEOF

mkdir -p "$WORK" "$(dirname "$OUT")" "$ROOT/logs"
RESUME=""
[ -f "$WORK/args.json" ] && [ -f "$WORK/ckpt/job.json" ] && { RESUME="-resume"; echo "[info] 기존 작업 발견 → -resume"; }

echo "[run] EXL3 변환 시작 $(date '+%F %T')  (로그: $LOG)"
# -hq: MoE 레이어 비트↑(품질), -pm: MoE 소형 텐서 병렬모드(속도), -d 0: GPU0
"$PY" "$ROOT/exl3/convert.py" \
  -i "$SRC" -w "$WORK" -o "$OUT" \
  -b "$BITS" -hb "$HEAD_BITS" -hq -pm -d 0 $RESUME 2>&1 | tee -a "$LOG"

[ -f "$OUT/config.json" ] || { echo "[err] 변환 산출물에 config.json 없음 — 실패."; exit 1; }
echo "[done] 변환 완료 → $OUT ($(du -sh "$OUT" | cut -f1))"

if [ "${CLEAN_SRC:-0}" = "1" ]; then
  echo "[clean] 원본 삭제(공간 회수): $SRC"; rm -rf "$SRC" "$WORK"
fi
echo ""
echo "다음: 프로파일로 서빙 →  ./setup-exl3.sh e-ornith  &&  ./start-tabby-server.sh"
echo "      벤치            →  ./bench-exl3.sh"
