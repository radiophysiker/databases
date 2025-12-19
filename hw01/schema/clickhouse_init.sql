-- ============================================================
-- Аналитическая схема (OLAP) для системы поощрений
-- Хранилище событий пользовательской активности (page views)
-- ============================================================

-- ------------------------------------------------------------
-- База данных
-- ------------------------------------------------------------
CREATE DATABASE IF NOT EXISTS rewards;
USE rewards;

-- ============================================================
-- Таблица: page_views
-- ============================================================

CREATE TABLE IF NOT EXISTS page_views
(
    event_id UUID,                          -- уникальный идентификатор события
    user_id UInt64,                         -- идентификатор пользователя
    view_date Date,                         -- дата события (для партиционирования)
    view_ts DateTime,                       -- точное время просмотра

    screen_name LowCardinality(String),     -- имя экрана (profile, games, tasks и т.п.)
    section LowCardinality(String),         -- логический раздел приложения
    region LowCardinality(String),          -- регион пользователя
    device_type LowCardinality(String),     -- тип устройства (android, ios)
    app_version LowCardinality(String),     -- версия приложения
    session_id String                       -- идентификатор пользовательской сессии
)
ENGINE = ReplacingMergeTree(view_ts)
PARTITION BY toYYYYMM(view_date)
ORDER BY (user_id, event_id)
TTL view_date + INTERVAL 12 MONTH
SETTINGS index_granularity = 8192;

COMMENT ON TABLE page_views IS
'Фактовая таблица событий просмотров экранов мобильного приложения. Используется для аналитики пользовательской активности.';

COMMENT ON COLUMN page_views.event_id IS
'Уникальный идентификатор события для дедупликации.';

COMMENT ON COLUMN page_views.user_id IS
'Идентификатор пользователя (соответствует users.user_id в PostgreSQL).';

COMMENT ON COLUMN page_views.screen_name IS
'Имя экрана или страницы приложения.';

COMMENT ON COLUMN page_views.section IS
'Логический раздел приложения (используется для группировки экранов).';

COMMENT ON COLUMN page_views.view_date IS
'Дата события, используется для партиционирования и TTL.';

COMMENT ON COLUMN page_views.view_ts IS
'Точное время просмотра экрана.';

-- ============================================================
-- Материализованное представление: daily_screen_stats
-- ============================================================

CREATE MATERIALIZED VIEW IF NOT EXISTS daily_screen_stats
ENGINE = AggregatingMergeTree
PARTITION BY toYYYYMM(view_date)
ORDER BY (view_date, screen_name, region)
AS
SELECT
    view_date,
    screen_name,
    region,
    countState() AS views,
    uniqState(user_id) AS unique_users
FROM page_views
GROUP BY
    view_date,
    screen_name,
    region;

COMMENT ON TABLE daily_screen_stats IS
'Агрегированные показатели просмотров экранов по дням, регионам и экранам. Используется для расчёта DAU и популярности экранов.';

COMMENT ON COLUMN daily_screen_stats.views IS
'Состояние агрегата count() для подсчёта просмотров. Для получения значения использовать countMerge(views).';

COMMENT ON COLUMN daily_screen_stats.unique_users IS
'Состояние агрегата uniq() для подсчёта уникальных пользователей. Для получения значения использовать uniqMerge(unique_users).';
