# Развёртывание на VPS

Пошаговая инструкция «с нуля до панелей». Всё выполняется на VPS, где уже
работает прод ababawa (`/opt/abavava`), под пользователем деплоя (`deploy`,
член группы `docker`). Sudo нужен ровно один раз — на шаге 1.

Обозначения:

```bash
export VPS_HOST=<ip или домен>
export VPS_USER=deploy
```

---

## Шаг 0. Предусловия

Все команды ниже выполняются на VPS от пользователя деплоя (`deploy`, член
группы `docker`), кроме помеченных `sudo`.

```bash
docker compose version            # v2.x
docker ps --format '{{.Names}}'   # abavava-api-1, abavava-web-1, abavava-postgres-1, abavava-coturn-1
```

Порты стека должны быть свободны (все — loopback):

```bash
ss -ltn | grep -E ':(9090|9093|3001|9100|8088|9187)\b' || echo 'порты свободны'
```

Что должно отвечать до первого запуска (это те цели, которые будет скрейпить
Prometheus):

```bash
curl -s -o /dev/null -w 'api      %{http_code}\n' http://127.0.0.1:18082/healthz        # 200
curl -s -o /dev/null -w 'coturn   %{http_code}\n' http://127.0.0.1:9641/metrics         # 200
ss -ltn | grep -q '127.0.0.1:5432' && echo 'postgres ok' || echo 'postgres НЕ опубликован'
```

`127.0.0.1:5432` в abavava публикуется сервисом `postgres`
(`"127.0.0.1:5432:5432"`), `9641` открывает coturn с флагом `--prometheus`.
Если postgres не опубликован — `postgres_exporter` не сможет подключиться;
вариант решения — подключить экспортёр к docker-сети проекта
(`docs/ADD-PROJECT.md`, раздел «Ограничения»).

## Шаг 1. Каталог на VPS (один раз, от root)

`/opt` принадлежит root, поэтому каталог создаёт админ и отдаёт деплой-юзеру:

```bash
sudo install -d -o deploy -g deploy -m 0755 /opt/monitoring
```

Дальше всё делает CI. Проверка: `ssh deploy@$VPS_HOST 'test -w /opt/monitoring && echo ok'`.

## Шаг 2. Секреты GitHub

Сгенерируйте два пароля (на любой машине):

```bash
openssl rand -base64 24   # GRAFANA_ADMIN_PASSWORD
openssl rand -base64 24   # ABABAWA_DB_MONITOR_PASSWORD
```

Сохраните оба — второй понадобится на шаге 4.

В репозитории `slaffka85/monitoring`: **Settings → Secrets and variables →
Actions**.

| Тип | Имя | Значение |
|---|---|---|
| Secret | `VPS_HOST` | IP или домен VPS |
| Secret | `VPS_USER` | `deploy` |
| Secret | `VPS_SSH_PRIVATE_KEY` | приватный ключ деплоя (тот же, что в repo abavava) |
| Secret | `VPS_KNOWN_HOSTS` | строка known_hosts для VPS (та же, что в abavava) |
| Secret | `GRAFANA_ADMIN_PASSWORD` | первый сгенерированный пароль |
| Secret | `ABABAWA_DB_MONITOR_PASSWORD` | второй сгенерированный пароль |
| Variable | `GRAFANA_ADMIN_USER` | *(опционально)* `admin` |
| Variable | `GRAFANA_ROOT_URL` | *(опционально)* `http://127.0.0.1:3001` |
| Variable | `ABABAWA_DB_MONITOR_USER` | *(опционально)* `abv_monitor` |

Первые четыре значения уже есть в настройках репозитория `abavava` — секреты
не переносятся между репозиториями автоматически, их нужно добавить и здесь.

## Шаг 3. Первый деплой

Вариант А — через CI (рекомендуется). Запушьте репозиторий в `main`:

```bash
git push origin main
```

или запустите вручную: **Actions → Validate and deploy to VPS → Run workflow**.

