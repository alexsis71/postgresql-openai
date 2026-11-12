# QWEN.md — контекст проекта для агента

## Обзор проекта

**PostgreSQL OpenAI** — пет-проект для генерации SQL-функций по текстовому описанию. PostgreSQL сам собирает каталог своей схемы, OpenAI-совместимая модель составляет по нему обзор предметной области для разработчика, а будущая `ai.make_func` должна возвращать сигнатуру и тело обычной SQL-функции по заданию и каталогу.

Ключевой архитектурный принцип: **модель вызывается только на этапе подготовки SQL**. Применённый DDL создаёт обычную функцию или представление PostgreSQL, которое работает без обращения к модели. Снятый каталог переиспользуется между заданиями, поэтому повторные вызовы модели — это осознанная, а не случайная операция.

- **Язык интерфейса** — SQL. Основные пользовательские точки входа: `ai.init_catalog()` и (в плане) `ai.make_func()`.
- **Стек:** PostgreSQL 17, PL/pgSQL, расширение `http` (pgsql-http) как транспорт JSON/HTTP, OpenAI-совместимый `/v1/chat/completions`.
- **Демо-данные:** классическая база `dvdrental` (`dvdrental.tar`) в базе `dvd_rent`.
- **Модель:** `qwen3.8-flash-next` (vLLM) на DGX-хосте.
- **Стадия:** прототип. Каталог работает, `make_func` не реализована. Собственного пакета `CREATE EXTENSION`, ролей и авторизации внешних провайдеров нет.

### Структура репозитория

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога, разбор первого прогона, план `make_func` |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Единственный DDL: схемы `ai`/`ai_http`, таблицы `ai.model_profile`, `ai.catalog_snapshot`, функция `ai.init_catalog()` |
| [sql/init_dvd_rent.sql](sql/init_dvd_rent.sql) | Профиль `default` + создание снимка демо-базы с выборками |
| [examples/inspect_catalog.sql](examples/inspect_catalog.sql) | Чтение последнего снимка, колонок и ограничений `payment` |
| [examples/customer_revenue_baseline.sql](examples/customer_revenue_baseline.sql) | Эталонный запрос-ожидание для будущей проверки `make_func` |
| [dvd_rent-synopsis.md](dvd_rent-synopsis.md) | Сохранённый обзор базы, возвращённый моделью |
| [README.md](README.md) | Постановка команд запуска (PowerShell) и SQL-интерфейс |
| `dvdrental.tar` | Исходный архив демо-базы для `pg_restore` (бинарный, не редактировать) |

## Состояние окружения (проверено 11.11.2026)

Проверялось прямыми командами на этом хосте (Linux, bash). Это актуальное состояние, а не описание из README:

