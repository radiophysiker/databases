# Анализ индексов и ограничений БД бонусной системы

## 1. Анализ возможных запросов и отчетов

### Типичные запросы приложения

1. **Авторизация**: Поиск пользователя по номеру телефона
2. **Профиль пользователя**: Получение баланса и информации о пользователе
3. **История транзакций**: Последние 20 операций пользователя
4. **Активные покупки**: Список активных продуктов пользователя
5. **Ежедневные задания**: Список доступных заданий на сегодня
6. **Birthday-бонусы**: Массовое начисление бонусов именинникам

### Аналитические запросы

1. Отчет по начислениям бонусов по типам за период
2. Популярность продуктов (количество покупок)
3. Активность пользователей по регионам
4. Поиск истекающих покупок для уведомлений

---

## 2. Созданные индексы с описанием

### 2.1. Индексы для таблицы `users`

**Автоматические индексы:**

- `PRIMARY KEY (user_id)` - B-tree, уникальный идентификатор
- `UNIQUE (phone)` - B-tree, уникальный поиск по телефону

**Дополнительный индекс:**

```sql
CREATE INDEX idx_users_region_id ON users (region_id);
```

- **Кардинальность**: Низкая (~100 регионов на миллионы пользователей)
- **Зачем**: Массовые рассылки региональных промо-акций, аналитика по регионам
- **Тип запроса**: `SELECT * FROM users WHERE region_id = 5`

---

### 2.2. Индексы для таблицы `user_profiles`

```sql
CREATE INDEX idx_profiles_birthday_month_day 
ON user_profiles (extract(month from birth_date), extract(day from birth_date));
```

- **Кардинальность**: Средняя (~365 комбинаций месяц-день)
- **Зачем**: Ежедневное автоматическое начисление birthday_bonus
- **Тип запроса**:

```sql
SELECT user_id FROM user_profiles 
WHERE extract(month from birth_date) = 3 
  AND extract(day from birth_date) = 15;
```

---

### 2.3. Индексы для таблицы `purchases`

```sql
-- Частичный индекс для активных покупок с истечением
CREATE INDEX idx_purchases_active_expires 
ON purchases (expires_at) 
WHERE status = 'active';
```

- **Кардинальность**: Средняя (зависит от длительности подписок)
- **Зачем**: Ежедневная задача проверки истекающих подписок для отправки уведомлений
- **Особенность**: Частичный индекс экономит место (индексируются только активные)
- **Тип запроса**:

```sql
SELECT * FROM purchases 
WHERE status = 'active' 
  AND expires_at BETWEEN NOW() AND NOW() + INTERVAL '7 days';
```

```sql
-- Индекс для аналитики по продуктам
CREATE INDEX idx_purchases_product_id ON purchases (product_id);
```

- **Кардинальность**: Низкая (~50-200 продуктов)
- **Зачем**: Отчеты по популярности продуктов, подсчет количества покупок
- **Тип запроса**: `SELECT COUNT(*) FROM purchases WHERE product_id = 10`

---

### 2.4. Индексы для таблицы `point_transactions`

```sql
-- Композитный индекс для истории пользователя
CREATE INDEX idx_tx_user_created 
ON point_transactions (user_id, created_at DESC);
```

- **Кардинальность**: Высокая по user_id + timestamp
- **Зачем**: Самый частый запрос - история транзакций в мобильном приложении
- **Тип запроса**:

```sql
SELECT * FROM point_transactions 
WHERE user_id = 12345 
ORDER BY created_at DESC 
LIMIT 20;
```

```sql
-- Индекс для аналитики по типам транзакций
CREATE INDEX idx_tx_type_created 
ON point_transactions (type, created_at);
```

- **Кардинальность**: Низкая по type (~5 типов), высокая по timestamp
- **Зачем**: Аналитические отчеты по начислениям/списаниям бонусов
- **Тип запроса**:

```sql
SELECT type, SUM(amount) 
FROM point_transactions 
WHERE created_at >= NOW() - INTERVAL '7 days'
GROUP BY type;
```

---

## 3. Логические ограничения (Constraints)

### 3.1. Ограничения целостности данных

#### Таблица `users`

```sql
-- Формат телефона: ровно 10 цифр
CONSTRAINT chk_phone_digits CHECK (phone ~ '^\\d{10}$')

-- Баланс не может быть отрицательным
CONSTRAINT chk_balance_non_negative CHECK (current_balance >= 0)
```

**Бизнес-логика**: Защита от некорректных номеров и отрицательного баланса

#### Таблица `user_profiles`

```sql
-- Допустимый диапазон дат рождения
CONSTRAINT chk_birth_date_valid CHECK (
  birth_date > '1900-01-01'
)
```

**Бизнес-логика**: Защита от ошибок ввода

#### Таблица `tasks`

```sql
-- Награда должна быть положительной
CONSTRAINT chk_reward_points CHECK (reward_points > 0)
```

**Бизнес-логика**: Нельзя создать задание без награды или с отрицательной наградой

#### Таблица `task_availability`

```sql
-- Окончание периода не раньше начала
CONSTRAINT chk_task_availability_dates CHECK (valid_to >= valid_from)
```

