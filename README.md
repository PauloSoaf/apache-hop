# Online Retail — ETL completo em Apache Hop

Trabalho final do módulo de Apache Hop. O projeto transforma o dataset público
**Online Retail** (UCI, 541.909 linhas em Excel) em um modelo dimensional no
PostgreSQL, com staging, tratamento de qualidade, dimensões, tabela fato,
indicadores e dashboard — tudo orquestrado por um workflow do Apache Hop.

```text
Online Retail.xlsx (UCI)
      │
      ▼  01_ingestao_online_retail.hpl
stg_online_retail            (cópia textual da fonte + batch_id + linha_seq)
      │
      ▼  02_tratamento_online_retail.hpl
      ├─────────────► rejeitados            (motivo + conteúdo original)
      ▼
wrk_online_retail_validos    (tipado, deduplicado, com valor_total)
      │
      ├──► 03_dim_produto.hpl ──► dim_produto
      ├──► 04_dim_pais.hpl    ──► dim_pais
      ├──► 05_dim_tempo.hpl   ──► dim_tempo
      ▼
      └──► 06_fato_venda.hpl  ──► fato_venda   (upsert pela chave natural)
                                      │
                                      ▼  07_indicadores.hpl
                            indicadores_resumo + views
                                      │
                                      ▼
                              Dashboard (Metabase)
```

Todas as etapas gravam auditoria em `log_execucao`, uma linha por execução,
identificada por `batch_id`.

---

## 1. Objetivo

Demonstrar, ponta a ponta e de forma executável, um processo de ETL no Apache
Hop: leitura de uma fonte suja, staging fiel ao original, regras de qualidade
visíveis no grafo do pipeline, modelagem dimensional, carga idempotente,
indicadores calculados sobre a fato e camada de visualização.

O foco não é o tamanho da aplicação — é a correção e a rastreabilidade do
processo.

## 2. Arquitetura

| Camada | Onde vive | Responsabilidade |
|---|---|---|
| Fonte | `projects/online-retail/data/online_retail.xlsx` | Excel original do UCI, imutável |
| Ingestão | `01_ingestao_online_retail.hpl` | Lê a planilha, gera `linha_seq` e `registro_hash`, carrega a staging |
| Staging | `stg_online_retail` | Cópia **textual** da fonte, sem conversão destrutiva |
| Qualidade | `02_tratamento_online_retail.hpl` | Tipagem, cancelamentos, duplicatas, regras de rejeição |
| Quarentena | `rejeitados` | Toda linha descartada, com motivo e conteúdo original |
| Área de trabalho | `wrk_online_retail_validos` | Linhas aprovadas e tipadas do lote |
| Dimensões | `dim_produto`, `dim_pais`, `dim_tempo` | Upsert por chave de negócio |
| Fato | `fato_venda` | Upsert pela chave natural, com surrogate keys |
| Indicadores | `indicadores_resumo` + 6 views | Calculados **sobre a fato**, nunca sobre o Excel |
| Auditoria | `log_execucao` | `RUNNING` → `SUCCESS`/`FAILED`, com todas as contagens |
| Dashboard | Metabase | Cards SQL sobre as views |

### Infraestrutura

Três serviços no `docker-compose.yml` da raiz:

| Serviço | Imagem | Porta no host | Para que serve |
|---|---|---|---|
| `hop-web` | derivada de `apache/hop-web` (ver `Dockerfile`) | `8080` | Apache Hop 2.19.0 (GUI no navegador + `hop-run`) |
| `online-retail-db` | `postgres:16.15` | `127.0.0.1:5434` | Banco do projeto; roda os scripts de `sql/` na criação |
| `online-retail-metabase` | `metabase/metabase:v0.63.13` | `127.0.0.1:3001` | Dashboard |

O `Dockerfile` existe por um motivo prático: realinha o UID/GID do usuário
interno `hop` para 1000, de modo que os arquivos criados pela GUI dentro de
`projects/` fiquem editáveis pelo seu usuário no host.

## 3. Dataset

- **Online Retail**, de Daqing Chen — UCI Machine Learning Repository, dataset 352.
- Página: <https://archive.ics.uci.edu/dataset/352/online%2Bretail>
- DOI: <https://doi.org/10.24432/C5BW33> — licença CC BY 4.0.
- 541.909 linhas, 8 colunas, planilha `Online Retail`, período de
  2010-12-01 08:26 a 2011-12-09 12:50.