- **PostgreSQL работает на отдельной машине `10.8.0.6` — это ноутбук `MyLegion` под Windows, пользователь `alexs`** (сообщено пользователем 11.11.2026, ОС уточнена 12.11.2026). С этого хоста порт 5432 открыт, `ping` отвечает (35 мс 11.11.2026, 77–163 мс 12.11.2026 — путь идёт через туннель и по качеству плавает). **Сервер PostgreSQL на этом хосте отсутствует:** контейнера `postgres1` нет ни в запущенном, ни в остановленном виде (`docker ps -a` — 20 контейнеров, ни одного postgres-related), серверного образа тоже нет, как и хостовых `psql`, `pg_restore`, `createdb`. Команды `docker exec postgres1 ...` из README относятся к `MyLegion` и на этом хосте завершатся ошибкой. 11.11.2026 подтянут только **клиентский** образ `postgres:17-alpine` (291 МБ) — он нужен для `psql` из контейнера, сервером он не является.
- **LLM endpoint — на этом хосте:** `http://10.8.0.10:8002/v1/models` отвечает `200` и отдаёт единственную модель `qwen3.8-flash-next` (vLLM, `nvidia/Qwen3.8-Flash-Next-FP4-Local`, `max_model_len: 262144`). Его обслуживает запущенный контейнер `qwen38-fp4local` с `NetworkMode=host`; сервер слушает `0.0.0.0:8002`, поэтому endpoint доступен и с 10.8.0.6.
- **Топология сети:** этот хост — `mydgx`. Адрес `10.8.0.10` принадлежит туннельному интерфейсу `tun8` (peer `10.8.0.9`), LAN-адрес — `192.168.1.70`. Остальные адреса `10.8.0.0/24`, включая `10.8.0.6`, — **отдельные машины**: маршрут к ним идёт через `10.8.0.9 dev tun8`. Привычка «всё делать напрямую, без ssh» из других проектов этого пользователя к 10.8.0.6 неприменима.
- **Доступ к `MyLegion` по ssh не настроен:** порт 22 открыт, но ключевая аутентификация отклоняется (`ssh -o BatchMode=yes alexs@10.8.0.6` → `Permission denied (publickey,password,keyboard-interactive)`). Причина механическая: на этом хосте есть только **публичные** половины ключей (`id_ed25519.pub` с комментарием `alexs@MyLegion`, `dgx_sl.pub` — `sl-dgx`), приватных половин нет ни в `~/.ssh`, ни в агенте (`SSH_AUTH_SOCK` не задан, `ssh-add -l` — «Could not open a connection»), и оба ключа созданы на самой цели, то есть их приватные половины живут на `MyLegion`. Поиск по содержимому `/home` на заголовок `BEGIN OPENSSH PRIVATE KEY` дал только текст самой проверки в логе сессии — реальных ключей на хосте нет. `sshpass` не установлен, интерактивный ввод пароля здесь недоступен.
  11.11.2026 создан отдельный ключ `~/.ssh/id_ed25519_pgopen` — клиент его предлагает (`Offering public key: ... SHA256:LYwJJB/ydJoOBqS3RD624SJvvBhiTyw72hoTsWtAcOE`), сервер отклоняет. Сервер — `OpenSSH_for_Windows_9.5` (проверено 12.11.2026 по строке `remote software version`), поэтому путь к файлу авторизованных ключей **не** `~/.ssh/authorized_keys`, а `C:\Users\alexs\.ssh\authorized_keys`; а если `alexs` состоит в группе Administrators, sshd читает только `C:\ProgramData\ssh\administrators_authorized_keys` и личный файл игнорирует — это типичная причина «ключ добавлен, но не работает». Команды установки — в разделе «Применение SQL-скриптов». Перепроверено 12.11.2026: ключ предлагается и отклоняется, отпечаток серверного хоста в `known_hosts` не менялся (это та же машина), а `psql` по TCP в это время работает.
- **Рабочий путь к БД — `psql` в контейнере, без ssh (проверено 11.11.2026):** хостового `psql` нет, но клиентский образ `postgres:17-alpine` подключается к `10.8.0.6:5432` напрямую; готовая команда — в разделе «Применение SQL-скриптов». Проверенный ответ сервера: `PostgreSQL 17.10 (Debian 17.10-1.pgdg12+1)`, `current_database() = dvd_rent`, `current_user = postgres`. Секрет берётся из `~/.pgpass` пользователя `alex` (права `0600`; `libpq` отказывается читать файл с групповыми или прочими битами), пароль не попадает ни в чат, ни в историю shell.
- **Git:** одна ветка `main`, один коммит `fb1c296`, **удалённого репозитория нет** (`git remote -v` пуст) — push невозможен без добавления remote.

Практический вывод: каталог строится базой на `10.8.0.6`, а модель отвечает на этом хосте. Проверять связность нужно **с той машины, где работает PostgreSQL**, а не только отсюда: `curl http://10.8.0.10:8002/v1/models`. Именно из-за разнесения машин профиль использует маршрутизируемый адрес `10.8.0.10`, а не `localhost`: для сервера на 10.8.0.6 локальный адрес означал бы «сам себя» и к модели не привёл бы. Обратное направление (база → модель) уже подтверждено косвенно: в `ai.catalog_snapshot` лежат снимки, а значит `pgsql-http` с `MyLegion` до endpoint'а пробивается; новый снимок после успешного прогона — лучшее тому доказательство.

