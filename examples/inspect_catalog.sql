\set ON_ERROR_STOP on

SELECT id AS snapshot_id
FROM ai.catalog_snapshot
WHERE schemas @> ARRAY['public']
ORDER BY id DESC
LIMIT 1
\gset

SELECT id, captured_at, database_name, schemas, profile, model,
       jsonb_array_length(metadata->'relations') AS relations,
       jsonb_array_length(metadata->'routines') AS routines,
       jsonb_array_length(metadata->'types') AS custom_types
FROM ai.catalog_snapshot
WHERE id = :snapshot_id;

SELECT sample.key AS table_name,
       sample.value->'columns' AS columns,
       sample.value->>'rows' AS sampled_rows
FROM ai.catalog_snapshot AS snapshot
CROSS JOIN LATERAL jsonb_each(snapshot.sample_manifest) AS sample
WHERE snapshot.id = :snapshot_id
ORDER BY sample.key;

SELECT field.value->>'name' AS column_name,
       field.value->>'type' AS column_type,
       (field.value->>'not_null')::boolean AS not_null
FROM ai.catalog_snapshot AS snapshot
CROSS JOIN LATERAL jsonb_array_elements(snapshot.metadata->'relations') AS relation
CROSS JOIN LATERAL jsonb_array_elements(relation.value->'columns') WITH ORDINALITY
    AS field(value, position)
WHERE snapshot.id = :snapshot_id
  AND relation.value->>'schema' = 'public'
  AND relation.value->>'name' = 'payment'
ORDER BY field.position;

SELECT constraint_info.value->>'definition' AS payment_constraint
FROM ai.catalog_snapshot AS snapshot
CROSS JOIN LATERAL jsonb_array_elements(snapshot.metadata->'relations') AS relation
CROSS JOIN LATERAL jsonb_array_elements(relation.value->'constraints') AS constraint_info
WHERE snapshot.id = :snapshot_id
  AND relation.value->>'schema' = 'public'
  AND relation.value->>'name' = 'payment'
ORDER BY constraint_info.value->>'name';
