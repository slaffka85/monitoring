# Как подключить следующий проект

Стек рассчитан на несколько проектов на одном VPS. Новый проект — это набор
меток `project` и файлов целей; конфиги Prometheus и дашборды при этом не
переписываются.

## Соглашения

* `project` — короткое имя проекта строчными буквами без пробелов (`ababawa`). Значение попадает в каждый ряд метрик,
  в переменную дашборда и в алерты, поэтому его нельзя менять задним числом.
* `component` — что именно за цель: `api`, `web`, `postgres`, `turn`, `redis`,
  `probe` и т.п.
* `env` — `production` / `staging` / `dev`.
* Один файл `prometheus/targets/<компонент>/<проект>.yml` на компонент проекта.

## Шаг 1. Решить, что вообще можно собрать

| Тип проекта | Как отдать метрики |
|---|---|
| Java / Spring Boot | `spring-boot-starter-actuator` + `micrometer-registry-prometheus` → `/actuator/prometheus` |
| Go | `promhttp.Handler()` на отдельном служебном порту → `/metrics` |
| Node.js | `prom-client` + `collectDefaultMetrics()` → `/metrics` |
| PostgreSQL | один `postgres-exporter` на сервер БД (роль `pg_monitor`), не на проект |
| Nginx | `nginx-prometheus-exporter` со stub_status, либо `location /metrics` из `nginx` с `prometheus_module` |
| Всё остальное (внешние API, домены, TLS) | `blackbox_exporter` (заготовка джобы уже есть) |

## Шаг 2. Выставить метрики на loopback

Правило стека: наружу ничего не торчит. Значит, порт метрик публикуется как
`127.0.0.1:<порт>:<порт>` либо приложение слушает loopback само (как coturn с
`--prometheus`).

Пример для Go-трека ababawa (`chat-abavava` / `abavava-go`): добавить
`promhttp` и поднять `/metrics` на `127.0.0.1:9464`, затем в его compose:

```yaml
    ports:
      - "127.0.0.1:9464:9464"
```

## Шаг 3. Файлы целей

`prometheus/targets/api/ababawa-go.yml`:

```yaml
- targets:
    - 127.0.0.1:9464
  labels:
    project: ababawa-go
    component: api
    env: production
```

Создать недостающее экспортёра-сервиса — например Redis:

```yaml
  redis-exporter:
    image: oliver006/redis_exporter:<pinned-version>
    container_name: monitoring-redis-exporter
    network_mode: host
    environment:
      REDIS_ADDR: redis://127.0.0.1:6379
      REDIS_EXPORTER_WEB_LISTEN_ADDRESS: 127.0.0.1:9121
    restart: unless-stopped
```

и файл `prometheus/targets/redis/<проект>.yml` на `127.0.0.1:9121` плюс новую
джобу в `prometheus/prometheus.yml` (по образцу `postgres`).

## Шаг 4. Проверить

```bash
# targets подхватываются сами (file_sd, refresh_interval: 1m)
docker compose exec prometheus kill -HUP 1     # правила и config
curl -s http://127.0.0.1:9090/api/v1/targets | grep -o '"health":"[a-z]*"' | sort | uniq -c
curl -s 'http://127.0.0.1:9090/api/v1/label/project/values'
```

`up{project="<новый>"} == 1` — цель жива. Если 0, у Prometheus в
`http://127.0.0.1:9090/targets` будет причина (connection refused / 404 /
timeout).

## Шаг 5. Дашборд

Переменная `project` в «ababawa / Overview» — это `label_values(up, project)`,
поэтому новый проект появляется в выпадающем списке сам, как только Prometheus
увидит его цели. Панели (API/JVM/БД/контейнеры/TURN) написаны на общих джобах
`api`/`postgres`/`turn`, так что для проекта с теми же компонентами ничего
делать не нужно.

Если у проекта другие компоненты (Redis, Kafka, Node.js вместо JVM) — проще
сделать отдельный дашборд: скопировать JSON в
`grafana/dashboards/<проект>-overview.json`, поменять `title`, `uid` и набор
панелей. Провайдер Grafana подхватывает все файлы каталога.

## Шаг 6. Алерты

Общие правила (`rules/platform.yml`) работают для нового проекта автоматически —
в частности `TargetDown`. Проектные правила добавляются отдельным файлом
`prometheus/rules/<проект>.yml`:

```yaml
groups:
  - name: ababawa-go
    rules:
      - alert: AbabawaGoErrorRateHigh
        expr: >-
          sum(rate(http_requests_total{job="api",project="ababawa-go",code=~"5.."}[5m]))
          / clamp_min(sum(rate(http_requests_total{job="api",project="ababawa-go"}[5m])), 1e-9)
          > 0.05
        for: 10m
        labels:
          project: ababawa-go
          severity: critical
        annotations:
          summary: "ababawa-go: более 5% ответов с ошибкой 5xx"
```

Проверить синтаксис до пуша:

```bash
docker run --rm --entrypoint promtool \
  -v "$PWD/prometheus/rules:/rules:ro" prom/prometheus:v3.16.0 \
  check rules /rules/platform.yml /rules/ababawa.yml
```

`group_by: [project, alertname]` в Alertmanager разложит алерты по проектам
автоматически.

## Ограничения, о которых стоит помнить

* **Один `postgres-exporter` — один сервер БД.** Две базы на одном сервере
  покрываются одним экспортёром; вторая БД на другом сервере — второй контейнер
  экспортёра (другой порт) и отдельный файл цели.
* **БД проекта не публикуется на хост?** Тогда подключайте экспортёр к
  docker-сети проекта: сервис без `network_mode: host`,
  `networks: [<проект>]`, `ports: ["127.0.0.1:<порт>:<порт>"]`, а в
  `DATA_SOURCE_URI` — DNS-имя сервиса (`postgres:5432`); сеть объявляется в
  конце `compose.yaml` как `external: true` с именем `<project>_<network>`.
  Если порт опубликован на loopback (как `5432` у ababawa) — проще обычная
  host-network цель, без внешней сети и без зависимости от чужого стека.
* **Кардинальность.** Не добавляйте метки с высокой мощностью (`user_id`,
  `message_id`, `url` с параметрами) — Prometheus хранит каждый уникальный набор
  меток отдельно. Для таких разрезов нужны логи, а не метрики.
* **Loopback из контейнера.** `network_mode: host` видит `127.0.0.1` хоста; если
  проект использует bridge-сеть, публикуйте порт метрик на `127.0.0.1` хоста, а
  не на `0.0.0.0`.
