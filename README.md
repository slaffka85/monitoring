# monitoring

Стек наблюдаемости для проектов, которые я делаю и держу на своём VPS.
Первый (и пока единственный) проект — **ababawa** (бывший `abavava`): Java API,
React-клиент, PostgreSQL и coturn для видеозвонков.

Задача репозитория — быть точкой расширения: добавить второй проект должно
значить «добавить файл целей и, при необходимости, контейнер экспортёра», а не
переписывать конфиги. Как это устроено — [docs/ADD-PROJECT.md](docs/ADD-PROJECT.md).

## Что уже собирается

| Источник | Что видно | Откуда данные |
|---|---|---|
| Java API ababawa | RPS, p95-задержка, доля 5xx, разбивка по статусам и эндпоинтам, JVM (heap, GC, потоки), пул HikariCP | `GET /actuator/prometheus` — Spring Boot Actuator + Micrometer, порт `127.0.0.1:18082` |
| PostgreSQL | соединения и `max_connections`, размер БД, commit/rollback в секунду, buffer cache hit, долгие транзакции, блокировки, deadlock-и | `postgres-exporter` живёт в docker-сети ababava (постгрес на хост не публикуется), наружу для скрейпа — `127.0.0.1:9187` |
| coturn (TURN) | живые аллокации (сессии) по протоколам, обработанные/отброшенные пакеты, байты завершённых сессий, отказы аутентификации | `127.0.0.1:9641/metrics` — **требует `--prometheus` в coturn**, сейчас в abavava флаг не включён, цель лежит заготовкой `targets/turn/ababawa.yml.example` |
| Контейнеры | CPU и RAM по `abavava-api-1`, `-web-1`, `-postgres-1`, `-coturn-1` | `cAdvisor` на `127.0.0.1:8088` |
| Хост VPS | загрузка CPU, занятая RAM, место на `/`, PSI-давление на память | `node-exporter` на `127.0.0.1:9100` |
| Сам стек | `up` по всем целям, скорость вычисления правил, успешность reload | Prometheus `127.0.0.1:9090` |

Панели: дашборд **«ababawa / Overview»** (uid `ababawa-overview`) с переменной
`project` — им же будут открываться следующие проекты.
Алерты: `prometheus/rules/*.yml`, доставка через Alertmanager (`alertmanager/alertmanager.yml`).

## Как это устроено

```
VPS (Linux)
├── /opt/abavava          прод ababawa (свой compose): api 127.0.0.1:18082,
│                         web 127.0.0.1:18080, postgres — только внутри
│                         docker-сети abavava_default, coturn 3478/udp
└── /opt/monitoring       этот репозиторий
    ├── prometheus        :9090  ← скрейпит всё перечисленное по loopback
    ├── alertmanager      :9093
    ├── grafana           :3001  ← панели
    ├── node-exporter     :9100
    ├── cadvisor          :8088
    └── postgres-exporter :9187  ← внутри сети abavava, наружу только loopback
```

Сознательные решения:

* **`network_mode: host` и только loopback.** Все сервисы слушают `127.0.0.1`,
  поэтому снаружи панели недоступны без SSH-туннеля, порты не публикуются и не
  требуют правок файрвола. Docker-сеть между `abavava` и `monitoring` не нужна:
  приложение уже публикует свои порты на loopback хоста.
* **Исключение — `postgres_exporter`.** Прод-постгрес на хост не публикуется
  (так задумано в abavava), поэтому экспортёр подключён к чужой сети
  `abavava_default` как `external` и ходит в БД по DNS-имени `postgres`, а
  наружу выставлен только `127.0.0.1:9187` для скрейпа. Следствие: стек
  поднимается **после** ababava, иначе сети ещё нет и `compose up` упадёт.
* **Цели проектов — через `file_sd`.** `prometheus/targets/<компонент>/<проект>.yml`
  перечитывается раз в минуту: цели можно менять без перезапуска Prometheus.
* **Дашборды и алерты — как код.** JSON дашбордов и правила лежат в Git,
  Grafana не даёт править их из UI (`allowUiUpdates: false`), так что «накрутил
  в интерфейсе и забыл» не случится.
