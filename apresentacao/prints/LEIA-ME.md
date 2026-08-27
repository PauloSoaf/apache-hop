# Prints para a apresentação

Capturas feitas nas telas reais do projeto rodando em `localhost`, na execução
validada (`batch` com `status = SUCCESS`, 12/12 verificações OK).

| Arquivo | O que mostra | Slide |
|---|---|---|
| `01-workflow-wf_online_retail.png` | Workflow completo no Apache Hop: as 9 etapas em verde e os 9 desvios de erro em laranja convergindo para `99_marcar_falha` | **4 — Arquitetura** |
| `02-pipeline-01-ingestao.png` | Pipeline de ingestão: leitura do Excel → staging, com o ramo que conta as linhas recebidas | 4 — Arquitetura |
| `03-pipeline-02-tratamento.png` | Pipeline de tratamento: os *error hops* vermelhos (erro de conversão e duplicata) e o filtro que separa válidos de rejeitados | **7 — Tratamento** |
| `04-pipeline-06-fato-venda.png` | Carga da fato por upsert na chave natural | 5 / 6 — Modelo e chave |
| `05-pipeline-07-indicadores.png` | Indicadores calculados sobre a fato persistida | 10 — Indicadores |
| `06-metabase-dashboard.png` | Dashboard completo no Metabase, os 13 cards | 10 — Indicadores |
| `07-validacoes-12-de-12.png` | As 12 verificações, esperado × obtido, todas `OK` | **9 — Idempotência e prova** |
| `08-rejeitados-com-motivo.png` | Tabela `rejeitados` com linha crua e a coluna `motivo` — amostra dos três motivos | **8 — Rejeitados** |
| `09-evolucao-mensal.png` | Faturamento mensal: bruto, cancelado e líquido | **10 — Indicadores** |
| `10-metricas-do-etl.png` | Todas as métricas do ETL já rotuladas (origem, nulos, rejeições, fato, financeiro) | 8 / 10 |

Os quatro em negrito são os placeholders que o `.pptx` marca como `PRINT` ou
`GRÁFICO`.

## Como reproduzir

Com os containers no ar (`docker compose up -d`) e o workflow executado:

- **Apache Hop** — <http://localhost:8080/ui>, projeto `online-retail`,
  abrir o arquivo em `pipelines/` ou `workflows/`.
- **Metabase** — <http://localhost:3001>, coleção `Online Retail`.
  O dashboard e os cards são recriados por
  `python3 scripts/provisionar-metabase.py`.
- **As 12 validações** — também rodam no terminal, como consulta 0 de
  `projects/online-retail/sql/validacoes.sql`.

Números de referência: `projects/online-retail/docs/metricas_esperadas.md`.
