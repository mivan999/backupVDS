#!/usr/bin/env bash
# ─── Poker Club: бэкап БД + загрузок ─────────────────────────────────────────
#
# Сохраняет PostgreSQL (custom-формат, сжатый, переносимый) и каталог загрузок
# (uploads) в один timestamped-архив с контрольной суммой. Работает на любом
# сервере, где крутится приложение — сам находит, как достучаться до Postgres:
#   1) docker-контейнер (docker exec … pg_dump)          — локально / docker-стек
#   2) pg_dump на хосте (нативный Postgres)              — прод (host.docker.internal)
#   3) разовый postgres-образ (docker run … pg_dump)     — fallback
#
# Использование:
#   ./scripts/backup.sh                 # бэкап в ./backups/
#   BACKUP_DIR=/var/backups ./scripts/backup.sh
#   INCLUDE_UPLOADS=0 ./scripts/backup.sh   # только БД, без загрузок
#   MAX_AGE_DAYS=14 ./scripts/backup.sh     # удалить архивы старше 14 дней
#
# Удалённая отправка (опционально, после создания локального архива):
#   REMOTE_HOST=user@1.2.3.4 REMOTE_PATH=/backups ./scripts/backup.sh   # scp
#   S3_BUCKET=my-bucket S3_PREFIX=poker-club rclone ...   # см. PUSH_S3=1
#
# Безопасность: пароль БД берётся из env (PGPASSWORD / POSTGRES_PASSWORD),
# никогда не пишется в файлы и не попадает в аргументы командной строки.

set -euo pipefail

# ─── Настройки (переопределяются env) ────────────────────────────────────────
DB_HOST="${PGHOST:-127.0.0.1}"
DB_PORT="${PGPORT:-5432}"
DB_USER="${PGUSER:-${POSTGRES_USER:-poker_user}}"
DB_NAME="${PGDATABASE:-${POSTGRES_DB:-poker_club}}"
DB_PASS="${PGPASSWORD:-${POSTGRES_PASSWORD:-}}"

BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
INCLUDE_UPLOADS="${INCLUDE_UPLOADS:-1}"
MAX_AGE_DAYS="${MAX_AGE_DAYS:-0}"          # 0 = не чистить старые
TS="$(date +%Y%m%d-%H%M%S)"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# uploads: docker-volume или путь на хосте
UPLOAD_VOLUME="${UPLOAD_VOLUME:-poker_uploads_data}"
UPLOAD_DIR="${UPLOAD_DIR:-}"

