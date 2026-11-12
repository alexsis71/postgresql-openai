# PostgreSQL OpenAI

Пет-проект для разработки SQL-функций по текстовому описанию. PostgreSQL собирает каталог своей схемы, LLM составляет обзор базы для разработчика, а `make_func` выводит сигнатуру и тело обычной SQL-функции по заданию и каталогу.

## Что уже работает

`ai.init_catalog('public')` сканирует одну схему текущей базы, при необходимости добавляет небольшие выборки из указанных столбцов и вызывает OpenAI-совместимую модель. В `ai.catalog_snapshot` хранится одна запись на схему. Повторный успешный вызов обновляет её с тем же `id`. Метаданные и обзор можно читать обычным SQL без повторного вызова модели.

Демо использует `dvd_rent` в локальном Docker с PostgreSQL 17.10 и `qwen3.8-flash-next` на DGX. Каталог `public` содержит 22 таблицы и представления, 10 функций и агрегатов и 2 пользовательских типа. [Пример обзора модели](dvd_rent-synopsis.md)

Кроме подготовки SQL, из базы можно говорить с моделью напрямую: `SELECT * FROM llm(<system prompt>, <user_prompt>)` возвращает ответ вместе с моделью, расходом токенов и временем запроса. Подробно — в разделе «Чат с моделью».

## Файлы проекта

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога и алгоритм `make_func` |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Установка и миграция каталога, `ai.init_catalog()`, `ai.make_func()` и `llm()` |
| [sql/init_dvd_rent.sql](sql/init_dvd_rent.sql) | Профиль Flash Next и обновление каталога демо-базы |
| [sql/install_dvd_rent_skills.sql](sql/install_dvd_rent_skills.sql) | Навык расчёта выручки и его привязки к функциям демо-базы |
| [examples/inspect_catalog.sql](examples/inspect_catalog.sql) | Чтение каталога `public`, типов и связей таблицы платежей |
| [examples/make_func_customer_revenue.sql](examples/make_func_customer_revenue.sql) | Создание функции суммы платежей в схеме `reporting` |
| [examples/llm_chat.sql](examples/llm_chat.sql) | Чат с моделью: одиночный вопрос, история разговора, вопрос про каталог |
| [examples/customer_revenue_baseline.sql](examples/customer_revenue_baseline.sql) | Эталонный запрос для проверки созданной функции |
| [dvdrental.tar](dvdrental.tar) | Исходный архив демо-базы для `pg_restore` |

## Запуск в локальном Docker

Команды ниже рассчитаны на PowerShell, контейнер `postgres1` и базу `dvd_rent`. Для PostgreSQL 17 серверу нужен пакет `postgresql-17-http`. Если он уже установлен, сразу переходите к SQL-скриптам.

В Debian-образе с настроенным репозиторием PGDG сначала проверьте план установки пакета. В текущем контейнере эта установка добавила `pgsql-http` и его зависимости без обновления PostgreSQL.

```powershell
docker exec postgres1 apt-get -s install --no-install-recommends --no-upgrade postgresql-17-http
docker exec postgres1 apt-get -y install --no-install-recommends --no-upgrade postgresql-17-http
```

Если демо-базы ещё нет, восстановите архив в новую пустую базу.

```powershell
docker cp .\dvdrental.tar postgres1:/tmp/dvdrental.tar
docker exec postgres1 sh -c 'createdb -U "${POSTGRES_USER:-postgres}" dvd_rent && pg_restore --exit-on-error --no-owner --no-privileges -U "${POSTGRES_USER:-postgres}" -d dvd_rent /tmp/dvdrental.tar'
```

Запустите скрипты под владельцем установки. Первый создаёт объекты в `dvd_rent` или обновляет существующую установку. При миграции из старого формата он оставляет для каждой схемы самый свежий снимок с его исходным `id`. Второй скрипт добавляет профиль `default` при его отсутствии и создаёт или обновляет каталог `public` с профилем текущей сессии.

```powershell
Get-Content -Raw .\sql\install_catalog.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\sql\init_dvd_rent.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\examples\inspect_catalog.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
```

Демо-профиль обращается к `http://10.8.0.10:8002/v1/chat/completions` напрямую из PostgreSQL. Внутренний endpoint DGX принимает запросы без ключа. Если PostgreSQL работает в Docker, сетевую доступность проверяют из контейнера. Другой совместимый endpoint можно зарегистрировать по его базовому URL.

### Профиль и настройки сессии

