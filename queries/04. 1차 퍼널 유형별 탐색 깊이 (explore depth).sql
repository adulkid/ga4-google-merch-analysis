-- ================================================================
-- 04. 1차 퍼널 유형별 탐색 깊이 (explore depth)
-- 목적: "탐색 깊이가 깊을수록 상품 상세에 더 잘 도달한다"는 가설 검증
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
-- 원본 이벤트에서 필요한 필드만 추출 (세션키, 이벤트명, 타임스탬프, URL)
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
-- 그룹별로 세션의 탐색 깊이 계산
-- 탐색 깊이 = 탐색 행동이 일어난 고유 page_location 개수 (COUNT DISTINCT)
session_depth AS (
  SELECT
    ss.fail_type,
    ss.user_pseudo_id,
    ss.session_id,
    COUNT(DISTINCT CASE
      WHEN se.event_name IN ('view_item_list', 'view_search_results')
        OR (se.event_name IN ('page_view','scroll','click','user_engagement')
            AND se.page_location LIKE '%/Google+Redesign/%')
      THEN se.page_location END) AS explore_depth
  FROM sessions ss
  JOIN session_events se
    ON ss.user_pseudo_id = se.user_pseudo_id
    AND ss.session_id = se.session_id
  GROUP BY 1, 2, 3
)
-- 깊이를 구간화(5 이상은 '5+'로 묶음)하여 그룹별 분포 산출
SELECT
  fail_type,
  CASE WHEN explore_depth >= 5 THEN '5+' ELSE CAST(explore_depth AS STRING) END AS depth_bin,
  COUNT(*) AS session_cnt,
  ROUND(COUNT(*) * 100.0 / SUM(COUNT(*)) OVER (PARTITION BY fail_type), 2) AS pct
FROM session_depth
GROUP BY fail_type, depth_bin
ORDER BY fail_type, depth_bin