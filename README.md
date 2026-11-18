# PostgreSQL OpenAI

Пет-проект для разработки SQL-функций по текстовому описанию. PostgreSQL собирает каталог своей схемы, LLM составляет обзор базы для разработчика, а `make_func` выводит сигнатуру и тело обычной SQL-функции по заданию и каталогу.

## Что уже работает

`ai.init_catalog('public')` сканирует одну схему текущей базы, при необходимости добавляет небольшие выборки из указанных столбцов и вызывает OpenAI-совместимую модель. В `ai.catalog_snapshot` хранится одна запись на схему. Повторный успешный вызов обновляет её с тем же `id`. Метаданные и обзор можно читать обычным SQL без повторного вызова модели.

Кроме подготовки SQL, из базы можно говорить с моделью напрямую: `SELECT * FROM llm(<system prompt>, <user_prompt>)` возвращает ответ вместе с моделью, расходом токенов и временем запроса. Подробно — в разделе «Чат с моделью».

## Файлы проекта

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога и алгоритм `make_func` |
| [scripts/build_extension.py](scripts/build_extension.py) | Сборка файлов для `CREATE EXTENSION postgresql_openai` |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Исходный SQL расширения и установщик для существующих скриптовых инсталляций |
| [examples/llm_chat.sql](examples/llm_chat.sql) | Общие примеры чата с моделью и историей разговора |
| [examples/dvd_rent](examples/dvd_rent/README.md) | Демобаза, настройка, навыки, примеры и эталоны |

## Установка в PostgreSQL

На сервере PostgreSQL 17 установите `pgsql-http`. Для Debian с PGDG пакет называется `postgresql-17-http`. Соберите пакет из корня репозитория с помощью Python 3.10+ и скопируйте два файла в каталог расширений **сервера**. Используйте `pg_config` той же версии PostgreSQL, что и сервер. Для Docker файлы должны находиться внутри контейнера или в его образе.

```shell
python3 scripts/build_extension.py build/extension
sudo install -m 0644 build/extension/postgresql_openai.control \
  build/extension/postgresql_openai--0.1.0.sql "$(pg_config --sharedir)/extension/"
```

В целевой базе выполните под суперпользователем PostgreSQL:

```sql
CREATE SCHEMA ai_http;
REVOKE ALL ON SCHEMA ai_http FROM PUBLIC;
CREATE EXTENSION http WITH SCHEMA ai_http;
CREATE EXTENSION postgresql_openai;
```

Если `http` уже установлен, достаточно последней команды. Расширение использует схему `ai`, а совместимая обёртка `llm` находится в `public`. Установка создаёт общие навыки. Профили моделей, снимки, корпус документации и данные демобазы подключаются отдельно.

Для существующей установки через `sql/install_catalog.sql` продолжайте использовать этот скрипт. Версия 0.1.0 рассчитана на чистую установку; перевода существующих объектов под управление расширения пока нет. Удаление расширения удаляет и его служебные таблицы с данными.

После установки зарегистрируйте модель и создайте снимок нужной схемы. HTTP-запросы выполняются с сервера PostgreSQL. При установке в Docker сетевую доступность endpoint проверяют из контейнера.

### Профиль и настройки сессии

```sql
-- Имя профиля берётся из идентификатора модели.
SELECT ai.register_model_profile('http://llm-host:8000/v1');

-- Можно задать собственное имя профиля.
SELECT ai.register_model_profile('http://llm-host:8000/v1', 'default');

SET ai.model_profile = 'default';
SET ai.enable_thinking = true;
SET ai.reasoning_effort = 'low';

SELECT answer, profile FROM ai.llm(NULL, 'Что делает VACUUM?');
```

`register_model_profile` читает `/v1/models`. Ответ должен содержать ровно одну модель. Функция записывает её ID и адрес `/v1/chat/completions`. Повторная регистрация обновляет адрес и ID модели, сохраняя заданные лимиты и параметры запроса. Для регистрации требуется доступ к endpoint без ключа.

