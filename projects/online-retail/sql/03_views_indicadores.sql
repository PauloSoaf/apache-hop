BEGIN;

CREATE OR REPLACE VIEW online_retail.vw_indicadores_gerais AS
WITH agregados AS (
    SELECT
        COALESCE(
          SUM(CASE WHEN NOT cancelamento THEN valor_total ELSE 0 END),
          0
        )::NUMERIC(20,4) AS faturamento_bruto,
        COALESCE(
          SUM(CASE WHEN cancelamento THEN ABS(valor_total) ELSE 0 END),
          0
        )::NUMERIC(20,4) AS valor_cancelado,
        COALESCE(
          SUM(CASE WHEN NOT cancelamento THEN quantity ELSE 0 END),
          0
        )::BIGINT AS quantidade_vendida,
        COALESCE(
          SUM(CASE WHEN cancelamento THEN ABS(quantity) ELSE 0 END),
          0
        )::BIGINT AS quantidade_cancelada,
        COUNT(DISTINCT invoice_no)
          FILTER (WHERE NOT cancelamento)::BIGINT AS invoices_venda,
        COUNT(DISTINCT invoice_no)
          FILTER (WHERE cancelamento)::BIGINT AS invoices_canceladas,
        COUNT(DISTINCT invoice_no)::BIGINT AS invoices_total,
        COUNT(*) FILTER (WHERE cancelamento)::BIGINT AS linhas_cancelamento,
        COUNT(*) FILTER (WHERE customer_id IS NULL)::BIGINT AS customer_id_nulos,
        COUNT(*)::BIGINT AS total_linhas_fato,
        MIN(invoice_date) AS primeira_venda_em,
        MAX(invoice_date) AS ultima_venda_em
    FROM online_retail.fato_venda
)
SELECT
    faturamento_bruto,
    valor_cancelado,
    (faturamento_bruto - valor_cancelado)::NUMERIC(20,4)
      AS faturamento_liquido,
    quantidade_vendida,
    quantidade_cancelada,
    (quantidade_vendida - quantidade_cancelada)::BIGINT
      AS quantidade_liquida,
    COALESCE(
      ROUND(
        (faturamento_bruto - valor_cancelado) /
        NULLIF(invoices_venda, 0),
        4
      ),
      0
    )::NUMERIC(20,4) AS ticket_medio,
    COALESCE(
      ROUND(100.0 * invoices_canceladas / NULLIF(invoices_total, 0), 4),
      0
    )::NUMERIC(9,4) AS taxa_cancelamento_pct,
    invoices_venda,
    invoices_canceladas,
    invoices_total,
    linhas_cancelamento,
    customer_id_nulos,
    total_linhas_fato,
    primeira_venda_em,
    ultima_venda_em
FROM agregados;

CREATE OR REPLACE VIEW online_retail.vw_top_produtos AS
WITH agregados AS (
    SELECT
        p.stock_code,
        p.description,
        COALESCE(
          SUM(CASE WHEN NOT f.cancelamento THEN f.quantity ELSE 0 END),
          0
        )::BIGINT AS quantidade_bruta,
        COALESCE(
          SUM(CASE WHEN f.cancelamento THEN ABS(f.quantity) ELSE 0 END),
          0
        )::BIGINT AS quantidade_cancelada,
        COALESCE(
          SUM(CASE WHEN NOT f.cancelamento THEN f.valor_total ELSE 0 END),
          0
        )::NUMERIC(20,4) AS faturamento_bruto,
        COALESCE(
          SUM(CASE WHEN f.cancelamento THEN ABS(f.valor_total) ELSE 0 END),
          0
        )::NUMERIC(20,4) AS valor_cancelado,
        COUNT(DISTINCT f.invoice_no)
          FILTER (WHERE NOT f.cancelamento)::BIGINT AS invoices_venda
    FROM online_retail.fato_venda f
    JOIN online_retail.dim_produto p
      ON p.produto_sk = f.produto_sk
    GROUP BY p.stock_code, p.description
)
SELECT
    stock_code,
    description,
    quantidade_bruta,
    quantidade_cancelada,
    (quantidade_bruta - quantidade_cancelada)::BIGINT
      AS quantidade_liquida,
    (faturamento_bruto - valor_cancelado)::NUMERIC(20,4)
      AS faturamento_liquido,
    faturamento_bruto,
    valor_cancelado,
    invoices_venda,
    DENSE_RANK() OVER (
      ORDER BY quantidade_bruta - quantidade_cancelada DESC,
               stock_code
    )::BIGINT AS ranking_quantidade