Colunas de origem: `InvoiceNo`, `StockCode`, `Description`, `Quantity`,
`InvoiceDate`, `UnitPrice`, `CustomerID`, `Country`.

O arquivo **não é versionado** (23 MB). Baixe, descompacte e copie
`Online Retail.xlsx` para `projects/online-retail/data/online_retail.xlsx`;
`scripts/verificar-dataset.sh` confere o SHA-256 contra
`projects/online-retail/data/CHECKSUMS.sha256`. Os números de referência deste
repositório valem para exatamente aquele arquivo.

O perfil completo da fonte e todos os valores esperados estão em
[`projects/online-retail/docs/metricas_esperadas.md`](projects/online-retail/docs/metricas_esperadas.md).

## 4. Regras de tratamento

Implementadas **dentro do Apache Hop**, visíveis no grafo de
`02_tratamento_online_retail.hpl`, não escondidas em SQL.

| Situação | Decisão | Motivo registrado |
|---|---|---|
| `CustomerID` nulo | **Mantém a venda**, `customer_id` fica `NULL` | — |
| `InvoiceNo` começa com `C` | Marca `cancelamento = true` e **mantém** a linha | — |
| `Quantity <= 0` e **não** é cancelamento | Rejeita | `QUANTIDADE_INVALIDA` |
| `Quantity <= 0` e **é** cancelamento | Mantém (negativo é legítimo) | — |
| `UnitPrice <= 0` | Rejeita | `PRECO_UNITARIO_INVALIDO` |
| Os 8 campos repetem uma linha anterior | Rejeita só a ocorrência excedente | `DUPLICATA_INTEGRAL` |
| Falha de conversão de tipo | Rejeita pelo *error hop* | `ERRO_CONVERSAO_TIPO` |
| `Description` vazia | Preenche com `SEM_DESCRICAO` | — |
| `Country` vazio | Preenche com `NAO_INFORMADO` | — |

Detalhes que mudam os números e por isso ficam explícitos:

- **O preço é validado com `<= 0`, não `= 0`.** A fonte tem dois ajustes com
  preço negativo.
- **Prioridade de motivo**: `DUPLICATA_INTEGRAL` → `QUANTIDADE_INVALIDA` →
  `PRECO_UNITARIO_INVALIDO`. Cada linha recebe um único motivo primário, então
  as contagens por motivo são somáveis. Existem 2.512 linhas únicas com preço
  não positivo, mas 1.336 delas já foram rejeitadas por quantidade — restam
  1.176 atribuídas ao preço.
- **Duplicata integral** compara os 8 campos originais. `batch_id`, `linha_seq`
  e datas técnicas não entram na comparação. Conserva-se a ocorrência de menor
  `linha_seq`. O mesmo produto aparecendo duas vezes na mesma nota com valores
  diferentes **não** é duplicata.
- **`valor_total = unit_price * quantity`**, com o sinal da quantidade
  preservado. Cancelamentos ficam negativos, o que permite calcular bruto,
  cancelado e líquido de forma consistente.

### Reconciliação da qualidade

```text
541.909  origem/staging
 -  5.268  DUPLICATA_INTEGRAL
 -  1.336  QUANTIDADE_INVALIDA
 -  1.176  PRECO_UNITARIO_INVALIDO
 = 534.129  linhas na fato        (1,435665% rejeitado)
```

## 5. Estrutura do banco

Schema `online_retail`, criado por `sql/01_schema.sql` e `sql/02_tables.sql`.

| Tabela | Papel | Chave |
|---|---|---|
| `log_execucao` | Auditoria de cada execução | `batch_id` |
| `stg_online_retail` | Staging textual da fonte | `(batch_id, linha_seq)` |
| `rejeitados` | Quarentena com motivo e original | `id`; único por `(batch_id, linha_seq, motivo)` |
| `wrk_online_retail_validos` | Linhas válidas tipadas do lote | `(invoice_no, stock_code, linha_seq)` |
| `dim_produto` | Dimensão de produto | `produto_sk`; natural `stock_code` |
| `dim_pais` | Dimensão de país | `pais_sk`; natural `country` |
| `dim_tempo` | Dimensão de tempo | `tempo_sk`; natural `data` |
| `fato_venda` | Vendas e cancelamentos | `venda_sk`; natural `(invoice_no, stock_code, linha_seq)` |
| `indicadores_resumo` | Uma linha de indicadores por lote | `batch_id` |

