# QWEN.md — контекст проекта для агента

## Обзор проекта

**PostgreSQL OpenAI** — пет-проект для генерации SQL-функций и представлений по текстовому описанию. PostgreSQL сам собирает каталог своей схемы, OpenAI-совместимая модель составляет по нему обзор предметной области для разработчика, а `ai.make_func` и `ai.make_view` возвращают сигнатуру и DDL обычной SQL-функции или представления по заданию и каталогу.

Ключевой архитектурный принцип: **модель вызывается только на этапе подготовки SQL**. Применённый DDL создаёт обычную функцию или представление PostgreSQL, которое работает без обращения к модели. Снятый каталог переиспользуется между заданиями, поэтому повторные вызовы модели — это осознанная, а не случайная операция.

- **Язык интерфейса** — SQL. Точки входа: `ai.init_catalog()`, `ai.make_func()`, `ai.make_view()`, `ai.review_function()`, `llm()`, `ai.register_model_profile()`.
- **Стек:** PostgreSQL 17, PL/pgSQL, расширение `http` (pgsql-http) как транспорт JSON/HTTP, OpenAI-совместимый `/v1/chat/completions`.
- **Демо-данные:** классическая база `dvdrental` (`examples/dvd_rent/dvdrental.tar`) в базе `dvd_rent`.
- **Модель:** `qwen3.8-flash-next` (vLLM, `max_model_len: 262144`) на этом хосте.
- **Стадия:** прототип с полным циклом генерации. Работают каталог по схемам, чат с навыками и историей, генерация функций и представлений с отдельным LLM-ревью, история запусков. Собственного пакета `CREATE EXTENSION`, ролей разделения и авторизации внешних провайдеров нет.

### Структура репозитория

| Файл | Назначение |
| --- | --- |
| [docs/design.md](docs/design.md) | Исходная постановка, устройство каталога, генерация, навыки, ревью, история, контракт отчёта, отбор контекста, представления |
| [sql/install_catalog.sql](sql/install_catalog.sql) | Единственный установщик **и мигратор**: схемы `ai`/`ai_http`, служебные таблицы, все функции `ai.*` и обёртка `public.llm` |
| [README.md](README.md) | Пользовательский SQL-интерфейс: установка, профили, GUC, `make_func`, `make_view`, ревью, чат, навыки, `GRANT` рабочей роли |
| [examples/llm_chat.sql](examples/llm_chat.sql) | Общие примеры `llm()`: один вопрос и многоходовый разговор через `p_history` |
| [examples/dvd_rent/README.md](examples/dvd_rent/README.md) | Сценарий демобазы: установка, снимок, навык, проверка результата с эталоном |
| [examples/dvd_rent/init_dvd_rent.sql](examples/dvd_rent/init_dvd_rent.sql) | Профиль `default` + снимок `public` с выборками (`\gset` возвращает `id`) |
| [examples/dvd_rent/install_dvd_rent_skills.sql](examples/dvd_rent/install_dvd_rent_skills.sql) | Предметный навык `rental-revenue@1` и его привязки в `ai.skill_binding` |
| [examples/dvd_rent/inspect_catalog.sql](examples/dvd_rent/inspect_catalog.sql) | Чтение снимка по схеме: колонок и ограничений `payment`, состав выборок |
| [examples/dvd_rent/make_func_customer_revenue.sql](examples/dvd_rent/make_func_customer_revenue.sql) | Генерация `reporting.customer_revenue` в транзакции |
| [examples/dvd_rent/make_view_monthly_film_revenue.sql](examples/dvd_rent/make_view_monthly_film_revenue.sql) | Генерация `reporting.monthly_film_revenue` + `DO`-сверка с эталоном через `EXCEPT ALL` |
| [examples/dvd_rent/customer_revenue_baseline.sql](examples/dvd_rent/customer_revenue_baseline.sql) | Эталонный запрос-ожидание для проверки генерации |
| [examples/dvd_rent/dvd_rent-synopsis.md](examples/dvd_rent/dvd_rent-synopsis.md) | Сохранённый обзор базы, возвращённый моделью |
| `examples/dvd_rent/dvdrental.tar` | Исходный архив демо-базы для `pg_restore` (бинарный, не редактировать) |

## Состояние окружения (проверено 14–15.11.2026)

Проверялось прямыми командами на этом хосте (Linux, bash). Это актуальное состояние, а не описание из README.

- **PostgreSQL теперь на Synology NAS `192.168.1.68:5433`** (сообщено пользователем 14.11.2026, подтверждено подключением в тот же день). Проверено запросом к серверу: `PostgreSQL 17.12 on aarch64-unknown-linux-gnu (GCC 8.5.0)`, `data_directory = /volume1/@appdata/postgresql/data`, `config_file` и `hba_file` там же, `listen_addresses = *`, `port = 5433`, `max_connections = 100`, superuser-роли `postgres` и `sc-postgresql`. Путь `/volume1/@appdata/` плюс роль `sc-postgresql` — это пакет **PostgreSQL из Package Center на DSM** (Synology, ARM/aarch64), а не Debian-контейнер и не нативная установка на «обычной» машине.
- **Соединение есть, но аутентификация пока без пароля.** После того как пользователь 14.11.2026 добавил правило в `pg_hba.conf`, `psql -w -U postgres -h 192.168.1.68 -p 5433 -d postgres` подключился, не запрашивая пароль, хотя в `~/.pgpass` строк для `.68` нет — то есть для `10.8.0.10` стоит `trust`. С `listen_addresses = *` это означает superuser без пароля для любого, кто дотянется до сервера. Для отладки удобно, но как постоянное состояние — нет; при переходе на `scram-sha-256` понадобится строка учётки (см. «Применение SQL-скриптов»).
- **Живого правила в `pg_hba.conf` раньше не было, и это выглядело так:** `FATAL: no pg_hba.conf entry for host "10.8.0.10", user "postgres", database "postgres", no encryption` — одинаково из контейнера с NAT и с `--network host` (14.11.2026). Источник не менялся, потому что адрес выглядит LAN-ным, а трафик идёт через туннель: `ip route get 192.168.1.68` → `via 10.8.0.9 dev tun8 src 10.8.0.10`. Сервер авторизует не адрес из `-h`, а адрес пришедшего пакета, поэтому правило нужно на `10.8.0.10/32`, а не на `192.168.1.70/32`.
- **Старый адрес `10.8.0.6:5432` закрыт (14.11.2026):** прежний сервер больше не отвечает. Всё, что ниже в разделе «Прежний хост», — история, а не рабочее состояние.
- **Проект на NAS развёрнут и работает 14.11.2026.** База `dvd_rent` создана и заполнена из `examples/dvd_rent/dvdrental.tar` (проверено: `payment` = 14 596 строк, `customer` = 599), `sql/install_catalog.sql` прошёл до `COMMIT`. Проверено запросом к серверу: схемы `ai`, `ai_http`, `reporting`; в `ai` — 5 таблиц (`catalog_snapshot`, `function_generation`, `model_profile`, `skill`, `skill_binding`) и 12 функций; `ai.skill` — 4 навыка (`rental-revenue@1`, `review-function@1`, `supabase-postgres-best-practices@1`, `use-snapshot@1`), `ai.skill_binding` — 4 привязки, `ai.model_profile` — 1 профиль (`default`). В `ai.function_generation` 2 записи: `function:customer_revenue`, `view:monthly_film_revenue`. Рабочий цикл (снимок → генерация → ревью → эталон) прогнан целиком, числа — в п. 4.
- **Расширение `http` на сервере установлено**, `pg_available_extensions` — 9 позиций (`cube`, `earthdistance`, `http`, `pg_trgm`, `plpgsql`, `postgis`, `unaccent`, `uuid-ossp`, `vector`); это именно *доступные* расширения — control-файлы удалённых `postgis` и `vector` остались в каталоге пакета. В `pg_extension` базы `dvd_rent` реально установлены `http` плюс унаследованные от `template1` `cube`, `earthdistance`, `pg_trgm`, `plpgsql`, `unaccent`, `uuid-ossp`. До установки (14.11.2026, утром) установщик падал на транспорте и откатывался целиком:

  ```text
  ERROR:  extension "http" is not available
  DETAIL:  Could not open extension control file "/volume1/@appstore/postgresql/share/extension/http.control": No such file or directory.
  ```

  Путь из `DETAIL` раскрывает раскладку пакета: `/volume1/@appstore/postgresql/` (там же `bin/`, `share/extension/`). Как именно поставили готовый arm64-бинарник — в п. 1.
