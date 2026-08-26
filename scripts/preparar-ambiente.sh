#!/usr/bin/env bash
#
# Prepara os arquivos de configuracao locais do projeto Online Retail.
#
#   1. cria .env a partir do .env.example (se ainda nao existir);
#   2. gera projects/online-retail/online-retail-dev.json (ambiente do Apache Hop)
#      a partir dos valores do .env, para que exista uma unica fonte de verdade.
#
# Nenhum dos dois arquivos gerados vai para o controle de versao (ver .gitignore).
#
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJETO="${RAIZ}/projects/online-retail"
ENV_FILE="${RAIZ}/.env"
ENV_EXEMPLO="${RAIZ}/.env.example"
HOP_ENV_FILE="${PROJETO}/online-retail-dev.json"

if [[ ! -f "${ENV_FILE}" ]]; then
  cp "${ENV_EXEMPLO}" "${ENV_FILE}"
  echo "[criado] ${ENV_FILE} (a partir do .env.example)"
  echo "         >>> troque DB_PASSWORD antes de subir o ambiente <<<"
fi

# shellcheck disable=SC1090
set -a; source "${ENV_FILE}"; set +a

: "${DB_HOST:?DB_HOST ausente no .env}"
: "${DB_PORT:?DB_PORT ausente no .env}"
: "${DB_NAME:?DB_NAME ausente no .env}"
: "${DB_USER:?DB_USER ausente no .env}"
: "${DB_PASSWORD:?DB_PASSWORD ausente no .env}"
: "${ONLINE_RETAIL_FILE:?ONLINE_RETAIL_FILE ausente no .env}"

cat > "${HOP_ENV_FILE}" <<JSON
{
  "variables": [
    { "name": "DB_HOST", "value": "${DB_HOST}", "description": "Host do PostgreSQL" },
    { "name": "DB_PORT", "value": "${DB_PORT}", "description": "Porta do PostgreSQL" },
    { "name": "DB_NAME", "value": "${DB_NAME}", "description": "Banco de dados do projeto" },
    { "name": "DB_USER", "value": "${DB_USER}", "description": "Usuario do PostgreSQL" },
    { "name": "DB_PASSWORD", "value": "${DB_PASSWORD}", "description": "Senha do PostgreSQL - arquivo nao versionado" },
    { "name": "ONLINE_RETAIL_FILE", "value": "${ONLINE_RETAIL_FILE}", "description": "Arquivo Online Retail dentro do container" },
    { "name": "ONLINE_RETAIL_SCHEMA", "value": "online_retail", "description": "Schema do modelo dimensional" }
  ]
}
JSON

chmod 600 "${HOP_ENV_FILE}"
echo "[gerado] ${HOP_ENV_FILE} (ambiente 'online-retail-dev' do Apache Hop)"