Профиль выбирается в порядке `p_profile` → `ai.model_profile` → `default`. Явный аргумент доступен в `ai.llm`, `public.llm` и `ai.init_catalog`. `ai.make_func` использует профиль сессии или `default`. Эти функции применяют настройки thinking через общий HTTP-вызов. Для одной транзакции можно использовать `SET LOCAL`.

По умолчанию `enable_thinking` равен `false` для профилей с `chat_template_kwargs`. При явном `SET ai.enable_thinking` значение передаётся через `chat_template_kwargs`. По умолчанию `reasoning_effort` считается `none` и поле не отправляется. Явно заданный уровень, включая `none`, передаётся провайдеру. Поддержка этих параметров зависит от endpoint.

`max_context_length` ограничивает размер сериализованного массива сообщений в байтах. Один и тот же лимит применяется к чату, инициализации каталога и генерации функций. `max_tokens` ограничивает ответ модели. Если в параметрах профиля есть `max_completion_tokens`, используется он.

### Поиск по документации PostgreSQL 17

После установки расширения загрузите выбранные разделы из локального
официального PDF. Импортёр хранит текст, ссылку на раздел, выпуск PDF и номер страницы.
Повторный импорт заменяет корпус PostgreSQL 17 одной транзакцией.

```powershell
python -m pip install pypdf "psycopg[binary]"
python scripts/import_postgres17_docs.py postgresql-17-A4.pdf --dsn "host=localhost port=5432 dbname=mydb user=postgres"
```

`ai.make_func` и `ai.make_view` подбирают до четырёх выдержек для текущей основной версии
сервера и передают их генератору и ревьюеру. Поиск использует полнотекстовый индекс,
русские метки разделов и приоритет точных имён функций. При пустой выдаче вызов
продолжается со снапшотом и навыками. В обоих генераторах
`supabase-postgres-best-practices@1` подключён по умолчанию.

```sql
SELECT ai.search_postgres_docs('пересечение массивов unnest');
SET ai.postgres_docs_rag = off;
RESET ai.postgres_docs_rag;

SELECT id, signature, documentation_sources
FROM ai.function_generation
ORDER BY id DESC
LIMIT 5;
```

В `documentation_sources` сохраняются URL и координаты выдержек, переданных модели.
Поле содержит пустой массив для старых записей и вызовов без выдержек.

#### Гибридный поиск

На хосте для эмбеддингов можно запустить CPU-сервис с моделью
`intfloat/multilingual-e5-small`. Укажите адрес, доступный PostgreSQL и импортёру.

```sh
python -m pip install fastembed
python scripts/serve_doc_embeddings.py --host 127.0.0.1 --port 8031
```

```sql
INSERT INTO ai.doc_embedding_profile (profile, endpoint, model, dimensions)
VALUES ('default', 'http://127.0.0.1:8031/v1/embeddings', 'intfloat/multilingual-e5-small', 384)
ON CONFLICT (profile) DO UPDATE
SET endpoint = EXCLUDED.endpoint, model = EXCLUDED.model, dimensions = EXCLUDED.dimensions;
```

```sh
python scripts/embed_postgres_docs.py --dsn "host=localhost dbname=mydb user=postgres"
```

```sql
SET ai.postgres_docs_search = 'hybrid';
SELECT ai.search_postgres_docs('как найти общие элементы двух массивов');
SET ai.postgres_docs_search = 'fts';
```

`fts` остаётся режимом по умолчанию. `hybrid` объединяет полнотекстовую и
косинусную выдачу методом Reciprocal Rank Fusion (RRF). Для малого корпуса используется точный
поиск по массивам PostgreSQL. При недоступном endpoint поиск возвращается к FTS
с уведомлением. В истории доступны фактический `search_mode` и ранги источников.
После повторного импорта запустите индексацию эмбеддингов для новых выдержек.

#### Корпус оптимизации запросов

`psql -f sql/install_query_optimization_corpus.sql` добавляет краткие конспекты
по русскому изданию книги Г. Домбровской, Б. Новикова и А. Бейликовой, ссылки
на страницы локального PDF и навык `postgres-query-optimization@1`.
Полнотекстовый поиск доступен сразу. Для гибридного поиска обновите эмбеддинги
тем же импортёром. Корпус документации и конспекты можно переустанавливать отдельно.

