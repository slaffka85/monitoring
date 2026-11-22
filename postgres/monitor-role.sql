-- ============================================================================
-- Роль PostgreSQL только для чтения статистики — для postgres_exporter.
--
-- Запуск (на VPS, из каталога /opt/abavava; пароль БЕЗ дополнительных кавычек —
-- экранированием занимается psql через %L):
--
--   cd /opt/abavava
--   docker compose --env-file .env.production --env-file .deploy.env \
--     -f compose.prod.yaml exec -T postgres \
--     psql -U abavava -d abavava -v monitor_password='<пароль>' \
--     -f - < /opt/monitoring/postgres/monitor-role.sql
--
-- Пароль тот же, что в /opt/monitoring/.env (ABABAWA_DB_MONITOR_PASSWORD).
-- Роль нужна потому, что экспортёру нечего делать с правами владельца схемы:
-- ему достаточно pg_monitor — чтения pg_stat_* и pg_settings без прав на данные.
--
-- ВНИМАНИЕ: psql НЕ подставляет переменные внутрь dollar-quoted блоков
-- (DO $$ ... $$), поэтому создание роли сделано через SELECT + \gexec.
-- ============================================================================

-- Создать роль, если её ещё нет.
SELECT format('CREATE ROLE abv_monitor LOGIN PASSWORD %L', :'monitor_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'abv_monitor')
\gexec

-- Обновить пароль, если роль уже была (идемпотентный повторный запуск).
SELECT format('ALTER ROLE abv_monitor LOGIN PASSWORD %L', :'monitor_password')
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'abv_monitor')
\gexec

-- pg_monitor = pg_read_all_stats + pg_read_all_settings + pg_read_all_data-статистика.
-- Этого достаточно всем коллекторам postgres_exporter.
GRANT pg_monitor TO abv_monitor;

-- Подключение к базе приложения (по умолчанию CONNECT есть у PUBLIC, но
-- фиксируем явно на случай ужесточения прав).
GRANT CONNECT ON DATABASE abavava TO abv_monitor;

-- Никаких прав на таблицы: экспортёр читает только системные представления.
