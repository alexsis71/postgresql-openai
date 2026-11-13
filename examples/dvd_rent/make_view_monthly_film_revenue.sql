\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA IF NOT EXISTS reporting;

SELECT * FROM ai.make_view(
    'reporting.monthly_film_revenue',
    'Return one row per film and calendar month that has payments.
     Output film_id, title, payment_month as a date on the first day of the month,
     and total_amount as the sum of payments. Use payment_date to determine the month.
     Include all years. Use the payment to rental to inventory to film path.'
);

DO $check$
BEGIN
    IF EXISTS (
        WITH expected AS (
            SELECT f.film_id, f.title, date_trunc('month', p.payment_date)::date AS payment_month,
                   sum(p.amount) AS total_amount
            FROM public.payment p
            JOIN public.rental r USING (rental_id)
            JOIN public.inventory i USING (inventory_id)
            JOIN public.film f USING (film_id)
            GROUP BY f.film_id, f.title, date_trunc('month', p.payment_date)::date
        ), actual AS (
            SELECT film_id, title, payment_month, total_amount FROM reporting.monthly_film_revenue
        )
        (SELECT * FROM expected EXCEPT ALL SELECT * FROM actual)
        UNION ALL
        (SELECT * FROM actual EXCEPT ALL SELECT * FROM expected)
    ) THEN
        RAISE EXCEPTION 'Monthly film revenue differs from the reference query';
    END IF;
END;
$check$;
COMMIT;