* **Версии образов запинены** (Prometheus 3.16.0, Grafana 13.2.6, Alertmanager
  0.35.0, node-exporter 1.13.1, cAdvisor 0.61.1, postgres-exporter 0.21.1).
  Обновление — отдельный осознанный шаг, а не сюрприз при `pull`.

Одна оговорка про TURN. Метрики coturn появляются только при флаге
`--prometheus`, а в текущем `/opt/abavava/compose.prod.yaml` его нет — поэтому
файл цели лежит заготовкой: `prometheus/targets/turn/ababawa.yml.example`
(Prometheus читает только `*.yml`, так что она игнорируется и `TargetDown` не
шумит).

Включить (нужны правки в обоих репозиториях):

1. в репозитории abavava в команду сервиса `coturn` добавить `- --prometheus`;
   если сборка поддерживает `--prometheus-address`, добавить и
   `- --prometheus-address=127.0.0.1` — без него coturn слушает **все**
   интерфейсы на `:9641`;
2. выкатить abavava и проверить: `curl -s http://127.0.0.1:9641/metrics | head`;
3. в этом репозитории переименовать `prometheus/targets/turn/ababawa.yml.example`
   → `ababawa.yml` и раскомментировать джобу `turn` в `prometheus/prometheus.yml`
   (в закомментированном виде она не сыпет WARNING про пустой file_sd);
4. запушить — CI разложит файлы и пересоздаст Prometheus.

Если оставлять порт открытым нельзя, а метрики нужны — либо
`--prometheus-address=127.0.0.1`, либо `sudo ufw deny 9641/tcp`.

## Установка на VPS

Пошаговая инструкция с предусловиями, проверками и диагностикой —
**[docs/DEPLOY.md](docs/DEPLOY.md)**. Ниже — сжатая версия.

Нужен только Docker Engine + Compose plugin (на VPS он уже есть для ababawa).
Все шаги — от пользователя деплоя (`deploy`), без sudo (кроме создания каталога
в шаге 1).

При работе через CI шаги 1, 2 и 4 выполняются автоматически после пуша в `main`;
руками остаётся только роль БД (шаг 3).

### 1. Каталог и файлы

`/opt` принадлежит root, поэтому каталог создаётся один раз от root:

```bash
sudo install -d -o deploy -g deploy -m 0755 /opt/monitoring
```

Дальше файлы раскладывает CI (пуш в `main`). Если CI не нужен — скопировать
локально одной командой:

```bash
tar -czf - compose.yaml prometheus alertmanager grafana postgres \
  | ssh deploy@<VPS_HOST> 'cd /opt/monitoring && tar -xzf -'
```

### 2. Секреты

```bash
cd /opt/monitoring
cp .env.example .env        # или создайте .env на VPS
chmod 600 .env
# заполните GRAFANA_ADMIN_PASSWORD и ABABAWA_DB_MONITOR_PASSWORD:
openssl rand -base64 24
```

### 3. Роль БД для экспортёра

Экспортёру не нужны права владельца схемы — только чтение статистики.
Пароль в `.env` (`ABABAWA_DB_MONITOR_PASSWORD`) и в SQL должны совпадать.

```bash
# на VPS, рядом с прод-стеком ababawa
cd /opt/abavava
docker compose --env-file .env.production --env-file .deploy.env \
  -f compose.prod.yaml exec -T postgres \
  psql -U abavava -d abavava -v monitor_password='<пароль из .env>' \
  -f - < /opt/monitoring/postgres/monitor-role.sql
```

Пароль передаётся без дополнительных кавычек (`-v имя='значение'`): psql сам
экранирует его через `%L`. Скрипт идемпотентен — повторный запуск просто
обновит пароль роли.

Проверка, что экспортёр сможет подключиться (метрики отдаются на loopback хоста,
поэтому достаточно curl с VPS — exec внутрь контейнера не нужен):

```bash
curl -s http://127.0.0.1:9187/metrics | grep '^pg_up'
# pg_up 1
```

### 4. Запуск

```bash
cd /opt/monitoring
docker compose pull
docker compose up -d
docker compose ps
```

### 5. Проверка, что метрики пошли

