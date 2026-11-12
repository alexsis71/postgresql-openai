\set ON_ERROR_STOP on
BEGIN;

INSERT INTO ai.skill (name, version, description, instructions, catalog_objects, sql_examples)
VALUES (
    'rental-revenue', 1, 'Calculate DVD rental revenue by customer, film, and calendar period.',
    $instructions$
Rental revenue is SUM(public.payment.amount). Attribute payments to public.payment.payment_date.
Use a half-open date-time interval: include the start and exclude the end. For an annual
filter use calendar-year bounds. Join payment.rental_id to rental.rental_id, rental.inventory_id
to inventory.inventory_id, and inventory.film_id to film.film_id.
For monthly film revenue, group by film ID, film title, and the month of payment_date.
Keep the month in GROUP BY even when the output columns are only title and amount.
A film can then appear once for each month in which it generated revenue.
$instructions$,
    ARRAY['public.payment', 'public.rental', 'public.inventory', 'public.film'],
    jsonb_build_array(
        jsonb_build_object('name', 'monthly-film-revenue', 'sql', $sql$
SELECT f.title, sum(p.amount) AS total_amount
FROM public.payment AS p
JOIN public.rental AS r ON r.rental_id = p.rental_id
JOIN public.inventory AS i ON i.inventory_id = r.inventory_id
JOIN public.film AS f ON f.film_id = i.film_id
WHERE p.payment_date >= timestamp '2007-01-01' AND p.payment_date < timestamp '2008-01-01'
GROUP BY f.film_id, f.title, date_trunc('month', p.payment_date)
ORDER BY total_amount DESC
$sql$),
        jsonb_build_object('name', 'customer-revenue', 'sql', $sql$
SELECT coalesce(sum(p.amount), 0)
FROM public.payment AS p
WHERE p.customer_id = 1::smallint
  AND p.payment_date >= timestamp '2007-02-01' AND p.payment_date < timestamp '2007-06-01'
$sql$)
    )
)
ON CONFLICT (name, version) DO NOTHING;

INSERT INTO ai.skill_binding (target_schema, target_function, skill_name, skill_version)
VALUES
    ('reporting', 'film_box_office', 'rental-revenue', 1),
    ('reporting', 'customer_revenue', 'rental-revenue', 1),
    ('public', 'customer_revenue', 'rental-revenue', 1)
ON CONFLICT (target_schema, target_function, skill_name) DO NOTHING;

COMMIT;
