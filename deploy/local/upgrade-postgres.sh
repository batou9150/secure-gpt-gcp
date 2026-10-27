#!/usr/bin/env bash
# One-off: copy the litellm and openwebui databases from the Postgres 16 volume
# (postgres-data) into the Postgres 18 volume (postgres18-data).
# The old volume is never modified; delete it yourself once you've checked
# the upgraded stack.
set -euo pipefail
cd "$(dirname "$0")/../.."

project="$(docker compose config | sed -n 's/^name: //p' | head -1)"
old_volume="${project}_postgres-data"
new_volume="${project}_postgres18-data"
dumper="${project}-pg16-dump"

if ! docker volume inspect "$old_volume" >/dev/null 2>&1; then
  echo "No Postgres 16 volume ($old_volume): nothing to upgrade."
  exit 0
fi
if docker volume inspect "$new_volume" >/dev/null 2>&1; then
  echo "$new_volume already exists. Remove it first if you want to re-run the copy:"
  echo "  docker compose down && docker volume rm $new_volume"
  exit 1
fi

dumps="$(mktemp -d)"
chmod 700 "$dumps"
cleanup() { docker rm -f "$dumper" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> stopping the stack"
docker compose down

echo "==> dumping from Postgres 16 ($old_volume)"
docker run -d --name "$dumper" -v "$old_volume:/var/lib/postgresql/data" \
  postgres:16-alpine >/dev/null
for _ in $(seq 60); do
  docker exec "$dumper" pg_isready -U securegpt -q && break
  sleep 1
done
databases="$(docker exec "$dumper" psql -U securegpt -d postgres -Atc \
  "select datname from pg_database where not datistemplate and datname <> 'postgres'")"
for db in $databases; do
  docker exec "$dumper" pg_dump -U securegpt -Fc "$db" > "$dumps/$db.dump"
  echo "  $db: $(du -h "$dumps/$db.dump" | cut -f1)"
done
cleanup

echo "==> restoring into Postgres 18 ($new_volume)"
docker compose up -d --wait postgres
for db in $databases; do
  docker compose exec -T postgres psql -U securegpt -d postgres -qtc \
    "select 1 from pg_database where datname = '$db'" | grep -q 1 \
    || docker compose exec -T postgres createdb -U securegpt "$db"
  docker compose exec -T postgres pg_restore -U securegpt -d "$db" \
    --clean --if-exists --no-owner --exit-on-error < "$dumps/$db.dump"
  tables="$(docker compose exec -T postgres psql -U securegpt -d "$db" -Atc \
    "select count(*) from information_schema.tables where table_schema = 'public'")"
  echo "  $db: restored, $tables tables"
done

rm -rf "$dumps"
echo
echo "Done. Start everything with 'make up' and check your chats and keys."
echo "The Postgres 16 data is still in $old_volume. Once you're happy, delete it:"
echo "  docker volume rm $old_volume"
