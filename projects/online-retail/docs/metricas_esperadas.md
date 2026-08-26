# Dataset e métricas esperadas

Este documento fixa a versão da fonte, as regras de qualidade e os valores de
referência usados para validar o projeto. As contagens abaixo foram calculadas
diretamente sobre o arquivo Excel identificado pelo checksum informado nesta
página. Um arquivo diferente, ainda que tenha o mesmo nome, precisa ser
revalidado antes de comparar os resultados.

## Fonte oficial e licença

- Dataset: **Online Retail**.
- Autor: Daqing Chen.
- Repositório: UCI Machine Learning Repository, dataset 352.
- Página oficial: <https://archive.ics.uci.edu/dataset/352/online%2Bretail>
- Download oficial: <https://archive.ics.uci.edu/static/public/352/online%2Bretail.zip>
- DOI: <https://doi.org/10.24432/C5BW33>
- Licença: [Creative Commons Attribution 4.0 International
  (CC BY 4.0)](https://creativecommons.org/licenses/by/4.0/).

Citação recomendada:

> Chen, D. (2015). Online Retail [Dataset]. UCI Machine Learning Repository.
> https://doi.org/10.24432/C5BW33.

O arquivo usado pelo projeto é `Online Retail.xlsx`, renomeado localmente para
`online_retail.xlsx` quando colocado em `projects/online-retail/data/`.

| Propriedade | Valor esperado |
|---|---:|
| SHA-256 | `43465a06f2ccf7c8b5bd2892bc7defb52f97487934fe93b16ae4c3936424676d` |
| Tamanho | 23.715.344 bytes |
| Planilha | `Online Retail` |
| Faixa preenchida | `A1:H541910` |
| Linhas de dados | 541.909 |
| Colunas | 8 |
| Período | 2010-12-01 08:26:00 a 2011-12-09 12:50:00 |

Cabeçalho esperado, na ordem da fonte:

```text
InvoiceNo, StockCode, Description, Quantity, InvoiceDate, UnitPrice, CustomerID, Country
```

## Convenções de processamento

`linha_seq` é o **número físico da linha na planilha**, produzido pelo próprio
transform de leitura do Excel (campo *sheet row number*), com uma única cópia do
transform de entrada e antes de qualquer ordenação ou deduplicação. Como a linha
1 é o cabeçalho, a primeira linha de dados é `linha_seq = 2` e a última é
`linha_seq = 541910`. A vantagem prática é a rastreabilidade direta: uma linha
rejeitada com `linha_seq = 4711` é a linha 4711 do arquivo Excel.

O valor não vem de uma sequence do banco, e sim da posição na fonte — é isso que
o torna idêntico em toda reexecução e permite que ele componha a chave natural.

Uma duplicata integral é uma repetição dos oito campos originais. `batch_id`,
`linha_seq` e datas técnicas não participam dessa comparação. Quando houver
repetição, conserva-se a ocorrência com a menor `linha_seq` e as demais são
registradas com motivo `DUPLICATA_INTEGRAL`.

As regras de rejeição usam esta prioridade para que cada linha tenha um único
motivo primário e as métricas sejam somáveis:

1. `DUPLICATA_INTEGRAL`;
2. `QUANTIDADE_INVALIDA`, quando `Quantity <= 0` e `InvoiceNo` não começa com
   `C`;
3. `PRECO_UNITARIO_INVALIDO`, quando `UnitPrice <= 0` e a linha ainda não foi
   rejeitada.

O preço é validado com `<= 0`, e não somente `= 0`, porque a fonte contém dois
ajustes com preço negativo. `CustomerID` nulo é preservado como `NULL` e não é
motivo de rejeição. Cancelamentos são identificados por
`upper(trim(InvoiceNo)) LIKE 'C%'` e continuam na tabela fato mesmo quando a
quantidade é negativa.

A chave natural da fato é:

```text
invoice_no + stock_code + linha_seq
```

`batch_id` não faz parte dessa chave. Uma reexecução da mesma fonte deve fazer
upsert sem duplicar fatos e sem alterar uma linha quando nenhum atributo de
negócio mudou.

## Perfil da fonte

| Métrica bruta | Valor |
|---|---:|
| Linhas de origem | 541.909 |
| `CustomerID` nulo | 135.080 |
| `Description` nula | 1.454 |
| Linhas de cancelamento (`C%`) | 9.288 |
| `Quantity <= 0` | 10.624 |
| `Quantity <= 0` sem prefixo `C` | 1.336 |
| `UnitPrice = 0` | 2.515 |
| `UnitPrice < 0` | 2 |
| `UnitPrice <= 0` | 2.517 |
| Duplicatas integrais excedentes | 5.268 |

Depois de conservar a primeira ocorrência de cada duplicata existem 536.641
linhas, das quais 9.251 são linhas de cancelamento e 135.037 têm
`CustomerID` nulo.

## Waterfall de qualidade

| Etapa ou destino | Linhas | Observação |
|---|---:|---|
| Origem/staging | 541.909 | Uma linha de staging por linha da planilha |
| `DUPLICATA_INTEGRAL` | 5.268 | Ocorrências excedentes; conserva a primeira |
| `QUANTIDADE_INVALIDA` | 1.336 | Não canceladas com quantidade não positiva |
| `PRECO_UNITARIO_INVALIDO` | 1.176 | Preço não positivo após a prioridade anterior |
| Total rejeitado/descartado | 7.780 | 1,435665% da origem |
| Total válido esperado na fato | 534.129 | Não deve crescer na reexecução idêntica |

Reconciliação obrigatória:

```text
541.909 = 5.268 + 1.336 + 1.176 + 534.129
```

Existem 2.512 linhas únicas com preço não positivo. Dessas, 1.336 também têm
quantidade inválida e recebem o motivo primário `QUANTIDADE_INVALIDA`; por isso
restam 1.176 rejeições atribuídas ao preço. Não se deve somar 1.336 e 2.512 sem
considerar essa interseção.

## Cardinalidades após o tratamento

| Métrica | Valor esperado |
|---|---:|
| Linhas na fato | 534.129 |
| Linhas da fato com `CustomerID` nulo | 132.565 |
| Linhas de cancelamento na fato | 9.251 |
| Invoices distintas válidas | 23.796 |
| Invoices de venda distintas | 19.960 |
| Invoices de cancelamento distintas | 3.836 |
| Produtos/`StockCode` distintos | 3.938 |
| Países distintos | 38 |
| Datas distintas com movimento | 305 |

Se `dim_tempo` for preenchida apenas a partir das datas presentes na fato, ela
terá 305 linhas. Uma dimensão de calendário contínuo entre a menor e a maior
data terá cardinalidade diferente e essa decisão deve ser documentada.

## Fórmulas financeiras

O valor de linha é calculado sem inverter o sinal da quantidade:

```text
valor_total = unit_price * quantity
```

Use precisão decimal no banco e arredonde para duas casas apenas na camada de
apresentação. Isso evita acumular erro de arredondamento por linha.

### Cuidado com o transform Calculator

A multiplicação de `BigNumber` do transform **Calculator** do Apache Hop aplica
um `MathContext` derivado da precisão dos operandos e arredonda o resultado
para poucos dígitos significativos. Na prática, `9 × 15,0000` sai como
`140,0000` e `50 × 2,1000` sai como `100,0000` — o erro atinge 126.534 das
534.129 linhas e reduz o faturamento bruto em £5.113,51.

Por isso `valor_total` é calculado com o transform **User Defined Java
Expression**:

```java
unit_price.multiply(java.math.BigDecimal.valueOf(quantity.longValue()))
```

Essa é uma multiplicação exata de `BigDecimal`, sem arredondamento
intermediário. O resultado confere dígito a dígito com o total calculado
diretamente sobre o arquivo Excel.

### Faturamento bruto

Soma somente as vendas não canceladas:

```sql
sum(valor_total) filter (where cancelamento = false)
```

Valor esperado: **£10.642.110,8040**.

### Valor cancelado

É apresentado como valor positivo para facilitar a leitura:

```sql
sum(abs(valor_total)) filter (where cancelamento = true)
```

Valor esperado: **£893.979,7300**.

### Faturamento líquido

```text
faturamento_liquido = faturamento_bruto - valor_cancelado
```

Valor esperado: **£9.748.131,0740**.

O cálculo explícito acima é preferível a simplesmente somar `valor_total`, pois
continua correto caso uma futura fonte traga cancelamento com quantidade
positiva.

### Quantidade vendida

```sql
sum(quantity) filter (where cancelamento = false)
```

Quantidade bruta esperada: **5.572.420 unidades**. A quantidade absoluta nas
linhas canceladas é **275.560 unidades**.

### Ticket médio

O indicador principal usa o faturamento líquido e apenas invoices de venda no
denominador:

```text
ticket_medio = faturamento_liquido / 19.960 invoices de venda distintas
```

Valor esperado: **£488,38**. Como indicador complementar, o ticket bruto é
**£533,17**, calculado como faturamento bruto dividido pelas mesmas 19.960
invoices. Invoices iniciadas por `C` não entram no denominador.

### Taxa de cancelamento

A taxa é calculada no grão de invoice, para que notas com muitos itens não
tenham peso artificialmente maior:

```text
taxa_cancelamento = 3.836 invoices C / 23.796 invoices válidas * 100
```

Valor esperado: **16,1204%**.

### Rankings e série temporal

- Ranking de produtos: quantidade líquida por `stock_code`, com cancelamentos
  subtraídos em valor absoluto. A quantidade bruta pode ser exibida em coluna
  auxiliar.
- Ranking de países: faturamento líquido por país.
- Evolução mensal: bruto, cancelado e líquido agrupados pelo mês de
  `invoice_date`. O cancelamento é reconhecido no mês em que sua própria linha
  ocorreu.

## Critérios de aceite da carga

- O checksum da fonte corresponde ao documentado.
- Staging possui 541.909 linhas no lote concluído.
- A reconciliação entre origem, duplicatas, rejeições e válidos fecha sem
  diferença.
- A fato possui 534.129 linhas e nenhuma duplicidade em
  `(invoice_no, stock_code, linha_seq)`.
- Não existem chaves órfãs para produto, país ou tempo.
- Duas execuções consecutivas da mesma fonte mantêm 534.129 fatos. Tabelas de
  auditoria e rejeitados podem ganhar um novo `batch_id` por execução; isso é
  histórico intencional, não duplicação da fato.
- As views de apresentação reproduzem os valores financeiros deste documento,
  com tolerância apenas de formatação/arredondamento na exibição.
