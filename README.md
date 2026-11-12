# PostgreSQL OpenAI

Пет-проект для разработки SQL-функций по текстовому описанию. PostgreSQL собирает каталог своей схемы, LLM составляет обзор базы для разработчика, а `make_func` выводит сигнатуру и тело обычной SQL-функции по заданию и каталогу.

## Что уже работает

`ai.init_catalog('public')` сканирует одну схему текущей базы, при необходимости добавляет небольшие выборки из указанных столбцов и вызывает OpenAI-совместимую модель. В `ai.catalog_snapshot` хранится одна запись на схему. Повторный успешный вызов обновляет её с тем же `id`. Метаданные и обзор можно читать обычным SQL без повторного вызова модели.

Демо использует `dvd_rent` в локальном Docker с PostgreSQL 17.10 и `qwen3.8-flash-next` на DGX. Каталог `public` содержит 22 таблицы и представления, 10 функций и агрегатов и 2 пользовательских типа. [Пример обзора модели](dvd_rent-synopsis.md)

## Файлы проекта

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога и алгоритм `make_func` |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Установка и миграция каталога и `ai.init_catalog()` |
| [sql/init_dvd_rent.sql](sql/init_dvd_rent.sql) | Профиль Flash Next и обновление каталога демо-базы |
| [examples/inspect_catalog.sql](examples/inspect_catalog.sql) | Чтение каталога `public`, типов и связей таблицы платежей |
| [examples/make_func_customer_revenue.sql](examples/make_func_customer_revenue.sql) | Создание функции суммы платежей в схеме `reporting` |
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

Запустите скрипты под владельцем установки. Первый создаёт объекты в `dvd_rent` или обновляет существующую установку. При миграции из старого формата он оставляет для каждой схемы самый свежий снимок с его исходным `id`. Второй скрипт создаёт или обновляет каталог `public` с профилем `default`. Если профиль с этим именем уже есть, скрипт использует его настройки.

```powershell
Get-Content -Raw .\sql\install_catalog.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\sql\init_dvd_rent.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\examples\inspect_catalog.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
```

Демо-профиль обращается к `http://10.8.0.10:8002/v1/chat/completions` напрямую из PostgreSQL. Внутренний endpoint DGX принимает запросы без ключа. Если PostgreSQL работает в Docker, сетевую доступность проверяют из контейнера. Для другого OpenAI-совместимого endpoint укажите адрес и модель в `ai.model_profile`. Авторизация внешних провайдеров пока в плане.

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

Вызов использует профиль `default` и сохранённый каталог. Он создаёт функцию в указанной схеме и возвращает её `signature`, выполненный `ddl` и `assumptions`. Вызывающему нужно право `CREATE` на целевую схему. Если функция с такой сигнатурой уже существует, PostgreSQL возвращает ошибку.

Описание может задавать скалярный или табличный результат. Для помесячного отчёта укажите месяц среди выходных столбцов, если его нужно видеть в выдаче.

```sql
SELECT reporting.customer_revenue(
    1::smallint, timestamp '2007-02-01', timestamp '2007-06-01'
);
```

Результат можно сравнить с [эталоном](examples/customer_revenue_baseline.sql).
