import numpy as np
from statsmodels.stats.power import NormalIndPower
from statsmodels.stats.proportion import proportion_effectsize

# ── 입력값 ──
baseline = 0.2277          # 현행 CTR
mde_relative = 0.10        # 상대 10% 개선
treatment = baseline * (1 + mde_relative)  # 25.05%
alpha = 0.05               # 유의수준 (양측검정)
power = 0.80               # 검정력
daily_sessions = 177557 / 92   # 일 평균 목록 진입 세션 ≈ 1,930

# ── 효과 크기 (Cohen's h) ──
# 두 비율 차이를 표준화한 값. 비율 비교의 효과 크기 척도.
effect_size = proportion_effectsize(treatment, baseline)

# ── 그룹당 표본 크기 산출 ──
analysis = NormalIndPower()
n_per_group = analysis.solve_power(
    effect_size=effect_size,
    alpha=alpha,
    power=power,
    ratio=1.0,                 # A:B = 50:50
    alternative='two-sided'    # 양측검정
)

n_per_group = int(np.ceil(n_per_group))
n_total = n_per_group * 2

# ── 실험 기간 환산 ──
# 전체 트래픽 중 절반씩 두 그룹에 배정되므로, 필요 일수 = 총 표본 / 일 트래픽
days_needed = n_total / daily_sessions
days_final = max(days_needed, 14)   # 최소 2주 하한 (요일 효과 흡수)

# ── 출력 ──
print(f"기준선 CTR       : {baseline:.2%}")
print(f"목표 CTR (상대10%): {treatment:.2%}")
print(f"효과크기(Cohen's h): {effect_size:.4f}")
print(f"그룹당 표본       : {n_per_group:,} 세션")
print(f"총 표본 (A+B)     : {n_total:,} 세션")
print(f"일 평균 트래픽     : {daily_sessions:,.0f} 세션")
print(f"필요 기간         : {days_needed:.1f}일 → 적용 {days_final:.0f}일")