## Сборка, запуск, проверка

Автоматических тестов, `Makefile`, `package.json` и CI в репозитории **нет**. Проверка — ручные прогоны SQL-скриптов в `psql` (см. «Как проверить, что изменения работают»).

**Все команды `docker exec postgres1 ...` из README и примеров ниже выполняются на машине `10.8.0.6`, где стоит PostgreSQL.** С этого хоста (`mydgx`) они не запускаются: здесь нет ни контейнера, ни клиента `psql`, ни настроенного ssh-доступа к 10.8.0.6 (см. «Состояние окружения»).

### 1. Транспорт `http` на сервере PostgreSQL

Серверу PostgreSQL 17 нужен пакет `http` из `postgresql-17-http` (Debian/PGDG). Сначала план установки, потом сама установка — в прошедшем прогоне это добавило `pgsql-http` и зависимости без обновления самого PostgreSQL:

```bash
docker exec postgres1 apt-get -s install --no-install-recommends --no-upgrade postgresql-17-http
docker exec postgres1 apt-get -y install --no-install-recommends --no-upgrade postgresql-17-http
```

Создание контейнера в репозитории не описано: `postgres1` на 10.8.0.6 считается существующим. Поднимать свой контейнер на этом хосте не стоит — это дало бы вторую, пустую базу отдельно от данных и накопленных снимков на 10.8.0.6.

### 2. Восстановление демо-базы (только если базы ещё нет)

```bash
docker cp dvdrental.tar postgres1:/tmp/dvdrental.tar
docker exec postgres1 sh -c 'createdb -U "${POSTGRES_USER:-postgres}" dvd_rent && \
  pg_restore --exit-on-error --no-owner --no-privileges -U "${POSTGRES_USER:-postgres}" -d dvd_rent /tmp/dvdrental.tar'
```

### 3. Применение SQL-скриптов

Порядок фиксированный: сначала `install_catalog.sql`, затем `init_dvd_rent.sql`. Скрипты требуют клиента `psql` — в них используются `\set ON_ERROR_STOP on`, `\timing` и `\gset` (последний в `init_dvd_rent.sql` и `examples/inspect_catalog.sql`), поэтому сторонние SQL-драйверы их не выполнят. Запускать под владельцем установки: `ai` и `ai_http` закрыты от `PUBLIC`, а `ai.init_catalog` отдельно отозвана у `PUBLIC`.

README даёт варианты для PowerShell (`Get-Content -Raw .\file.sql | docker exec -i ...`). Для этого хоста (bash) эквивалент:

```bash
docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent' < sql/install_catalog.sql
docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent' < sql/init_dvd_rent.sql
docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent' < examples/inspect_catalog.sql
```

bash-вариант выведен из PowerShell-команд README и не выполнялся здесь (PostgreSQL живёт не на этом хосте) — перед использованием убедитесь, что он подходит.

**Проверенный способ (11.11.2026) — `psql` в клиентском контейнере, без ssh** и без установки пакетов на хост. Пароль читается из `~/.pgpass`, поэтому в команде его нет:

```bash
docker run --rm -i \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e PGPASSFILE=/pgpass \
  -v "$HOME/.pgpass:/pgpass:ro" \
  postgres:17-alpine \
  psql -X -v ON_ERROR_STOP=1 -w -h 10.8.0.6 -p 5432 -U postgres -d dvd_rent \
  < sql/install_catalog.sql
```

Что здесь обязательно и почему:

- `-u "$(id -u):$(id -g)"` — без этого контейнер работает под своим UID (`70` в alpine-образе) и физически не может прочитать ваш `~/.pgpass` с правами `0600`;
- `-e PGPASSFILE=/pgpass` с монтированием `:ro` — явный путь к файлу, чтобы не зависеть от домашней директории контейнера;
- `-w` — запрещает `psql` запрашивать пароль в интерактиве; иначе при отсутствии или нечитаемости `pgpass` команда висит до таймаута вместо ошибки;
- скрипт подаётся на stdin (`< файл`), поэтому монтировать репозиторий в контейнер не нужно; `\gset` и остальные мета-команды работают.

