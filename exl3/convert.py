# exllamav3 EXL3 변환 러너 (pip 패키지엔 리포 루트 convert.py가 빠져 있어 재현).
# convert_model.py 는 parser/prepare/main 만 정의하고 스스로 실행 안 함(엔트리포인트 없음).
from exllamav3.conversion.convert_model import parser, main, prepare

if __name__ == "__main__":
    _args = parser.parse_args()
    _in_args, _job_state, _ok, _err = prepare(_args)
    if not _ok:
        print(f" !! Error: {_err}")
        raise SystemExit(1)
    main(_in_args, _job_state)