Что произойдёт:

1. **validate** — `docker compose config`, `promtool check config`,
   `promtool check rules`, `amtool check-config`, парсинг JSON дашбордов;
2. **deploy** — создаст `/opt/monitoring` (если может), заменит каталоги
   конфигов, запишет `.env` из секретов (`umask 077`), сделает
   `docker compose pull && up -d --force-recreate`, дождётся `/‑/ready` у
   Prometheus и `/api/health` у Grafana.

Вариант Б — руками, если CI недоступен: см. [Ручной деплой](#ручной-деплой-без-github-actions).

Промежуточный итог первого деплоя (7 целей: `prometheus`, `alertmanager`,
`node`, `cadvisor`, `postgres`, `turn`, `api`):

* `prometheus`, `alertmanager`, `grafana`, `node-exporter`, `cadvisor` — `up`;
* `turn` — `up` (coturn с `--prometheus` уже работает в проде);
* `postgres` — цель `up`, но `pg_up 0`: экспортёру ещё нет роли БД
  (лечится шагом 4);
* `api` — `down`: в текущем образе ababawa нет `/actuator/prometheus`
  (лечится шагом 5).

## Шаг 4. Роль БД для postgres_exporter

Один раз, с паролем из `ABABAWA_DB_MONITOR_PASSWORD` (без лишних кавычек):

```bash
ssh deploy@$VPS_HOST
cd /opt/abavava
docker compose --env-file .env.production --env-file .deploy.env \
  -f compose.prod.yaml exec -T postgres \
  psql -U abavava -d abavava -v monitor_password='<ABABAWA_DB_MONITOR_PASSWORD>' \
  -f - < /opt/monitoring/postgres/monitor-role.sql
```

Скрипт идемпотентен (создаст роль или обновит пароль) и выдаёт только
`pg_monitor` + `CONNECT` — прав на таблицы нет.

Применить и проверить:

```bash
cd /opt/monitoring
docker compose restart postgres-exporter
sleep 5
curl -s http://127.0.0.1:9187/metrics | grep '^pg_up'      # pg_up 1
```

Если `pg_up 0` — смотрите `docker compose logs postgres-exporter`: чаще всего
несовпадение пароля с `.env` или роль не создана.

## Шаг 5. Включить метрики приложения

Правки в репозитории `abavava` уже подготовлены (`pom.xml` и
`application.yml`). Если они ещё не в Git — закоммитить и запушить; если уже
закоммичены в ветку, отличную от `main`, — влить в ветку из
`on.push.branches` в `.github/workflows/deploy-vps.yml` этого репозитория
(сейчас там `main` и `monitoring`):

```bash
cd /path/to/abavava
git add pom.xml src/main/resources/application.yml
git commit -m "feat(metrics): expose /actuator/prometheus for monitoring"
git push        # deploy-vps.yml соберёт образ и выкатит его на VPS
```

После выкатки:

```bash
ssh deploy@$VPS_HOST 'curl -s http://127.0.0.1:18082/actuator/prometheus | head -5'
# # HELP jvm_memory_used_bytes ...
```

> Локальная офлайн-сборка (`build.ps1 check` с `mvn -o`) после этих правок
> потребует один онлайн-прогон `mvn -q -DskipTests compile`, чтобы в кэш Maven
> попали actuator 4.1.2 и micrometer 1.17.2. CI собирает образ онлайн.

## Шаг 6. Проверка, что всё собралось

```bash
ssh deploy@$VPS_HOST
cd /opt/monitoring
docker compose ps                                  # все running

curl -s http://127.0.0.1:9090/-/ready              # Prometheus Server is Ready.
curl -s http://127.0.0.1:3001/api/health           # {"database":"ok",...}

# цели: prometheus, alertmanager, node, cadvisor, postgres, turn, api
curl -s http://127.0.0.1:9090/api/v1/targets \
  | grep -o '"health":"[a-z]*"' | sort | uniq -c
# 6 "health":"up"     ← после шага 4 (turn поднимается сразу)
# 1 "health":"down"   ← api, пока не выполнен шаг 5
# подробности по каждой цели: http://127.0.0.1:9090/targets (через туннель)

curl -s 'http://127.0.0.1:9090/api/v1/label/project/values'   # ["ababawa"]
curl -s http://127.0.0.1:9090/api/v1/rules | head -c 300      # правила загружены
```

Чек-лист:

- [ ] `docker compose ps` — 6 сервисов `running`
- [ ] цели `up`, кроме `api` (до шага 5)
- [ ] `pg_up 1` на `127.0.0.1:9187/metrics`
- [ ] `curl 127.0.0.1:18082/actuator/prometheus` отдаёт метрики
- [ ] в Prometheus `/alerts` нет `TargetDown`
- [ ] в Grafana открывается дашборд «ababawa / Overview» без ошибок запросов
- [ ] панели «TURN: …» показывают данные (в проде уже есть `--prometheus`)

## Шаг 7. Проверить порт метрик TURN

Метрики TURN собираются сразу — coturn в проде уже запущен с `--prometheus`
(образ `coturn/coturn:4.19.2`, `network_mode: host`). Единственное, что нужно
проверить руками: **куда** слушает экспортёр. Без `--prometheus-address` он
поднимается на всех интерфейсах:

```bash
ss -ltnp | grep 9641          # 0.0.0.0:9641 или 127.0.0.1:9641?
curl -s http://127.0.0.1:9641/metrics | head -5
```

Если слушает `0.0.0.0` — закройте порт файрволом:

```bash
sudo ufw deny 9641/tcp        # или правило в security group провайдера
```

Либо (предпочтительнее) ограничить адрес в abavava — флаг поддержан в 4.19.2:

```yaml
# compose.prod.yaml, сервис coturn, в command:
      - --prometheus
      - --prometheus-address=127.0.0.1
```

## Доступ к панелям

Порты слушают только loopback, поэтому — SSH-туннели с рабочей машины
(PowerShell):

```powershell
ssh -N -L 3001:127.0.0.1:3001 deploy@<VPS_HOST>   # Grafana:    http://127.0.0.1:3001
ssh -N -L 9090:127.0.0.1:9090 deploy@<VPS_HOST>   # Prometheus: http://127.0.0.1:9090
ssh -N -L 9093:127.0.0.1:9093 deploy@<VPS_HOST>   # Alertmanager: http://127.0.0.1:9093
```

Логин — `GRAFANA_ADMIN_USER` / `GRAFANA_ADMIN_PASSWORD`.
Открывать порты в интернет не нужно: Prometheus и Alertmanager не умеют
аутентификацию, а Grafana без TLS/basic-auth станет дырой.

## Обновление стека

```bash
# правки конфигов: пуш в main → CI сам разложит файлы и пересоздаст контейнеры
git push origin main
```

Только правила/цели, без пересоздания контейнеров (быстро, без простоя):

```bash
ssh deploy@$VPS_HOST
cd /opt/monitoring
docker compose exec prometheus kill -HUP 1     # перечитать config + rules
# цели file_sd подхватываются сами в течение минуты
```

Обновление версии образа: поменять тег в `compose.yaml`, запушить. Пин
специально сделан в одном месте, чтобы обновление было осознанным шагом.

## Откат

```bash
cd /opt/monitoring
git -C /path/to/monitoring revert <commit>     # или вернуть прежние теги в compose.yaml
git push                                        # CI разложит прежнюю версию
```

Полный сброс данных (метрики и настройки Grafana):

```bash
cd /opt/monitoring
docker compose down -v        # ВНИМАНИЕ: удаляет prometheus/grafana/alertmanager volumes
docker compose up -d
```

## Ручной деплой (без GitHub Actions)

```bash
# локально
tar -czf monitoring.tgz compose.yaml prometheus alertmanager grafana postgres
scp monitoring.tgz deploy@$VPS_HOST:/tmp/

# на VPS
ssh deploy@$VPS_HOST
cd /opt/monitoring
rm -rf prometheus alertmanager grafana postgres
tar -xzf /tmp/monitoring.tgz
cp .env.example .env && chmod 600 .env
$EDITOR .env                    # GRAFANA_ADMIN_PASSWORD, ABABAWA_DB_MONITOR_PASSWORD
docker compose pull
docker compose up -d --remove-orphans --force-recreate
```

## Диагностика

| Симптом | Причина | Что делать |
|---|---|---|
| `up{job="api"} = 0`, в `/targets` — 404 | на VPS старый образ ababawa без Actuator | шаг 5: закоммитить правки и дождаться деплоя |
| `up{job="api"} = 0`, connection refused | api не слушает `127.0.0.1:18082` | `ss -ltnp` на VPS, `docker compose ps` в `/opt/abavava` |
| `up{job="postgres"} = 0` | экспортёр не поднялся | `docker compose logs postgres-exporter`, пароль в `.env` |
| `pg_up 0` при `up{job="postgres"} = 1` | экспортёр жив, но не подключается к БД | роль не создана (шаг 4); пароль в `.env` ≠ пароль роли; порт `5432` не опубликован в abavava |
| `up{job="turn"} = 0` | coturn без `--prometheus` или занят 9641 | `ss -ltnp \| grep 9641`, `docker logs abavava-coturn-1 \| grep -i prometheus` |
| Prometheus пишет `no files found matching` | каталог targets пуст или не смонтирован | проверить `docker compose config` и `/opt/monitoring/prometheus/targets/*/` |
| Grafana пустая, «datasource not found» | provisioning не применился | `docker compose logs grafana \| grep -i provision` |
| `docker compose up` падает на `GRAFANA_ADMIN_PASSWORD` | `.env` не создан или пуст | записать `.env` (`umask 077`), права `600` |
| cAdvisor падает: `/dev/kmsg: no such file` | усечённое ядро VPS | убрать `devices:` из сервиса `cadvisor` в `compose.yaml` |
| Grafana-volume: permission denied | том создан под root | `docker compose down`, `docker volume rm monitoring_grafana_data`, `up -d` |
| Цель `up`, но панели пустые | метрики ещё не накопились (нужно 2+ скрейпа) | подождать 1–2 минуты, проверить запрос в `/graph` |

Полезное:

```bash
docker compose logs -f --tail=100 prometheus     # ошибки скрейпа и reload
docker compose exec prometheus promtool check config /etc/prometheus/prometheus.yml
docker compose exec prometheus sh -c 'promtool check rules /etc/prometheus/rules/*.yml'
docker compose exec alertmanager amtool check-config /etc/alertmanager/alertmanager.yml
```

Отдельно про панели API: если `up{job="api"}` есть, а панели «Запросы по
статусам» пустые — проверьте, как приложение назвало метрики:

```bash
ssh deploy@$VPS_HOST "curl -s http://127.0.0.1:18082/actuator/prometheus | grep -iE '^http_server' | head -5"
```

Ожидается `http_server_requests_seconds_count` / `_bucket` / `_sum`. Если имя
другое (например `http_server_request_duration_seconds_*`), поменяйте его в
запросах дашборда и в правиле `AbabawaApiErrorRateHigh`.

## Удаление

```bash
cd /opt/monitoring
docker compose down -v
# каталог /opt/monitoring удаляется от root:
# sudo rm -rf /opt/monitoring
```

Роль в БД, если больше не нужна:

```bash
cd /opt/abavava && docker compose --env-file .env.production --env-file .deploy.env \
  -f compose.prod.yaml exec -T postgres psql -U abavava -d abavava \
  -c 'REVOKE pg_monitor FROM abv_monitor; DROP ROLE abv_monitor;'
```
