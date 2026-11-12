# Синтаксис базы данных `dvd_rent`

## Домен и архитектура
База данных `dvd_rent` моделирует систему проката DVD-дисков. Она охватывает управление каталогом фильмов, инвентарем в магазинах, клиентами, сотрудниками и транзакциями аренды и оплаты. Схема `public` содержит нормализованные таблицы, справочники и предопределенные представления для отчетности.

## Пользовательские типы данных
*   **`public.mpaa_rating`** (ENUM): Допустимые значения рейтинга фильма: `'G'`, `'PG'`, `'PG-13'`, `'R'`, `'NC-17'`. Используется в столбце `film.rating`.
*   **`public.year`** (DOMAIN): Тип `integer` с ограничением `CHECK (VALUE >= 1901 AND VALUE <= 2155)`. Применяется к столбцу `film.release_year`.

## Основные таблицы и зернистость

### Каталог фильмов
*   **`public.film`**: Зернистость — один фильм. PK: `film_id` (integer). Содержит метаданные (`title`, `description`, `rental_rate` numeric(4,2), `replacement_cost` numeric(5,2)). Полнотекстовый поиск обеспечивается триггером, обновляющим поле `fulltext` (tsvector).
*   **`public.actor`**: Зернистость — один актер. PK: `actor_id` (integer).
*   **`public.category`**: Зернистость — одна категория. PK: `category_id` (integer).
*   **`public.language`**: Зернистость — один язык. PK: `language_id` (integer).

### Связующие таблицы (M:N)
*   **`public.film_actor`**: Связь «фильм-актер». PK: `(actor_id, film_id)`. Оба столбца `smallint`. Индекс `idx_fk_film_id` ускоряет поиск по фильмам.
*   **`public.film_category`**: Связь «фильм-категория». PK: `(film_id, category_id)`. Оба столбца `smallint`.

### Инвентарь и магазины
*   **`public.store`**: Зернистость — один магазин. PK: `store_id` (integer). Ссылается на `staff` (менеджер) и `address`.
*   **`public.inventory`**: Зернистость — одна физическая копия фильма в конкретном магазине. PK: `inventory_id` (integer). FK: `film_id`, `store_id`. Индекс `idx_store_id_film_id` оптимизирует запросы наличия.

### Клиенты, сотрудники и география
*   **`public.customer`**: Зернистость — один клиент. PK: `customer_id` (integer). FK: `address_id`, `store_id`.
*   **`public.staff`**: Зернистость — один сотрудник. PK: `staff_id` (integer). FK: `address_id`, `store_id`.
*   **`public.address`**, **`public.city`**, **`public.country`**: Иерархия географических данных. `address.city_id` -> `city.city_id` -> `city.country_id` -> `country.country_id`.

### Транзакции
*   **`public.rental`**: Зернистость — одна аренда. PK: `rental_id` (integer). FK: `inventory_id`, `customer_id`, `staff_id`. Уникальный индекс `(rental_date, inventory_id, customer_id)` предотвращает дублирование активных аренд.
*   **`public.payment`**: Зернистость — одна транзакция оплаты. PK: `payment_id` (integer). FK: `rental_id` (ON DELETE SET NULL), `customer_id`, `staff_id`.

## Ключевые связи и пути соединения

1.  **Фильмы и категории**:
    `film` -> `film_category` -> `category`
2.  **Фильмы и актеры**:
    `film` -> `film_actor` -> `actor`
3.  **Аренда и инвентарь**:
    `rental` -> `inventory` -> `film`
4.  **Полный путь транзакции (от оплаты до категории)**:
    `payment` -> `rental` -> `inventory` -> `film` -> `film_category` -> `category`
5.  **География клиента**:
    `customer` -> `address` -> `city` -> `country`

## Функции и агрегаты

*   **`public.film_in_stock(p_film_id integer, p_store_id integer)`**: Возвращает `SETOF integer` (список `inventory_id`) и OUT-параметр `p_film_count`.
*   **`public.film_not_in_stock(p_film_id integer, p_store_id integer)`**: Аналогично, но для недоступных копий.
*   **`public.inventory_in_stock(p_inventory_id integer)`**: Возвращает `boolean`.
*   **`public.get_customer_balance(p_customer_id integer, p_effective_date timestamp without time zone)`**: Возвращает `numeric`.
*   **`public.rewards_report(min_monthly_purchases integer, min_dollar_amount_purchased numeric)`**: Возвращает `SETOF public.customer`.
*   **`public.group_concat(text)`**: Агрегатная функция, возвращающая `text`. Используется в представлениях `actor_info`, `film_list` и `nicer_but_slower_film_list` для объединения имен актеров или категорий в одну строку.

## Представления
*   **`public.film_list`** и **`public.nicer_but_slower_film_list`**: Предоставляют сводную информацию о фильмах с именами актеров, объединенными через `group_concat`.
*   **`public.sales_by_film_category`**: Агрегирует `payment.amount` по категориям фильмов.
*   **`public.sales_by_store`**: Агрегирует продажи по магазинам, включая имя менеджера и географическое положение.

## Примечания для разработчика
*   Все таблицы с изменяемыми данными имеют столбец `last_update` (timestamp), который автоматически обновляется триггером `last_updated`.
*   При работе с `film_actor` и `film_category` учитывайте, что внешние ключи ссылаются на `smallint`, тогда как PK в родительских таблицах (`actor`, `film`, `category`) имеют тип `integer`. Это требует явного приведения типов или аккуратного сравнения в SQL-запросах.
*   Ограничения `ON DELETE RESTRICT` на большинстве FK защищают целостность данных; удаление родительских записей (например, фильмов или клиентов) невозможно при наличии связанных дочерних записей.
