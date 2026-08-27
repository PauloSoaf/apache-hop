#!/usr/bin/env python3
"""
Provisiona o dashboard do Online Retail no Metabase, via API.

Faz, de ponta a ponta e de forma idempotente:
  1. conclui o setup inicial do Metabase (ou faz login, se ja estiver configurado);
  2. registra a conexao PostgreSQL do projeto e sincroniza o schema;
  3. cria a colecao "Online Retail";
  4. cria os cards SQL dos indicadores;
  5. monta o dashboard "Online Retail - ETL e Vendas".

Rodar de novo apenas atualiza o que ja existe; nao duplica cards nem dashboards.

Uso (a partir da raiz do repositorio):

    python3 scripts/provisionar-metabase.py

Credenciais: lidas do .env da raiz. O usuario administrador do Metabase e uma
conta propria do Metabase (nao e o usuario do PostgreSQL) e sai de
MB_ADMIN_EMAIL / MB_ADMIN_PASSWORD.
"""

import json
import os
import pathlib
import sys
import urllib.error
import urllib.request

RAIZ = pathlib.Path(__file__).resolve().parent.parent
METABASE = os.environ.get("METABASE_URL", "http://localhost:3001")


def carregar_env():
    env = {}
    arquivo = RAIZ / ".env"
    if not arquivo.exists():
        sys.exit("ERRO: .env nao encontrado. Rode antes: ./scripts/preparar-ambiente.sh")
    for linha in arquivo.read_text(encoding="utf-8").splitlines():
        linha = linha.strip()
        if linha and not linha.startswith("#") and "=" in linha:
            chave, valor = linha.split("=", 1)
            env[chave.strip()] = valor.strip()
    env.setdefault("MB_ADMIN_EMAIL", "admin@online-retail.local")
    env.setdefault("MB_ADMIN_PASSWORD", "OnlineRetail#2024")
    for chave in ("MB_ADMIN_EMAIL", "MB_ADMIN_PASSWORD"):
        if os.environ.get(chave):
            env[chave] = os.environ[chave]
    return env


class Metabase:
    def __init__(self, base):
        self.base = base.rstrip("/")
        self.sessao = None

    def chamar(self, metodo, caminho, corpo=None):
        dados = json.dumps(corpo).encode() if corpo is not None else None
        req = urllib.request.Request(f"{self.base}{caminho}", data=dados, method=metodo)
        req.add_header("Content-Type", "application/json")
        if self.sessao:
            req.add_header("X-Metabase-Session", self.sessao)
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                bruto = resp.read().decode() or "null"
                return json.loads(bruto)
        except urllib.error.HTTPError as erro:
            detalhe = erro.read().decode()[:600]
            raise SystemExit(f"ERRO {erro.code} em {metodo} {caminho}\n{detalhe}") from None
        except urllib.error.URLError as erro:
            raise SystemExit(
                f"ERRO: nao consegui falar com o Metabase em {self.base} ({erro.reason}).\n"
                "Confira se o container esta no ar: docker compose ps online-retail-metabase"
            ) from None


CARDS = [
    ("Faturamento bruto", "scalar", 0, 0, 6, 3,
     "select faturamento_bruto from online_retail.vw_indicadores_gerais;"),
    ("Valor cancelado", "scalar", 0, 6, 6, 3,
     "select valor_cancelado from online_retail.vw_indicadores_gerais;"),
    ("Faturamento líquido", "scalar", 0, 12, 6, 3,
     "select faturamento_liquido from online_retail.vw_indicadores_gerais;"),
    ("Quantidade vendida", "scalar", 0, 18, 6, 3,
     "select quantidade_vendida from online_retail.vw_indicadores_gerais;"),
    ("Ticket médio", "scalar", 3, 0, 12, 3,
     "select ticket_medio from online_retail.vw_indicadores_gerais;"),
    ("Taxa de cancelamento (%)", "scalar", 3, 12, 12, 3,
     "select taxa_cancelamento_pct from online_retail.vw_indicadores_gerais;"),
    ("Produtos mais vendidos", "row", 6, 0, 12, 7,
     "select description, quantidade_liquida\n"
     "  from online_retail.vw_top_produtos\n"
     " order by ranking_quantidade\n"
     " limit 10;"),
    ("Países por faturamento", "row", 6, 12, 12, 7,
     "select country, faturamento_liquido\n"
     "  from online_retail.vw_faturamento_pais\n"
     " order by ranking_faturamento\n"
     " limit 10;"),
    ("Evolução mensal do faturamento", "line", 13, 0, 24, 7,
     "select ano_mes, faturamento_bruto, valor_cancelado, faturamento_liquido\n"
     "  from online_retail.vw_evolucao_mensal\n"
     " order by data_mes;"),
    ("Métricas do ETL", "table", 20, 0, 12, 8,
     "select metrica, valor, unidade\n"
     "  from online_retail.vw_metricas_apresentacao\n"
     " order by ordem;"),
    ("Rejeições por motivo", "table", 36, 0, 12, 8,
     "select motivo, sum(quantidade) as quantidade\n"
     "  from online_retail.vw_rejeicoes_por_motivo\n"
     " group by motivo\n"
     " order by quantidade desc;"),
    ("As 12 validações", "table", 20, 12, 12, 8,
     """WITH u AS (
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
FROM v ORDER BY ordem;"""),
    ("Rejeitados · linha crua, motivo e lote", "table", 28, 0, 24, 8,
     "with u as (select batch_id from online_retail.log_execucao\n"
     "            where status = 'SUCCESS' order by inicio_execucao desc limit 1),\n"
     "amostra as (\n"
     "  select r.*, row_number() over (partition by r.motivo order by r.linha_seq) as n\n"
     "    from online_retail.rejeitados r join u on u.batch_id = r.batch_id)\n"
     "select linha_seq as \"linha do Excel\", invoice_no, stock_code, description,\n"
     "       quantity_original as quantidade, unit_price_original as preco,\n"
     "       customer_id_original as cliente, country_original as pais, motivo\n"
     "  from amostra\n"
     " where n <= 7\n"
     " order by motivo, linha_seq;"),
]


