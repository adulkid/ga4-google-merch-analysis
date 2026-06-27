-- ================================================================
-- 07. 객단가 (AOV, Average Order Value) — 기대효과 계산 입력값
-- 목적: 구매 세션당 평균 매출 산출
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
-- 구매 세션 단위로 매출 합산 (유효 매출 > 0인 purchase 이벤트만)
purchase_sessions AS (
  SELECT
    s.user_pseudo_id,
    s.session_id,
    SUM(s.purchase_revenue) AS session_revenue
  FROM (
    SELECT
      user_pseudo_id,
      (SELECT value.int_value FROM UNNEST(event_params) WHERE key='ga_session_id') AS session_id,
      ecommerce.purchase_revenue_in_usd AS purchase_revenue,
    FROM `bigquery-public-data.ga4_obfuscated_sample_ecommerce.events_*`
    WHERE _TABLE_SUFFIX BETWEEN '20201101' AND '20210131'
      AND event_name = 'purchase'
      AND ecommerce.purchase_revenue_in_usd > 0   -- 구매액 음수, 0 제외
  ) s
  LEFT JOIN anomaly_sessions a -- 구매액 음수 세션 제거
    ON s.user_pseudo_id = a.user_pseudo_id AND s.session_id = a.session_id
  WHERE a.session_id IS NULL
  GROUP BY 1, 2
)
-- 구매 세션 수, 총 매출, AOV(= 총매출 / 구매 세션 수)
SELECT
  COUNT(*) AS purchase_session_cnt,
  ROUND(SUM(session_revenue), 2) AS total_revenue,
  ROUND(SUM(session_revenue) / COUNT(*), 2) AS aov
FROM purchase_sessions