#!/usr/bin/env bash
# =====================================================================
#  02 - Provisionamento da aplicação web
#  Apache2 endurecido (sem exibir versão), VirtualHost do domínio e
#  publicação do site acessível que está na pasta site/ do repositório.
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_begin "$@"
validate_config

FQDN="${SERVER_HOSTNAME}.${DOMAIN}"
SITE_SRC="$CT_BASE_DIR/site"
VHOST="/etc/apache2/sites-available/${DOMAIN}.conf"
SEC_CONF="/etc/apache2/conf-available/zz-citizentech-seguranca.conf"

[[ -f "$SITE_SRC/index.html" ]] || die "Site não encontrado em $SITE_SRC"
[[ "$WEB_ROOT" == /var/www/?* ]] || die "WEB_ROOT deve ficar dentro de /var/www (atual: $WEB_ROOT)"

# ------------------------------------------------------------ dependências
section "1/4 Dependências"
apt_install apache2 curl

# ------------------------------------------------------------ segurança
section "2/4 Endurecimento do Apache"
# Nome "zz-" garante que seja carregado por último e sobrescreva o security.conf padrão.
cat > "$SEC_CONF" <<EOF
# Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')
ServerName ${FQDN}

# Não revelar versão do Apache nem do sistema operacional
ServerTokens Prod
ServerSignature Off

# Desabilita o método TRACE (Cross-Site Tracing) e ETag com inode
TraceEnable Off
FileETag None

<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "DENY"
    Header always set Referrer-Policy "no-referrer"
    Header always set Permissions-Policy "geolocation=(), camera=(), microphone=()"
    Header always set Content-Security-Policy "default-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"
    Header always unset X-Powered-By
</IfModule>

# Nega acesso a todo o sistema de arquivos, exceto o que for liberado
<Directory />
    Options None
    AllowOverride None
    Require all denied
</Directory>

# Bloqueia arquivos ocultos (.git, .env, .htpasswd...)
<FilesMatch "^\.">
    Require all denied
</FilesMatch>
EOF

run a2enmod -q headers
run a2dismod -q -f autoindex status    # sem listagem de diretórios nem /server-status
run a2enconf -q zz-citizentech-seguranca

# ------------------------------------------------------------ virtualhost
section "3/4 VirtualHost ${DOMAIN}"
backup_file "$VHOST"
cat > "$VHOST" <<EOF
# Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')
<VirtualHost *:80>
    ServerName ${DOMAIN}
    ServerAlias www.${DOMAIN} ${FQDN} ${SERVER_IP}
    ServerAdmin webmaster@${DOMAIN}
    DocumentRoot ${WEB_ROOT}

    <Directory ${WEB_ROOT}>
        Options None
        AllowOverride None
        Require all granted
    </Directory>

    ErrorDocument 403 /404.html
    ErrorDocument 404 /404.html

    ErrorLog \${APACHE_LOG_DIR}/${DOMAIN}-error.log
    CustomLog \${APACHE_LOG_DIR}/${DOMAIN}-access.log combined
</VirtualHost>
EOF

run a2dissite -q 000-default || true
run a2ensite -q "${DOMAIN}"

# ------------------------------------------------------------ publicação
section "4/4 Publicação do site"
install -d -m 0755 -o root -g root "$WEB_ROOT"
find "$WEB_ROOT" -mindepth 1 -delete
cp -r "$SITE_SRC/." "$WEB_ROOT/"

PUBLICADO="$(date '+%d/%m/%Y %H:%M')"
EQUIPE_HTML=""
IFS=';' read -r -a membros <<< "${EQUIPE:-$ALUNO_NOME|$ALUNO_RM}"
for m in "${membros[@]}"; do
  EQUIPE_HTML+="<li>${m%%|*} <span class=\"rm\">RM ${m##*|}</span></li>"
done
while IFS= read -r -d '' f; do
  sed -i \
    -e "s|{{EQUIPE}}|$(sed_escape "$EQUIPE_HTML")|g" \
    -e "s|{{ALUNO_NOME}}|$(sed_escape "$ALUNO_NOME")|g" \
    -e "s|{{ALUNO_RM}}|$(sed_escape "$ALUNO_RM")|g" \
    -e "s|{{DOMAIN}}|$(sed_escape "$DOMAIN")|g" \
    -e "s|{{SITE_NAME}}|$(sed_escape "$SITE_NAME")|g" \
    -e "s|{{PUBLICADO}}|$(sed_escape "$PUBLICADO")|g" \
    "$f"
done < <(find "$WEB_ROOT" -type f -name '*.html' -print0)

chown -R root:root "$WEB_ROOT"
find "$WEB_ROOT" -type d -exec chmod 0755 {} +
find "$WEB_ROOT" -type f -exec chmod 0644 {} +
log OK "Site publicado em $WEB_ROOT ($(find "$WEB_ROOT" -type f | wc -l) arquivos)"

run apache2ctl configtest
systemd_restart_policy "$WEB_SERVICE"
run systemctl enable "$WEB_SERVICE"
run systemctl restart "$WEB_SERVICE"
sleep 1

# ------------------------------------------------------------ validação
headers="$(curl -sI -m 5 -H "Host: ${DOMAIN}" "http://127.0.0.1/" || true)"
code="$(awk 'NR==1{print $2}' <<< "$headers")"
server="$(grep -i '^Server:' <<< "$headers" | tr -d '\r' || true)"
[[ "$code" == "200" ]] || die "Site não respondeu HTTP 200 (obtido: '${code}')"
log OK "HTTP 200 em http://${DOMAIN}/"
if grep -qiE '^Server:.*[0-9]' <<< "$server"; then
  die "Cabeçalho ainda revela versão: $server"
fi
log OK "Cabeçalho sem versão -> ${server}"

audit CONFIG "vhost=$VHOST webroot=$WEB_ROOT servertokens=Prod"
