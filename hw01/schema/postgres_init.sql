-- ============================================================
-- init.sql — Схема БД бонусной системы (PostgreSQL, OLTP)
-- ============================================================

CREATE EXTENSION IF NOT EXISTS btree_gist;

DROP SCHEMA IF EXISTS rewards CASCADE;
CREATE SCHEMA rewards;
SET search_path TO rewards;

-- ----------------------------
-- Типы (ENUM / CHECK аналоги)
-- ----------------------------

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'purchase_status') THEN
    CREATE TYPE purchase_status AS ENUM ('active', 'expired', 'cancelled');
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'points_tx_type') THEN
    CREATE TYPE points_tx_type AS ENUM (
      'welcome_bonus',
      'task_reward',
      'purchase',
      'birthday_bonus',
      'manual_adjustment'
    );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'task_availability_reason') THEN
    CREATE TYPE task_availability_reason AS ENUM ('seasonal', 'promo', 'experiment');
  END IF;
END$$;

-- ----------------------------
-- Таблица: regions (справочник)
-- ----------------------------

CREATE TABLE regions (
  region_id   SERIAL PRIMARY KEY,
  code VARCHAR(10) UNIQUE NOT NULL,
  name VARCHAR(100) NOT NULL
);

COMMENT ON TABLE regions IS 'Справочник регионов пользователей';


