-- ================================================================
-- 01. 퍼널 분석 (funnel)
-- 목적: 7단계 퍼널의 단계별 잔존율/이탈율 산출
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
-- 세션 단위로 각 퍼널 단계 도달 여부를 플래그(0/1)로 집계 후 합산
funnel_session_cnt AS (
  SELECT
    COUNT(DISTINCT CONCAT(user_pseudo_id, '-', CAST(session_id AS STRING))) AS session_cnt, 
    SUM(has_view_item) AS view_item_cnt,
    SUM(has_cart) AS cart_cnt,
    SUM(has_checkout) AS checkout_cnt,
    SUM(has_shipping) AS shipping_cnt,
    SUM(has_payment) AS payment_cnt,
    SUM(has_purchase) AS purchase_cnt
  FROM (
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
      MAX(CASE WHEN event_name = 'add_to_cart' THEN 1 ELSE 0 END) AS has_cart,
      MAX(CASE WHEN event_name = 'begin_checkout' THEN 1 ELSE 0 END) AS has_checkout,
      MAX(CASE WHEN event_name = 'add_shipping_info' THEN 1 ELSE 0 END) AS has_shipping,
      MAX(CASE WHEN event_name = 'add_payment_info' THEN 1 ELSE 0 END) AS has_payment,
      MAX(CASE WHEN event_name = 'purchase' THEN 1 ELSE 0 END) AS has_purchase
    FROM (
      SELECT
        user_pseudo_id,
        event_name,
        (SELECT value.int_value FROM UNNEST(event_params) WHERE key = 'ga_session_id') AS session_id, 
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
),
-- 가로 집계된 퍼널 단계별 수를 세로로 변환
funnel_stage AS (
  SELECT 1 AS step, 'session_start' AS stage, session_cnt AS cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 2, 'view_item', view_item_cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 3, 'add_to_cart', cart_cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 4, 'begin_checkout', checkout_cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 5, 'add_shipping_info', shipping_cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 6, 'add_payment_info', payment_cnt FROM funnel_session_cnt
  UNION ALL
  SELECT 7, 'purchase', purchase_cnt FROM funnel_session_cnt
)
-- 직전 단계 대비 잔존율/이탈율 계산 (LAG로 이전 step의 cnt 참조)
SELECT
  *,
  LAG(cnt) OVER (ORDER BY step) AS prev_cnt,
  ROUND(cnt / LAG(cnt) OVER (ORDER BY step) * 100, 2) AS retention_rate,
  ROUND((1 - cnt / LAG(cnt) OVER (ORDER BY step)) * 100, 2) AS drop_off_rate
FROM funnel_stage
ORDER BY step