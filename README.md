# PostgreSQL OpenAI

Пет-проект для разработки SQL-функций по текстовому описанию. PostgreSQL собирает каталог своей схемы, LLM составляет обзор базы для разработчика, а `make_func` выводит сигнатуру и тело обычной SQL-функции по заданию и каталогу.

## Что уже работает

`ai.init_catalog('public')` сканирует одну схему текущей базы, при необходимости добавляет небольшие выборки из указанных столбцов и вызывает OpenAI-совместимую модель. В `ai.catalog_snapshot` хранится одна запись на схему. Повторный успешный вызов обновляет её с тем же `id`. Метаданные и обзор можно читать обычным SQL без повторного вызова модели.

Кроме подготовки SQL, из базы можно говорить с моделью напрямую: `SELECT * FROM llm(<system prompt>, <user_prompt>)` возвращает ответ вместе с моделью, расходом токенов и временем запроса. Подробно — в разделе «Чат с моделью».

## Файлы проекта

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога и алгоритм `make_func` |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Установка и миграция каталога, `ai.init_catalog()`, `ai.make_func()` и `llm()` |
| [examples/llm_chat.sql](examples/llm_chat.sql) | Общие примеры чата с моделью и историей разговора |
| [examples/dvd_rent](examples/dvd_rent/README.md) | Демобаза, настройка, навыки, примеры и эталоны |

## Установка в PostgreSQL

Установите `pgsql-http` на сервер PostgreSQL. Для Debian с PGDG и PostgreSQL 17 пакет называется `postgresql-17-http`. Запустите установщик через `psql` под ролью, которая может создать расширение `http` и служебные схемы. Замените `your_database` на имя своей базы.

```shell
psql -X -v ON_ERROR_STOP=1 -d your_database -f sql/install_catalog.sql
```

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

Установщик регистрирует `supabase-postgres-best-practices@1`, краткую адаптацию [рекомендаций Supabase для PostgreSQL](https://github.com/supabase/agent-skills/tree/c9be0e931b7930f7d02126d04774d904c381e7d7/skills/supabase-postgres-best-practices). `ai.make_func` передаёт её модели при генерации и ревью черновика, а `ai.review_function` — при ревью существующей функции. Привязка к схеме или функции может выбрать другую версию навыка. В чате навык выбирается явно и доступен без снимка схемы.

```sql
SELECT answer, applied_skills
FROM ai.llm(
    'Отвечай по-русски.',
    'Как написать фильтр за календарный месяц по колонке timestamp?',
    p_skills => ARRAY['supabase-postgres-best-practices@1']
);
```