FROM agregados;

CREATE OR REPLACE VIEW online_retail.vw_faturamento_pais AS
WITH agregados AS (
    SELECT
        p.country,
        COALESCE(
          SUM(CASE WHEN NOT f.cancelamento THEN f.valor_total ELSE 0 END),
          0
        )::NUMERIC(20,4) AS faturamento_bruto,
        COALESCE(
          SUM(CASE WHEN f.cancelamento THEN ABS(f.valor_total) ELSE 0 END),
          0
        )::NUMERIC(20,4) AS valor_cancelado,
        COALESCE(
          SUM(CASE WHEN NOT f.cancelamento THEN f.quantity ELSE 0 END),
          0
        )::BIGINT AS quantidade_vendida,
        COUNT(DISTINCT f.invoice_no)
          FILTER (WHERE NOT f.cancelamento)::BIGINT AS invoices_venda,
        COUNT(DISTINCT f.customer_id)
          FILTER (WHERE f.customer_id IS NOT NULL)::BIGINT AS clientes_identificados
    FROM online_retail.fato_venda f
    JOIN online_retail.dim_pais p
      ON p.pais_sk = f.pais_sk
    GROUP BY p.country
)
SELECT
    country,
    faturamento_bruto,
    valor_cancelado,
    (faturamento_bruto - valor_cancelado)::NUMERIC(20,4)
      AS faturamento_liquido,
    quantidade_vendida,
    invoices_venda,
    clientes_identificados,
    DENSE_RANK() OVER (
      ORDER BY faturamento_bruto - valor_cancelado DESC,
               country
    )::BIGINT AS ranking_faturamento
FROM agregados;

CREATE OR REPLACE VIEW online_retail.vw_evolucao_mensal AS
WITH agregados AS (
    SELECT
        DATE_TRUNC('month', invoice_date)::DATE AS data_mes,
        COALESCE(
          SUM(CASE WHEN NOT cancelamento THEN valor_total ELSE 0 END),
          0
        )::NUMERIC(20,4) AS faturamento_bruto,
        COALESCE(
          SUM(CASE WHEN cancelamento THEN ABS(valor_total) ELSE 0 END),
          0
        )::NUMERIC(20,4) AS valor_cancelado,
        COALESCE(
          SUM(CASE WHEN NOT cancelamento THEN quantity ELSE 0 END),
          0
        )::BIGINT AS quantidade_vendida,
        COUNT(DISTINCT invoice_no)
          FILTER (WHERE NOT cancelamento)::BIGINT AS invoices_venda,
        COUNT(DISTINCT invoice_no)
          FILTER (WHERE cancelamento)::BIGINT AS invoices_canceladas,
        COUNT(DISTINCT invoice_no)::BIGINT AS invoices_total
    FROM online_retail.fato_venda
    GROUP BY DATE_TRUNC('month', invoice_date)::DATE
)
SELECT
    data_mes,
    TO_CHAR(data_mes, 'YYYY-MM') AS ano_mes,
    faturamento_bruto,
    valor_cancelado,
    (faturamento_bruto - valor_cancelado)::NUMERIC(20,4)
      AS faturamento_liquido,
    quantidade_vendida,
    invoices_venda,
    invoices_canceladas,
    COALESCE(
      ROUND(100.0 * invoices_canceladas / NULLIF(invoices_total, 0), 4),
      0
    )::NUMERIC(9,4) AS taxa_cancelamento_pct
FROM agregados;

CREATE OR REPLACE VIEW online_retail.vw_rejeicoes_por_motivo AS
SELECT
    batch_id,
    motivo,
    COUNT(*)::BIGINT AS quantidade
FROM online_retail.rejeitados
GROUP BY batch_id, motivo;