-- ----------------------------
-- Таблица: users
-- ----------------------------
CREATE TABLE users (
  user_id         BIGSERIAL PRIMARY KEY,
  phone           VARCHAR(10) UNIQUE NOT NULL,
  CONSTRAINT chk_phone_digits CHECK (phone ~ '^\\d{10}$'),
  region_id       INT NOT NULL REFERENCES regions(region_id),
  current_balance INT NOT NULL DEFAULT 0, -- кэш баланса
  CONSTRAINT chk_balance_non_negative CHECK (current_balance >= 0),
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE users IS 'Пользователи бонусной системы';
COMMENT ON COLUMN users.phone IS 'Номер телефона пользователя (10 цифр, без кода страны)';
COMMENT ON COLUMN users.current_balance IS 'Текущий баланс баллов (кэш), подтверждается журналом транзакций';

-- Индекс для выборок по региону (например, для массовых рассылок бонусов по регионам)
CREATE INDEX idx_users_region_id 
ON rewards.users (region_id);

-- ----------------------------
-- Таблица: user_profiles
-- ----------------------------
CREATE TABLE user_profiles (
  user_id      BIGINT PRIMARY KEY REFERENCES users(user_id) ON DELETE CASCADE,
  display_name VARCHAR(100),
  birth_date   DATE,
  CONSTRAINT chk_birth_date_valid 
    CHECK (
      -- Допустимые даты рождения: с 1900-01-02 по текущую дату
      birth_date > '1900-01-01'
      -- другие ограничения по дате рождения добавляются на уровне приложения
    ),
  created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at   TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE user_profiles IS 'Профиль пользователя';
COMMENT ON COLUMN user_profiles.display_name IS 'Ник для отображения в UI';
COMMENT ON COLUMN user_profiles.birth_date IS 'Дата рождения (используется для начисления birthday_bonus)';

-- Индекс для выборок по дню и месяцу рождения (для массового начисления birthday_bonus)
CREATE INDEX idx_profiles_birthday_month_day 
ON rewards.user_profiles (extract(month from birth_date), extract(day from birth_date));

-- ----------------------------
-- Таблица: tasks
-- ----------------------------
CREATE TABLE tasks (
  task_id       SERIAL PRIMARY KEY,
  code          VARCHAR(50) NOT NULL UNIQUE,
  title         VARCHAR(255) NOT NULL,
  reward_points INT NOT NULL,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  CONSTRAINT chk_reward_points CHECK (reward_points > 0)
);

COMMENT ON TABLE tasks IS 'Справочник типов ежедневных заданий для пользователей.';
COMMENT ON COLUMN tasks.code IS 'Код задания (open_profile/open_games и т.п.).';
COMMENT ON COLUMN tasks.reward_points IS 'Награда в баллах за выполнение задания.';

-- ----------------------------
-- Таблица: task_availability (Дополнительная таблица для сезонных/промо заданий)
-- ----------------------------
CREATE TABLE task_availability (
  availability_id SERIAL PRIMARY KEY,
  task_id         INT NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
  valid_from      DATE NOT NULL,
  valid_to        DATE NOT NULL,
  reason          task_availability_reason,
  CONSTRAINT chk_task_availability_dates CHECK (valid_to >= valid_from)
);

COMMENT ON TABLE task_availability IS 'Дополнительная таблица для сезонных/промо заданий';
COMMENT ON COLUMN task_availability.reason IS 'Причина/тип окна доступности задания';

-- Композитный индекс для поиска активных промо-заданий на текущую дату
CREATE INDEX idx_task_availability_dates 
ON rewards.task_availability (task_id, valid_from, valid_to);

COMMENT ON INDEX rewards.idx_task_availability_dates IS 
'Используется для выборки: какие промо-задания доступны сегодня?';


-- ----------------------------
-- Таблица: daily_tasks
-- ----------------------------

CREATE TABLE daily_tasks (
  daily_task_id SERIAL PRIMARY KEY,
  task_id       INT NOT NULL REFERENCES tasks(task_id) ON DELETE CASCADE,
  task_date     DATE   NOT NULL,
  created_at    TIMESTAMP NOT NULL DEFAULT now(),

  CONSTRAINT uq_daily_tasks_task_date
    UNIQUE (task_id, task_date)
);

COMMENT ON TABLE daily_tasks IS 'Ежедневные задания, доступные для выполнения пользователями.';
COMMENT ON COLUMN daily_tasks.task_date IS 'Дата, на которую назначено задание.';

-- Индекс для быстрого получения всех заданий на конкретную дату
CREATE INDEX idx_daily_tasks_date 
ON rewards.daily_tasks (task_date);

COMMENT ON INDEX rewards.idx_daily_tasks_date IS 
'Индекс для выборки заданий на конкретную дату';


-- ----------------------------
-- Таблица: user_tasks
-- ----------------------------
CREATE TABLE user_tasks (
  user_task_id  SERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  daily_task_id INT NOT NULL REFERENCES daily_tasks(daily_task_id) ON DELETE CASCADE,
  completed_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_user_tasks_user_daily_task
    UNIQUE (user_id, daily_task_id)
);

COMMENT ON TABLE user_tasks IS 'Выполненные задания пользователям';

-- Индекс для выборки всех пользователей, выполнивших конкретное задание
CREATE INDEX idx_user_tasks_daily_task 
ON rewards.user_tasks (daily_task_id, completed_at);

COMMENT ON INDEX rewards.idx_user_tasks_daily_task IS 
'Используется для аналитики: сколько пользователей выполнили задание X?';

-- Композитный индекс для истории выполненных заданий пользователя
CREATE INDEX idx_user_tasks_user_completed 
ON rewards.user_tasks (user_id, completed_at DESC);

COMMENT ON INDEX rewards.idx_user_tasks_user_completed IS 
'Для отображения истории выполненных заданий в профиле пользователя';

-- ----------------------------
-- Таблица: products
-- ----------------------------
CREATE TABLE products (
  product_id    SERIAL PRIMARY KEY,
  code          VARCHAR(50) NOT NULL UNIQUE,
  name          VARCHAR(255) NOT NULL,
  duration_days INT,
  is_active     BOOLEAN NOT NULL DEFAULT true,
  CONSTRAINT chk_duration_days CHECK (duration_days IS NULL OR duration_days > 0)
);

COMMENT ON TABLE products IS 'Виртуальные продукты/привилегии, приобретаемые за баллы';
COMMENT ON COLUMN products.duration_days IS 'Длительность действия продукта в днях (NULL для бессрочных продуктов)';

-- ----------------------------
-- Таблица: prices (версионные)
-- ----------------------------
CREATE TABLE prices (
  price_id    SERIAL PRIMARY KEY,
  product_id  INT NOT NULL REFERENCES products(product_id) ON DELETE CASCADE,
  amount      INT NOT NULL
  CONSTRAINT chk_amount_non_zero CHECK (
    amount > 0 AND -- цена должна быть положительной
    amount <= 1000000 -- ограничение сверху для защиты от ошибок
  ),

  valid_from  DATE NOT NULL,
  valid_to    DATE, -- NULL означает "действует бессрочно"

  CONSTRAINT chk_price_period CHECK (valid_to IS NULL OR valid_to >= valid_from),

  CONSTRAINT no_price_overlap EXCLUDE USING GIST (
    product_id WITH =,
    daterange(valid_from, valid_to, '[]') WITH &&
  )
);

COMMENT ON TABLE prices IS 'Версионные цены продуктов (стоимость в баллах на период)';
COMMENT ON COLUMN prices.amount IS 'Цена продукта в баллах';
COMMENT ON COLUMN prices.valid_to IS 'Дата окончания действия цены (NULL означает бессрочно)';

-- ----------------------------
-- Таблица: purchases (покупки/активации)
-- ----------------------------
CREATE TABLE purchases (
  purchase_id   BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(user_id) ON DELETE CASCADE,
  product_id    INT NOT NULL REFERENCES products(product_id),
  price_id      INT NOT NULL REFERENCES prices(price_id),
  price_amount  INT NOT NULL,
  purchased_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ,
  status        purchase_status NOT NULL DEFAULT 'active',
  CONSTRAINT chk_price_amount_snapshot CHECK (price_amount > 0)
);

COMMENT ON TABLE purchases IS 'Факт покупки/активации продукта пользователем.';
COMMENT ON COLUMN purchases.price_amount IS 'Снимок цены на момент покупки (не меняется при обновлении prices).';
COMMENT ON COLUMN purchases.expires_at IS 'Срок действия активированного продукта (если применимо).';

-- Бизнес-ограничение: срок истечения должен быть позже даты покупки
ALTER TABLE purchases ADD CONSTRAINT chk_expires_after_purchase 
  CHECK (expires_at IS NULL OR expires_at > purchased_at);

COMMENT ON CONSTRAINT chk_expires_after_purchase ON purchases IS 
'Срок истечения не может быть раньше даты покупки';

-- Частичный индекс для ускорения выборок активных покупок, которые скоро истекают
CREATE INDEX idx_purchases_active_expires 
ON rewards.purchases (expires_at) 
WHERE status = 'active';

COMMENT ON INDEX rewards.idx_purchases_active_expires IS 
'Частичный индекс для поиска истекающих подписок (только активные)';

-- Индекс для выборок по продукту (например, для отчетов: Сколько пользователей приобрели продукт X?)
CREATE INDEX idx_purchases_product_id 
ON rewards.purchases (product_id);

COMMENT ON INDEX rewards.idx_purchases_product_id IS 
'Для аналитики популярности продуктов и подсчета количества покупок';

-- Композитный индекс для истории покупок пользователя
CREATE INDEX idx_purchases_user_purchased 
ON rewards.purchases (user_id, purchased_at DESC);

COMMENT ON INDEX rewards.idx_purchases_user_purchased IS 
'Для отображения истории покупок в профиле пользователя';

-- ----------------------------
-- Таблица: point_transactions (журнал баллов)
-- ----------------------------
CREATE TABLE point_transactions (
  tx_id         BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users(user_id),

  amount        INT NOT NULL,
  CONSTRAINT chk_amount_non_zero CHECK (amount <> 0), 

  balance_after INT NOT NULL,          

  type          points_tx_type NOT NULL, -- 'task_reward', 'purchase' и т.д.

  user_task_id  INT REFERENCES user_tasks(user_task_id) ON DELETE CASCADE,
  purchase_id   BIGINT REFERENCES purchases(purchase_id),

  CONSTRAINT chk_single_source CHECK (
    (user_task_id IS NOT NULL)::int + (purchase_id IS NOT NULL)::int <= 1
  ),

  external_id   UUID UNIQUE,           
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

COMMENT ON TABLE point_transactions IS 'Журнал начислений/списаний баллов пользователям';
COMMENT ON COLUMN point_transactions.external_id IS 'Идемпотентный ключ операции (защита от повторных начислений)';
COMMENT ON COLUMN point_transactions.balance_after IS 'Баланс пользователя после операции (денормализация для аудита)';
COMMENT ON COLUMN point_transactions.user_task_id IS 'Ссылка на выполненное задание (для type = task_reward)';
COMMENT ON COLUMN point_transactions.purchase_id IS 'Ссылка на покупку (для type = purchase)';

-- Ожидается самый частый запрос от мобильного приложения: «Покажи мои последние 20 транзакций».
CREATE INDEX idx_tx_user_created 
ON rewards.point_transactions (user_id, created_at DESC);

COMMENT ON INDEX rewards.idx_tx_user_created IS 
'Основной индекс для получения истории транзакций пользователя с сортировкой по дате';

-- Индекс для выборок по типу транзакции и времени (для отчетов: Сколько бонусов типа welcome_bonus мы выдали за последнюю неделю?).
CREATE INDEX idx_tx_type_created 
ON rewards.point_transactions (type, created_at);

COMMENT ON INDEX rewards.idx_tx_type_created IS 
'Для аналитических отчетов по типам операций за период';

-- Бизнес-ограничение: баланс после операции должен быть неотрицательным
ALTER TABLE point_transactions ADD CONSTRAINT chk_balance_after_non_negative 
  CHECK (balance_after >= 0);

COMMENT ON CONSTRAINT chk_balance_after_non_negative ON point_transactions IS 
'Баланс пользователя после операции не может быть отрицательным';