- **PostGIS удалён из кластера 14.11.2026** по указанию пользователя: `DROP EXTENSION postgis CASCADE` в `template1`, `postgres` и `dvd_rent`; перед удалением проверено, что объектов с `geometry`/`geography` нет ни в одной из трёх баз, зависимых объектов — 0. Он был установлен в `template1`, поэтому каждая новая база получала `spatial_ref_sys`, `geometry_columns` и `geography_columns`, и `ai.init_catalog('public')` отправлял модели эти служебные объекты вместо предметной области. После удаления снимок `public` в `dvd_rent`: **22 отношения, 223 функции, 3 типа, 64 834 байта метаданных, 46.3 с** — против 25 / 1032 / 202 682 байт / 59.3 с до удаления (типов было тоже три: `earth` принадлежит `earthdistance` и никуда не делся). Заземлённый чат по этому снимку (`public.llm` с вопросом про связи `public.payment`): **18 125 токенов / 8 663 мс** против 56 026 / 25 432. Двоичные файлы пакета на месте, `CREATE EXTENSION postgis` по-прежнему возможен в отдельной базе.
- **Из `template1` убран и `vector` (pgvector) — 15.11.2026** по решению пользователя, тем же способом (`DROP EXTENSION vector CASCADE` в `template1`, `postgres`, `dvd_rent`; колонок `vector`/`halfvec`/`sparsevec` и индексов `ivfflat`/`hnsw` не было). Это самый большой источник шума по объёму: функций `public` стало **94** в `template1`/`postgres` и **105** в `dvd_rent` против 212 / 212 / 223 с `vector`. Снимок `public` после этого: **22 отношения, 105 функций, 3 типа, 44 263 байта `metadata`, ~7.4 КБ `synopsis`, 36.0 с**; заземлённый чат по нему — **12 582 токена / 6 254 мс**. Итог двух зачисток относительно состояния до них: метаданные 202 682 → 44 263 байта, функции 1032 → 105, токенезатраты чата 56 026 → 12 582.
- **Остаточный шум в каталоге:** из `template1` в `dvd_rent` по-прежнему наследуются `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp` — 94 функции `public` и домен `earth` (он принадлежит `earthdistance`). Удалять их не запрашивалось; при разборе снимка, отборе контекста и ревью объекты расширений надо отделять от предметной области проката — к ней относятся только 11 функций `dvdrental` (в том числе агрегат `group_concat`) и 22 отношения.
- **Риск обновления пакета DSM:** `http.so`, `http.control` и SQL-скрипты `http--*.sql` скопированы в каталог пакета вручную, а не через менеджер пакетов. Обновление PostgreSQL из Package Center перезаписывает `/volume1/@appstore/postgresql/`, и расширение исчезнет — `CREATE EXTENSION http` снова станет недоступен. Проверять после любого обновления: `select name, default_version from pg_available_extensions where name = 'http';`.
- **SSH на NAS — на нестандартном порту `4222`, а не 22.** Порт 22 закрыт; `4222` открыт и это действительно SSH: `Remote protocol version 2.0, remote software version OpenSSH_8.2` (проверено 14.11.2026). Вывод «SSH закрыт», полученный с 22-го порта, был ошибкой. Путь на сервер проверен на деле: файлы расширения положены в `/volume1/@appstore/postgresql/` именно по SSH (как — в п. 1). Что в DSM при этом не работает, так это штатная передача файлов: `scp` обрывается с `Connection closed`, `sftp` не пускает (`Permission denied (publickey,password)`), а из диагностических утилит нет `ldd`, `readelf`, `objdump` и `file`. Поэтому содержимое переносится архивом по stdin самого `ssh -T` (см. п. 1), а проверка `.so` делается на этом хосте. Для привилегированных команд — `sudo -S`, пароль подаётся на stdin удалённой команды. Учётные данные нигде не сохраняются (ни в файлы репозитория, ни в память агента, ни в `~/.ssh`); перебирать их нельзя: в DSM включён auto-block неудачных входов. Веб-интерфейс DSM — на `5000`/`5001`.
- **LLM endpoint — на этом хосте:** `http://127.0.0.1:8002/v1/models` отвечает `200` (перепроверено 14.11.2026) и отдаёт единственную модель `qwen3.8-flash-next` (vLLM, `nvidia/Qwen3.8-Flash-Next-FP4-Local`). Его обслуживает запущенный контейнер `qwen38-fp4local` с `NetworkMode=host`; сервер слушает `0.0.0.0:8002`, поэтому адрес `10.8.0.10:8002` для внешних машин корректен.
- **Достижимость модели с NAS подтверждена 14.11.2026.** Профиль `default` указывает на `http://10.8.0.10:8002/v1/chat/completions`, и с сервера базы этот endpoint отвечает: `ai_http.http_get` вернул HTTP 200 со списком моделей, а `ai.init_catalog` и обе генерации получили от модели полноценный ответ (иначе ни снимка, ни объектов в `ai.function_generation` не было бы — снимок пишется только при 2xx и `finish_reason = 'stop'`). Менять адрес на LAN (`192.168.1.70:8002`) не нужно: путь до `.68` идёт через туннель, а не по LAN, и текущий адрес работает.
- **На этом хосте нет сервера PostgreSQL:** хостовых `psql`, `pg_restore`, `createdb` нет, контейнера с сервером нет. 11.11.2026 подтянут только **клиентский** образ `postgres:17-alpine` — он нужен для `psql` из контейнера, сервером он не является.
- **Топология сети:** этот хост — `mydgx`. `10.8.0.10` принадлежит туннельному интерфейсу `tun8` (peer `10.8.0.9`), LAN-адрес — `192.168.1.70`. Соседние адреса `10.8.0.0/24` — отдельные машины; маршрут к ним идёт через `10.8.0.9 dev tun8`. Привычка «всё делать напрямую, без ssh» из других проектов этого пользователя к чужим хостам неприменима.
- **Git:** одна ветка `main`, **удалённого репозитория нет** (`git remote -v` пуст) — push невозможен без добавления remote. Число коммитов и HEAD здесь не перечисляются: смотреть `git log`.

