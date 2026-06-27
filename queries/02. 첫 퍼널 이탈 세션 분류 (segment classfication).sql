-- ================================================================
-- 02. 첫 퍼널 이탈 세션 분류 (segment classfication)
-- 목적: view_item 미도달 세션을 탐색 행동 유무로 분류, 개선 타겟을 식별
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
-- 세션 단위로 두 플래그 집계: 상품 상세(view_item) 도달 여부, 탐색 행동 여부
session_base AS (
  SELECT
    o.user_pseudo_id,
    o.session_id,
    -- view_item 조건: 상품영역(Redesign) URL 하위 경로 존재 AND 카테고리 목록으로 끝나지 않음
    MAX(
      CASE 
        WHEN REGEXP_CONTAINS(page_location, r'/Google\+Redesign/[^/?]+')
        AND NOT REGEXP_CONTAINS(
          page_location,r'/Google\+Redesign/(Apparel|Shop\+by\+Brand|Clearance|New|Lifestyle|Campus\+Collection|eco\+friendly|Stationery|Accessories|Office|Gift\+Cards|Electronics)(/(Mens|Hats|Womens|Kids|Socks|YouTube|Google|Android|Drinkware|Bags|Small\+Goods|Stickers|Notebooks|Writing|Audio))?/?(\?.*)?$'
        ) THEN 1 ELSE 0 
      END
    ) AS has_view_item,
    -- 탐색 행동 조건: 탐색 이벤트(list, search) 포함 OR 능동 이벤트가 상품영역(Redesign) URL에서 발생
    MAX(
    CASE
      WHEN event_name IN (
        'view_item_list',
        'view_search_results'
      )
      OR (
        event_name IN ('page_view', 'scroll', 'click', 'user_engagement')
        AND page_location LIKE '%/Google+Redesign/%'
      )
      THEN 1 ELSE 0 END
  ) AS has_explore_event
  FROM (
    SELECT
      user_pseudo_id,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
      event_name, 
      (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
  ) o
  LEFT JOIN anomaly_sessions a
    ON o.user_pseudo_id = a.user_pseudo_id
    AND o.session_id = a.session_id
  WHERE a.session_id IS NULL -- 구매액 음수 세션 제거
  GROUP BY 1, 2
)
-- 플래그로 세션 유형 분류 (도달 우선, 그 다음 탐색 여부)
SELECT
  CASE
    WHEN has_view_item = 1 THEN '도달'
    WHEN has_explore_event = 1 THEN '탐색 후 이탈'
    ELSE '즉시 이탈'
  END AS session_type,
  COUNT(*) AS total_sessions,
  ROUND(COUNT(*) * 100 / SUM(COUNT(*)) OVER (), 1) AS percentage
FROM session_base
GROUP BY session_type
ORDER BY total_sessions DESC