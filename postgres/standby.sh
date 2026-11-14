#!/usr/bin/env bash
set -euo pipefail
: "${PGDATA:?PGDATA harus terisi}"
mkdir -p "$PGDATA"
chown -R postgres:postgres "$PGDATA"
if [ ! -s "$PGDATA/PG_VERSION" ]; then
    echo 'Menginisialisasi standby dari pg_basebackup (streaming WAL)...'
    until gosu postgres env PGPASSWORD="$REPL_PASSWORD" \
        pg_basebackup -h "$PRIMARY_HOST" -p 5432 -U replicator \
        -D "$PGDATA" -Fp -Xs -R -P -C -S sbdt_replica_slot; do
        # Jika gagal setelah membuat slot saat bootstrap, operator mungkin perlu mereset volume latihan.
        echo 'pg_basebackup belum berhasil; memeriksa primary dan kredensial...'
        sleep 5
    done
fi
exec docker-entrypoint.sh postgres -c hot_standby=on
