\set ON_ERROR_STOP on
\timing on

INSERT INTO ai.model_profile (profile, endpoint, model, request_options)
VALUES (
    'default',
    'http://10.8.0.10:8002/v1/chat/completions',
    'qwen3.8-flash-next',
    '{"temperature": 0, "chat_template_kwargs": {"enable_thinking": false}}'
)
ON CONFLICT (profile) DO NOTHING;

SELECT ai.init_catalog(
    p_samples => '{
        "public.category": ["category_id", "name"],
        "public.language": ["language_id", "name"],
        "public.film": ["film_id", "title", "release_year", "rental_duration", "rental_rate", "rating"],
        "public.film_category": ["film_id", "category_id"]
    }'::jsonb
) AS snapshot_id \gset

SELECT id, database_name, schemas, model,
       jsonb_array_length(metadata->'relations') AS relation_count,
       jsonb_array_length(metadata->'routines') AS routine_count,
       sample_manifest
FROM ai.catalog_snapshot
WHERE id = :snapshot_id;