### Прежний хост `10.8.0.6` (MyLegion) — справка, не рабочее состояние

До 14.11.2026 сервер PostgreSQL работал на ноутбуке `MyLegion` под Windows (пользователь `alexs`), контейнер `postgres1`, образ Debian с `PostgreSQL 17.10 (Debian 17.10-1.pgdg12+1)`, база `dvd_rent`, порт 5432. Команды `docker exec postgres1 ...` из `README.md` и `examples/dvd_rent/README.md` относятся именно к тому хосту и там, и здесь сейчас нерабочи.

Доступ по ssh к нему так и не был настроен: порт 22 открыт, `ssh -o BatchMode=yes alexs@10.8.0.6` → `Permission denied (publickey,password,keyboard-interactive)`. Приватных половин ключей на этом хосте нет (в `~/.ssh` только `.pub`, агент не запущен, `sshpass` не установлен), созданный 11.11.2026 ключ `~/.ssh/id_ed25519_pgopen` сервер отклоняет. Сервер — `OpenSSH_for_Windows_9.5`, поэтому файл авторизованных ключей **не** `~/.ssh/authorized_keys`, а `C:\Users\alexs\.ssh\authorized_keys`; для члена группы Administrators sshd читает только `C:\ProgramData\ssh\administrators_authorized_keys` и личный файл игнорирует. Команды добавления ключа в PowerShell — в истории коммитов `QWEN.md`; пригодятся, если `MyLegion` снова станет сервером БД.

## Сборка, запуск, проверка

Автоматических тестов, `Makefile`, `package.json` и CI в репозитории **нет**. Проверка — ручные прогоны SQL-скриптов в `psql` и сверка с эталонными запросами.

### 1. Транспорт `http` на сервере PostgreSQL (выполнено на NAS 14.11.2026 — расширение установлено, `ai._complete` работает)

Единственный транспорт проекта — расширение `http` (pgsql-http). Без него `sql/install_catalog.sql` не проходит (`CREATE EXTENSION http` → ошибка отсутствия control-файла) и ни `ai.init_catalog`, ни `llm`, ни `make_func` не работают, то есть развёртывание упирается не в SQL репозитория, а в установку расширения. На NAS его поставили 14.11.2026 **готовым arm64-бинарником, без компилятора** — так и стоит делать на этом сервере; варианты ниже остались как запасные.

- **Взять готовый arm64-бинарник PGDG — собирать не нужно** (этот путь и был реализован). Настоящий источник — `https://github.com/pramsey/pgsql-http`, в репозитории PGDG есть `postgresql-17-http` для arm64 (проверено 14.11.2026: `1.7.2-2.pgdg12+2`, SHA-256 `fcca764d…` сверен с индексом). Из .deb нужны три вида файлов, раскладываются по каталогу пакета DSM: `usr/lib/postgresql/17/lib/http.so` → `/volume1/@appstore/postgresql/lib/`, а `http.control` и `http--1.7.sql` (плюс скрипты переходов `1.0--1.1` … `1.6--1.7`) → `/volume1/@appstore/postgresql/share/extension/`. Положены файлы от `root:root` с правами `644`, после чего `CREATE EXTENSION http` в базе `dvd_rent` прошёл успешно.
  Совместимость проверена до переноса, на этом хосте (в DSM нет ни `ldd`, ни `readelf`): `NEEDED` = `libcurl.so.4`, `libc.so.6`, `ld-linux-aarch64.so.1`; максимальная требуемая версия символа — `GLIBC_2.17` (базовый минимум aarch64), то есть возраст glibc в DSM не мешает, а локальная сборка на Ubuntu 24.04 (glibc 2.39) была бы строго хуже — «собери на DGX» проигрывает готовому пакету PGDG именно поэтому. `http.control` не задаёт ни `schema`, ни `relocatable`, поэтому `CREATE EXTENSION http WITH SCHEMA ai_http` из установщика легален.
  **Доставка файлов в DSM.** `scp` обрывается (`Connection closed`), `sftp` не авторизуется, SSH — на порту `4222`. Рабочий способ — архив по stdin самого `ssh -T`, привилегированная раскладка через `sudo -S` с паролем на stdin удалённой команды:

  ```bash
  (cd /tmp/qwen_stage && tar cf - .) | \
    ssh -p 4222 -T -o StrictHostKeyChecking=accept-new <логин-dsm>@192.168.1.68 'tar xf - -C /tmp/qwen_http'
  ```

  Файлы в `/tmp` DSM раскладываются от обычного пользователя, а в каталог пакета их ставит уже `sudo -S`. Пароль при этом не попадает ни в файл, ни в историю: скрипт-спросчик печатает его из переменных окружения (`SSH_ASKPASS` + `SSH_ASKPASS_REQUIRE=force` + `setsid`), а не из своего содержимого.
- **Собрать pgsql-http под пакет DSM** — запасной вариант, если бинарник PGDG не заведётся. Пакет PostgreSQL на Synology не даёт ни `apt`, ни компилятора, ни `pg_config` в PATH; нужен доступ по SSH в DSM и сборка из исходников против `pg_config` этого пакета (`/volume1/@appstore/postgresql/bin/pg_config`). Сборка на этом хосте не годится из-за glibc (см. выше).
- **Вернуть базу туда, где `http` ставится штатно.** На прежнем Debian-контейнере это был пакет PGDG; порядок — сначала план, потом установка (зависимости добавлялись без обновления самого PostgreSQL):

  ```bash
  docker exec postgres1 apt-get -s install --no-install-recommends --no-upgrade postgresql-17-http
  docker exec postgres1 apt-get -y install --no-install-recommends --no-upgrade postgresql-17-http
  ```

- **Поднять сервер в контейнере на этом хосте** (`postgres:17` + `postgresql-17-http`) — самый короткий путь к рабочему циклу генерации, но это вторая, пустая база отдельно от данных на NAS. Годится как осознанный выбор для отладки, не как замена серверу.

