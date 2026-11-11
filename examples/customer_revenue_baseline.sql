\set ON_ERROR_STOP on

WITH cases(label, customer_id, date_from, date_to) AS (
    VALUES
        ('with_payments', 1::smallint, timestamp '2007-02-01', timestamp '2007-06-01'),
        ('without_payments', 1::smallint, timestamp '2008-01-01', timestamp '2008-02-01')
)
SELECT cases.label, cases.customer_id, cases.date_from, cases.date_to,
       count(payment.payment_id) AS payment_count,
       coalesce(sum(payment.amount), 0::numeric) AS expected_revenue
FROM cases
LEFT JOIN public.payment
    ON payment.customer_id = cases.customer_id
   AND payment.payment_date >= cases.date_from
   AND payment.payment_date < cases.date_to
GROUP BY cases.label, cases.customer_id, cases.date_from, cases.date_to
ORDER BY cases.date_from;
