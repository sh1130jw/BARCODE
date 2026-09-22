#!/usr/bin/env python3
"""
"상품바코드조회" 형태의 엑셀 파일을 앱이 오프라인으로 읽는
assets/product_barcodes.json 으로 변환하는 스크립트.

상품 마스터 데이터가 갱신될 때마다 이 스크립트를 다시 실행해서
assets/product_barcodes.json을 새로 만들고, 앱을 다시 빌드하면 됩니다.
(인터넷 연결 없이 기기에 데이터가 그대로 들어가는 방식이라, 데이터가
바뀔 때는 파일을 새로 만들어 앱을 재배포해야 합니다.)

사용법:
    pip install openpyxl
    python3 convert_barcode_xlsx_to_json.py 상품바코드조회.xlsx

원본 엑셀은 다음 컬럼 순서를 갖고 있다고 가정합니다(1행이 헤더):
    품번, 품명, 색상, 사이즈, 사이즈표기, 바코드, 사이즈구분명,
    사이즈범위, 사이즈위치, 성별구분명, 최초판매가, 택가, ...
컬럼 순서가 다르면 아래 COLUMN_INDEX 값을 실제 위치(1부터 시작)에 맞게 수정하세요.
"""

import json
import sys
from pathlib import Path

try:
    import openpyxl
except ImportError:
    sys.exit("openpyxl이 필요합니다. 먼저 `pip install openpyxl`을 실행하세요.")

# 1부터 시작하는 열 번호 (원본 "상품바코드조회.xlsx" 기준)
COLUMN_INDEX = {
    "itemNo": 1,      # 품번
    "name": 2,        # 품명
    "color": 3,       # 색상
    "size": 4,        # 사이즈
    "sizeLabel": 5,   # 사이즈표기
    "barcode": 6,     # 바코드
    "category": 7,    # 사이즈구분명
    "gender": 10,     # 성별구분명
    "price": 11,      # 최초판매가
    "tagPrice": 12,   # 택가
}


def convert(xlsx_path: str, out_path: str, sheet_name: str | None = None) -> int:
    wb = openpyxl.load_workbook(xlsx_path, data_only=True)
    ws = wb[sheet_name] if sheet_name else wb[wb.sheetnames[0]]

    records = []
    for r in range(2, ws.max_row + 1):
        def cell(col_key):
            return ws.cell(row=r, column=COLUMN_INDEX[col_key]).value

        item_no = cell("itemNo")
        barcode = cell("barcode")
        if not item_no or not barcode:
            continue  # 품번/바코드가 없는 빈 행은 건너뜀

        price = cell("price")
        tag_price = cell("tagPrice")

        records.append({
            "itemNo": str(item_no).strip(),
            "name": str(cell("name") or "").strip(),
            "color": str(cell("color") or "-").strip(),
            "size": str(cell("size") or "").strip(),
            "sizeLabel": str(cell("sizeLabel") or "").strip(),
            "barcode": str(barcode).strip(),
            "category": str(cell("category") or "").strip(),
            "gender": str(cell("gender") or "").strip(),
            "price": int(price) if isinstance(price, (int, float)) else None,
            "tagPrice": int(tag_price) if isinstance(tag_price, (int, float)) else None,
        })

    Path(out_path).write_text(
        json.dumps(records, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    return len(records)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        sys.exit("사용법: python3 convert_barcode_xlsx_to_json.py <엑셀파일.xlsx>")

    input_path = sys.argv[1]
    output_path = str(Path(__file__).resolve().parent.parent / "assets" / "product_barcodes.json")

    count = convert(input_path, output_path)
    print(f"완료: {count}건 -> {output_path}")