```sql
SELECT answer, applied_skills
FROM ai.llm(NULL, 'Как проверить, почему планировщик выбрал Seq Scan?',
    p_skills => ARRAY['postgres-query-optimization@1']);
```

Для `make_func` и `make_view` навык подключается через `ai.skill_binding`
к схеме или имени объекта. Оценка производительности использует измерения из
плана, если он предоставлен.

#### Автоматический разбор плана

`ai.optimize_query` принимает один `SELECT`, включая запрос с CTE, и возвращает
план PostgreSQL в JSON, рекомендации модели, применённые навыки и ссылки на
документацию. Параметры `p_goal` и `p_profile` необязательны.

```sql
BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '2s';

SELECT plan, advice, applied_skills, documentation_sources
FROM ai.optimize_query(
    $$SELECT customer_id, sum(amount)
      FROM public.payment
      WHERE payment_date::date = DATE '2007-02-15'
      GROUP BY customer_id$$,
    p_goal => 'Оцени фильтр по дате и предложи эквивалентный диапазон'
);
COMMIT;
```

План строится с правами и `search_path` вызывающей роли. PostgreSQL планирует
запрос как подзапрос через `EXPLAIN (FORMAT JSON, COSTS TRUE, VERBOSE TRUE, SETTINGS TRUE, ANALYZE FALSE)`.
План содержит оценки строк и стоимости. Фактические времена и буферы требуют отдельного замера.
SQL и план отправляются в выбранный профиль модели. Используйте профиль, которому можно
передать идентификаторы объектов, условия и литералы этого запроса. Рекомендации возвращаются
текстом, изменения SQL или индексов выполняет разработчик.

### SQL-интерфейс

```sql
-- Scan public, with metadata only.
SELECT ai.init_catalog();

-- Replace public.your_table and its columns with objects from your schema.
SELECT ai.init_catalog(
    p_schema => 'public',
    p_samples => '{"public.your_table": ["id", "name"]}',
    p_sample_rows => 3,
    p_profile => 'default'
);

-- Read the saved synopsis without contacting the model.
SELECT id, model, synopsis
FROM ai.catalog_snapshot
WHERE schema_name = 'public';
```

### Генерация функции

```sql
CREATE SCHEMA IF NOT EXISTS reporting;

SELECT * FROM ai.make_func(
    'reporting.row_count',
    'Верни число строк в public.your_table. Входных параметров нет.'
);
```

Вызов использует профиль текущей сессии и сохранённый каталог. Он создаёт функцию в указанной схеме и возвращает её `signature`, выполненный `ddl` и `assumptions`. Вызывающему нужно право `CREATE` на целевую схему. Если функция с такой сигнатурой уже существует, PostgreSQL возвращает ошибку.

Описание может задавать скалярный или табличный результат. Для помесячного отчёта укажите месяц среди выходных столбцов, если его нужно видеть в выдаче.

Пример проверки созданной функции приведён в [сценарии демобазы](examples/dvd_rent/README.md).

Историю успешно созданных функций можно посмотреть в `ai.function_generation`.

```sql
SELECT created_at, signature, generator_model, catalog_sha256,
       applied_skills, review->>'verdict' AS verdict
FROM ai.function_generation
WHERE target_schema = 'reporting'
ORDER BY id DESC;
```

У отчётных функций в `ai.function_generation.report_contract` сохраняются мера, поле даты,
фильтры, группировка, выходные столбцы и сортировка. Ревьюер сверяет контракт с заданием
и проверяет, что SQL реализует его.

```sql
SELECT signature, report_contract
FROM ai.function_generation
WHERE report_contract IS NOT NULL
ORDER BY id DESC;
```

