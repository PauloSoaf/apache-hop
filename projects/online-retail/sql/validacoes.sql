-- Execute após o workflow, a partir da raiz do repositório:
--
--   docker compose exec -T online-retail-db \
--     psql -U online_retail -d online_retail \
--     -f /dev/stdin < projects/online-retail/sql/validacoes.sql
--
-- Ou, para rodar uma consulta específica, abra um psql interativo:
--
--   docker compose exec online-retail-db psql -U online_retail -d online_retail

-- 0. RESUMO: as 12 verificações em uma tabela só.
-- Todas as linhas devem sair com Status = OK. É a consulta usada no
-- dashboard e na apresentação; as consultas 1 a 12 abaixo detalham cada uma.
WITH u AS (
    SELECT batch_id, linhas_origem, linhas_staging, linhas_validas,
           linhas_rejeitadas, duplicatas_removidas, linhas_fato
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS' ORDER BY inicio_execucao DESC LIMIT 1
),
v (ordem, verificacao, esperado, obtido) AS (
    SELECT 1, 'Origem = staging', 0::BIGINT,
           (SELECT linhas_origem - linhas_staging FROM u)
    UNION ALL SELECT 2, 'Staging = válidos + rejeitados', 0::BIGINT,
           (SELECT u.linhas_staging - u.linhas_validas
                   - (SELECT COUNT(DISTINCT linha_seq) FROM online_retail.rejeitados r
                       WHERE r.batch_id = u.batch_id) FROM u)
    UNION ALL SELECT 3, 'Duplicatas rejeitadas', 5268::BIGINT,
           (SELECT COUNT(*) FROM online_retail.rejeitados r JOIN u ON u.batch_id = r.batch_id
             WHERE motivo = 'DUPLICATA_INTEGRAL')
    UNION ALL SELECT 4, 'Duplicatas por hash = pipeline', 0::BIGINT,
           (SELECT COALESCE(SUM(n-1),0) - (SELECT COUNT(*) FROM online_retail.rejeitados r
              JOIN u ON u.batch_id = r.batch_id WHERE motivo='DUPLICATA_INTEGRAL')
              FROM (SELECT COUNT(*) n FROM online_retail.stg_online_retail s JOIN u ON u.batch_id=s.batch_id
                     GROUP BY s.registro_hash HAVING COUNT(*)>1) g)
    UNION ALL SELECT 5, 'Chave natural duplicada na fato', 0::BIGINT,
           (SELECT COUNT(*) FROM (SELECT 1 FROM online_retail.fato_venda
              GROUP BY invoice_no, stock_code, linha_seq HAVING COUNT(*)>1) d)
    UNION ALL SELECT 6, 'stock_code duplicado em dim_produto', 0::BIGINT,
           (SELECT COUNT(*) FROM (SELECT 1 FROM online_retail.dim_produto GROUP BY stock_code HAVING COUNT(*)>1) d)
    UNION ALL SELECT 7, 'country duplicado em dim_pais', 0::BIGINT,
           (SELECT COUNT(*) FROM (SELECT 1 FROM online_retail.dim_pais GROUP BY country HAVING COUNT(*)>1) d)
    UNION ALL SELECT 8, 'data duplicada em dim_tempo', 0::BIGINT,
           (SELECT COUNT(*) FROM (SELECT 1 FROM online_retail.dim_tempo GROUP BY data HAVING COUNT(*)>1) d)
    UNION ALL SELECT 9, 'Fatos órfãos de dimensão', 0::BIGINT,
           (SELECT COUNT(*) FROM online_retail.fato_venda f
             LEFT JOIN online_retail.dim_produto p ON p.produto_sk=f.produto_sk
             LEFT JOIN online_retail.dim_pais   c ON c.pais_sk=f.pais_sk
             LEFT JOIN online_retail.dim_tempo  t ON t.tempo_sk=f.tempo_sk
            WHERE p.produto_sk IS NULL OR c.pais_sk IS NULL OR t.tempo_sk IS NULL)
    UNION ALL SELECT 10, 'Regras violadas dentro da fato', 0::BIGINT,
           (SELECT COUNT(*) FROM online_retail.fato_venda
             WHERE unit_price <= 0
                OR (NOT cancelamento AND quantity <= 0)
                OR cancelamento <> (LEFT(invoice_no,1) = 'C')
                OR valor_total <> quantity * unit_price)
    UNION ALL SELECT 11, 'Fato após reexecução', 534129::BIGINT,
           (SELECT COUNT(*) FROM online_retail.fato_venda)
    UNION ALL SELECT 12, 'Baseline UCI (origem)', 541909::BIGINT,
           (SELECT linhas_origem FROM u)
)
SELECT ordem AS "#", verificacao AS "Verificação", esperado AS "Esperado", obtido AS "Obtido",
       CASE WHEN esperado = obtido THEN 'OK' ELSE 'FALHOU' END AS "Status"
