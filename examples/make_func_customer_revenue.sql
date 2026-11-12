\set ON_ERROR_STOP on
\x on
BEGIN;
CREATE SCHEMA IF NOT EXISTS reporting;

SELECT * FROM ai.make_func(
    'reporting.customer_revenue',
    'By customer ID and date-time range, return the total amount of the customer payments.
     Include the start, exclude the end, and return zero when there are no payments.'
);
COMMIT;
