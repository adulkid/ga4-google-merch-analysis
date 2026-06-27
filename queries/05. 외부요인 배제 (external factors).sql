-- ================================================================
-- 05. 외부요인 베재 (external factors)
-- 목적: 첫 퍼널 이탈이 외부 요인에서 기인하는지 검증

-- 방문 유형: 첫방문 | 재방문
-- 접속 기기: desktop | mobile | tablet
-- 유입 채널: organic | (none) | referral | <Other> | (data deleted) | cpc
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
-- 원본 이벤트 추출: 세션키,이벤트명, URL에 더해 기기, 채널 속성 포함
session_events AS (
  SELECT
    user_pseudo_id,
    (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id,
    event_name,
    event_timestamp, 
    (SELECT value.string_value FROM UNNEST(event_params) WHERE key = 'page_location') AS page_location, 
    device.category AS device_category, 
    traffic_source.medium AS medium
  FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
  WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
),
-- 세션 단위 집계: 도달/탐색 플래그 + 외부 변수(방문유형·기기·채널)
-- 기기·채널은 세션 내 동일하다고 보고 ANY_VALUE로 대표값 사용
session_summary AS (
  SELECT
    s.user_pseudo_id,
    s.session_id,
    MAX(
      CASE 
        WHEN REGEXP_CONTAINS(page_location, r'/Google\+Redesign/[^/?]+')
        AND NOT REGEXP_CONTAINS(
          page_location,r'/Google\+Redesign/(Apparel|Shop\+by\+Brand|Clearance|New|Lifestyle|Campus\+Collection|eco\+friendly|Stationery|Accessories|Office|Gift\+Cards|Electronics)(/(Mens|Hats|Womens|Kids|Socks|YouTube|Google|Android|Drinkware|Bags|Small\+Goods|Stickers|Notebooks|Writing|Audio))?/?(\?.*)?$'
          ) THEN 1 ELSE 0 
      END
    ) AS reached_view_item,
    MAX(
      CASE
        WHEN event_name IN ('view_item_list', 'view_search_results')
        OR (event_name IN ('page_view', 'scroll', 'click', 'user_engagement')
            AND page_location LIKE '%/Google+Redesign/%')
        THEN 1 ELSE 0
      END
    ) AS has_explore_event, 
    MAX(CASE WHEN event_name = 'first_visit' THEN 1 ELSE 0 END) AS is_first_visit_session, 
    ANY_VALUE(device_category) AS device_category, 
    ANY_VALUE(medium) AS medium
  FROM session_events s
  LEFT JOIN anomaly_sessions a
    ON s.user_pseudo_id = a.user_pseudo_id
    AND s.session_id = a.session_id
  WHERE a.session_id IS NULL -- 구매액 음수 세션 제거
  GROUP BY 1, 2
),
sessions AS (
  SELECT 
    user_pseudo_id, 
    session_id, 
    is_first_visit_session, 
    device_category, 
    medium, 
    CASE 
      WHEN reached_view_item = 1 THEN 'pass_to_view_item'
      WHEN has_explore_event = 1 THEN 'explore_fail'
      ELSE 'instantly_fail'
    END AS fail_type
  FROM session_summary
), 
-- 세 외부 변수를 세로로 통합
factor_long AS (
  SELECT fail_type, 'visit_type' AS variable, 
    CASE WHEN is_first_visit_session = 1 THEN '첫방문' ELSE '재방문' END AS category
  FROM sessions
  UNION ALL
  SELECT fail_type, 'device' AS variable, device_category AS category
  FROM sessions
  UNION ALL
  SELECT fail_type, 'channel' As variable, medium AS category
  FROM sessions
), 
-- 변수, 그룹, 값별 구성 비율 계산
ratio_rate AS (
  SELECT
    variable, 
    fail_type, 
    category, 
    COUNT(*) AS session_cnt, 
    ROUND(COUNT(*) / SUM(COUNT(*)) OVER (PARTITION BY variable, fail_type), 4) AS ratio
  FROM factor_long
  GROUP BY 1, 2, 3
  ORDER BY variable, fail_type, ratio DESC
)
-- 값별 비율 차의 절댓값을 변수 단위로 합산 (차이 절댓값 합)
SELECT
  variable, 
  ROUND(SUM(ABS(COALESCE(ratio_explore, 0) - COALESCE(ratio_pass, 0))) * 100, 2) AS abs_diff_sum_pp
FROM
(
  SELECT 
    variable, 
    category, 
    MAX(CASE WHEN fail_type = 'explore_fail' THEN ratio END) AS ratio_explore, 
    MAX(CASE WHEN fail_type = 'pass_to_view_item' THEN ratio END) AS ratio_pass
  FROM ratio_rate
  GROUP BY 1, 2 
)
GROUP BY variable