A staging guarda tudo como texto de propósito: nada se perde na ingestão, e a
conversão de tipos acontece na camada de tratamento, onde a falha pode ser
capturada e rejeitada com o valor original preservado.

`fato_venda` tem FKs para as três dimensões e `UNIQUE (invoice_no, stock_code,
linha_seq)` — é essa constraint que garante, no banco, o que a idempotência
promete no pipeline.

## 6. Chave natural

```text
invoice_no + stock_code + linha_seq
```

`invoice_no + stock_code` **não** basta: o mesmo produto pode aparecer
legitimamente mais de uma vez na mesma nota fiscal.

`linha_seq` é o **número físico da linha na planilha**, produzido pelo próprio
transform de leitura do Excel (campo *sheet row number*). A primeira linha de
dados é a `linha_seq = 2`, porque a linha 1 é o cabeçalho. Como o valor vem da
posição na fonte, e não de uma sequence do banco, ele é idêntico em toda
reexecução — que é exatamente o que a idempotência exige. Ele também dá
rastreabilidade direta: `linha_seq = 4711` é a linha 4711 do Excel.

`batch_id` **não** faz parte da chave natural.

## 7. Idempotência

Rodar o workflow duas vezes sobre a mesma fonte produz o mesmo estado final:
534.129 linhas na fato, não 1.068.258.

Como isso é garantido, camada por camada:

| Camada | Estratégia |
|---|---|
| `stg_online_retail` | Truncada no início de cada ingestão (`Table output` com *truncate*) |
| `wrk_online_retail_validos` | Truncada no início de cada tratamento |
| `rejeitados` | **Acumula** por `batch_id` — é histórico de auditoria, intencional |
| `dim_produto` / `dim_pais` / `dim_tempo` | `Insert / Update` pela chave de negócio; nunca truncadas |
| `fato_venda` | `Insert / Update` pela chave natural; nunca truncada |
| `indicadores_resumo` | `Insert / Update` por `batch_id` |
| `log_execucao` | Uma linha nova por execução |

Nenhum `INSERT` cego. As dimensões e a fato usam o transform **Insert / Update**
do Hop: ele procura a chave, atualiza se existir, insere se não existir.

## 8. Como funciona o `batch_id`

1. `00_inicializar_batch.hpl` pede um UUID ao PostgreSQL
   (`gen_random_uuid()`), insere a linha em `log_execucao` com status `RUNNING`
   e publica o valor como variável **`BATCH_ID` no workflow pai**
   (transform *Set Variables*, escopo `PARENT_WORKFLOW`).
2. Todos os pipelines seguintes herdam `${BATCH_ID}` do workflow: a ingestão o
   anexa a cada linha (*Get Variables*), os demais filtram o lote por ele.
3. `08_finalizar_sucesso.hpl` reconta staging, válidos, rejeitados, duplicatas
   e fato **daquele** `batch_id` e fecha o log como `SUCCESS`.
4. Se qualquer etapa crítica falhar, `99_marcar_falha.hpl` grava `FAILED` com
   mensagem de erro e aborta, para que a execução nunca termine como sucesso.

Cada execução é, portanto, auditável isoladamente — e `rejeitados` guarda o
histórico de todas elas.

## 9. Pipelines

Todos em `projects/online-retail/pipelines/`.