### 2. Восстановление демо-базы (выполнено на NAS 14.11.2026 — база `dvd_rent` создана и заполнена)

Клиентский образ `postgres:17-alpine` содержит `psql`, `pg_dump`, `createdb` и `pg_restore` (проверено 14.11.2026), поэтому архив восстанавливается **удалённо**, без доступа к файловой системе сервера:

```bash
docker run --rm -i \
  -u "$(id -u):$(id -g)" -e HOME=/tmp -e PGPASSFILE=/pgpass \
  -v "$HOME/.pgpass:/pgpass:ro" \
  -v "$PWD/examples/dvd_rent/dvdrental.tar:/tmp/dvdrental.tar:ro" \
  postgres:17-alpine sh -c \
  'createdb -w -h 192.168.1.68 -p 5433 -U postgres dvd_rent && \
   pg_restore -w -h 192.168.1.68 -p 5433 -U postgres \
     --exit-on-error --no-owner --no-privileges -d dvd_rent /tmp/dvdrental.tar'
```

Команда выше выполнена 14.11.2026 и вернула пустой вывод с кодом 0 (ни ошибок, ни предупреждений); содержимое проверено после прогона. Прежний вариант через `docker cp` + `docker exec postgres1` относится к закрытому хосту `10.8.0.6`. Офлайн-разбор архива по `toc.dat` даёт 15 таблиц, 7 представлений, 2 типа и 13 последовательностей — это и есть объекты `dvdrental`, и ровно 22 отношения (15 + 7) лежат в живой схеме `public` после удаления PostGIS. До удаления к ним добавлялись унаследованные из `template1` `spatial_ref_sys`, `geometry_columns` и `geography_columns` — их и убрал `DROP EXTENSION postgis`; домен `earth` остался, он принадлежит `earthdistance`.

### 3. Применение SQL-скриптов

Порядок фиксированный: `sql/install_catalog.sql` → `examples/dvd_rent/init_dvd_rent.sql` → `examples/dvd_rent/install_dvd_rent_skills.sql` → генераторы. Скрипты требуют клиента `psql` — в них используются `\set ON_ERROR_STOP on`, `\timing`, `\x` и `\gset` (`init_dvd_rent.sql`, `inspect_catalog.sql`), поэтому сторонние SQL-драйверы их не выполнят. Запускать под владельцем установки: `ai` и `ai_http` закрыты от `PUBLIC`, все функции `ai.*` и `public.llm` отдельно отозваны у `PUBLIC`.

**Проверенный способ (11.11.2026) — `psql` в клиентском контейнере, без ssh** и без установки пакетов на хост. Пароль читается из `~/.pgpass`, поэтому в команде его нет:

```bash
docker run --rm -i \
  -u "$(id -u):$(id -g)" \
  -e HOME=/tmp -e PGPASSFILE=/pgpass \
  -v "$HOME/.pgpass:/pgpass:ro" \
  postgres:17-alpine \
  psql -X -v ON_ERROR_STOP=1 -w -h 192.168.1.68 -p 5433 -U postgres -d dvd_rent \
  < sql/install_catalog.sql
```

Здесь `-h`/`-p` — адрес актуального сервера; при переезде базы меняются только они. Что обязательно и почему:

- `-u "$(id -u):$(id -g)"` — без этого контейнер работает под своим UID (`70` в alpine-образе) и физически не может прочитать ваш `~/.pgpass` с правами `0600`;
- `-e PGPASSFILE=/pgpass` с монтированием `:ro` — явный путь к файлу, чтобы не зависеть от домашней директории контейнера;
- `-w` — запрещает `psql` запрашивать пароль в интерактиве; иначе при отсутствии или нечитаемости `pgpass` команда висит до таймаута вместо ошибки;
- скрипт подаётся на stdin (`< файл`), поэтому монтировать репозиторий в контейнер не нужно; `\gset` и остальные мета-команды работают.

Пока сервер пускает `10.8.0.10` по `trust`, `~/.pgpass` в подключении не участвует — команда с `-w` проходит и без строки для `192.168.1.68`. Строка учётки станет обязательна при переходе на `scram-sha-256`.

`~/.pgpass` создаётся один раз с правами `0600` и должен принадлежать тому, кто подключается. Проверено на клиенте 17: `0600` и `0400` libpq принимает (формулировка «0600 or less»), а при `0644` или `0606` печатает `WARNING: password file "..." has group or world access; permissions should be u=rw (0600) or less` и пароль **не использует**. Именно требование к владельцу и заставляет запускать контейнер под `-u $(id -u):$(id -g)`. Вводите пароль через `read -rs`, чтобы он не попал в историю shell и не появился в чате; строка привязана к хосту и порту, поэтому при смене адреса нужна новая строка:

```bash
umask 077 && read -rs 'PGP?password: ' && \
  printf '192.168.1.68:5433:dvd_rent:postgres:%s\n' "$PGP" >> ~/.pgpass && \
  unset PGP && chmod 600 ~/.pgpass
```

Если установите клиент `psql` на сам хост, то же самое делается короче через `-f` — но этот вариант не проверялся. Варианты README для PowerShell (`Get-Content -Raw .\file.sql | docker exec -i postgres1 ...`) описывают прежний хост с контейнером `postgres1`.

### 4. Результаты прогона на NAS (подтверждено 14.11.2026)

Все скрипты репозитория применены к базе `dvd_rent` на `192.168.1.68:5433` в указанном порядке, результат проверен запросами к серверу.

