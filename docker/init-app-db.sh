#!/bin/bash
set -e

echo "Criando bancos de dados flags_db e targeting_db..."

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE DATABASE flags_db;
    CREATE DATABASE targeting_db;
EOSQL

echo "Executando schema em flags_db..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "flags_db" -f /docker-entrypoint-initdb.d/flag-init.sql

echo "Executando schema em targeting_db..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "targeting_db" -f /docker-entrypoint-initdb.d/targeting-init.sql

echo "Bancos de dados flags_db e targeting_db inicializados com sucesso!"
