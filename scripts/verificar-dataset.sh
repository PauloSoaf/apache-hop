#!/usr/bin/env bash
#
# Confere se o arquivo Online Retail presente no projeto e exatamente a versao
# do UCI documentada em projects/online-retail/docs/metricas_esperadas.md.
# Rode antes do workflow: os numeros de referencia do projeto so valem para
# este arquivo.
#
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DADOS="${RAIZ}/projects/online-retail/data"

if [[ ! -f "${DADOS}/online_retail.xlsx" ]]; then
  cat >&2 <<'MSG'
ERRO: projects/online-retail/data/online_retail.xlsx nao encontrado.

Baixe o dataset oficial (UCI, dataset 352 - CC BY 4.0):
  https://archive.ics.uci.edu/static/public/352/online%2Bretail.zip
Descompacte e copie "Online Retail.xlsx" para
  projects/online-retail/data/online_retail.xlsx
MSG
  exit 1
fi

cd "${DADOS}"
if sha256sum --check --status CHECKSUMS.sha256; then
  echo "[ok] online_retail.xlsx confere com o SHA-256 documentado."
  echo "     $(wc -c < online_retail.xlsx) bytes"
else
  echo "[ATENCAO] O SHA-256 do arquivo NAO confere com o documentado." >&2
  echo "          esperado: $(cut -d' ' -f1 CHECKSUMS.sha256)" >&2
  echo "          obtido:   $(sha256sum online_retail.xlsx | cut -d' ' -f1)" >&2
  echo "          As metricas de referencia do projeto valem apenas para o" >&2
  echo "          arquivo documentado; revalide antes de comparar resultados." >&2
  exit 1
fi