| Arquivo | O que faz | Transforms principais |
|---|---|---|
| `00_inicializar_batch.hpl` | Gera o `batch_id`, publica a variável, abre o log como `RUNNING` | Table input · Set Variables · Table output |
| `01_ingestao_online_retail.hpl` | Lê o Excel, normaliza nomes, canoniza texto, calcula SHA-256 do registro, anexa `batch_id`, carrega a staging e registra a quantidade recebida | Microsoft Excel input · Select values · String operations · Add a checksum · Get Variables · Table output · Memory group by · Insert / Update |
| `02_tratamento_online_retail.hpl` | Tipagem com captura de erro, dedup, regras de negócio, `valor_total`, separação válidos/rejeitados | Table input · String operations · Select values (+ *error hop*) · Sort rows · Unique rows (+ *error hop*) · JavaScript · Filter rows · User Defined Java Expression · Table output ×4 |
| `03_dim_produto.hpl` | Upsert de produtos por `stock_code` | Table input · Insert / Update |
| `04_dim_pais.hpl` | Upsert de países por `country` | Table input · Insert / Update |
| `05_dim_tempo.hpl` | Deriva dia/mês/trimestre/ano/dia da semana e faz upsert por `data` | Table input · Insert / Update |
| `06_fato_venda.hpl` | Resolve as três surrogate keys e faz upsert da fato pela chave natural | Table input · Insert / Update |
| `07_indicadores.hpl` | Agrega **a fato persistida** e grava `indicadores_resumo` | Table input · Insert / Update |
| `08_finalizar_sucesso.hpl` | Reconcilia contagens e fecha o log como `SUCCESS` | Table input · Insert / Update |
| `99_marcar_falha.hpl` | Grava `FAILED` com a mensagem e aborta | Table input · Insert / Update · Abort |

Três escolhas que valem explicar:

- **Nenhum `Merge join`.** As junções deste projeto são lookups por chave contra
  tabelas já persistidas; resolvê-las no `Table input` que alimenta a carga é
  mais simples e mais rápido do que ordenar dois fluxos para juntá-los no grafo.
- **`valor_total` não usa o transform `Calculator`.** A multiplicação de
  `BigNumber` do Calculator aplica um `MathContext` derivado da precisão dos
  operandos e arredonda o resultado para poucos dígitos significativos: `9 ×
  15,00` sairia como `140,00`, e o faturamento total ficava £5.113,51 menor.
  O cálculo é feito com **User Defined Java Expression**, que multiplica dois
  `BigDecimal` sem arredondamento intermediário. O valor confere dígito a dígito
  com o total calculado direto do arquivo Excel.
- **Os caminhos de erro são *error hops* de verdade.** Falha de conversão de
  tipo e duplicata saem pela saída de erro do transform, ganham um motivo e vão
  para `rejeitados` — em vez de derrubar o pipeline.

## 10. Workflow

`projects/online-retail/workflows/wf_online_retail.hwf`:

```text
START → 00_inicializar_batch → 01_ingestao → 02_tratamento
      → 03_dim_produto → 04_dim_pais → 05_dim_tempo
      → 06_fato_venda → 07_indicadores → 08_finalizar_sucesso → END
```

Cada uma das nove etapas tem, além do *hop* de sucesso, um *hop* de **erro**
apontando para `99_marcar_falha`. Se qualquer etapa falhar, a execução é
marcada como `FAILED` no `log_execucao` e o workflow termina em erro.

## 11. Indicadores

Calculados em `07_indicadores.hpl` (grava `indicadores_resumo`) e disponíveis
nas views de `sql/03_views_indicadores.sql`.

| # | Indicador | Fórmula |
|---|---|---|
| 1 | **Faturamento bruto** | `SUM(valor_total) WHERE NOT cancelamento` |
| 2 | **Valor cancelado** | `SUM(ABS(valor_total)) WHERE cancelamento` — positivo, para leitura |
| 3 | **Faturamento líquido** | `faturamento_bruto − valor_cancelado` |
| 4 | **Quantidade vendida** | `SUM(quantity) WHERE NOT cancelamento` |
| 5 | **Ticket médio** | `faturamento_líquido ÷ invoices de venda distintas` |
| 6 | **Taxa de cancelamento** | `invoices que começam com C ÷ invoices distintas totais × 100` |
| 7 | **Produtos mais vendidos** | `vw_top_produtos` — ranking por quantidade líquida |
| 8 | **Países por faturamento** | `vw_faturamento_pais` — ranking por faturamento líquido |
| 9 | **Evolução mensal** | `vw_evolucao_mensal` — bruto, cancelado e líquido por mês |

Decisões documentadas:

- **O indicador principal de faturamento é o líquido**, mas os três valores
  (bruto, cancelado, líquido) são publicados juntos em todas as views.
- **Ticket médio** usa o faturamento **líquido** no numerador e apenas as
  **invoices de venda** (que não começam com `C`) no denominador. Notas
  canceladas não inflam nem o numerador nem o denominador.
- **Taxa de cancelamento** é medida **no grão de invoice**, não de linha, para
  que uma nota com muitos itens não pese mais que outra. O denominador é o
  total de invoices distintas na fato (vendas + cancelamentos).