- `sql/install_catalog.sql` прошёл до `COMMIT` и подтвердил идемпотентность: `CREATE ... IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`, `ON CONFLICT DO NOTHING`, обёртка `BEGIN`/`COMMIT`; он же выполняет миграции (см. «Миграции» в «Соглашениях»). Повторный прогон безопасен.
- `init_dvd_rent.sql` вставил профиль `default` (`ON CONFLICT (profile) DO NOTHING`) и создал снимок `public`; повторный запуск после удаления PostGIS **обновил ту же запись** (`schema_name` уникален, `id` сохранился: `id = 1`, `captured_at` передвинулось) — это не append-only.
- Замеренный снимок `public` (после зачистки PostGIS и `vector`): **22 отношения, 105 функций и агрегатов, 3 типа, 44 263 байта `metadata`, ~7.4 КБ `synopsis`, 36.0 с** прогона. Путь к этим числам: было 25 / 1032 / 202 682 байт и 59.3 с; удаление PostGIS дало 22 / 223 / 64 834 байта и 46.3 с; удаление `vector` — текущие 105 функций и 44 263 байта. Типы в снимке: `mpaa_rating`, `year` и `earth` (домен из `earthdistance`).
- `install_dvd_rent_skills.sql` добавил `rental-revenue@1` и 4 привязки (`INSERT 0 1`, `INSERT 0 4`).
- `make_func_customer_revenue.sql` создал `reporting.customer_revenue`; **сверка с эталоном из `customer_revenue_baseline.sql` совпала целиком:** клиент № 1 → `114.70` за `2007-02-01`…`2007-06-01` и `0` за `2008-01-01`…`2008-02-01` (эталонные `114,70` по 30 платежам и `0`). Ревью черновик пропустило.
- `make_view_monthly_film_revenue.sql` создал `reporting.monthly_film_revenue`, его `DO`-сверка с эталоном через `EXCEPT ALL` в обе стороны прошла (иначе — `Monthly film revenue differs from the reference query`); всего в представлении **2957 строк**. Помесячный отчёт требует учёта повторов: одна пара «название, сумма» встречается несколько раз.
- Обе генерации записаны в `ai.function_generation` (`function:customer_revenue`, `view:monthly_film_revenue`).
- Сгенерированный DDL (как ориентир ожидаемого качества): функция — `LANGUAGE sql SECURITY INVOKER SET search_path = pg_catalog` с `COALESCE(SUM(p.amount), 0)` и полуоткрытым периодом `>= / <` по `payment.payment_date`; представление — `CREATE VIEW ... WITH (security_invoker = true)` с цепочкой `payment → rental → inventory → film`.

## SQL-интерфейс

```sql
-- Сканировать одну схему, только метаданные.
SELECT ai.init_catalog();

-- Добавить маленькие выборки из справочников.
SELECT ai.init_catalog(
    p_schema => 'public',
    p_samples => '{"public.category": ["category_id", "name"]}',
    p_sample_rows => 3,
    p_profile => 'default'
);

-- Прочитать сохранённый обзор без обращения к модели.
SELECT id, model, synopsis
FROM ai.catalog_snapshot
WHERE schema_name = 'public';

-- Спросить модель напрямую, без каталога.
SELECT * FROM llm('Отвечай на русском кратко.', 'Что делает VACUUM?');

-- Сгенерировать функцию и представление (профиль — из сессии).
SET ai.model_profile = 'default';
CREATE SCHEMA IF NOT EXISTS reporting;
SELECT * FROM ai.make_func('reporting.row_count',
    'Верни число строк в public.your_table. Входных параметров нет.');
SELECT * FROM ai.make_view('reporting.monthly_film_revenue', '<описание>');
```

### Профили и настройки сессии

Профиль выбирается в порядке `p_profile` → `SET ai.model_profile` → `default` (`ai._get_model_profile`). Явный аргумент есть у `ai.llm`, `public.llm`, `ai.init_catalog` и `ai.review_function`; `ai.make_func` и `ai.make_view` берут профиль сессии.

| GUC | Значение |
| --- | --- |
| `ai.model_profile` | профиль генератора и чата для сессии |
| `ai.reviewer_profile` | профиль отдельного LLM-ревьюера; пусто — профиль генератора |
| `ai.enable_thinking` | `true`/`false`; уходит в `chat_template_kwargs.enable_thinking`, только если GUC задан или в профиле уже есть `chat_template_kwargs` |
| `ai.reasoning_effort` | `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max`; не задан — поле не отправляется, явно заданный `none` отправляется |
| `ai.function_catalog_mode` | `full` (по умолчанию) или `focused` — отбор отношений в контекст генерации |

`ai.register_model_profile(p_base_url, p_profile NULL)` читает `/v1/models` (таймауты 3000/10000 мс), требует ровно одну модель и адрес, оканчивающийся на `/v1`, пишет `model` и `endpoint = base || '/chat/completions'`, добавляет `{"chat_template_kwargs": {}}` если провайдер вернул `max_model_len`, и обновляет существующий профиль по имени, сохраняя лимиты и `request_options`. Ошибки: `Provide an HTTP(S) base URL ending in /v1`, `Provide a non-empty profile name or omit it`, `Model discovery requires exactly one model, endpoint advertises %`.

### `ai.init_catalog(p_schema, p_samples, p_sample_rows, p_profile) RETURNS bigint`

Сканирует **одну схему текущей базы**; для нескольких схем вызывают отдельно, для другой базы — подключаются к ней. Возвращает `id` записи снимка. Валидация на входе, каждое нарушение — `RAISE EXCEPTION`:

| Ограничение | Значение |
| --- | --- |
| Схема | существующая; запрещены `information_schema`, `pg\_%`, `ai`, `ai_http` → `Specify an existing application schema: %` |
| Строк на таблицу | `p_sample_rows` от 1 до 5 → `p_sample_rows must be between 1 and 5` |
| Таблиц выборок | не больше 8 → `At most 8 sample tables are supported` |
| Столбцов на таблицу | от 1 до 12 → `Specify 1 to 12 column names for %`; только существующие столбцы (`Unknown sample column for %`) и обычные/секционированные таблицы схемы (`Sample target must be a table in the requested schema: %`) |
| Длина значения | `left(...::text, 160)` на поле |
| Профиль | должен существовать → `Unknown model profile: %` |

Внутренние детали, важные при правках:

- `SET search_path = pg_catalog` на уровне функции; все обращения к системным каталогам — только `pg_catalog`.
- Запись пишется `INSERT ... ON CONFLICT (schema_name) DO UPDATE ... WHERE snapshot.captured_at <= EXCLUDED.captured_at RETURNING id`; если строка не обновлена (более раннее сканирование пытается перезаписать более позднее), `id` дочитывается отдельным `SELECT`.
- Снимок появляется **только** при HTTP 2xx, `finish_reason = 'stop'` и непустом `content`. Сетевая ошибка, HTTP-ошибка и оборванный ответ не меняют каталог — остаётся последний успешный обзор.
- Сырые строки выборок уходят в запрос к модели, но в снимке не сохраняются — остаётся только `sample_manifest` (таблицы, столбцы, число строк).
- Определение представления читается `pg_get_viewdef`, сигнатуры — `pg_get_function_identity_arguments` / `pg_get_function_result`; в каталог попадают только валидные индексы (`indisvalid`) и включённые невнутренние триггеры (`NOT tgisinternal AND tgenabled <> 'D'`).

### Общий HTTP-транспорт `ai._complete(p_profile, p_messages)`

Единственная точка выхода наружу для `init_catalog`, `llm`, `make_func`, `make_view` и `review_function`. Правки транспорта — только здесь.

