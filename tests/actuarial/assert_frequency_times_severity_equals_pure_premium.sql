-- Frequency x severity = pure premium in rpt_frequency_severity, on every row with claims and
-- exposure:
--
--   (claims / exposure) x (loss / claims) = loss / exposure
--
-- The identity is exact before rounding, so the only allowed difference is the rounding of the
-- three stored columns. Each is rounded half a unit of its last decimal at most, which bounds
-- the error of the product:
--   pure_premium to 2 decimals                      +- 0.005
--   severity to 2 decimals, times frequency         +- 0.005 x frequency
--   frequency to 8 decimals, times severity         +- 0.000000005 x severity
-- A larger difference means the three columns were computed on different bases (for example a
-- claim count that does not match the one behind the incurred loss).
with frequency_severity as (
    select * from {{ ref('rpt_frequency_severity') }}
),

checked as (
    select
        accident_year,
        line_of_business,
        coverage_code,
        is_catastrophe_included,
        claim_frequency,
        average_incurred_severity,
        pure_premium,
        claim_frequency * average_incurred_severity as frequency_times_severity,
        0.005
            + 0.005 * claim_frequency
            + 0.000000005 * abs(average_incurred_severity) as tolerance
    from frequency_severity
    where claim_exposure_count > 0
        and earned_exposure_years > 0
)

select *
from checked
where abs(frequency_times_severity - pure_premium) > tolerance
    -- Both sides must exist where claims and exposure do.
    or claim_frequency is null
    or average_incurred_severity is null
    or pure_premium is null