По умолчанию `make_func` использует полный снимок. Чтобы передать только подобранные
объекты и их ближайшие связи, включите `SET ai.function_catalog_mode = 'focused'`.
Вернуться к полному снимку можно через `RESET ai.function_catalog_mode`.
В `ai.function_generation.catalog_selection` сохраняются режим, размер исходного
и переданного снимка, входные токены генератора и время создания с учётом ревью.

### Генерация представления

`ai.make_view(имя, описание)` использует сохранённый снимок, навыки и настройки
профиля так же, как `make_func`. После вердикта `pass` создаётся обычное
представление `SECURITY INVOKER`. Чтение выполняется с правами вызывающего
и без обращения к модели. Уже существующее отношение с тем же именем вызывает ошибку.

Пример на демобазе создаёт помесячную выручку по фильмам и сверяет все строки
с эталоном. [SQL-сценарий](examples/dvd_rent/make_view_monthly_film_revenue.sql)

```sql
SELECT created_at, signature, report_contract, applied_skills, review->>'verdict' AS verdict
FROM ai.function_generation
WHERE object_kind = 'view'
ORDER BY id DESC;
```

### Ревью функций

`make_func` перед созданием запрашивает отдельное LLM-ревью с навыком `review-function@1`.
При вердикте `needs_changes` или `ambiguous` функция не создаётся, а пояснения возвращаются
в `DETAIL` ошибки. Для ревью можно выбрать зарегистрированный профиль через
`SET ai.reviewer_profile = 'review-model'`. Если настройка пуста, применяется текущий профиль модели.

Перед созданием функции или представления ревьюер возвращает вердикт и до трёх замечаний
с полями `requirement`, `sql_fragment` и `reason` (до 120, 180 и 240 символов соответственно).
PostgreSQL проверяет этот формат. Если сервер модели поддерживает `response_format: json_schema`,
включите передачу схемы для выбранного профиля ревьюера:

```sql
UPDATE ai.model_profile
SET compact_review_json_schema = true
WHERE profile = 'review-model';
```

Для остальных профилей действует тот же контракт через промпт. Расширенное
`ai.review_function()` использует собственный формат с `logic` и `confidence`.

Для уже созданного объекта передайте его точную сигнатуру и описание ожидаемого поведения.
Явный аргумент `p_profile` имеет приоритет над настройкой сессии.

```sql
SELECT ai.review_function(
    'reporting.row_count()',
    'Верни число строк в public.your_table. Входных параметров нет.'
);
```

В чате можно выбрать `p_skills => ARRAY['review-function@1']` и приложить SQL функции к вопросу.
Вердикт оценивает соответствие определения заданию. Проверку результата на данных выполняют отдельно.

Если ожидаемое поведение неизвестно, передайте только сигнатуру:

```sql
SELECT jsonb_pretty(ai.review_function('public.my_function(integer)'));
```

`logic` описывает фактическое поведение, включая порядок шагов, ветвления, возвраты,
операции с данными и то, что нельзя вывести из определения. В `findings` входят
фрагмент, причина и уверенность (`high` или `medium`). Снимок используется при наличии.
Ревьюер читает код SQL и PL/pgSQL из PostgreSQL без выполнения функции. Если модель вернула
объяснение в неверном формате, PostgreSQL повторяет запрос один раз и проверяет ответ снова.
Язык объяснения и замечаний определяется по описанию задания, комментариям к функции
или описаниям связанных объектов. Для кода без явных языковых признаков используется английский.

## Чат с моделью

`llm(<system prompt>, <user_prompt>)` — общий доступ к модели из SQL. Если новый вопрос
содержит имя вида `схема.объект`, чат добавляет метаданные соответствующей схемы из
`ai.catalog_snapshot`, когда снимок существует и доступен вызывающему. Снимок включает
ограничения других таблиц этой схемы. Для обычных вопросов каталог не добавляется.

```sql
SELECT * FROM llm(
    'Отвечай на русском одним коротким предложением без предисловий.',
    'Что делает команда VACUUM в PostgreSQL?'
);
```