- `octet_length(p_messages::text) > max_context_length` профиля → `Context of % bytes exceeds max_context_length % of profile %`. **Лимит проверяется до HTTP-вызова и одинаков для чата, каталога и генерации** — отдельного хардкода в вызывающих функциях нет.
- Сначала `PERFORM ai_http.http_list_curlopt()` — загружает библиотеку `http` в свежем бэкенде, и только потом ставятся GUC. Убрать этот вызов нельзя: `set_config` для чужих GUC без загрузки библиотеки не сработает.
- Таймаут соединения жёстко 3000 мс, таймаут запроса — `timeout_ms` профиля.
- `max_tokens` подставляется **только если** в `request_options` нет `max_completion_tokens` — иначе провайдер получает только `request_options`.
- Неверный `ai.reasoning_effort` → `Invalid ai.reasoning_effort: %`; не-2xx → `LLM endpoint returned HTTP % for profile %`; оборванный ответ → `Model did not return a complete response (finish_reason: %)`.

### `llm(p_system, p_user, p_profile, p_history, p_skills) RETURNS TABLE (answer, model, profile, finish_reason, prompt_tokens, completion_tokens, total_tokens, latency_ms, applied_skills)`

Общий чат с моделью из SQL. Реализация — `ai.llm` (PL/pgSQL) и обёртка `public.llm` (`LANGUAGE sql`, `SECURITY INVOKER`) с теми же аргументами. Правка сигнатуры требует `DROP FUNCTION IF EXISTS` для **обеих** — `CREATE OR REPLACE` не меняет список выходных столбцов.

- `p_system` допускается `NULL`; `p_history` — массив `{"role": "user|assistant", "content": ...}` между системным промптом и новым вопросом; историю хранит вызывающая сторона, в БД диалоги не пишутся.
- `p_skills` — массив ссылок `name@version`; применённые версии возвращаются в `applied_skills`. Неизвестная ссылка → `Unknown skill: % (use name@version)` (проверка в `ai._skill_context`, порядок сохраняется).
- **Заземление на каталог:** если в вопросе встречается имя вида `схема.объект` (регулярка по `p_user`) или навык перечисляет `catalog_objects`, а снимок этой схемы существует и доступен вызывающему (`has_table_privilege('ai.catalog_snapshot','SELECT')`), в системный промпт добавляется инструкция опираться на снимок, а пользовательское сообщение становится объектом `{question, catalog_snapshot, skills}`. Для обычных вопросов каталог не добавляется.
- Навык с `requires_snapshot = true` без доступного снимка → `Selected skills require an accessible catalog snapshot` — ошибка до обращения к модели.
- Валидация: `Provide a user prompt`, `p_history must be an array of role and content objects`, `Each history item needs a user or assistant role and non-empty content`, `Unknown model profile: %`. Профиль читается **до** сборки сообщений — иначе лимит брать неоткуда, поэтому ошибка неизвестного профиля опережает ошибку истории.
- Промпт уходит только в тело HTTP-запроса: динамического SQL в `llm` нет, содержимое промпта не может стать выполнимым SQL; ответ модели тоже не исполняется.
- Важно: у выходного столбца есть имя `profile`, поэтому запрос профиля обязан быть с квалификатором — `WHERE mp.profile = p_profile`. Без алиаса PL/pgSQL подставил бы в `WHERE` выходной параметр вместо столбца таблицы.

### `ai.make_func(p_name, p_description) RETURNS TABLE (signature, ddl, assumptions, applied_skills)`

`SECURITY INVOKER`, `SET check_function_bodies = on`. Цепочка: описание → профиль сессии → навыки из `ai.skill_binding` (привязка к имени функции важнее привязки к схеме, `DISTINCT ON (skill_name) ... priority DESC`) → снимок схемы (`focused`/`full`) → запрос черновика → разбор JSON (`arguments`, `return_type` или `return_columns`, `report_contract`, `body`, `assumptions`) → проверка контракта → **отдельное LLM-ревью** → `EXECUTE` DDL → запись в `ai.function_generation`. Всё в одной транзакции вызывающего, объект создаётся под его правами.

- Имя без схемы → `public`. Ошибки: `Provide a function description`, `Provide a function name or schema-qualified function name`, `Target schema does not exist: %` (3F000), `Permission denied to create a function in schema %` (42501), `Initialize a schema catalog before generating a function`, `Unknown ai.function_catalog_mode: %. Use focused or full.`
- Типы аргументов берются из указанных моделью исходных столбцов каталога и проверяются в PostgreSQL: `Model response is missing function draft fields`, `Invalid or repeated draft argument name: %`, `Could not resolve type for draft argument %`, `Unsupported scalar return type: %`, `Unsupported type for result column %: %`, `The draft body must be a single SELECT`.
- DDL: `CREATE FUNCTION <сигнатура> LANGUAGE sql SECURITY INVOKER SET search_path = pg_catalog AS <тело>;`
- Дубликаты сигнатуры не проверяются заранее — ошибка приходит от PostgreSQL.
- Ревью отклонило черновик → `Function review: %`, в `DETAIL` — jsonb замечаний, функция не создана.

### `ai.make_view(p_name, p_description) RETURNS TABLE (view_name, ddl, assumptions, applied_skills)`

Тот же выбор профиля, навыков и снимка, включая `ai.reviewer_profile` и `ai.function_catalog_mode`; историческое поле `target_function` в `ai.skill_binding` может содержать имя представления. Отличия: `Provide a view description`, `Provide a view name or schema-qualified view name`, `Relation already exists: %` (42P07, проверка `to_regclass`), `Initialize a schema catalog before generating a view`, `Model response is missing view draft fields`, `The view draft body must be a single SELECT`, `View review: %`.

DDL: `CREATE VIEW <имя> WITH (security_invoker = true) AS <SELECT>;` — PostgreSQL 15+. В истории `object_kind = 'view'`, а имя объекта лежит в `function_name` и `signature`.

### Ревью: `ai._review_function` и `ai.review_function`

Ревьюер — **отдельный** запрос с системной ролью ревьюера и навыком `review-function@1`; профиль — `ai.reviewer_profile`, иначе профиль генератора. Вердикты: `pass`, `needs_changes`, `ambiguous`; первые создание разрешает, последние два прерывают, замечания уходят в `DETAIL`. При невалидном ответе запрос повторяется один раз (`FOR v_attempt IN 1..2`) с дописанным `The previous response failed validation: ...`; после второй неудачи — `RAISE` с `DETAIL = 'Reviewer profile: %s. Attempts: 2.'`.

`ai.review_function(p_function regprocedure, p_description NULL, p_profile NULL) RETURNS jsonb` проверяет уже созданный объект: читает `pg_get_functiondef`, требует обычную функцию (`Specify an existing ordinary function by signature`), возвращает `logic` (`summary`, `steps`, `returns`, `side_effects`, `unknowns`) и `findings` с фрагментом, причиной и уверенностью `high`/`medium`. Код функции **не выполняется**. Навыки: привязки схемы и имени ∪ `supabase-postgres-best-practices@1`. Режим `explain` (без описания) требует в ответе блок `logic`, режим ревью — вердикт.

### Служебные объекты