```bash
curl -s http://127.0.0.1:9090/api/v1/targets \
  | grep -o '"health":"[a-z]*"' | sort | uniq -c
# ожидаем up для postgres, node, cadvisor, prometheus, alertmanager;
# api станет up после выкатки ababawa с Actuator (см. следующий раздел),
# turn — только если включён --prometheus у coturn

curl -s 'http://127.0.0.1:9090/api/v1/label/project/values'
# {"status":"success","data":["ababawa"]}
```

`job="api"` будет `down`, пока на VPS не поедет образ ababawa с включённым
Actuator. `job="turn"` по умолчанию отсутствует: файл цели лежит заготовкой
(метрики TURN требуют флага `--prometheus`, см. выше).

## Что нужно со стороны ababawa

Метрики приложения — это две правки в репозитории `abavava`:

1. `pom.xml` — `spring-boot-starter-actuator` и `micrometer-registry-prometheus`
   (версии из BOM Spring Boot 4.1.2).
2. `src/main/resources/application.yml` — секция `management`: открыты только
   `health` и `prometheus`, добавлена общая метка `application: ababawa`.

Эндпоинт `GET /actuator/prometheus` живёт на том же порту, что и API, и наружу
не публикуется: Nginx проксирует только `/api/` (в api) и `/` (в web), а сам
порт контейнера опубликован исключительно на `127.0.0.1:18082`.
Правки `compose.prod.yaml` не нужны.

Раскатка — обычным путём репозитория abavava:

```bash
cd /path/to/abavava
git add pom.xml src/main/resources/application.yml
git commit -m "feat(metrics): expose /actuator/prometheus for monitoring"
git push        # deploy-vps.yml соберёт образ и выкатит его на VPS
```

Деплой запускается только для ветвей из `on.push.branches` в
`.github/workflows/deploy-vps.yml` репозитория abavava. Если правки лежат в
отдельной ветке — либо добавьте её в список, либо влейте в `main`.

> Если локальная сборка идёт офлайн (`build.ps1 check` с `mvn -o`), один раз
> выполните онлайн-команду `mvn -q -DskipTests compile` — в локальный кэш Maven
> должны попасть actuator 4.1.2 и micrometer 1.17.2, которых там пока нет.
> CI abavava собирает образ онлайн, поэтому сам деплой это не блокирует.

Проверка на VPS после деплоя:

```bash
curl -s http://127.0.0.1:18082/actuator/prometheus | head -20
```

## Доступ к панелям

Все порты слушают loopback, поэтому — SSH-туннели с рабочей машины:

```powershell
# Grafana:    http://127.0.0.1:3001
ssh -N -L 3001:127.0.0.1:3001 deploy@<VPS_HOST>
# Prometheus: http://127.0.0.1:9090  (в другом окне)
ssh -N -L 9090:127.0.0.1:9090 deploy@<VPS_HOST>
# Alertmanager: http://127.0.0.1:9093
ssh -N -L 9093:127.0.0.1:9093 deploy@<VPS_HOST>
```

Логин в Grafana — `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD` из `.env`.
Если очень нужно открыть панели в интернет — делать это через тот же Nginx с
TLS и basic-auth, а не публикацией порта: Prometheus и Alertmanager вообще не
умеют аутентификацию.

## Алерты