Views disponíveis: `vw_indicadores_gerais`, `vw_top_produtos`,
`vw_faturamento_pais`, `vw_evolucao_mensal`, `vw_rejeicoes_por_motivo` e
`vw_metricas_apresentacao` (esta última entrega, prontas, todas as métricas
pedidas para a apresentação).

### Números medidos — para a apresentação

Valores da execução validada sobre o arquivo UCI documentado. Reproduza com
`select metrica, valor, unidade from online_retail.vw_metricas_apresentacao order by ordem;`

| Métrica | Valor |
|---|---:|
| Total de linhas da origem | 541.909 |
| Total de linhas na staging | 541.909 |
| `CustomerID` nulos na origem | 135.080 |
| Duplicatas integrais removidas | 5.268 |
| Rejeitados por quantidade | 1.336 |
| Rejeitados por preço | 1.176 |
| **Total rejeitado** | **7.780** |
| **Percentual rejeitado** | **1,4357%** |
| **Total final da fato** | **534.129** |
| Linhas de cancelamento na fato | 9.251 |
| Quantidade vendida | 5.572.420 |
| **Faturamento bruto** | **£10.642.110,8040** |
| Valor cancelado | £893.979,7300 |
| **Faturamento líquido** | **£9.748.131,0740** |
| **Ticket médio** | **£488,3833** |
| **Taxa de cancelamento** | **16,1204%** |

Cardinalidades: 3.938 produtos, 38 países, 305 datas com movimento, 19.960
invoices de venda e 3.836 invoices canceladas (23.796 no total).

Os valores financeiros conferem **dígito a dígito** com o total calculado
diretamente sobre o arquivo Excel, fora do Hop e fora do banco.

## 12. Subir o PostgreSQL (e o resto)

Pré-requisitos: Docker e Docker Compose. Não é preciso Java no host.

```bash
cd ~/"Área de trabalho/CursoApacheHop"

# 1. credenciais locais + ambiente do Hop (gera .env e online-retail-dev.json)
cp .env.example .env
$EDITOR .env                     # troque DB_PASSWORD
./scripts/preparar-ambiente.sh

# 2. dataset (baixe do UCI e copie para projects/online-retail/data/)
./scripts/verificar-dataset.sh   # confere o SHA-256

# 3. sobe PostgreSQL + Apache Hop + Metabase
docker compose up -d
```

Na primeira subida o PostgreSQL executa sozinho `sql/01_schema.sql`,
`sql/02_tables.sql` e `sql/03_views_indicadores.sql`. Confira:

```bash
docker compose exec online-retail-db \
  psql -U online_retail -d online_retail -c "\dt online_retail.*"
```

> Os scripts de inicialização só rodam quando o volume está vazio. Para
> recriar o banco do zero: `docker compose down -v && docker compose up -d`.

## 13. Configurar o Apache Hop

Já vem configurado. O container abre direto no projeto certo:

- projeto **`online-retail`** → `/project/online-retail` (é
  `projects/online-retail/` no host);
- ambiente **`online-retail-dev`** → fornece `DB_HOST`, `DB_PORT`, `DB_NAME`,
  `DB_USER`, `DB_PASSWORD` e `ONLINE_RETAIL_FILE`;
- conexão **`OnlineRetailPostgreSQL`** → definida em
  `metadata/rdbms/OnlineRetailPostgreSQL.json`, usando **apenas variáveis**;
  nenhuma credencial está escrita nos pipelines.

GUI: <http://localhost:8080/ui> (a primeira abertura leva ~30 s, o Tomcat está
publicando a interface).

> Caminhos digitados na GUI são caminhos **do container**: use
> `/project/online-retail/...`, nunca `/home/seu-usuario/...`.

Se trocar a senha no `.env`, rode `./scripts/preparar-ambiente.sh` de novo e
reinicie: `docker compose up -d --force-recreate`.

## 14. Executar o workflow

**Pela linha de comando** (é o caminho recomendado, e o que foi validado):

```bash
docker exec hop-web /usr/local/tomcat/webapps/ROOT/hop-run.sh \
  --project=online-retail \
  --environment=online-retail-dev \
  --runconfig=local \
  --file=/project/online-retail/workflows/wf_online_retail.hwf \
  --level=Basic
```

