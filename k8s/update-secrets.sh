#!/usr/bin/env bash
set -e

# Carregar variáveis do .env na raiz
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  source "$ROOT_DIR/.env"
  set +a
fi

b64() { echo -n "$1" | base64 -w 0; }

cat <<EOF > "$SCRIPT_DIR/02-secrets.yaml"
apiVersion: v1
kind: Secret
metadata:
  name: togglemaster-secrets
  namespace: togglemaster
type: Opaque
data:
  MASTER_KEY: $(b64 "${MASTER_KEY:-admin-secreto-123}")
  SERVICE_API_KEY: $(b64 "${SERVICE_API_KEY:-}")
  AWS_ACCESS_KEY_ID: $(b64 "${AWS_ACCESS_KEY_ID:-}")
  AWS_SECRET_ACCESS_KEY: $(b64 "${AWS_SECRET_ACCESS_KEY:-}")
  AWS_SESSION_TOKEN: $(b64 "${AWS_SESSION_TOKEN:-}")
  AUTH_DATABASE_URL: $(b64 "${AUTH_DATABASE_URL:-postgres://auth_user:auth_pass@auth-db.cxxxxxx.us-east-1.rds.amazonaws.com:5432/auth_db?sslmode=disable}")
  FLAGS_DATABASE_URL: $(b64 "${FLAGS_DATABASE_URL:-postgresql://flag_user:flag_pass@flag-db.cxxxxxx.us-east-1.rds.amazonaws.com:5432/flags_db}")
  TARGETING_DATABASE_URL: $(b64 "${TARGETING_DATABASE_URL:-postgresql://targeting_user:targeting_pass@targeting-db.cxxxxxx.us-east-1.rds.amazonaws.com:5432/targeting_db}")
  REDIS_URL: $(b64 "${REDIS_URL:-evaluation-redis.xxxxxx.0001.use1.cache.amazonaws.com:6379}")
EOF

echo "✓ Arquivo k8s/02-secrets.yaml atualizado em Base64 com sucesso a partir do .env!"