FROM v ORDER BY ordem;

-- 1. Resumo da execução concluída mais recente.
WITH ultima_execucao AS (
    SELECT *
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
)
SELECT
    batch_id,
    inicio_execucao,
    fim_execucao,
    status,
    linhas_origem,
    linhas_staging,
    linhas_validas,
    linhas_rejeitadas,
    duplicatas_removidas,
    linhas_fato,
    mensagem_erro
FROM ultima_execucao;

-- 2. Reconciliação origem -> staging -> válidos/rejeitados.
-- Esperado: origem = staging e staging = válidos + rejeitados.
WITH ultima_execucao AS (
    SELECT *
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
),
contagens AS (
    SELECT
        u.batch_id,
        u.linhas_origem,
        (
          SELECT COUNT(*)
          FROM online_retail.stg_online_retail s
          WHERE s.batch_id = u.batch_id
        )::BIGINT AS staging_real,
        (
          SELECT COUNT(*)
          FROM online_retail.wrk_online_retail_validos w
          WHERE w.batch_id = u.batch_id
        )::BIGINT AS validas_real,
        (
          SELECT COUNT(DISTINCT r.linha_seq)
          FROM online_retail.rejeitados r
          WHERE r.batch_id = u.batch_id
        )::BIGINT AS rejeitadas_reais
    FROM ultima_execucao u
)
SELECT
    *,
    (linhas_origem - staging_real) AS diferenca_origem_staging,
    (staging_real - validas_real - rejeitadas_reais)
      AS diferenca_staging_destinos
FROM contagens;

-- 3. Rejeições por motivo da última execução.
WITH ultima_execucao AS (
    SELECT batch_id
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
)
SELECT
    r.motivo,
    COUNT(*) AS quantidade,
    ROUND(
      100.0 * COUNT(*) /
      NULLIF((SELECT linhas_origem
              FROM online_retail.log_execucao l
              WHERE l.batch_id = u.batch_id), 0),
      4
    ) AS percentual_origem
FROM online_retail.rejeitados r
JOIN ultima_execucao u
  ON u.batch_id = r.batch_id
GROUP BY r.motivo, u.batch_id
ORDER BY quantidade DESC, r.motivo;

-- 4. Duplicatas integrais conferidas de forma independente do pipeline.
-- O pipeline 02 deduplica comparando as oito colunas da fonte; a staging guarda
-- o SHA-256 dessas mesmas oito colunas. Agrupar por hash tem de chegar ao mesmo
-- número de ocorrências excedentes que o pipeline mandou para `rejeitados`.
-- Esperado: diferenca = 0 e excedentes_por_hash = 5268.
WITH ultima_execucao AS (
    SELECT batch_id
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
),
grupos AS (
    SELECT s.registro_hash, COUNT(*) AS ocorrencias
    FROM online_retail.stg_online_retail s
    JOIN ultima_execucao u ON u.batch_id = s.batch_id
    WHERE s.registro_hash IS NOT NULL
    GROUP BY s.registro_hash
    HAVING COUNT(*) > 1
)
SELECT
    (SELECT COUNT(*) FROM grupos)::BIGINT AS grupos_com_repeticao,
    (SELECT COALESCE(SUM(ocorrencias - 1), 0) FROM grupos)::BIGINT
      AS excedentes_por_hash,
    (SELECT COUNT(*)
       FROM online_retail.rejeitados r
       JOIN ultima_execucao u ON u.batch_id = r.batch_id
      WHERE r.motivo = 'DUPLICATA_INTEGRAL')::BIGINT AS rejeitados_pelo_pipeline,
    (SELECT COALESCE(SUM(ocorrencias - 1), 0) FROM grupos)
      - (SELECT COUNT(*)
           FROM online_retail.rejeitados r
           JOIN ultima_execucao u ON u.batch_id = r.batch_id
          WHERE r.motivo = 'DUPLICATA_INTEGRAL') AS diferenca;