| Алерт | Смысл | Что делать |
|---|---|---|
| `TargetDown` | любая цель не скрейпится 2 мин | `docker compose ps` в /opt/monitoring и /opt/abavava, `ss -ltnp` |
| `AbabawaApiErrorRateHigh` | >5% ответов 5xx | `docker logs --tail=200 abavava-api-1`, панель «по статусам» |
| `AbabawaApiLatencyHigh` | p95 > 1 c | панель «БД»: медленные запросы, соединения, CPU |
| `AbabawaJvmHeapHigh` | heap > 90% | проверить лимит памяти контейнера api и GC в панели JVM |
| `AbabawaJvmGcPauseHigh` | средняя пауза GC > 0,5 c | обычно следствие heap-давления или нехватки CPU |
| `AbabawaDbDown` | `pg_up = 0` | контейнер postgres, лимит соединений, свободное место |
| `AbabawaDbConnectionsHigh` | >80% `max_connections` | пул приложения (`hikaricp_connections_*`), утечки соединений |
| `AbabawaDbLongTransaction` | транзакция > 10 мин | `pg_stat_activity`, блокировки, bloat |
| `AbabawaDbDeadlocks` | есть deadlock-и | искать в логах api пары операций, конфликтующих по строкам |
| `AbabawaTurnAuthFailures` | TURN отклоняет креденшелы | только при включённых метриках TURN: `GET /api/v1/config/ice`, `ABV_TURN_*` в `/opt/abavava/.deploy.env`; симптом — звонок «идёт», медиа нет |
| `HostDiskSpaceLow` | <15% на `/` | чистка образов (`docker image prune`), ретеншен Prometheus |
| `HostMemoryPressureHigh` | PSI memory > 20% | `docker stats`; кандидат на OOM-kill |

Доставка по умолчанию выключена намеренно: алерты видны в UI Alertmanager, но
никуда не уходят. Включить канал (Telegram / e-mail через Postfix хоста /
webhook) — раскомментировать блок в `alertmanager/alertmanager.yml` и
`docker compose restart alertmanager`.

## CI и деплой

`.github/workflows/deploy-vps.yml`:

* **validate** (PR и push) — `docker compose config`, `promtool check config`,
  `promtool check rules`, `amtool check-config`, проверка JSON дашбордов.
  Правила проверяются тем же образом Prometheus, что и в проде;
* **deploy** (push в `main` и `workflow_dispatch`) — раскладывает файлы в
  `/opt/monitoring`, пишет `.env` из секретов, делает `pull` и пересоздаёт
  контейнеры (`up -d --force-recreate`), затем проверяет, что Prometheus и
  Grafana отвечают.

Секреты репозитория: `VPS_HOST`, `VPS_USER`, `VPS_SSH_PRIVATE_KEY`,
`VPS_KNOWN_HOSTS` (те же значения, что в репозитории abavava),
`GRAFANA_ADMIN_PASSWORD`, `ABABAWA_DB_MONITOR_PASSWORD`.
Переменные (не секреты, опционально): `GRAFANA_ADMIN_USER`, `GRAFANA_ROOT_URL`,
`ABABAWA_DB_MONITOR_USER`.

Роль БД одноразовая и в деплой не входит — шаг 3 выполняется руками, потому что
требует доступа к чужому стеку и пароля, которого в CI быть не должно.

## Эксплуатация

```bash
cd /opt/monitoring

# правила и config/targets перечитываются без перезапуска
docker compose exec prometheus kill -HUP 1     # или POST /-/reload
# targets подхватываются автоматически (file_sd, 1 минута)

docker compose logs -f --tail=100 prometheus   # отладка скрейпа
docker compose ps                              # что упало
```

* Ретеншен — 15 дней или 2 ГБ, что наступит раньше. Для истории за месяцы нужен
  внешний remote-write, это отдельная задача.
* Дашборд правится только через Git: `grafana/dashboards/*.json` →
  `docker compose restart grafana` (или подождать `updateIntervalSeconds: 30`).
* Проверка перед пушем — локально тот же набор, что в CI:
  `docker compose config --quiet` и `docker run --rm --entrypoint promtool -v "$PWD/prometheus:/etc/prometheus:ro" prom/prometheus:v3.16.0 check config /etc/prometheus/prometheus.yml`

## Что дальше

Осознанно не входит в первую версию:

* **Внешние проверки (blackbox_exporter):** доступность `https://ababawa.tssv85.com`,
  срок TLS-сертификата, редиректы. Заготовка джобы уже лежит в
  `prometheus/prometheus.yml` — нужен сервис и файлы целей.
* **Логи:** Loki + Promtail дали бы поиск по логам api рядом с метриками.
* **Бизнес-метрики ababawa:** сообщения/с, доставки, длительность и итог звонков,
  активные WebSocket-соединения. Требуют счётчиков в доменном коде приложения
  (пункт roadmap «Метрики Prometheus»), панели добавятся без изменений стека.
* **Синтетика:** прогон `media:check` из CI как метрика «звонки работают».
