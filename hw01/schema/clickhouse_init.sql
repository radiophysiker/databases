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
SETTINGS index_granularity = 8192
COMMENT 'Фактовая таблица событий просмотров экранов мобильного приложения. Используется для аналитики пользовательской активности.';

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
    region
COMMENT 'Агрегированные показатели просмотров экранов по дням, регионам и экранам. Используется для расчёта DAU и популярности экранов.';