CREATE OR REPLACE VIEW online_retail.vw_metricas_apresentacao AS
WITH ultima_execucao AS (
    SELECT
        batch_id,
        linhas_origem,
        linhas_staging,
        linhas_validas,
        linhas_rejeitadas,
        duplicatas_removidas,
        linhas_fato
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
),
metricas_execucao AS (
    SELECT
        u.*,
        (
          SELECT COUNT(*)
          FROM online_retail.stg_online_retail s
          WHERE s.batch_id = u.batch_id
            AND NULLIF(BTRIM(s.customer_id_original), '') IS NULL
        )::BIGINT AS customer_id_nulos_origem,
        (
          SELECT COUNT(*)
          FROM online_retail.rejeitados r
          WHERE r.batch_id = u.batch_id
            AND r.motivo = 'QUANTIDADE_INVALIDA'
        )::BIGINT AS rejeitados_quantidade,
        (
          SELECT COUNT(*)
          FROM online_retail.rejeitados r
          WHERE r.batch_id = u.batch_id
            AND r.motivo = 'PRECO_UNITARIO_INVALIDO'
        )::BIGINT AS rejeitados_preco,
        (
          SELECT COUNT(*)
          FROM online_retail.rejeitados r
          WHERE r.batch_id = u.batch_id
            AND r.motivo = 'DUPLICATA_INTEGRAL'
        )::BIGINT AS duplicatas_registradas
    FROM ultima_execucao u
),
gerais AS (
    SELECT *
    FROM online_retail.vw_indicadores_gerais
)
SELECT metrica, valor, unidade, ordem
FROM (
    SELECT 'Total de linhas da origem'::TEXT AS metrica,
           m.linhas_origem::NUMERIC AS valor,
           'linhas'::TEXT AS unidade,
           10 AS ordem
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Total de linhas na staging',
           m.linhas_staging::NUMERIC,
           'linhas',
           20
    FROM metricas_execucao m
    UNION ALL
    SELECT 'CustomerID nulos na origem',
           m.customer_id_nulos_origem::NUMERIC,
           'linhas',
           30
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Duplicatas integrais removidas',
           m.duplicatas_registradas::NUMERIC,
           'linhas',
           40
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Rejeitados por quantidade',
           m.rejeitados_quantidade::NUMERIC,
           'linhas',
           50
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Rejeitados por preço',
           m.rejeitados_preco::NUMERIC,
           'linhas',
           60
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Total rejeitado',
           m.linhas_rejeitadas::NUMERIC,
           'linhas',
           70
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Percentual rejeitado',
           COALESCE(
             ROUND(100.0 * m.linhas_rejeitadas /
                   NULLIF(m.linhas_origem, 0), 4),
             0
           )::NUMERIC,
           'percentual',
           80
    FROM metricas_execucao m
    UNION ALL
    SELECT 'Total final da fato',
           g.total_linhas_fato::NUMERIC,
           'linhas',
           90
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Linhas de cancelamento',
           g.linhas_cancelamento::NUMERIC,
           'linhas',
           100
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Quantidade vendida',
           g.quantidade_vendida::NUMERIC,
           'unidades',
           110
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Faturamento bruto',
           g.faturamento_bruto::NUMERIC,
           'GBP',
           120
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Valor cancelado',
           g.valor_cancelado::NUMERIC,
           'GBP',
           130
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Faturamento líquido',
           g.faturamento_liquido::NUMERIC,
           'GBP',
           140
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Ticket médio',
           g.ticket_medio::NUMERIC,
           'GBP por invoice',
           150
    FROM gerais g
    CROSS JOIN metricas_execucao m
    UNION ALL
    SELECT 'Taxa de cancelamento',
           g.taxa_cancelamento_pct::NUMERIC,
           'percentual',
           160
    FROM gerais g
    CROSS JOIN metricas_execucao m
) metricas;

COMMENT ON VIEW online_retail.vw_indicadores_gerais IS
  'Bruto exclui cancelamentos; líquido é bruto menos cancelado; ticket médio é líquido por invoice de venda.';
COMMENT ON VIEW online_retail.vw_top_produtos IS
  'Ranking por quantidade líquida, preservando vendas brutas e cancelamentos separadamente.';
COMMENT ON VIEW online_retail.vw_faturamento_pais IS
  'Faturamento por país com valores bruto, cancelado e líquido.';
COMMENT ON VIEW online_retail.vw_evolucao_mensal IS
  'Série mensal baseada na fato persistida, nunca diretamente no arquivo de origem.';
COMMENT ON VIEW online_retail.vw_metricas_apresentacao IS
  'Métricas ordenadas da execução SUCCESS mais recente para uso na apresentação.';

COMMIT;
