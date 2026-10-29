#!/bin/sh
# Applies the profile and manifest configuration, then the manifest's SQL files, in order.
set -eu

for file in /tmp/preview/sql/*.sql; do
  [ -f "$file" ] || continue
  echo "running $(basename "$file")"
  mysql -u "$MYSQL_USER" --host="$MYSQL_HOST" --port="$MYSQL_PORT" --password="$MYSQL_PASSWORD" "$MYSQL_DATABASE" < "$file"
done
