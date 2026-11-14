#!/usr/bin/env bash
set -euo pipefail
# Hanya dieksekusi saat inisialisasi volume PostgreSQL pertama kali.
psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" -v ON_ERROR_STOP=1 -v replpass="$REPL_PASSWORD" <<'SQL'
SELECT format('CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD %L', :'replpass') \gexec
SQL
printf '\nhost replication replicator 0.0.0.0/0 scram-sha-256\n' >> "$PGDATA/pg_hba.conf"