-- 4b. Os dez grupos com mais repetições, para inspeção manual.
WITH ultima_execucao AS (
    SELECT batch_id
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
)
SELECT
    s.registro_hash,
    COUNT(*) AS ocorrencias,
    MIN(s.linha_seq) AS linha_mantida,
    MIN(s.invoice_no) AS invoice_no,
    MIN(s.stock_code) AS stock_code
FROM online_retail.stg_online_retail s
JOIN ultima_execucao u
  ON u.batch_id = s.batch_id
WHERE s.registro_hash IS NOT NULL
GROUP BY s.registro_hash
HAVING COUNT(*) > 1
ORDER BY COUNT(*) DESC, s.registro_hash
LIMIT 10;

-- 5. Duplicidade da chave natural da fato. Esperado: zero.
SELECT COUNT(*) AS chaves_naturais_duplicadas
FROM (
    SELECT invoice_no, stock_code, linha_seq
    FROM online_retail.fato_venda
    GROUP BY invoice_no, stock_code, linha_seq
    HAVING COUNT(*) > 1
) duplicadas;

-- 6. Duplicidades nas chaves de negócio das dimensões. Todas esperadas: zero.
SELECT 'dim_produto.stock_code' AS verificacao, COUNT(*) AS duplicidades
FROM (
    SELECT stock_code
    FROM online_retail.dim_produto
    GROUP BY stock_code
    HAVING COUNT(*) > 1
) d
UNION ALL
SELECT 'dim_pais.country', COUNT(*)
FROM (
    SELECT country
    FROM online_retail.dim_pais
    GROUP BY country
    HAVING COUNT(*) > 1
) d
UNION ALL
SELECT 'dim_tempo.data', COUNT(*)
FROM (
    SELECT data
    FROM online_retail.dim_tempo
    GROUP BY data
    HAVING COUNT(*) > 1
) d;

-- 7. Integridade referencial. Todas esperadas: zero.
SELECT
    COUNT(*) FILTER (WHERE p.produto_sk IS NULL) AS fatos_sem_produto,
    COUNT(*) FILTER (WHERE c.pais_sk IS NULL) AS fatos_sem_pais,
    COUNT(*) FILTER (WHERE t.tempo_sk IS NULL) AS fatos_sem_tempo
FROM online_retail.fato_venda f
LEFT JOIN online_retail.dim_produto p
  ON p.produto_sk = f.produto_sk
LEFT JOIN online_retail.dim_pais c
  ON c.pais_sk = f.pais_sk
LEFT JOIN online_retail.dim_tempo t
  ON t.tempo_sk = f.tempo_sk;

-- 8. Regras que nunca podem aparecer na fato. Todas esperadas: zero.
SELECT
    COUNT(*) FILTER (WHERE unit_price <= 0) AS preco_invalido,
    COUNT(*) FILTER (
      WHERE NOT cancelamento AND quantity <= 0
    ) AS quantidade_invalida_nao_cancelamento,
    COUNT(*) FILTER (
      WHERE cancelamento <> (LEFT(invoice_no, 1) = 'C')
    ) AS flag_cancelamento_inconsistente,
    COUNT(*) FILTER (
      WHERE valor_total <> quantity * unit_price
    ) AS valor_total_inconsistente
FROM online_retail.fato_venda;

-- 9. Idempotência no estado atual. Esperado: diferença zero.
SELECT
    COUNT(*) AS total_fato,
    COUNT(DISTINCT (invoice_no, stock_code, linha_seq))
      AS chaves_naturais_distintas,
    COUNT(*) -
      COUNT(DISTINCT (invoice_no, stock_code, linha_seq))
      AS diferenca
