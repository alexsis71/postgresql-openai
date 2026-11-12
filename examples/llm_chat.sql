\set ON_ERROR_STOP on
\x on

-- Одно предложение модели: системный промпт задаёт формат, пользовательский — вопрос.
SELECT * FROM llm(
    'Отвечай на русском одним коротким предложением без предисловий.',
    'Что делает команда VACUUM в PostgreSQL?'
);

-- История разговора передаётся массивом сообщений user и assistant между системным
-- промптом и новым вопросом. Так в одном запросе собирается многоходовый чат.
SELECT * FROM llm(
    'Отвечай на русском одним коротким предложением без предисловий.',
    'А чем отличается от VACUUM FULL?',
    p_history => '[
        {"role": "user", "content": "Что делает команда VACUUM в PostgreSQL?"},
        {"role": "assistant", "content": "VACUUM помечает удалённые кортежи как свободное место и возвращает его каталогу без блокировок таблиц."}
    ]'::jsonb
);

-- Модель можно спросить про собственную базу: каталог читается обычным SQL и
-- подставляется в пользовательский промпт.
SELECT * FROM llm(
    'Ты отвечаешь на русском. Опирайся только на переданный каталог.',
    'Сколько столбцов у таблицы payment и какие из них обязательны? Ответь списком.'
    || E'\n\n' || (
        SELECT jsonb_pretty(r.value->'columns')
        FROM ai.catalog_snapshot AS s
        CROSS JOIN LATERAL jsonb_array_elements(s.metadata->'relations') AS r(value)
        WHERE s.schema_name = 'public' AND r.value->>'name' = 'payment'
    )
);