**Pela GUI**: abra `workflows/wf_online_retail.hwf` no explorador do projeto e
clique em *Run* (run configuration `local`).

A execução completa leva cerca de **2 a 3 minutos** para as 541.909 linhas.

> No log aparecem 5.268 linhas `ERROR: Registro integralmente duplicado`. **Isso
> é o comportamento esperado**: é assim que o Apache Hop reporta as linhas que
> saíram pelo *error hop* do transform `Unique rows` e foram para `rejeitados`.
> O workflow só é considerado com falha se terminar em `99_marcar_falha`.

### Testar o caminho de erro

Para demonstrar que uma falha nunca é registrada como sucesso, aponte a
ingestão para um arquivo que não existe:

```bash
docker exec hop-web /usr/local/tomcat/webapps/ROOT/hop-run.sh \
  --project=online-retail --environment=online-retail-dev --runconfig=local \
  --file=/project/online-retail/workflows/wf_online_retail.hwf \
  -p ONLINE_RETAIL_FILE=/project/online-retail/data/NAO_EXISTE.xlsx
```

O workflow desvia de `01_ingestao` para `99_marcar_falha`, grava
`status = FAILED` com a mensagem de erro e termina em erro. As tabelas do último
lote bem-sucedido **não** são afetadas: a staging só é truncada quando a
ingestão consegue começar.

```bash
docker compose exec online-retail-db psql -U online_retail -d online_retail \
  -c "select batch_id, status, linhas_fato, mensagem_erro from online_retail.log_execucao order by inicio_execucao;"
```

## 15. Testar a idempotência

Rode o **mesmo comando** uma segunda vez e compare:

```bash
docker compose exec online-retail-db psql -U online_retail -d online_retail -c "
select batch_id, status, linhas_origem, linhas_rejeitadas, linhas_fato
  from online_retail.log_execucao
 order by inicio_execucao;
select count(*) as total_fato from online_retail.fato_venda;"
```

O esperado: **duas** linhas em `log_execucao`, ambas `SUCCESS`, ambas com
`linhas_fato = 534129` — e `total_fato = 534129`, não o dobro. A consulta 10 de
`sql/validacoes.sql` faz essa comparação automaticamente.

> As duas execuções levam praticamente o mesmo tempo (~2min25 cada), mas fazem
> coisas diferentes na fato: na primeira, as 534.129 linhas caem no ramo de
> `INSERT` do upsert; na segunda, todas caem no ramo de `UPDATE`. É exatamente
> esse desvio que impede a duplicação.
>
> `rejeitados` **cresce** a cada execução (7.780 → 15.560): cada lote guarda seu
> próprio histórico de descartes, identificado por `batch_id`. Isso é auditoria
> intencional, não duplicação — a tabela fato continua com 534.129 linhas.

## 16. Consultar os resultados

```bash
docker compose exec online-retail-db psql -U online_retail -d online_retail

-- indicadores gerais
select * from online_retail.vw_indicadores_gerais;

-- tudo o que a apresentação precisa, já rotulado
select metrica, valor, unidade from online_retail.vw_metricas_apresentacao order by ordem;

-- rankings e série temporal
select * from online_retail.vw_top_produtos order by ranking_quantidade limit 10;
select * from online_retail.vw_faturamento_pais order by ranking_faturamento limit 10;
select * from online_retail.vw_evolucao_mensal order by data_mes;

-- por que cada linha foi descartada
select * from online_retail.vw_rejeicoes_por_motivo;
select linha_seq, invoice_no, motivo, detalhe from online_retail.rejeitados limit 20;
```

Para inspecionar de fora do Docker (DBeaver, psql local): `localhost:5434`.

## 17. Dashboard

Metabase roda em <http://localhost:3001>. O dashboard inteiro é provisionado por
script — não é preciso montar card por card:

```bash
python3 scripts/provisionar-metabase.py
```

O script conclui o setup do Metabase, registra a conexão PostgreSQL, sincroniza
o schema, cria a coleção `Online Retail`, os 11 cards e o dashboard
**`Online Retail - ETL e Vendas`**. Ao final ele imprime a URL e o login. Rodar
de novo apenas atualiza o que já existe.

O usuário administrador do Metabase sai de `MB_ADMIN_EMAIL` / `MB_ADMIN_PASSWORD`
no `.env` (é uma conta do Metabase, não do PostgreSQL).