| Столбец | Содержание |
| --- | --- |
| `answer` | Текст ответа модели |
| `model`, `profile` | Модель из ответа и имя использованного профиля |
| `finish_reason` | `stop`; неполный ответ прерывается ошибкой |
| `prompt_tokens`, `completion_tokens`, `total_tokens` | Расход токенов из ответа провайдера |
| `latency_ms` | Время запроса, измеренное в PostgreSQL |
| `applied_skills` | Имена и версии навыков, переданных модели |

Нужен только текст ответа — `SELECT answer FROM llm(...)`.

Многоходовость собирает вызывающая сторона: история разговора — массив сообщений `user` и
`assistant`, который вставляется между системным промптом и новым вопросом.

```sql
SELECT answer FROM llm(
    'Отвечай на русском кратко.',
    'А чем отличается от VACUUM FULL?',
    p_history => '[
        {"role": "user", "content": "Что делает VACUUM в PostgreSQL?"},
        {"role": "assistant", "content": "Освобождает место под удалённые кортежи без блокировки таблиц."}
    ]'::jsonb
);
```

Системный промпт допустим `NULL`. При наличии снимка чат добавляет инструкцию использовать его как источник сведений о базе. Пустой пользовательский промпт, неизвестный профиль и неверная структура истории возвращают ошибку.

Функция определена как `ai.llm` и как `public.llm` с одинаковыми аргументами, поэтому работают
и `SELECT * FROM ai.llm(...)`, и вызов без имени схемы. Обе, как и остальные функции `ai`,
закрыты от `PUBLIC`; доступ рабочей роли выдаётся явно:

```sql
GRANT USAGE ON SCHEMA ai TO app_user;
GRANT EXECUTE ON FUNCTION ai.llm(text, text, text, jsonb, text[]) TO app_user;
GRANT EXECUTE ON FUNCTION public.llm(text, text, text, jsonb, text[]) TO app_user;
```

Функции работают с правами вызывающего. При настройке роли отдельно учитывайте доступ к профилям, снимкам, навыкам и внутренним функциям. После обновления со старой сигнатуры проверьте явные права на `llm` и `make_func`.

### Чат с сохранением истории

`ai.create_conversation` создаёт диалог и возвращает UUID. `ai.chat` подставляет
сохранённые сообщения в вызов `ai.llm`, затем записывает вопрос и ответ одной
транзакцией. При ошибке модели ход можно повторить с тем же UUID.

```sql
SELECT ai.create_conversation('Знакомство с dvd_rent') AS conversation_id \gset

SELECT answer, turn_number
FROM ai.chat(:'conversation_id'::uuid, 'Как устроена таблица public.payment?');

SELECT answer, turn_number
FROM ai.chat(:'conversation_id'::uuid, 'Какой внешний ключ ты упомянул?');

SELECT position, role, content
FROM ai.message
WHERE conversation_id = :'conversation_id'::uuid
ORDER BY position;
```

`\gset` сохраняет UUID в переменную `psql`. В других клиентах передайте UUID из
первого запроса как параметр. Для каждого хода можно указать `p_system`,
`p_profile` и `p_skills`. В контекст входит вся история диалога в пределах
лимита выбранного профиля. Вызовы `ai.llm` с клиентским `p_history` работают
по прежнему интерфейсу.

RLS ограничивает чтение и запись владельцем диалога по `CURRENT_USER`. Роль
PostgreSQL служит идентификатором владельца. Клиенты, подключённые под одной ролью,
используют общий набор диалогов. Долгие транзакции задерживают следующий ход того
же диалога, поэтому завершайте транзакцию после получения ответа.

Для роли с уже настроенным доступом к `ai.llm` нужны дополнительные права:

```sql
GRANT EXECUTE ON FUNCTION ai.create_conversation(text), ai.chat(uuid, text, text, text, text[]) TO app_user;
GRANT SELECT ON ai.conversation, ai.message TO app_user;
GRANT INSERT (title), UPDATE (turn_count, updated_at) ON ai.conversation TO app_user;
GRANT INSERT (conversation_id, position, role, content) ON ai.message TO app_user;
```

