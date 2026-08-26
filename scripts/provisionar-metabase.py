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
    ("Rejeições por motivo", "table", 20, 12, 12, 8,
     "select motivo, sum(quantidade) as quantidade\n"
     "  from online_retail.vw_rejeicoes_por_motivo\n"
     " group by motivo\n"
     " order by quantidade desc;"),
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