O dashboard traz: faturamento bruto, cancelado e líquido, quantidade vendida,
ticket médio, taxa de cancelamento, ranking de produtos, ranking de países,
evolução mensal, a tabela de métricas do ETL e as rejeições por motivo.

Para montar ou ajustar cards à mão — o SQL de cada um, o tipo de visualização e
o valor de referência esperado — veja
[`projects/online-retail/dashboard/README.md`](projects/online-retail/dashboard/README.md).

## 18. Validar o projeto

```bash
docker compose exec -T online-retail-db \
  psql -U online_retail -d online_retail \
  -f /dev/stdin < projects/online-retail/sql/validacoes.sql
```

O arquivo começa com a consulta **0**, que devolve as 12 verificações em uma
tabela única — toda linha tem de sair com `Status = OK`. As consultas 1 a 12
detalham cada uma delas:

| # | Verifica | Esperado |
|---|---|---|
| 1 | Resumo da última execução `SUCCESS` | `status = SUCCESS` |
| 2 | Reconciliação origem → staging → válidos/rejeitados | diferenças **0** |
| 3 | Rejeições por motivo | 5.268 / 1.336 / 1.176 |
| 4 | Duplicatas por SHA-256 na staging × duplicatas rejeitadas pelo pipeline | `diferenca = 0`, 5.268 excedentes |
| 5 | Duplicidade da chave natural na fato | **0** |
| 6 | Duplicidade em `stock_code`, `country`, `data` | **0** nas três |
| 7 | Fatos órfãos de produto, país ou tempo | **0** nos três |
| 8 | Regras violadas dentro da fato | **0** nas quatro |
| 9 | Chaves naturais distintas × total da fato | diferença **0** |
| 10 | Comparação das duas últimas execuções | `diferenca_reexecucao = 0` |
| 11 | Baseline contra o arquivo UCI | tudo `OK` |
| 12 | Indicadores usados no dashboard | valores da seção 11 |

---

## Estrutura do repositório

```text
CursoApacheHop/
├── docker-compose.yml            PostgreSQL + Apache Hop Web + Metabase
├── Dockerfile                    hop-web com UID/GID alinhados ao host
├── .env.example                  modelo das credenciais (copie para .env)
├── scripts/
│   ├── preparar-ambiente.sh      gera .env e o ambiente do Hop
│   ├── verificar-dataset.sh      confere o SHA-256 do Excel
│   └── provisionar-metabase.py   cria o dashboard inteiro via API
├── config/                       HOP_CONFIG_FOLDER (hop-config.json, samples)
├── jdbc-drivers/                 driver JDBC do PostgreSQL
└── projects/
    └── online-retail/            ← projeto Apache Hop (= /project/online-retail)
        ├── project-config.json
        ├── online-retail-dev.json    ambiente (gerado, não versionado)
        ├── metadata/rdbms/OnlineRetailPostgreSQL.json
        ├── data/online_retail.xlsx   dataset (não versionado) + CHECKSUMS
        ├── pipelines/                00 … 08 e 99
        ├── workflows/wf_online_retail.hwf
        ├── sql/                      01_schema · 02_tables · 03_views · validacoes
        ├── docs/metricas_esperadas.md
        └── dashboard/README.md
```

A pasta do projeto Hop fica em `projects/online-retail/` — e não `hop/` na raiz
— porque essa é a convenção do Apache Hop: um projeto é um diretório com
`project-config.json`, registrado no `hop-config.json` e montado no container
como `/project/online-retail`. `sql/`, `data/`, `docs/` e `dashboard/` vivem
dentro do projeto para que ele seja autocontido.

## Credenciais

Nenhuma credencial fica escrita em pipeline, workflow ou metadata: a conexão
`OnlineRetailPostgreSQL` referencia `${DB_HOST}`, `${DB_PORT}`, `${DB_NAME}`,
`${DB_USER}` e `${DB_PASSWORD}`.

`.env` é a **única** fonte de verdade — o Docker Compose lê dele, e
`scripts/preparar-ambiente.sh` gera a partir dele o ambiente do Hop
(`online-retail-dev.json`). Os dois arquivos gerados estão no `.gitignore`;
apenas `.env.example`, com senha de exemplo, é versionado.