FROM online_retail.fato_venda;

-- 10. Comparação das duas execuções SUCCESS mais recentes.
-- Ao reprocessar a mesma fonte, total_fato_atual = total_fato_anterior.
WITH execucoes AS (
    SELECT
        batch_id,
        inicio_execucao,
        linhas_fato AS total_fato_atual,
        LAG(linhas_fato) OVER (
          ORDER BY inicio_execucao
        ) AS total_fato_anterior
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
),
ultimas_duas AS (
    SELECT *
    FROM execucoes
    ORDER BY inicio_execucao DESC
    LIMIT 2
)
SELECT
    batch_id,
    inicio_execucao,
    total_fato_atual,
    total_fato_anterior,
    total_fato_atual - total_fato_anterior AS diferenca_reexecucao
FROM ultimas_duas
ORDER BY inicio_execucao DESC;

-- 11. Baseline validado diretamente no arquivo UCI fornecido.
-- Todas as diferenças devem ser zero para essa versão exata da fonte.
WITH ultima_execucao AS (
    SELECT batch_id
    FROM online_retail.log_execucao
    WHERE status = 'SUCCESS'
    ORDER BY inicio_execucao DESC
    LIMIT 1
),
atuais (metrica, valor_atual) AS (
    SELECT 'linhas_origem', COUNT(*)::BIGINT
    FROM online_retail.stg_online_retail s
    JOIN ultima_execucao u ON u.batch_id = s.batch_id
    UNION ALL
    SELECT 'duplicatas_integrais', COUNT(*)::BIGINT
    FROM online_retail.rejeitados r
    JOIN ultima_execucao u ON u.batch_id = r.batch_id
    WHERE r.motivo = 'DUPLICATA_INTEGRAL'
    UNION ALL
    SELECT 'quantidade_invalida', COUNT(*)::BIGINT
    FROM online_retail.rejeitados r
    JOIN ultima_execucao u ON u.batch_id = r.batch_id
    WHERE r.motivo = 'QUANTIDADE_INVALIDA'
    UNION ALL
    SELECT 'preco_invalido', COUNT(*)::BIGINT
    FROM online_retail.rejeitados r
    JOIN ultima_execucao u ON u.batch_id = r.batch_id
    WHERE r.motivo = 'PRECO_UNITARIO_INVALIDO'
    UNION ALL
    SELECT 'cancelamentos_validos', COUNT(*)::BIGINT
    FROM online_retail.fato_venda
    WHERE cancelamento
    UNION ALL
    SELECT 'linhas_fato', COUNT(*)::BIGINT
    FROM online_retail.fato_venda
),
esperados (metrica, valor_esperado) AS (
    VALUES
      ('linhas_origem', 541909::BIGINT),
      ('duplicatas_integrais', 5268::BIGINT),
      ('quantidade_invalida', 1336::BIGINT),
      ('preco_invalido', 1176::BIGINT),
      ('cancelamentos_validos', 9251::BIGINT),
      ('linhas_fato', 534129::BIGINT)
)
SELECT
    e.metrica,
    e.valor_esperado,
    a.valor_atual,
    a.valor_atual - e.valor_esperado AS diferenca,
    CASE
      WHEN a.valor_atual = e.valor_esperado THEN 'OK'
      ELSE 'DIVERGENTE'
    END AS status
FROM esperados e
LEFT JOIN atuais a USING (metrica)
ORDER BY e.metrica;

-- 12. Indicadores usados no dashboard e na apresentação.
SELECT * FROM online_retail.vw_indicadores_gerais;
SELECT * FROM online_retail.vw_metricas_apresentacao ORDER BY ordem;
SELECT * FROM online_retail.vw_top_produtos
ORDER BY ranking_quantidade, stock_code
LIMIT 20;
SELECT * FROM online_retail.vw_faturamento_pais
ORDER BY ranking_faturamento, country;
SELECT * FROM online_retail.vw_evolucao_mensal
ORDER BY data_mes;
