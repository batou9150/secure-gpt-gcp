#!/bin/bash
# Creates the OpenWebUI database alongside the LiteLLM one (POSTGRES_DB).
set -euo pipefail
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE openwebui OWNER $POSTGRES_USER;
EOSQL
echo "init-databases: created 'openwebui'"
