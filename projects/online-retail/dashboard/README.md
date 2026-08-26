# Dashboard no Metabase

O Metabase é a camada de visualização deste projeto. O banco, as views e os
dados são criados pela infraestrutura e pelo workflow do Apache Hop.

## Caminho automático (recomendado)

A partir da raiz do repositório, com os containers no ar e o workflow já
executado:

```bash
python3 scripts/provisionar-metabase.py
```

O script usa a API do Metabase para concluir o setup inicial, registrar a
conexão PostgreSQL, sincronizar o schema, criar a coleção `Online Retail`, os 11
cards e o dashboard **`Online Retail - ETL e Vendas`**. Ao final imprime a URL e
o login. Rodar de novo é seguro: ele atualiza o que já existe em vez de duplicar.

O restante deste documento descreve o caminho manual — útil para entender cada
card, ajustar formatação ou refazer algum deles pela interface.

## Pré-requisitos

Antes de configurar o dashboard:

1. inicie os serviços com `docker compose up -d` na raiz do repositório (sobem
   `online-retail-db`, `hop-web` e `online-retail-metabase`);
2. execute o workflow principal do Online Retail e confirme que ele terminou
   com status `SUCCESS`;
3. confirme que o schema `online_retail` contém as views:

   - `vw_indicadores_gerais`;
   - `vw_top_produtos`;
   - `vw_faturamento_pais`;
   - `vw_evolucao_mensal`;
   - `vw_metricas_apresentacao`.

A interface é publicada em <http://localhost:3001>. Na primeira abertura, o
Metabase solicita a criação de um usuário administrador. Essa conta é própria
do Metabase e não é o usuário do PostgreSQL.

## Conexão manual com o PostgreSQL

Na configuração inicial, ou depois em **Administração > Bancos de dados >
Adicionar banco de dados**, escolha PostgreSQL e use:

| Campo | Valor |
|---|---|
| Nome de exibição | `Online Retail` |
| Host | `online-retail-db` |
| Porta | `5432` |
| Banco | `online_retail` |
| Usuário | `online_retail` |
| Senha | valor efetivo de `DB_PASSWORD` |
| SSL | desativado no ambiente local |

O host deve ser `online-retail-db`, e não `localhost`, porque o Metabase acessa
o PostgreSQL pela rede interna do Compose. A porta `127.0.0.1:5434`, quando
publicada, é destinada a clientes executados diretamente na máquina host.

Depois de salvar a conexão, abra as ações do banco e execute **Sincronizar
schema agora** e **Recalcular valores de campos agora**. Se o workflow for
executado depois da primeira sincronização, repita essa etapa para que as views
apareçam no editor visual.

## Cards sugeridos

Crie uma coleção chamada `Online Retail`. Para cada card, use **Nova pergunta >
Consulta SQL nativa**, selecione o banco `Online Retail`, execute a consulta,
escolha a visualização indicada e salve na coleção.

Os nomes de coluna abaixo constituem o contrato esperado das views do projeto.

### 1. Faturamento bruto

```sql
select faturamento_bruto
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**. Formate como moeda GBP, com duas casas decimais.
Referência: **£10.642.110,80**.

### 2. Valor cancelado

```sql
select valor_cancelado
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**, moeda GBP. Referência: **£893.979,73**.

### 3. Faturamento líquido

```sql
select faturamento_liquido
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**, moeda GBP. Referência: **£9.748.131,07**.

### 4. Quantidade vendida

```sql
select quantidade_vendida
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**, sem casas decimais. Referência: **5.572.420**.

### 5. Ticket médio

```sql
select ticket_medio
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**, moeda GBP. Referência: **£488,38**. O indicador é
faturamento líquido dividido por 19.960 invoices de venda distintas.

### 6. Taxa de cancelamento

```sql
select taxa_cancelamento_pct
from online_retail.vw_indicadores_gerais;
```

Visualização: **Número**, sufixo `%` e duas ou quatro casas decimais. A view
retorna pontos percentuais, portanto o valor esperado é **16,1204**, e não
`0,161204`. Não habilite uma segunda multiplicação por 100 na formatação.

### 7. Produtos mais vendidos

```sql
select
  stock_code,
  description,
  quantidade_bruta,
  quantidade_cancelada,
  quantidade_liquida,
  faturamento_liquido
from online_retail.vw_top_produtos
order by quantidade_liquida desc, stock_code
limit 10;
```

Visualização: **Barras horizontais**. Use `description` como categoria e
`quantidade_liquida` como métrica. Mantenha os demais campos disponíveis no
tooltip ou em um card de tabela complementar.

### 8. Países por faturamento

```sql
select
  country,
  faturamento_bruto,
  valor_cancelado,
  faturamento_liquido
from online_retail.vw_faturamento_pais
order by faturamento_liquido desc, country
limit 10;
```

Visualização: **Barras horizontais**, país por faturamento líquido. Formate as
três medidas financeiras como GBP.

### 9. Evolução mensal

```sql
select
  ano_mes,
  faturamento_bruto,
  valor_cancelado,
  faturamento_liquido
from online_retail.vw_evolucao_mensal
order by data_mes;
```

Visualização: **Linha**. Configure `ano_mes` no eixo X e as três medidas no eixo
Y. A view expõe `data_mes` (tipo `date`, usado para ordenar) e `ano_mes` (texto
no formato `YYYY-MM`, usado como rótulo); ordenar por `data_mes` garante a
ordem cronológica mesmo quando a interface trata o rótulo como texto.

### 10. Métricas da apresentação

```sql
select metrica, valor, unidade
from online_retail.vw_metricas_apresentacao
order by ordem;
```

Visualização: **Tabela**. Este card concentra as contagens de auditoria, como
linhas da origem, nulos, rejeições por motivo, duplicatas, cancelamentos e total
da fato. Preserve a ordenação fornecida pela própria view.

## Montagem do dashboard

Crie um dashboard chamado `Online Retail - ETL e Vendas` e organize os cards:

1. primeira linha: faturamento bruto, valor cancelado, faturamento líquido e
   quantidade vendida;
2. segunda linha: ticket médio e taxa de cancelamento;
3. terceira linha: produtos mais vendidos e faturamento por país;
4. quarta linha: evolução mensal em toda a largura;
5. última linha: tabela de métricas da apresentação.

Não é necessário investir em identidade visual elaborada. O objetivo é tornar
visíveis a reconciliação do ETL e os indicadores de negócio. Inclua na descrição
do dashboard a origem UCI e um link para
`projects/online-retail/docs/metricas_esperadas.md`.

## Verificação

Compare os cards com os valores de referência em
`projects/online-retail/docs/metricas_esperadas.md`. Em especial:

- fato: 534.129 linhas;
- faturamento bruto: £10.642.110,80;
- cancelado: £893.979,73;
- faturamento líquido: £9.748.131,07;
- quantidade vendida: 5.572.420;
- ticket médio líquido: £488,38;
- taxa de cancelamento por invoice: 16,1204%.

Se uma view não aparecer, sincronize novamente o schema. Se a consulta retornar
`relation does not exist`, confirme que o workflow terminou e que o editor está
usando o banco `Online Retail`. Se houver erro de conexão, verifique primeiro o
container `online-retail-db`, o valor de `DB_PASSWORD` e o uso da porta interna
`5432`.
