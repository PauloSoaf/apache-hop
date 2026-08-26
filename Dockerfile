# Imagem derivada do Apache Hop Web.
#
# Motivo: na imagem oficial o usuario interno "hop" tem UID/GID 501. Como as
# pastas do projeto sao montadas do host (UID 1000), isso gera dois problemas:
#   - rodar o container como 1000 quebra o Tomcat (nao escreve em conf/ e
#     em webapps/ROOT/rwt-resources);
#   - rodar como 501 faz os arquivos criados pelo Hop ficarem inacessiveis
#     para edicao pelo seu usuario no host.
#
# Aqui o UID/GID do "hop" e realinhado para 1000, resolvendo os dois casos.
FROM apache/hop-web:latest

USER root

ARG HOST_UID=1000
ARG HOST_GID=1000

RUN set -eux; \
    # libera o GID/UID alvo caso ja estejam ocupados por outro usuario/grupo
    if getent group "${HOST_GID}" >/dev/null; then \
        groupmod -g 60501 "$(getent group "${HOST_GID}" | cut -d: -f1)"; \
    fi; \
    if getent passwd "${HOST_UID}" >/dev/null; then \
        usermod -u 60501 "$(getent passwd "${HOST_UID}" | cut -d: -f1)"; \
    fi; \
    groupmod -g "${HOST_GID}" hop; \
    usermod -u "${HOST_UID}" -g "${HOST_GID}" hop; \
    chown -R "${HOST_UID}:${HOST_GID}" /usr/local/tomcat /home/hop 2>/dev/null || true

USER hop
