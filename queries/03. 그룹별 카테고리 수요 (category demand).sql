-- ================================================================
-- 03. 그룹별 카테고리 수요 (category demand)
-- 목적: 탐색 후 이탈 vs 도달 그룹의 카테고리 관심 분포를 비교, 이탈 그룹 잠재 수요 확인
-- ================================================================

-- 구매액 음수(ecommerce.purchase_revenue_in_usd < 0) 세션 추출, 이후 조인으로 제거
WITH anomaly_sessions AS (
  SELECT DISTINCT user_pseudo_id, session_id
  FROM (
    SELECT
      user_pseudo_id,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
      AND ecommerce.purchase_revenue_in_usd < 0
  )
),
-- 원본 이벤트에서 필요한 필드만 추출 (세션키, 이벤트명, URL)
session_events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_name,
    event_timestamp,
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
-- 세션 단위로 두 플래그 집계: 상품 상세(view_item) 도달 여부, 탐색 행동 여부
session_summary AS (
  SELECT
    s.user_pseudo_id,
    s.session_id,
    -- view_item 조건: 상품영역(Redesign) URL 하위 경로 존재 AND 카테고리 목록으로 끝나지 않음
    MAX(
      CASE 
        WHEN REGEXP_CONTAINS(page_location, r'/Google\+Redesign/[^/?]+')
        AND NOT REGEXP_CONTAINS(
          page_location,r'/Google\+Redesign/(Apparel|Shop\+by\+Brand|Clearance|New|Lifestyle|Campus\+Collection|eco\+friendly|Stationery|Accessories|Office|Gift\+Cards|Electronics)(/(Mens|Hats|Womens|Kids|Socks|YouTube|Google|Android|Drinkware|Bags|Small\+Goods|Stickers|Notebooks|Writing|Audio))?/?(\?.*)?$'
          ) THEN 1 ELSE 0 
      END
    ) AS reached_view_item,
    -- 탐색 행동 조건: 탐색 이벤트(list, search) 포함 OR 능동 이벤트가 상품영역(Redesign) URL에서 발생
    MAX(
      CASE
        WHEN event_name IN ('view_item_list', 'view_search_results')
        OR (event_name IN ('page_view', 'scroll', 'click', 'user_engagement')
            AND page_location LIKE '%/Google+Redesign/%')
        THEN 1 ELSE 0
      END
    ) AS has_explore_event
  FROM session_events s
  LEFT JOIN anomaly_sessions a
    ON s.user_pseudo_id = a.user_pseudo_id
    AND s.session_id = a.session_id
  WHERE a.session_id IS NULL -- 구매액 음수 세션 제거
  GROUP BY 1, 2
),
-- 플래그 기준, 세션을 3개 그룹으로 라벨링
sessions AS (
  SELECT user_pseudo_id, session_id, 'explore_fail' AS fail_type
  FROM session_summary
  WHERE reached_view_item = 0 AND has_explore_event = 1
  UNION ALL
  SELECT user_pseudo_id, session_id, 'instantly_fail' AS fail_type
  FROM session_summary
  WHERE reached_view_item = 0 AND has_explore_event = 0
  UNION ALL
  SELECT user_pseudo_id, session_id, 'pass_to_view_item' AS fail_type
  FROM session_summary
  WHERE reached_view_item = 1
),
-- 라벨링된 세션에 원본 이벤트 다시 붙임
total_event AS (
  SELECT
    e.user_pseudo_id,
    e.session_id,
    e.event_name,
    f.fail_type,
    e.page_location
  FROM session_events e
  INNER JOIN sessions f
    ON e.user_pseudo_id = f.user_pseudo_id
    AND e.session_id = f.session_id
),
-- URL의 카테고리 경로를 12개 대분류로 매핑 (세션×카테고리 단위로 중복 제거)
-- LOWER + (rmg\+)? : 대소문자/URL 변종(rmg 삽입) 흡수
session_category AS (
  SELECT DISTINCT
    fail_type,
    user_pseudo_id,
    session_id,
    CASE
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/apparel') THEN 'Apparel'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/(lifestyle|drinkware|bags)') THEN 'Lifestyle'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/shop\+by\+brand') THEN 'Shop_by_Brand'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/clearance') THEN 'Clearance'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/new') THEN 'New'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/campus\+collection') THEN 'Campus_Collection'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/eco\+friendly') THEN 'eco_friendly'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/stationery') THEN 'Stationery'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/accessories') THEN 'Accessories'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/office') THEN 'Office'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/gift\+cards') THEN 'Gift_Cards'
      WHEN REGEXP_CONTAINS(LOWER(page_location), r'/google\+(rmg\+)?redesign/electronics') THEN 'Electronics'
      ELSE NULL
    END AS category
  FROM total_event
),
-- 그룹별 카테고리 비율 계산 (분모 = 그룹 내 카테고리 식별 세션 수)
category_ratio AS (
  SELECT
    fail_type,
    category,
    COUNT(*) AS session_cnt,
    ROUND(
      COUNT(*) / SUM(CASE WHEN category IS NOT NULL THEN COUNT(*) END) OVER (PARTITION BY fail_type)
    , 4) AS ratio
  FROM session_category
  WHERE category IS NOT NULL
  GROUP BY 1, 2
)
SELECT fail_type, category, session_cnt, ratio
FROM category_ratio
ORDER BY fail_type, ratio DESC