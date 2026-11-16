\set ON_ERROR_STOP on
\timing on

INSERT INTO ai.model_profile (profile, endpoint, model, max_tokens, max_context_length, request_options)
VALUES (
    'default',
    'http://10.8.0.10:8002/v1/chat/completions',
    'qwen3.8-flash-next',
    10000,
    250000,
    '{"temperature": 0, "chat_template_kwargs": {"enable_thinking": false}}'
)
ON CONFLICT (profile) DO NOTHING;

SELECT ai.init_catalog(
    p_schema => 'public',
    p_samples => '{
        "public.category": ["category_id", "name"],
        "public.language": ["language_id", "name"],
        "public.film": ["film_id", "title", "release_year", "rental_duration", "rental_rate", "rating"],
        "public.film_category": ["film_id", "category_id"]
    }'::jsonb
) AS snapshot_id \gset

SELECT id, captured_at, database_name, schema_name, model,
       jsonb_array_length(metadata->'relations') AS relation_count,
       jsonb_array_length(metadata->'routines') AS routine_count,
       sample_manifest
FROM ai.catalog_snapshot
WHERE id = :snapshot_id;
