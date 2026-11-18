SELECT pg_catalog.pg_extension_config_dump('ai.model_profile', '');
SELECT pg_catalog.pg_extension_config_dump('ai.doc_embedding_profile', '');
SELECT pg_catalog.pg_extension_config_dump('ai.catalog_snapshot', '');
SELECT pg_catalog.pg_extension_config_dump('ai.skill_binding', '');
SELECT pg_catalog.pg_extension_config_dump('ai.function_generation', '');
SELECT pg_catalog.pg_extension_config_dump('ai.postgres_doc_chunk', '');
SELECT pg_catalog.pg_extension_config_dump('ai.conversation', '');
SELECT pg_catalog.pg_extension_config_dump('ai.message', '');

SELECT pg_catalog.pg_extension_config_dump('ai.catalog_snapshot_id_seq', '');
SELECT pg_catalog.pg_extension_config_dump('ai.function_generation_id_seq', '');

-- The install script recreates these exact built-in versions on restore.
SELECT pg_catalog.pg_extension_config_dump('ai.skill', $filter$
    WHERE (name, version) NOT IN (
        ('use-snapshot', 1),
        ('review-function', 1),
        ('supabase-postgres-best-practices', 1),
        ('postgres-cube', 1)
    )
$filter$);