def visualizacao(display, sql):
    if display == "row":
        colunas = [l.strip() for l in sql.split("select", 1)[1].split("from")[0].split(",")]
        return {"graph.dimensions": [colunas[0]], "graph.metrics": [colunas[1]]}
    if display == "line":
        return {
            "graph.dimensions": ["ano_mes"],
            "graph.metrics": ["faturamento_bruto", "valor_cancelado", "faturamento_liquido"],
        }
    return {}


def main():
    env = carregar_env()
    mb = Metabase(METABASE)
    props = mb.chamar("GET", "/api/session/properties")

    detalhes_bd = {
        "host": env["DB_HOST"],
        "port": int(env["DB_PORT"]),
        "dbname": env["DB_NAME"],
        "user": env["DB_USER"],
        "password": env["DB_PASSWORD"],
        "ssl": False,
    }

    if not props.get("has-user-setup"):
        print("[1/5] Concluindo o setup inicial do Metabase...")
        resposta = mb.chamar("POST", "/api/setup", {
            "token": props["setup-token"],
            "user": {
                "first_name": "Online", "last_name": "Retail",
                "email": env["MB_ADMIN_EMAIL"], "password": env["MB_ADMIN_PASSWORD"],
                "site_name": "Online Retail",
            },
            "prefs": {"site_name": "Online Retail", "allow_tracking": False},
            "database": {"engine": "postgres", "name": "Online Retail", "details": detalhes_bd},
        })
        mb.sessao = resposta["id"] if isinstance(resposta, dict) and "id" in resposta else None
        if not mb.sessao:
            mb.sessao = mb.chamar("POST", "/api/session", {
                "username": env["MB_ADMIN_EMAIL"], "password": env["MB_ADMIN_PASSWORD"]})["id"]
        print(f"      administrador criado: {env['MB_ADMIN_EMAIL']}")
    else:
        print("[1/5] Metabase ja configurado, fazendo login...")
        mb.sessao = mb.chamar("POST", "/api/session", {
            "username": env["MB_ADMIN_EMAIL"], "password": env["MB_ADMIN_PASSWORD"]})["id"]

    print("[2/5] Garantindo a conexao PostgreSQL...")
    bancos = mb.chamar("GET", "/api/database")
    bancos = bancos.get("data", bancos) if isinstance(bancos, dict) else bancos
    banco = next((b for b in bancos if b.get("name") == "Online Retail"), None)
    if banco is None:
        banco = mb.chamar("POST", "/api/database", {
            "engine": "postgres", "name": "Online Retail", "details": detalhes_bd})
    banco_id = banco["id"]
    mb.chamar("POST", f"/api/database/{banco_id}/sync_schema")
    print(f"      banco id={banco_id}, sincronizacao de schema disparada")

    print("[3/5] Garantindo a colecao...")
    colecoes = mb.chamar("GET", "/api/collection")
    colecao = next((c for c in colecoes if c.get("name") == "Online Retail"), None)
    if colecao is None:
        colecao = mb.chamar("POST", "/api/collection", {"name": "Online Retail"})
    colecao_id = colecao["id"]
    print(f"      colecao id={colecao_id}")

    print("[4/5] Criando/atualizando os cards...")
    existentes = {c["name"]: c for c in mb.chamar("GET", f"/api/collection/{colecao_id}/items?models=card").get("data", [])}
    cards = {}
    for nome, display, linha, coluna, larg, alt, sql in CARDS:
        payload = {
            "name": nome,
            "dataset_query": {"type": "native", "native": {"query": sql}, "database": banco_id},
            "display": display,
            "visualization_settings": visualizacao(display, sql),
            "collection_id": colecao_id,
        }
        if nome in existentes:
            card = mb.chamar("PUT", f"/api/card/{existentes[nome]['id']}", payload)
        else:
            card = mb.chamar("POST", "/api/card", payload)
        cards[nome] = card["id"]
        print(f"      {nome}")

    print("[5/5] Montando o dashboard...")
    itens = mb.chamar("GET", f"/api/collection/{colecao_id}/items?models=dashboard").get("data", [])
    painel = next((d for d in itens if d.get("name") == "Online Retail - ETL e Vendas"), None)
    if painel is None:
        painel = mb.chamar("POST", "/api/dashboard", {
            "name": "Online Retail - ETL e Vendas",
            "description": "Indicadores do ETL Online Retail (dataset UCI 352). "
                           "Valores de referencia em projects/online-retail/docs/metricas_esperadas.md",
            "collection_id": colecao_id})
    painel_id = painel["id"]

    dashcards = []
    for i, (nome, _d, linha, coluna, larg, alt, _sql) in enumerate(CARDS):
        dashcards.append({
            "id": -(i + 1), "card_id": cards[nome],
            "row": linha, "col": coluna, "size_x": larg, "size_y": alt,
            "parameter_mappings": [], "visualization_settings": {},
        })
    mb.chamar("PUT", f"/api/dashboard/{painel_id}", {"dashcards": dashcards})

    print()
    print("Dashboard pronto:")
    print(f"  {METABASE}/dashboard/{painel_id}")
    print(f"  login: {env['MB_ADMIN_EMAIL']}")


if __name__ == "__main__":
    main()
