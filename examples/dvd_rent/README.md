# Демобаза dvd_rent

Сценарий показывает установку каталога, чат о схеме, подключение предметного навыка и сверку сгенерированной функции с эталоном. Для установки в свою базу используйте [общую инструкцию](../../README.md).

## Запуск в Docker

Команды рассчитаны на PowerShell и контейнер `postgres1`. Для Debian с PGDG и PostgreSQL 17 установите в контейнер пакет `postgresql-17-http`, если его ещё нет.

Если базы `dvd_rent` ещё нет, восстановите [архив](dvdrental.tar) в новую пустую базу. Команды запускаются из корня репозитория.

```powershell
docker cp .\examples\dvd_rent\dvdrental.tar postgres1:/tmp/dvdrental.tar
docker exec postgres1 sh -c 'createdb -U "${POSTGRES_USER:-postgres}" dvd_rent && pg_restore --exit-on-error --no-owner --no-privileges -U "${POSTGRES_USER:-postgres}" -d dvd_rent /tmp/dvdrental.tar'
```

Установите общий SQL, затем создайте снимок и загрузите навык демобазы.

```powershell
Get-Content -Raw .\sql\install_catalog.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\examples\dvd_rent\init_dvd_rent.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
Get-Content -Raw .\examples\dvd_rent\install_dvd_rent_skills.sql | docker exec -i postgres1 sh -c 'psql -X -v ON_ERROR_STOP=1 -U "${POSTGRES_USER:-postgres}" -d dvd_rent'
```

Демо-скрипт добавляет профиль `default` для `qwen3.8-flash-next` на внутреннем endpoint DGX `http://10.8.0.10:8002/v1/chat/completions`. Если профиль с таким именем уже настроен, скрипт использует его. [Пример обзора модели](dvd_rent-synopsis.md)

## Примеры

- [inspect_catalog.sql](inspect_catalog.sql) читает снимок `public`, типы и ограничения таблицы платежей.
- [install_dvd_rent_skills.sql](install_dvd_rent_skills.sql) добавляет `rental-revenue@1` с правилами выручки и привязками к функциям.
- Тот же скрипт привязывает `customer-similarity-cube@1` к `reporting.customer_like`.
  Для этого примера нужны расширение `cube` в схеме `public` и снимок, снятый после установки расширения.
  Навык показывает, как передать пять координат в `public.cube(double precision[])`
  и сравнить две точки через `public.cube_distance`.
- [make_func_customer_revenue.sql](make_func_customer_revenue.sql) создаёт `reporting.customer_revenue`.
- [customer_revenue_baseline.sql](customer_revenue_baseline.sql) возвращает эталонные суммы для двух периодов.

Вопрос про фактическую схему можно задать после создания снимка.

```sql
SELECT answer FROM ai.llm(
    'Ты специалист по PostgreSQL. Отвечай на русском без предисловий.',
    'С какими таблицами связана таблица public.country?'
);

SELECT answer, applied_skills FROM ai.llm(
    'Отвечай кратко по-русски.',
    'Почему фильм повторяется в помесячном отчёте о выручке?',
    p_skills => ARRAY['rental-revenue@1']
);
```

После создания функции её результат можно сверить с эталоном.

```sql
SELECT reporting.customer_revenue(
    1::smallint, timestamp '2007-02-01', timestamp '2007-06-01'
);
```

Для клиента № 1 эталон возвращает 114,70 по 30 платежам в указанном периоде и 0 за период с 1 января по 1 февраля 2008 года. Помесячный отчёт о выручке по фильмам проверяет другой случай: одна и та же пара «название, сумма» может встретиться несколько раз, поэтому при сравнении результата учитывают повторы.

### Наблюдения о схеме

В проверенном снимке было 22 таблицы и представления, 10 функций и агрегатов и 2 пользовательских типа. Обзор Flash Next предложил явно приводить типы для соединения `film_actor.film_id` с `film.film_id`. Обычный `JOIN` без приведения вернул 5 462 строки. В таблице `payment` колонка `rental_id` одновременно имеет `NOT NULL` и внешний ключ с `ON DELETE SET NULL`. Генератору важно учитывать оба свойства.