log()  { printf '\033[1;36m[backup]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[backup] ОШИБКА:\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

log "База: $DB_NAME @ $DB_HOST:$DB_PORT (user=$DB_USER)"
log "Каталог бэкапов: $BACKUP_DIR"
mkdir -p "$BACKUP_DIR"

# ─── 1. Дамп БД ──────────────────────────────────────────────────────────────
DB_DUMP="$STAGE/$DB_NAME.dump"

dump_via_docker_exec() {
  local c="$1"
  log "Дамп через docker-контейнер: $c"
  docker exec -e PGPASSWORD="${DB_PASS}" "$c" pg_dump \
    -U "$DB_USER" -d "$DB_NAME" -Fc --no-owner --no-privileges -f "/tmp/$DB_NAME.dump"
  docker cp "$c:/tmp/$DB_NAME.dump" "$DB_DUMP"
  docker exec "$c" rm -f "/tmp/$DB_NAME.dump"
}

dump_via_host_pg_dump() {
  log "Дамп через pg_dump на хосте"
  PGPASSWORD="${DB_PASS}" pg_dump -h "$DB_HOST" -p "$DB_PORT" \
    -U "$DB_USER" -d "$DB_NAME" -Fc --no-owner --no-privileges -f "$DB_DUMP"
}

dump_via_docker_run() {
  log "Дамп через разовый postgres-образ (postgres:16-alpine)"
  # pg_dump -Fc пишет бинарный custom-формат; выводим в stdout и ловим в файл.
  docker run --rm --network host \
    -e PGHOST="$DB_HOST" -e PGPORT="$DB_PORT" \
    -e PGUSER="$DB_USER" -e PGPASSWORD="${DB_PASS}" -e PGDATABASE="$DB_NAME" \
    postgres:16-alpine pg_dump -Fc --no-owner --no-privileges > "$DB_DUMP"
}

if [ -z "$DB_PASS" ]; then
  log "Пароль БД не задан (PGPASSWORD/POSTGRES_PASSWORD). Пробуем без пароля / trust."
fi

if have docker && docker ps --format '{{.Names}}' 2>/dev/null | grep -qiE 'postgres'; then
  PG_CONTAINER="$(docker ps --format '{{.Names}}' | grep -iE 'postgres' | head -n1)"
  dump_via_docker_exec "$PG_CONTAINER"
elif have pg_dump; then
  dump_via_host_pg_dump
elif have docker; then
  dump_via_docker_run
else
  die "Не найден ни docker, ни pg_dump — не могу создать дамп БД"
fi

[ -s "$DB_DUMP" ] || die "Дамп БД пуст или не создан"
log "БД: $(du -h "$DB_DUMP" | cut -f1)  ($DB_NAME.dump)"

# ─── 2. Загрузки (uploads) ───────────────────────────────────────────────────
UPLOAD_TAR=""
if [ "$INCLUDE_UPLOADS" = "1" ]; then
  UP_STAGE="$STAGE/uploads"
  mkdir -p "$UP_STAGE"
  got=0
  if [ -n "$UPLOAD_DIR" ] && [ -d "$UPLOAD_DIR" ]; then
    log "Загрузки из каталога: $UPLOAD_DIR"
    cp -a "$UPLOAD_DIR"/. "$UP_STAGE"/ 2>/dev/null && got=1
  fi
  if [ "$got" -eq 0 ] && have docker && docker volume inspect "$UPLOAD_VOLUME" >/dev/null 2>&1; then
    log "Загрузки из docker-volume: $UPLOAD_VOLUME"
    docker run --rm -v "$UPLOAD_VOLUME:/up:ro" -v "$STAGE:/st" alpine tar -C /up -cf - . | tar -C "$UP_STAGE" -xf - 2>/dev/null && got=1
  fi
  if [ "$got" -eq 1 ] && [ -n "$(ls -A "$UP_STAGE" 2>/dev/null)" ]; then
    UPLOAD_TAR="$STAGE/uploads.tar"
    tar -C "$UP_STAGE" -cf "$UPLOAD_TAR" .
    log "Загрузки: $(du -h "$UPLOAD_TAR" | cut -f1)  (uploads.tar)"
  else
    log "Загрузки не найдены — пропускаю (это нормально, если их нет)"
  fi
fi

# ─── 3. Манифест + сборка архива ─────────────────────────────────────────────
MANIFEST="$STAGE/MANIFEST.txt"
{
  echo "Poker Club backup"
  echo "created_at: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "database:   $DB_NAME"
  echo "db_user:    $DB_USER"
  echo "db_host:    $DB_HOST:$DB_PORT"
  echo "dump_file:  $DB_NAME.dump (pg_dump custom format, gzip)"
  echo "uploads:    $([ -n "$UPLOAD_TAR" ] && echo 'uploads.tar' || echo 'none')"
  echo "hostname:   $(hostname 2>/dev/null || echo unknown)"
  echo
  echo "Restore:"
  echo "  createdb -U $DB_USER $DB_NAME   # если БД ещё нет"
  echo "  pg_restore -U $DB_USER -d $DB_NAME --no-owner --no-privileges $DB_NAME.dump"
  [ -n "$UPLOAD_TAR" ] && echo "  tar -xf uploads.tar -C <uploads_dir>/"
} > "$MANIFEST"

ARCHIVE="$BACKUP_DIR/poker-backup-$TS.tar.gz"
# Явно перечисляем файлы (без префикса ./), чтобы restore-инструкция
#   tar -xzf backup.tar.gz poker_club.dump
# находила их в корне архива.
TAR_MEMBERS=(MANIFEST.txt "$DB_NAME.dump")
[ -n "$UPLOAD_TAR" ] && TAR_MEMBERS+=(uploads.tar)
tar -czf "$ARCHIVE" -C "$STAGE" "${TAR_MEMBERS[@]}"
sha256sum "$ARCHIVE" > "$ARCHIVE.sha256"

log "Готово: $ARCHIVE"
log "Размер: $(du -h "$ARCHIVE" | cut -f1)   SHA256: $(cut -d' ' -f1 "$ARCHIVE.sha256")"

# ─── 4. Чистка старых (опционально) ──────────────────────────────────────────
if [ "$MAX_AGE_DAYS" -gt 0 ]; then
  log "Удаляю архивы старше $MAX_AGE_DAYS дн."
  find "$BACKUP_DIR" -maxdepth 1 -name 'poker-backup-*.tar.gz' -mtime +"$MAX_AGE_DAYS" -print -delete
fi

# ─── 5. Удалённая отправка (опционально) ─────────────────────────────────────
if [ -n "${REMOTE_HOST:-}" ] && have scp; then
  log "Отправляю на $REMOTE_HOST:${REMOTE_PATH:-/} через scp"
  mkdir -p "${REMOTE_PATH:-/root/backups}"
  scp -o ConnectTimeout=30 "$ARCHIVE" "$ARCHIVE.sha256" "$REMOTE_HOST:${REMOTE_PATH:-/root/backups}/"
  log "Отправлено"
elif [ "${PUSH_S3:-0}" = "1" ] && have rclone; then
  log "Отправляю в S3: ${S3_BUCKET}/${S3_PREFIX:-} через rclone"
  rclone copy "$ARCHIVE" "${S3_REMOTE:-s3}:${S3_BUCKET}/${S3_PREFIX:-}"
  log "Отправлено в S3"
else
  log "Удалённая отправка не настроена — архив остаётся локально"
fi

log "✅ Бэкап завершён"