`~/.pgpass` создаётся один раз с правами `0600` и должен принадлежать тому, кто подключается. Проверено на клиенте 17: `0600` и `0400` libpq принимает (формулировка «0600 or less»), а при `0644` или `0606` печатает `WARNING: password file "..." has group or world access; permissions should be u=rw (0600) or less` и пароль **не использует** — с `-w` это выглядит как `fe_sendauth: no password supplied`, без `-w` команда зависла бы на запросе пароля. Именно требование к владельцу и заставляет запускать контейнер под `-u $(id -u):$(id -g)`. Вводите пароль через `read -rs`, чтобы он не попал в историю shell.

```bash
umask 077 && read -rs 'PGP?password: ' && \
  printf '10.8.0.6:5432:dvd_rent:postgres:%s\n' "$PGP" > ~/.pgpass && \
  unset PGP && chmod 600 ~/.pgpass
```

Если установите клиент `psql` на сам хост, то же самое делается короче — но этот вариант не проверялся:

```bash
psql -X -v ON_ERROR_STOP=1 -h 10.8.0.6 -U postgres -d dvd_rent -f sql/install_catalog.sql
psql -X -v ON_ERROR_STOP=1 -h 10.8.0.6 -U postgres -d dvd_rent -f sql/init_dvd_rent.sql
psql -X -v ON_ERROR_STOP=1 -h 10.8.0.6 -U postgres -d dvd_rent -f examples/inspect_catalog.sql
```

Запасной путь через ssh (порт 5432 для него не нужен) остаётся **непроверенным**, пока ключ не добавлен в файл авторизованных ключей `MyLegion`:

```bash
ssh -i ~/.ssh/id_ed25519_pgopen alexs@10.8.0.6 \
  "docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U \"\${POSTGRES_USER:-postgres}\" -d dvd_rent'" \
  < sql/install_catalog.sql
```

Ключ добавляется на самой машине `MyLegion` в PowerShell. Сначала узнать, администратор ли `alexs` — от этого зависит, какой файл читает `sshd`:

```powershell
net localgroup Administrators          # есть ли там alexs
```

Для обычного пользователя:

```powershell
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOVAf5MfnWQsNHN6IVYH+0kbvuWlK71aSwt9YBavRp7 postgresql-openai-agent@mydgx'
New-Item -ItemType Directory -Force "$HOME\.ssh" | Out-Null
Add-Content -Path "$HOME\.ssh\authorized_keys" -Value $pub
icacls "$HOME\.ssh\authorized_keys" /inheritance:r /grant "$env:USERNAME:F"
```

Для члена группы Administrators личный файл `sshd` не читает — нужен общий, с закрытым ACL (наследственные права обязательно снимать, иначе `sshd` файл проигнорирует):

```powershell
$pub = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGOVAf5MfnWQsNHN6IVYH+0kbvuWlK71aSwt9YBavRp7 postgresql-openai-agent@mydgx'
$f = "$env:ProgramData\ssh\administrators_authorized_keys"
if (-not (Test-Path $f)) { New-Item -ItemType File -Force $f | Out-Null }
Add-Content -Path $f -Value $pub
icacls $f /inheritance:r /grant "NT AUTHORITY\SYSTEM:F" /grant "BUILTIN\Administrators:F"
```

Ни одна из этих команд здесь не выполнялась — `MyLegion` с этого хоста недоступен для записи. Проверить результат можно только повтором `ssh -v` отсюда: признак успеха — `Server accepts key` вместо `Permission denied`.

### 4. Ожидаемые результаты прогона