**Бизнес-логика**: Временной период должен быть корректным

#### Таблица `products`

```sql
-- Длительность продукта положительна или NULL (бессрочно)
CONSTRAINT chk_duration_days CHECK (duration_days IS NULL OR duration_days > 0)
```

**Бизнес-логика**: Защита от некорректной длительности подписки

#### Таблица `prices`

```sql
-- Цена в разумных пределах
CONSTRAINT chk_amount_non_zero CHECK (
  amount > 0 AND 
  amount <= 1000000
)

-- Период цены корректен
CONSTRAINT chk_price_period CHECK (valid_to IS NULL OR valid_to >= valid_from)

-- Исключение пересечения периодов цен для одного продукта
CONSTRAINT no_price_overlap EXCLUDE USING GIST (
  product_id WITH =,
  daterange(valid_from, valid_to, '[]') WITH &&
)
```

**Бизнес-логика**:

- Цена должна быть положительной и не превышать разумный максимум
- Для одного продукта не может быть двух действующих цен одновременно
- Период действия цены должен быть корректным

#### Таблица `purchases`

```sql
-- Снимок цены должен быть положительным
CONSTRAINT chk_price_amount_snapshot CHECK (price_amount > 0)
```

**Бизнес-логика**: При покупке цена всегда положительная

#### Таблица `point_transactions`

```sql
-- Сумма транзакции не может быть нулевой
CONSTRAINT chk_amount_non_zero CHECK (amount <> 0)

-- Транзакция может иметь только один источник
CONSTRAINT chk_single_source CHECK (
  (user_task_id IS NOT NULL)::int + (purchase_id IS NOT NULL)::int <= 1
)
```

**Бизнес-логика**:

- Нельзя провести операцию на 0 баллов
- Начисление/списание должно иметь четкий источник (или задание, или покупка, или ничего для manual_adjustment)

---

### 3.2. Ограничения уникальности

```sql
-- Один номер телефона - один пользователь
users.phone UNIQUE

-- Код региона уникален
regions.code UNIQUE

-- Код задания уникален
tasks.code UNIQUE

-- Код продукта уникален
products.code UNIQUE

-- Задание может быть назначено только один раз на конкретную дату
CONSTRAINT uq_daily_tasks_task_date UNIQUE (task_id, task_date)

-- Пользователь не может выполнить одно задание дважды
CONSTRAINT uq_user_tasks_user_daily_task UNIQUE (user_id, daily_task_id)

-- Идемпотентность транзакций
point_transactions.external_id UNIQUE
```

---

---

## 4. Дополнительные индексы (расширенная версия)

### 4.1. Таблица `task_availability`

```sql
CREATE INDEX idx_task_availability_dates 
ON task_availability (task_id, valid_from, valid_to);
```

- **Кардинальность**: Средняя
- **Зачем**: Поиск активных промо-заданий на текущую дату
- **Тип запроса**:

```sql
SELECT * FROM task_availability 
WHERE task_id = 5 
  AND CURRENT_DATE BETWEEN valid_from AND valid_to;
```

### 4.2. Таблица `daily_tasks`

```sql
CREATE INDEX idx_daily_tasks_date 
ON daily_tasks (task_date);
```

- **Кардинальность**: Средняя (одно значение даты в день, но объем растет во времени)
- **Зачем**: Операции «покажи задания на сегодня/на дату X» идут часто, нужна быстрая выборка без seq scan по всей истории
- **Тип запроса**:

```sql
SELECT * 
FROM daily_tasks 
WHERE task_date = CURRENT_DATE;
```

### 4.3. Таблица `user_tasks`

```sql
-- Для аналитики по заданиям
CREATE INDEX idx_user_tasks_daily_task 
ON user_tasks (daily_task_id, completed_at);

-- Для профиля пользователя
CREATE INDEX idx_user_tasks_user_completed 
ON user_tasks (user_id, completed_at DESC);
```

- **Кардинальность**: Высокая
- **Зачем**:
  1. Аналитика: сколько пользователей выполнили задание
  2. История выполненных заданий пользователя

### 4.4. Таблица `purchases` (дополнительный индекс)

```sql
CREATE INDEX idx_purchases_user_purchased 
ON purchases (user_id, purchased_at DESC);
```

- **Кардинальность**: Высокая
- **Зачем**: История покупок в профиле пользователя
- **Тип запроса**:

```sql
SELECT * FROM purchases 
WHERE user_id = 12345 
ORDER BY purchased_at DESC 
LIMIT 10;
```

---

## 5. Дополнительные бизнес-ограничения

### 5.1. Таблица `purchases`

```sql
ALTER TABLE purchases ADD CONSTRAINT chk_expires_after_purchase 
  CHECK (expires_at IS NULL OR expires_at > purchased_at);
```

**Бизнес-логика**: Срок истечения продукта не может быть раньше даты покупки

### 5.2. Таблица `point_transactions`

```sql
ALTER TABLE point_transactions ADD CONSTRAINT chk_balance_after_non_negative 
  CHECK (balance_after >= 0);
```

**Бизнес-логика**: После любой операции баланс пользователя остается неотрицательным (защита от овердрафта)

---
