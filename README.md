# GA4 퍼널 분석: 진입 이탈 원인 규명과 전환 개선

Google Merchandise Store의 GA4 공개 데이터셋(2020.11~2021.01, 약 430만 이벤트)을
분석해, 구매 퍼널의 첫 진입 단계 이탈(75.5%)의 원인을 규명하고 A/B 테스트 기반
개선안을 설계한 개인 프로젝트.

## 핵심 요약

- **문제**: 세션 시작 → 상품 상세 단계에서 75.5% 이탈 (퍼널 최대 손실 구간)
- **분석**: 이탈 세션을 행동별로 분류 → 잠재 수요 존재 확인 → 외부 요인
  (방문유형·기기·채널) 차례로 배제 → 원인을 '목록→상세 동선'으로 수렴
- **결론**: 데이터로는 '왜'를 규명할 수 없어, 목록→상세 CTR 개선을 위한
  A/B 테스트(소셜 프루프 도입)를 통계적으로 설계 (기준선 22.77%, 상대 10% 개선 목표)

## 전체 분석 보고서

[Notion 보고서 링크] https://app.notion.com/p/GA4-37791bab7ce9803484a0f3920173dd8a?source=copy_link

## 기술 스택

SQL (BigQuery), Python (pandas, matplotlib, seaborn, statsmodels)

## 레포 구조
```
ga4-funnel-analysis/
├── README.md
├── queries/
│   ├── 01. 퍼널 분석 (funnel).sql
│   ├── 02. 첫 퍼널 이탈 세션 분류 (segment classfication).sql
│   ├── 03. 그룹별 카테고리 수요 (category demand).sql
│   ├── 04. 1차 퍼널 유형별 탐색 깊이 (explore depth).sql
│   ├── 05. 외부요인 배제 (external factors).sql
│   ├── 06. 기준선 CTR (baseline CTR).sql
│   └── 07. 객단가 (AOV, Average Order Value).sql
├── analysis.ipynb
├── data/
│   └── *.csv
├── images/
│   └── *.png
└── AB_test_표본크기.py
```

## 분석 흐름

1. **퍼널 분석** — 7단계 중 첫 진입 단계가 최대 이탈(75.5%)임을 확인
2. **이탈 세션 분류** — 탐색 행동 유무로 3분류, '탐색 후 이탈'을 타겟 선정
3. **카테고리 수요** — 타겟도 도달 세션과 유사한 관심(잠재 수요) 보유
4. **탐색 깊이** — 탐색량은 병목이 아님 (가설 기각)
5. **외부 요인 배제** — 방문유형, 기기, 유입채널 모두 그룹 간 차이 미미
6. **원인 수렴 & A/B 설계** — 목록 → 상세 CTR 개선안을 통계적으로 설계
