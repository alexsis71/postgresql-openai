\set ON_ERROR_STOP on
BEGIN;
CREATE SCHEMA IF NOT EXISTS reporting;

SELECT signature, applied_skills
FROM ai.make_func(
    'reporting.customer_like_v4',
    $prompt$По ID клиента верни 10 других клиентов, ближайших по евклидову расстоянию между бинарными признаками истории проката. Используй postgres-cube и шаблон привязанного навыка. Сравни уникальные фильмы, их категории, тексты описаний и актёров. Несовпадение address.city_id и customer.store_id добавляет по одному баллу, кандидатов по ним не фильтруй. Учитывай клиентов без прокатов; для неизвестного ID верни пустой результат. При равенстве расстояния сортируй по ID. Вход p_customer_id integer, выход customer_id integer и full_name text (имя, пробел, фамилия).$prompt$
);

SELECT customer_id, full_name
FROM reporting.customer_like_v4(42);
COMMIT;
