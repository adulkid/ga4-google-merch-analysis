-- ================================================================
-- 06. 기준선 CTR (baseline CTR) - A/B 테스트 입력 값
-- 목적: 목록/카테고리 페이지를 조회한 세션 중 상품 상세에 도달한 비율 산출
-- ================================================================

-- 구매액 음수(ecommerce.purchase_revenue_in_usd < 0) 세션 추출, 이후 조인으로 제거
WITH anomaly_sessions AS (
  SELECT DISTINCT user_pseudo_id, session_id
  FROM (
    SELECT user_pseudo_id,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key='ga_session_id') AS session_id
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
      AND ecommerce.purchase_revenue_in_usd < 0
  )
),
session_summary AS (
  SELECT
    s.user_pseudo_id,
    s.session_id,
    -- 상품 상세 도달: Redesign 뒤 경로 존재 AND 카테고리 목록으로 끝나지 않음
    MAX(CASE WHEN REGEXP_CONTAINS(page_location, r'/Google\+Redesign/[^/?]+')
      AND NOT REGEXP_CONTAINS(page_location,
        r'/Google\+Redesign/(Apparel|Shop\+by\+Brand|Clearance|New|Lifestyle|Campus\+Collection|eco\+friendly|Stationery|Accessories|Office|Gift\+Cards|Electronics)(/(Mens|Hats|Womens|Kids|Socks|YouTube|Google|Android|Drinkware|Bags|Small\+Goods|Stickers|Notebooks|Writing|Audio))?/?(\?.*)?$')
      THEN 1 ELSE 0 END) AS reached_detail,
    -- 목록/카테고리 조회: 능동 이벤트 + 카테고리 목록 패턴으로 "끝나는" URL (상세 제외)
    MAX(CASE
      WHEN (event_name IN ('page_view','scroll','click','user_engagement')
            AND page_location LIKE '%/Google+Redesign/%')
      AND REGEXP_CONTAINS(page_location,
          r'/Google\+Redesign/(Apparel|Shop\+by\+Brand|Clearance|New|Lifestyle|Campus\+Collection|eco\+friendly|Stationery|Accessories|Office|Gift\+Cards|Electronics)(/(Mens|Hats|Womens|Kids|Socks|YouTube|Google|Android|Drinkware|Bags|Small\+Goods|Stickers|Notebooks|Writing|Audio))?/?(\?.*)?$')
      THEN 1 ELSE 0 END) AS viewed_list
  FROM (
    SELECT user_pseudo_id,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key='ga_session_id') AS session_id,
      event_name,
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key='page_location') AS page_location
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  ) s
  LEFT JOIN anomaly_sessions a
    ON s.user_pseudo_id = a.user_pseudo_id AND s.session_id = a.session_id
  WHERE a.session_id IS NULL -- 구매액 음수 세션 제거
  GROUP BY 1, 2
)
-- 목록 세션이 분모, 그중 상세 도달이 분자 → baseline CTR
SELECT
  COUNTIF(viewed_list = 1) AS list_sessions,
  COUNTIF(viewed_list = 1 AND reached_detail = 1) AS list_to_detail_sessions,
  ROUND(COUNTIF(viewed_list = 1 AND reached_detail = 1) / COUNTIF(viewed_list = 1), 4) AS baseline_ctr
FROM session_summary