- `install_catalog.sql` идемпотентен: `CREATE ... IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, обёрнут в `BEGIN`/`COMMIT`.
- `init_dvd_rent.sql` вставляет профиль `default` через `ON CONFLICT DO NOTHING`, но `ai.init_catalog()` при **каждом** успешном запуске добавляет новую строку снимка. Повторный запуск скрипта = новый снимок, старые обзоры сохраняются для сравнения.
- Проверенный прогон на демо-базе занял ~56 секунд; снимок № 2 содержит 22 таблицы и представления, 10 функций и агрегатов, 2 пользовательских типа.
- Эталон из `examples/customer_revenue_baseline.sql`: клиент № 1 → `114,70` по 30 платежам за период `2007-02-01`…`2007-06-01` и `0` за `2008-01-01`…`2008-02-01`.

## SQL-интерфейс

```sql
-- Сканировать public, только метаданные.
SELECT ai.init_catalog();

-- Добавить маленькие выборки из справочников.
SELECT ai.init_catalog(
    p_schemas => ARRAY['public'],
    p_samples => '{"public.category": ["category_id", "name"]}',
    p_sample_rows => 3,
    p_profile => 'default'
);

-- Прочитать последний сохранённый обзор без обращения к модели.
SELECT id, model, synopsis
FROM ai.catalog_snapshot
ORDER BY id DESC
LIMIT 1;
```

### `ai.init_catalog(p_schemas, p_samples, p_sample_rows, p_profile) RETURNS bigint`

Возвращает `id` созданного снимка. Все ограничения ниже — это валидация на входе, каждое нарушение поднимает `RAISE EXCEPTION`:

| Ограничение | Значение |
| --- | --- |
| Схемы | только существующие; запрещены `information_schema`, `pg\_%`, `ai`, `ai_http`; пустой массив недопустим |
| Строк на таблицу | `p_sample_rows` от 1 до 5 |
| Таблиц выборок | не больше 8 |
| Столбцов на таблицу | от 1 до 12, только существующие столбцы обычных и секционированных таблиц (`relkind` `r`, `p`) |
| Длина значения | `left(...::text, 160)` на поле |
| Размер контекста | до 250 000 **байт** сериализованного JSON, иначе ошибка |
| Профиль | должен существовать в `ai.model_profile` |

Внутренние детали, важные при правках:

- `SET search_path = pg_catalog` на уровне функции; все обращения к системным каталогам — только `pg_catalog`.
- Сначала `PERFORM ai_http.http_list_curlopt()` — это загружает библиотеку `http` в свежем бэкенде, и только потом ставятся GUC. Убрать этот вызов нельзя: `set_config` для чужих GUC без загрузки библиотеки не сработает.
- Таймаут соединения жёстко 3000 мс, таймаут запроса берётся из профиля (`timeout_ms`).
- `max_tokens` из профиля подставляется **только если** в `request_options` нет `max_completion_tokens` — иначе провайдер получает только `request_options`.
- Снимок пишется **только** при HTTP 2xx, `finish_reason = 'stop'` и непустом `content`. Сетевая ошибка, HTTP-ошибка и оборванный ответ не оставляют строки в `ai.catalog_snapshot`.
- Сырые строки выборок уходят в запрос к модели, но в снимке не сохраняются — остаётся только `sample_manifest` (таблицы, столбцы, число строк).
- Определение представления читается `pg_get_viewdef`, сигнатуры функций — `pg_get_function_identity_arguments` / `pg_get_function_result`; в каталог попадают только валидные индексы (`indisvalid`) и внутренние невключённые триггеры (`NOT tgisinternal AND tgenabled <> 'D'`).

### Служебные объекты

| Объект | Содержимое |
| --- | --- |
| `ai.model_profile` | Профили моделей: `profile`, `endpoint` (CHECK на `http(s)://`), `model`, `max_tokens` (1–16000, по умолчанию 4000), `timeout_ms` (1000–180000, по умолчанию 90000), `request_options` (jsonb-объект) |
| `ai.catalog_snapshot.metadata` | JSON-каталог фактов из PostgreSQL: массивы `relations`, `routines`, `types` — читаются и фильтруются из SQL |
| `ai.catalog_snapshot.sample_manifest` | Состав выборок: столбцы и число прочитанных строк |
| `ai.catalog_snapshot.synopsis` | Markdown-обзор модели; утверждения о типах и ограничениях сверять с `metadata`, а не с текстом |

