# backupVDS — бэкап БД Poker Club на VDS

Один скрипт `backup.sh` сохраняет **PostgreSQL** (сжатый переносимый дамп) и **загрузки (uploads)** в один архив с контрольной суммой. Работает на любом сервере с приложением — сам находит, как достучаться до Postgres:

1. docker-контейнер (`docker exec … pg_dump`)
2. `pg_dump` на хосте (нативный Postgres)
3. разовый postgres-образ (`docker run … pg_dump`) — fallback

Пароль БД берётся из env (`PGPASSWORD` / `POSTGRES_PASSWORD`) — не пишется в файлы и не попадает в аргументы командной строки.

---

## Быстрый старт

```bash
git clone git@github.com:mivan999/backupVDS.git
cd backupVDS

# пароль БД взять из .env приложения (чтобы не вводить вручную)
set -a; source /путь/к/приложению/.env; set +a

./backup.sh
```

Результат — в `./backups/`:

```
poker-backup-YYYYMMDD-HHMMSS.tar.gz
poker-backup-YYYYMMDD-HHMMSS.tar.gz.sha256
```

---

## Переменные окружения

| Переменная | По умолчанию | Что делает |
|---|---|---|
| `BACKUP_DIR` | `$PWD/backups` | Куда складывать архивы |
| `INCLUDE_UPLOADS` | `1` | `0` = только БД, без загрузок |
| `MAX_AGE_DAYS` | `0` | Удалять архивы старше N дней (`0` = не чистить) |
| `PGHOST` / `PGPORT` | `127.0.0.1` / `5432` | Адрес Postgres |
| `PGUSER` / `PGPASSWORD` | `poker_user` / — | Креды БД |
| `PGDATABASE` | `poker_club` | Имя базы |
| `UPLOAD_DIR` | — | Путь к загрузкам на хосте (если не docker-volume) |
| `UPLOAD_VOLUME` | `poker_uploads_data` | Имя docker-volume с загрузками |
| `REMOTE_HOST` / `REMOTE_PATH` | — | Отправить архив на другой сервер через `scp` |
| `PUSH_S3` / `S3_BUCKET` / `S3_PREFIX` | `0` | `1` + `rclone` = отправить в S3-совместимое хранилище |

Примеры:

```bash
INCLUDE_UPLOADS=0 ./backup.sh              # только БД
MAX_AGE_DAYS=14 ./backup.sh                # + удалить старые (старше 14 дн.)
BACKUP_DIR=/var/backups ./backup.sh        # хранить в другом месте
REMOTE_HOST=user@новый-сервер REMOTE_PATH=/root/backups ./backup.sh   # сразу scp
```

---

## Восстановление (restore)

```bash
# 1. создать пустую БД
sudo -u postgres createdb poker_club

# 2. распаковать дамп
tar -xzf poker-backup-YYYYMMDD-HHMMSS.tar.gz poker_club.dump

# 3. восстановить данные
sudo -u postgres pg_restore -d poker_club --no-owner --no-privileges poker_club.dump

# 4. вернуть загрузки (если в архиве был uploads.tar)
tar -xzf poker-backup-YYYYMMDD-HHMMSS.tar.gz uploads.tar
tar -xf uploads.tar -C /путь/к/uploads/
```

Проверка:

```bash
sha256sum -c poker-backup-*.tar.gz.sha256     # целостность архива
sudo -u postgres psql -d poker_club -c '\dt'   # таблицы на месте
```

---

## Ежедневный бэкап (cron)

```bash
crontab -e
# каждый день в 03:30, хранить 14 дней, лог в файл
30 3 * * * cd /opt/backupVDS && set -a && . /opt/poker-club/.env && set +a && MAX_AGE_DAYS=14 ./backup.sh >> /var/log/poker-backup.log 2>&1
```

---

## Формат дампа

`pg_dump -Fc` (custom, gzip): переносим между версиями Postgres, можно фильтровать таблицы при restore. Внутри архива — `MANIFEST.txt` с датой, именем БД и готовыми командами восстановления.