| Объект | Содержимое |
| --- | --- |
| `ai.model_profile` | `profile` (PK), `endpoint` (CHECK на `http(s)://`), `model`, `max_tokens` (1–16000, по умолчанию 4000), `timeout_ms` (1000–180000, по умолчанию 90000), `max_context_length` (1000–10000000 **байт**, по умолчанию 250000), `request_options` (jsonb-объект) |
| `ai.catalog_snapshot` | одна запись на схему: `schema_name` UNIQUE, `captured_at`, `database_name`, `metadata`, `sample_manifest`, `profile`, `model`, `synopsis` (CHECK на непустой `btrim`) |
| `ai.catalog_snapshot.metadata` | JSON-каталог фактов: `database`, `schema`, массивы `relations`, `routines`, `types` — читаются и фильтруются из SQL |
| `ai.catalog_snapshot.sample_manifest` | состав выборок: столбцы и число прочитанных строк |
| `ai.catalog_snapshot.synopsis` | Markdown-обзор модели; утверждения о типах и ограничениях сверять с `metadata`, а не с текстом |
| `ai.skill` | `name` (CHECK `^[a-z0-9]+(-[a-z0-9]+)*$`), `version` (> 0), PK `(name, version)`, `description`, `instructions`, `catalog_objects text[]`, `sql_examples jsonb`, `requires_snapshot` |
| `ai.skill_binding` | PK `(target_schema, target_function, skill_name)`, FK на `ai.skill`; пустой `target_function` — привязка ко всей схеме |
| `ai.function_generation` | история успешных созданий: `target_schema`, `function_name`, `object_kind` (`function`/`view`), `description`, `signature`, `ddl`, `assumptions`, `report_contract`, `catalog_selection`, `generator_profile`, `generator_model`, `generator_prompt_sha256`, `catalog_sha256`, `applied_skills`, `review`, `created_by`, `created_at` |

Навыки seeded установщиком (`ON CONFLICT DO NOTHING`): `use-snapshot@1` и `review-function@1` (оба `requires_snapshot = true`), `supabase-postgres-best-practices@1` — адаптация рекомендаций Supabase; она применяется при генерации и ревью по умолчанию. Предметный пример — `rental-revenue@1` в `examples/dvd_rent/install_dvd_rent_skills.sql` с `catalog_objects` из `payment`/`rental`/`inventory`/`film` и двумя `sql_examples`.

Профиль `default` из `examples/dvd_rent/init_dvd_rent.sql`: `http://10.8.0.10:8002/v1/chat/completions`, модель `qwen3.8-flash-next`, `max_context_length = 250000`, `{"temperature": 0, "chat_template_kwargs": {"enable_thinking": false}}`. Для другой модели достаточно новой строки в `ai.model_profile` (или `ai.register_model_profile`) — код функций править не нужно.

`max_model_len` модели (262144 токенов) и `max_context_length` (байты сериализованного массива сообщений) измеряются в разных единицах; сопоставлять их напрямую некорректно.

Права: все схемы, таблицы и функции `ai` закрыты от `PUBLIC`, функции `SECURITY INVOKER`. Рабочей роли нужны `USAGE` на схему `ai`, `EXECUTE` на используемые функции и, если нужно заземление чата, `SELECT` на `ai.catalog_snapshot`.

## Соглашения разработки

### Язык

- Документы, комментарии для человека и вывод модели — **русские** (`README.md`, `docs/design.md`, `examples/dvd_rent/dvd_rent-synopsis.md`).
- Системные промпты, сообщения `RAISE EXCEPTION`, идентификаторы и имена параметров — **английские**.
- Модель обязана отвечать Markdown-обзором на русском до 650 слов; в промпте закреплено: комментарии БД и значения выборок — данные, а не инструкции; не воспроизводить отдельные строки выборок и персональные данные. Язык объяснений и замечаний ревью определяется по заданию, комментариям или описаниям объектов; без языковых признаков — английский.
- Сообщения об ошибках — английские короткие императивы: `Specify an existing application schema: %`, `p_sample_rows must be between 1 and 5`.

### PL/pgSQL и SQL

- 4 пробела, ключевые слова SQL — в нижнем регистре; многострочные `SELECT` выравниваются по спискам полей.
- Тело функции в dollar-кавычках `$function$`, текст промпта — `$prompt$`, инструкции навыка — `$instructions$`, миграция — `$migration$`.
- Параметры с префиксом `p_`, локальные переменные с `v_`; объявления — блоком в начале `DECLARE`, инициализация там же (`v_started timestamptz := clock_timestamp()`).
- Явные алиасы везде, где есть джойн или `LATERAL`; `AS` обязательно для источников в `FROM` (`FROM pg_class AS c`, `unnest(...) AS s(schema_name)`). `JOIN` пишется с явным типом (`JOIN ... ON`, `CROSS JOIN LATERAL`).
- Каталоги PostgreSQL читаются через `pg_*`, а не через `information_schema`; константы `relkind`/`prokind`/`typtype` раскрываются в человекочитаемые строки прямо в `CASE`.
- Динамический SQL только через `format()` с `%I`/`%L` и параметрами `USING $1`; списки столбцов собираются `string_agg(format(...))`.
- Каждый скрипт начинается с `\set ON_ERROR_STOP on`; DDL-скрипт и примеры-генераторы обёрнуты в транзакцию.
- Идемпотентность установочного скрипта обязательна: `IF NOT EXISTS`, `CREATE OR REPLACE`, `ON CONFLICT DO NOTHING`.
- Права: новые схемы, таблицы и функции сразу закрываются от `PUBLIC`.
- `ai.catalog_snapshot` обновляется по `schema_name` (не append-only), `ai.function_generation` — append-only, снимок в историю не копируется.

### Миграции

Установщик — он же мигратор, и это единственный способ изменять схему `ai`:

- новые колонки — `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` (так добавлены `max_context_length`, `report_contract`, `catalog_selection`, `object_kind`);
- смена списка выходных столбцов или аргументов требует явного `DROP FUNCTION IF EXISTS` старой сигнатуры — `CREATE OR REPLACE` не меняет ни то, ни другое (в установщике сняты `ai.init_catalog(text[],jsonb,integer,text)`, `public.llm(text,text,text,jsonb)`, `ai.llm(text,text,text,jsonb)`, условно `ai.make_func(text,text)` без `applied_skills`);
- переписывание данных — в `DO $migration$` под `LOCK TABLE ... ACCESS EXCLUSIVE`. Переход `schemas text[]` → `schema_name text` для дубликатов оставляет запись с максимальным `(captured_at, id)`, дополняет `metadata` ключом `schema` и ставит `NOT NULL` + UNIQUE. Если попадётся объединённый снимок нескольких схем, миграция останавливается на `Legacy catalog contains a snapshot without exactly one schema` с подсказкой экспортировать, удалить и инициализировать схемы по отдельности.