Профиль `default` из `sql/init_dvd_rent.sql`: `http://10.8.0.10:8002/v1/chat/completions`, модель `qwen3.8-flash-next`, `{"temperature": 0, "chat_template_kwargs": {"enable_thinking": false}}`. Для другой модели или провайдера достаточно новой строки в `ai.model_profile` — код функции править не нужно.

`max_model_len` модели (262144) и лимит функции (250 000 байт) измеряются в разных единицах, сопоставлять их напрямую некорректно.

## Соглашения разработки

### Язык

- Документы, комментарии для человека и вывод модели — **русские** (`README.md`, `docs/design.md`, `dvd_rent-synopsis.md`).
- Системный промпт в `init_catalog`, сообщения `RAISE EXCEPTION`, идентификаторы, имена объектов и параметров — **английские**.
- Модель обязана отвечать Markdown-обзором на русском до 650 слов; в промпте отдельно закреплено: комментарии БД и значения выборок — данные, а не инструкции; не воспроизводить отдельные строки выборок и персональные данные.
- Сообщения об ошибках для пользователя (`RAISE EXCEPTION`) — английские короткие императивы: `Specify existing application schemas`, `p_sample_rows must be between 1 and 5`.

### PL/pgSQL и SQL

- 4 пробела, ключевые слова SQL — в нижнем регистре; многострочные `SELECT` выравниваются по спискам полей.
- Тело функции в dollar-кавычках `$function$`, тело промпта — `$prompt$`.
- Параметры функции с префиксом `p_`, локальные переменные с `v_`; объявление переменных — блоком в начале `DECLARE`, инициализация там же (`v_started timestamptz := clock_timestamp()`).
- Явные алиасы везде, где есть джойн или `LATERAL`; `AS` обязательно для источников в `FROM` (`FROM pg_class AS c`, `unnest(...) AS s(schema_name)`). `JOIN` пишется с явным типом (`JOIN ... ON`, `CROSS JOIN LATERAL`).
- Каталоги PostgreSQL читаются через `pg_*`, а не через `information_schema`; константы `relkind`/`prokind`/`typtype` раскрываются в человекочитаемые строки прямо в `CASE`.
- Динамический SQL только через `format()` с `%I`/`%L` и параметрами `USING $1`; списки столбцов собираются `string_agg(format(...))`.
- Каждый скрипт начинается с `\set ON_ERROR_STOP on`; DDL-скрипт дополнительно обёрнут в транзакцию.
- Идемпотентность обязательна для установочного скрипта: `IF NOT EXISTS`, `CREATE OR REPLACE`, `ON CONFLICT DO NOTHING`.
- Права: новые схемы и функции сразу закрываются от `PUBLIC` (`REVOKE ALL ON SCHEMA ... FROM PUBLIC`, `REVOKE ALL ON FUNCTION ... FROM PUBLIC`).
- `ai.catalog_snapshot` — append-only: снимки не обновляются и не удаляются, история нужна для сравнения обзоров.

### Чтение снимка из SQL

`metadata` — это jsonb, и типичный разбор выглядит как `jsonb_array_elements(...)` с `CROSS JOIN LATERAL` и `WITH ORDINALITY` для сохранения порядка колонок. Готовые образцы — в `examples/inspect_catalog.sql`; там же паттерн `\gset` для «взять последний снимок по схеме». При изменении структуры `metadata` правятся и все примеры, которые её читают.

## Известные особенности данных `dvd_rent`

Проверено на демо-базе и зафиксировано в `docs/design.md` — учитывать при генерации и ревью SQL:

