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

INSERT INTO ai.skill (name, version, description, instructions, catalog_objects, sql_examples)
VALUES (
    'customer-similarity-cube', 1, 'Compare DVD rental customer profiles using the cube extension.',
    $instructions$
Use public.cube(double precision[]) to construct each point, then call
public.cube_distance(public.cube, public.cube). Pass all coordinates in one array
and use the same coordinate order on both sides. The constructor is not variadic.
For this report the coordinates are customer.store_id, address.city_id, and the distinct
counts of rented film IDs, category IDs, and actor IDs. Follow rental → inventory → film,
and use film_category and film_actor for the respective counts. Start from customer,
keep customers without rentals, and use zero for their three rental counts.
Use the store and city IDs as given. Compare the target profile to every other customer,
exclude the target itself, and apply the result limit after ordering by distance.
$instructions$,
    ARRAY['public.customer', 'public.address', 'public.rental', 'public.inventory',
          'public.film', 'public.film_category', 'public.film_actor'],
    jsonb_build_array(jsonb_build_object('name', 'five-coordinate-distance', 'sql',
        'SELECT public.cube_distance(public.cube(ARRAY[1, 2, 3, 4, 5]::double precision[]),
                                     public.cube(ARRAY[1, 2, 3, 4, 6]::double precision[]))'))
)
ON CONFLICT (name, version) DO NOTHING;

INSERT INTO ai.skill (name, version, description, instructions, catalog_objects, sql_examples)
VALUES (
    'customer-similarity-binary-cube', 1, 'Euclidean customer similarity from binary cube profiles',
    $instructions$
Use the complete query in sql_examples as the template for this report. The baseline counts
every occupied coordinate; for blocks occupied on both sides replace both counts with the
rounded squared cube distance. This sums squared distances, including against the zero point
for unmatched blocks. Sorting by the squared distance is equivalent to sorting by its square
root. A customer with no rentals has zero occupied coordinates. Store means customer.store_id.
Present the query body alone without SQL comments.
$instructions$,
    ARRAY['public.customer', 'public.address', 'public.rental', 'public.inventory',
          'public.film', 'public.film_category', 'public.film_actor'],
    jsonb_build_array(jsonb_build_object('name', 'customer-similarity', 'sql', $sql$
WITH rented AS (
    SELECT DISTINCT r.customer_id, i.film_id
    FROM public.rental r JOIN public.inventory i USING (inventory_id)
), description_ids AS (
    SELECT DISTINCT description, dense_rank() OVER (ORDER BY description)::integer AS item_id
    FROM public.film WHERE description IS NOT NULL
), items AS (
    SELECT customer_id, 'film' AS kind, film_id::integer AS item_id FROM rented
    UNION ALL
    SELECT DISTINCT r.customer_id, 'category', f.category_id::integer
    FROM rented r JOIN public.film_category f USING (film_id)
    UNION ALL
    SELECT DISTINCT r.customer_id, 'actor', f.actor_id::integer
    FROM rented r JOIN public.film_actor f USING (film_id)
    UNION ALL
    SELECT DISTINCT r.customer_id, 'description', d.item_id
    FROM rented r JOIN public.film f USING (film_id)
    JOIN description_ids d ON d.description = f.description
), blocks AS (
    SELECT customer_id, kind, (item_id - 1) / 100 AS block_id,
           count(*) AS ones, array_agg((item_id - 1) % 100) AS slots
    FROM items GROUP BY customer_id, kind, (item_id - 1) / 100
), points AS (
    SELECT b.customer_id, b.kind, b.block_id, b.ones, public.cube(ARRAY(
        SELECT (s.slot = ANY(b.slots))::integer::double precision
        FROM generate_series(0, 99) AS s(slot) ORDER BY s.slot
    )) AS point FROM blocks b
), totals AS (
    SELECT customer_id, sum(ones) AS ones FROM blocks GROUP BY customer_id
), adjustments AS (
    SELECT b.customer_id,
           sum(round(power(public.cube_distance(a.point, b.point), 2))::bigint - a.ones - b.ones) AS correction
    FROM points a JOIN points b USING (kind, block_id)
    WHERE a.customer_id = $1 AND b.customer_id <> $1
    GROUP BY b.customer_id
), target AS (
    SELECT c.customer_id, c.store_id, a.city_id
    FROM public.customer c JOIN public.address a USING (address_id)
    WHERE c.customer_id = $1
)
SELECT c.customer_id, (c.first_name || ' ' || c.last_name)::text AS full_name
FROM target t CROSS JOIN public.customer c
JOIN public.address a ON a.address_id = c.address_id
LEFT JOIN totals ct ON ct.customer_id = c.customer_id
LEFT JOIN totals tt ON tt.customer_id = t.customer_id
LEFT JOIN adjustments j ON j.customer_id = c.customer_id
WHERE c.customer_id <> t.customer_id
ORDER BY coalesce(ct.ones, 0) + coalesce(tt.ones, 0) + coalesce(j.correction, 0)
         + (a.city_id <> t.city_id)::integer + (c.store_id <> t.store_id)::integer,
         c.customer_id
LIMIT 10
$sql$))
)
ON CONFLICT (name, version) DO NOTHING;

INSERT INTO ai.skill_binding (target_schema, target_function, skill_name, skill_version)
VALUES
    ('reporting', 'film_box_office', 'rental-revenue', 1),
    ('reporting', 'monthly_film_revenue', 'rental-revenue', 1),
    ('reporting', 'customer_like', 'customer-similarity-cube', 1),
    ('reporting', 'customer_like_v4', 'customer-similarity-binary-cube', 1),
    ('reporting', 'customer_like_v4', 'postgres-cube', 1),
    ('reporting', 'customer_revenue', 'rental-revenue', 1),
    ('public', 'customer_revenue', 'rental-revenue', 1)
ON CONFLICT (target_schema, target_function, skill_name) DO NOTHING;

COMMIT;