Каждый вызов `llm` — обращение к модели, а не обычный `SELECT`. Готовые запросы — в
[examples/llm_chat.sql](examples/llm_chat.sql).

## Навыки

Установщик добавляет `use-snapshot@1`. Навык требует доступный снимок и передаёт его модели даже для вопроса без имени схемы. Если снимков нет или у роли отсутствует право чтения, вызов завершится ошибкой до обращения к модели.

```sql
SELECT answer, applied_skills
FROM ai.llm(
    'Отвечай кратко по-русски.',
    'Какие таблицы напрямую ссылаются на your_table?',
    p_skills => ARRAY['use-snapshot@1']
);
```

Навыки хранятся отдельно от снимков и доступны по паре `name, version`. Пример предметного навыка и его подключения есть в [сценарии демобазы](examples/dvd_rent/README.md).

`make_func(имя, описание)` сама загружает навыки из `ai.skill_binding` и возвращает их в `applied_skills`. Пустой `target_function` задаёт привязку ко всей схеме. Если один навык привязан и к схеме, и к имени функции, действует версия из привязки к функции.

### Навык из сохранённого диалога

Зафиксируйте в чате правило, которое нужно применять в следующих задачах. Например, диалог о таблице `billing.orders` может содержать такое подтверждение:

```sql
SELECT ai.create_conversation('Как считаем выручку') AS conversation_id \gset

SELECT answer
FROM ai.chat(
    :'conversation_id'::uuid,
    'Для billing.orders считаем выручку по месяцу оплаты paid_on. Суммируем amount только по оплаченным заказам.'
);

SELECT ai.draft_skill(
    :'conversation_id'::uuid, 'billing-revenue-month', p_schema => 'billing'
) AS draft \gset

SELECT :'draft'::jsonb;
```

`ai.draft_skill` отправляет модели историю диалога, доступного его владельцу, и возвращает редактируемый JSON. При указании `p_schema` функция берёт допустимые имена таблиц и представлений из снимка этой схемы. Для общего навыка без привязки к объектам вызовите её без `p_schema`. Модель использует профиль сессии или значение `p_profile`.

Проверьте формулировку и SQL-примеры перед публикацией. При необходимости отредактируйте JSON и передайте исправленный вариант. Публикация оставляет предыдущие версии доступными. Для новой редакции укажите свободный `p_version`.

```sql
SELECT ai.publish_skill(:'draft'::jsonb);

SELECT answer, applied_skills
FROM ai.llm(
    NULL, 'В какой месяц отнести заказ от 31 января, оплаченный 1 февраля?',
    p_skills => ARRAY['billing-revenue-month@1']
);

-- Подключить точную версию к генерации одноимённого отчёта.
INSERT INTO ai.skill_binding (target_schema, target_function, skill_name, skill_version)
VALUES ('reporting', 'monthly_revenue', 'billing-revenue-month', 1);
```

Роли с настроенным доступом к `ai.llm` и истории нужны `EXECUTE` на `ai.draft_skill(uuid,text,text,text)` и `ai._validate_skill_draft(jsonb)`. Для черновика с `p_schema` ей также нужен `SELECT` на `ai.catalog_snapshot`. Публикующей роли нужны `EXECUTE` на `ai.publish_skill(jsonb,integer)` и тот же валидатор, а также `INSERT` на `ai.skill`.

Установщик регистрирует `supabase-postgres-best-practices@1`, краткую адаптацию [рекомендаций Supabase для PostgreSQL](https://github.com/supabase/agent-skills/tree/c9be0e931b7930f7d02126d04774d904c381e7d7/skills/supabase-postgres-best-practices). `ai.make_func` передаёт её модели при генерации и ревью черновика, а `ai.review_function` — при ревью существующей функции. Привязка к схеме или функции может выбрать другую версию навыка. В чате навык выбирается явно и доступен без снимка схемы.

```sql
SELECT answer, applied_skills
FROM ai.llm(
    'Отвечай по-русски.',
    'Как написать фильтр за календарный месяц по колонке timestamp?',
    p_skills => ARRAY['supabase-postgres-best-practices@1']
);
```