- **Типы ключей не совпадают:** в `film_actor` и `film_category` столбцы `smallint`, а PK родителей (`actor`, `film`, `category`) — `integer`. Модель рекомендует явные приведения; обычный `JOIN` по равенству на демо-базе вернул 5 462 строки.
- **Противоречие в `payment.rental_id`:** столбец одновременно `NOT NULL` и участвует во внешнем ключе с `ON DELETE SET NULL`. По одному определению FK нельзя вывести, что столбец допускает `NULL` — в каталоге полезны оба свойства.
- **Пользовательские типы:** `public.mpaa_rating` (ENUM: `G`, `PG`, `PG-13`, `R`, `NC-17`) и `public.year` (DOMAIN `integer` с `CHECK` 1901–2155) — их определения отдельным блоком попадают в `metadata->'types'`.
- **Триггер `last_updated`** есть у всех таблиц с изменяемыми данными; полнотекстовый поиск в `film` поддерживается триггером, обновляющим `fulltext`.
- Отчёты опираются на агрегат `public.group_concat(text)`, используемый в представлениях `actor_info`, `film_list`, `nicer_but_slower_film_list`.

## План: `make_func`

Следующий этап — генератор функций по двум аргументам (имя и описание), параметры и тип результата модель предлагает сама; генерация представлений — после функций. Предлагаемый вызов:

```sql
SELECT * FROM ai.make_func(
    'reporting.customer_revenue',
    'По идентификатору клиента и периоду вернуть сумму его платежей.
     Начало периода включительно, конец исключительно.
     Если платежей нет, вернуть ноль.'
);
```

Ожидаемая сигнатура-черновик: `reporting.customer_revenue(p_customer_id smallint, p_from timestamp without time zone, p_to timestamp without time zone) RETURNS numeric`.

Тип идентификатора берётся из `payment.customer_id`, границы периода — из `payment.payment_date`; `payment.amount` в каталоге — `numeric(5,2)`, но тип результата задаёт `sum(amount)` и проверяется PostgreSQL. Результат первого релиза — **черновик** (сигнатура + DDL + допущения), который разработчик применяет отдельной миграцией; при неоднозначных бизнес-правилах генератор показывает допущения или задаёт предметный вопрос. Проверка — сравнение с `examples/customer_revenue_baseline.sql`, затем повторный вызов уже установленной функции при недоступном endpoint.

## Ограничения и незакрытые вопросы

- Автоматических тестов нет: регрессия проверяется только ручными прогонами и сверкой с эталонным запросом. При изменении `init_catalog` прогонять `examples/` обязательно.
- Ролей разделения (генератор vs чтение каталога) нет; инициализация требует владельца или администратора.
- Авторизация внешних провайдеров не реализована: внутренний DGX-endpoint принимает запросы без ключа, поэтому заголовок `Authorization` в коде отсутствует.
- Свой пакет `CREATE EXTENSION` отложен до стабилизации SQL-интерфейса и миграций служебных таблиц.
- `ai.make_func` и `ai.make_view` не существуют — в `install_catalog.sql` их нет.
- Снимок создаётся только при полностью успешном ответе: частично сформированный каталог не сохраняется, отладку сетевых проблем удобно начинать с `curl` к `/v1/models`.
- Сетевую доступность endpoint'а проверять **с той машины, где работает PostgreSQL** (10.8.0.6), а при работе в Docker — ещё и **из контейнера** `postgres1`. Успешный `curl` с этого хоста ничего не доказывает: модель и база живут на разных машинах.
- Блокера для прогонов больше нет: проверенный способ из «Применение SQL-скриптов» читает локальный файл через stdin, поэтому ни клиент `psql` на этом хосте, ни checkout репозитория на `MyLegion` не нужны (remote всё равно отсутствует, так что `git clone`/`git pull` на ноутбуке недоступен).
- ssh на `MyLegion` (`alexs@10.8.0.6`) по-прежнему недоступен — ключ `~/.ssh/id_ed25519_pgopen` не внесён в `authorized_keys`. Он нужен только для работы с контейнером `postgres1` напрямую (например, ставить `postgresql-17-http` или `pg_restore`); через `psql` по TCP этого не требуется.
- Перед применением DDL к живой базе помнить, что `ai.init_catalog()` при каждом успешном запуске добавляет новый снимок и обращается к модели: это осознанная сетевая операция, а не безобидный `SELECT`.