### Чтение снимка из SQL

`metadata` — это jsonb, типичный разбор — `jsonb_array_elements(...)` с `CROSS JOIN LATERAL` и `WITH ORDINALITY` для сохранения порядка колонок. Готовые образцы — в `examples/dvd_rent/inspect_catalog.sql`; там же паттерн `\gset` для «взять снимок по схеме». При изменении структуры `metadata` правятся и все примеры, которые её читают.

## Известные особенности данных `dvd_rent`

Проверено на демо-базе и зафиксировано в `docs/design.md` — учитывать при генерации и ревью SQL:

- **Типы ключей не совпадают:** в `film_actor` и `film_category` столбцы `smallint`, а PK родителей (`actor`, `film`, `category`) — `integer`. Модель рекомендует явные приведения; обычный `JOIN` по равенству на демо-базе вернул 5 462 строки.
- **Противоречие в `payment.rental_id`:** столбец одновременно `NOT NULL` и участвует во внешнем ключе с `ON DELETE SET NULL`. По одному определению FK нельзя вывести, что столбец допускает `NULL` — в каталоге полезны оба свойства.
- **Пользовательские типы:** `public.mpaa_rating` (ENUM: `G`, `PG`, `PG-13`, `R`, `NC-17`) и `public.year` (DOMAIN `integer` с `CHECK` 1901–2155) — их определения отдельным блоком попадают в `metadata->'types'`.
- **Триггер `last_updated`** есть у всех таблиц с изменяемыми данными; полнотекстовый поиск в `film` поддерживается триггером, обновляющим `fulltext`.
- Отчёты опираются на агрегат `public.group_concat(text)`, используемый в представлениях `actor_info`, `film_list`, `nicer_but_slower_film_list`.
- Путь выручки: `payment.rental_id` → `rental.rental_id` → `rental.inventory_id` → `inventory.inventory_id` → `inventory.film_id` → `film.film_id`; дата — `payment.payment_date`, период полуоткрытый (`>= start`, `< end`).

## Текущее состояние и что дальше

Реализовано и описано в `docs/design.md`: каталог по схеме с выборками и обзором, профили и `register_model_profile`, настройки сессии, чат с историей, навыками и заземлением, навыки и привязки, генерация функций и представлений, контракт отчёта, отбор контекста `focused`, отдельное LLM-ревью с ретраем, история генераций.

Открытые вопросы:

- Автоматических тестов нет: регрессия — ручные прогоны `examples/` и сверка с эталонами. При изменении `install_catalog.sql` прогонять примеры обязательно.
- Универсальный механизм регистрации предметных тестов (контрольные примеры к генерируемому объекту) не реализован; сейчас роль теста выполняют эталонные запросы и `DO`-сверка в примере представлений.
- Ролей разделения (генератор vs чтение каталога) нет; инициализация требует владельца или администратора.
- Авторизация внешних провайдеров не реализована: внутренний DGX-endpoint принимает запросы без ключа, заголовка `Authorization` в коде нет.
- Свой пакет `CREATE EXTENSION` отложен до стабилизации SQL-интерфейса и миграций служебных таблиц.
- `README.md` и `examples/dvd_rent/README.md` описывают запуск через контейнер `postgres1` на прежнем хосте — после переезда БД на `192.168.1.68:5433` эти команды устарели, живой путь доступа описан здесь.
- Развёртывание на NAS сделано вручную и не оформлено скриптом: установка `http` в каталог пакета DSM, `trust`-доступ и порядок прогонов существуют только как текст в этом файле. Кандидат на автоматизацию — хотя бы проверка окружения перед прогоном установщика (`pg_available_extensions` содержит `http`, endpoint модели отвечает).
- В `template1` кластера лежали расширения, не относящиеся к задаче: они попадают в каждую новую базу, раздувают снимок и стоят токенов в каждом запросе. `postgis` убран 14.11.2026, `vector` — 15.11.2026; остались `cube`, `earthdistance`, `pg_trgm`, `unaccent`, `uuid-ossp` (94 функции `public`) — на усмотрение пользователя, control-файлы всех удалённых расширений по-прежнему доступны для `CREATE EXTENSION`.

## Ограничения и незакрытые вопросы

- **Проект на NAS развёрнут и работает:** `192.168.1.68:5433`, база `dvd_rent`, схемы `ai`/`ai_http`/`reporting`, транспорт `http` установлен, снимок и обе генерации прогнаны с совпадением эталонов (п. 4). Это состояние получено вручную 14.11.2026 и ничем не закреплено, кроме содержимого репозитория: переезд на другой сервер по-прежнему начинается с транспорта (`CREATE EXTENSION http`), а не с SQL репозитория.
- **Аутентификация на сервере сейчас `trust` для `10.8.0.10` при `listen_addresses = *`** — superuser `postgres` без пароля. Это удобно для отладки и неприемлемо как постоянное состояние, тем более что в `dvd_rent` уже есть данные: переходить на `scram-sha-256` стоит как можно раньше, после чего понадобится строка учётки в `~/.pgpass` (см. п. 3).
- Перед применением DDL к живой базе помнить, что `ai.init_catalog()`, `ai.make_func()`, `ai.make_view()`, `ai.review_function()` и каждый `llm()` обращаются к модели: это осознанные сетевые операции, а не безобидные `SELECT`.
- Сетевую доступность endpoint'а проверять **с той машины, где работает PostgreSQL** (`192.168.1.68`), а при сервере в Docker — ещё и **из контейнера**. Успешный `curl` с этого хоста ничего не доказывает: модель и база живут на разных машинах.
- Снимок формируется только при полностью успешном ответе, поэтому частично собранный каталог не сохраняется; отладку сетевых проблем удобно начинать с `curl` к `/v1/models`.
- **Путь на сервер есть, но только по учётным данным пользователя:** SSH на `192.168.1.68` работает на порту `4222` (`OpenSSH_8.2`), а не на 22-м; им и пользовались, чтобы положить `http.so` и `http.control` в `/volume1/@appstore/postgresql/`. Логин и пароль DSM агенту дал пользователь под разовую операцию, и нигде они не сохранены (ни в репозитории, ни в `~/.ssh`, ни в памяти агента) — для следующей операции на файловой системе сервера их придётся запросить заново. Подбирать учётные данные нельзя: в DSM включён auto-block неудачных входов. Для `psql` по TCP SSH не нужен.
- **Для отладки генерации остаётся полезным замер стоимости запроса:** `prompt_tokens`/`completion_tokens`/`total_tokens`/`latency_ms` возвращает и `llm`, и `ai.catalog_snapshot` хранит объём снимка; на раздутом каталоге (`template1` с расширениями) платят токенами — см. цифры до и после зачистки PostGIS и `vector` в «Состоянии окружения» (56 026 → 12 582 токена на один и тот же заземлённый вопрос).