```sql
-- Имя профиля берётся из идентификатора модели.
SELECT ai.register_model_profile('http://10.8.0.10:8002/v1');

-- Можно задать собственное имя профиля.
SELECT ai.register_model_profile('http://10.8.0.10:8002/v1', 'flash-next');

SET ai.model_profile = 'flash-next';
SET ai.enable_thinking = true;
SET ai.reasoning_effort = 'low';

SELECT answer, profile FROM ai.llm(NULL, 'Что делает VACUUM?');
```

`register_model_profile` читает `/v1/models`. Ответ должен содержать ровно одну модель. Функция записывает её ID и адрес `/v1/chat/completions`. Повторная регистрация обновляет адрес и ID модели, сохраняя заданные лимиты и параметры запроса. Для регистрации требуется доступ к endpoint без ключа.

Профиль выбирается в порядке `p_profile` → `ai.model_profile` → `default`. Явный аргумент доступен в `ai.llm`, `public.llm` и `ai.init_catalog`. `ai.make_func` использует профиль сессии или `default`. Эти функции применяют настройки thinking через общий HTTP-вызов. Для одной транзакции можно использовать `SET LOCAL`.

По умолчанию `enable_thinking` равен `false` для профилей с `chat_template_kwargs`, включая демо-профиль и автоматически обнаруженный Flash Next. При явном `SET ai.enable_thinking` значение передаётся через `chat_template_kwargs`. По умолчанию `reasoning_effort` считается `none` и поле не отправляется. Явно заданный уровень, включая `none`, передаётся провайдеру. Поддержка этих параметров зависит от endpoint.

`max_context_length` ограничивает размер сериализованного массива сообщений в байтах. Один и тот же лимит применяется к чату, инициализации каталога и генерации функций. `max_tokens` ограничивает ответ модели. Если в параметрах профиля есть `max_completion_tokens`, используется он.

### SQL-интерфейс

```sql
-- Scan public, with metadata only.
SELECT ai.init_catalog();

-- Add a small sample from a reference table.
SELECT ai.init_catalog(
    p_schema => 'public',
    p_samples => '{"public.category": ["category_id", "name"]}',
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
    'reporting.customer_revenue',
    'По клиенту и периоду вернуть сумму платежей.
     Начало включительно, конец исключительно. При отсутствии платежей вернуть ноль.'
);
```

Вызов использует профиль текущей сессии и сохранённый каталог. Он создаёт функцию в указанной схеме и возвращает её `signature`, выполненный `ddl` и `assumptions`. Вызывающему нужно право `CREATE` на целевую схему. Если функция с такой сигнатурой уже существует, PostgreSQL возвращает ошибку.

Описание может задавать скалярный или табличный результат. Для помесячного отчёта укажите месяц среди выходных столбцов, если его нужно видеть в выдаче.

```sql
SELECT reporting.customer_revenue(
    1::smallint, timestamp '2007-02-01', timestamp '2007-06-01'
);
```

Результат можно сравнить с [эталоном](examples/customer_revenue_baseline.sql).

## Чат с моделью

`llm(<system prompt>, <user_prompt>)` — общий доступ к модели из SQL. Если новый вопрос
содержит имя вида `схема.объект`, чат добавляет метаданные соответствующей схемы из
`ai.catalog_snapshot`, когда снимок существует и доступен вызывающему. Например, вопрос
про `public.country` получит снимок `public`, в котором видны и внешние ключи из других
таблиц этой схемы. Для обычных вопросов каталог не добавляется.

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
    'Какая таблица напрямую ссылается на country?',
    p_skills => ARRAY['use-snapshot@1']
);
```

Выполните [install_dvd_rent_skills.sql](sql/install_dvd_rent_skills.sql) в `dvd_rent`, чтобы добавить `rental-revenue@1` и привязать его к функциям расчёта выручки. Навыки хранятся отдельно от снимков и доступны по паре `name, version`.

```sql
SELECT * FROM ai.skill WHERE name = 'rental-revenue' AND version = 1;

SELECT answer, applied_skills
FROM ai.llm(
    'Отвечай кратко по-русски.',
    'Почему фильм повторяется в помесячном отчёте о выручке?',
    p_skills => ARRAY['rental-revenue@1']
);
```

`make_func(имя, описание)` сама загружает навыки из `ai.skill_binding` и возвращает их в `applied_skills`. Пустой `target_function` задаёт привязку ко всей схеме. Если один навык привязан и к схеме, и к имени функции, действует версия из привязки к функции.
