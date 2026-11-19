#!/usr/bin/env bash
# =====================================================================
#  Verificação do ambiente CitizenTech (evidências para prints/vídeo)
#  Uso: sudo ./verificar.sh
# =====================================================================
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_prepare_logs
export LC_ALL=C

PASS=0; FAIL=0
FQDN="${SERVER_HOSTNAME}.${DOMAIN}"

show() {   # mostra o comando e sua saída
  printf '\n%s$ %s%s\n' "$C_BLD" "$1" "$C_RST"
  eval "$1" 2>&1 | sed 's/^/    /'
}
check() {  # check "descrição" 'teste'
  if eval "$2" >/dev/null 2>&1; then
    log OK "$1"; PASS=$((PASS + 1))
  else
    log FALHA "$1"; FAIL=$((FAIL + 1))
  fi
}

audit START "verificacao"
printf '%sCitizenTech - %s | Responsável: %s (RM %s) | %s%s\n' \
  "$C_BLD" "$SITE_NAME" "$ALUNO_NOME" "$ALUNO_RM" "$(date '+%d/%m/%Y %H:%M:%S')" "$C_RST"

section "Identificação e rede"
show "hostname; hostname -f"
show "ip -br -4 addr"
show "ip route"
check "Hostname é $SERVER_HOSTNAME" '[[ "$(hostname)" == "$SERVER_HOSTNAME" ]]'
check "IP fixo $SERVER_IP configurado" 'ip -o -4 addr | grep -q "inet $SERVER_IP/"'

section "Serviços"
show "systemctl is-active $DNS_SERVICE $WEB_SERVICE citizentech-monitor auditd"
for s in "$DNS_SERVICE" "$WEB_SERVICE" citizentech-monitor; do
  check "Serviço $s ativo e habilitado no boot" "systemctl is-active --quiet $s && systemctl is-enabled --quiet $s"
done

section "DNS (BIND9)"
show "dig @$SERVER_IP $DOMAIN A +short"
show "dig @$SERVER_IP www.$DOMAIN A +short"
show "dig @$SERVER_IP $DOMAIN SOA +short"
show "dig @$SERVER_IP $DOMAIN NS +short"
show "dig @$SERVER_IP $DOMAIN MX +short"
show "dig @$SERVER_IP mail.$DOMAIN A +short"
show "dig @$SERVER_IP -x $SERVER_IP +short"
show "dig @$SERVER_IP $DOMAIN AXFR"
show "dig @$SERVER_IP version.bind TXT CHAOS +short"
check "$DOMAIN resolve para $SERVER_IP"     '[[ "$(dig +short @$SERVER_IP $DOMAIN A)" == "$SERVER_IP" ]]'
check "www.$DOMAIN resolve para $SERVER_IP" '[[ "$(dig +short @$SERVER_IP www.$DOMAIN A)" == "$SERVER_IP" ]]'
check "SOA 28800/14400/86400/600"            'dig +short @$SERVER_IP $DOMAIN SOA | grep -qE " 28800 14400 86400 600$"'
check "NS ns1 e ns2"                          '[[ "$(dig +short @$SERVER_IP $DOMAIN NS | sort | tr "\n" " ")" == "ns1.$DOMAIN. ns2.$DOMAIN. " ]]'
check "MX mail.$DOMAIN -> $NS2_IP"            'dig +short @$SERVER_IP $DOMAIN MX | grep -q "mail.$DOMAIN." && [[ "$(dig +short @$SERVER_IP mail.$DOMAIN A)" == "$NS2_IP" ]]'
check "Reverso $SERVER_IP -> $FQDN"         '[[ "$(dig +short @$SERVER_IP -x $SERVER_IP)" == "$FQDN." ]]'
check "Transferência de zona (AXFR) bloqueada" 'dig @$SERVER_IP $DOMAIN AXFR | grep -q "Transfer failed"'
check "Versão do BIND oculta"                 '! dig +short @$SERVER_IP version.bind TXT CHAOS | grep -q "[0-9]\.[0-9]"'
check "Recursão desativada (não é DNS aberto)" 'dig @$SERVER_IP google.com A | grep -qE "status: REFUSED|WARNING: recursion requested but not available"'

section "Servidor web (Apache)"
show "curl -sI http://www.$DOMAIN/ --resolve www.$DOMAIN:80:$SERVER_IP"
check "Site responde HTTP 200"          '[[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: www.$DOMAIN" http://$SERVER_IP/)" == 200 ]]'
check "Cabeçalho Server sem versão"     'curl -sI -H "Host: $DOMAIN" http://$SERVER_IP/ | tr -d "\r" | grep -qx "Server: Apache"'
check "Página de erro não revela versão" '! curl -s -H "Host: $DOMAIN" http://$SERVER_IP/nao-existe | grep -qiE "apache/[0-9]"'
check "Listagem de diretórios bloqueada" '[[ "$(curl -s -o /dev/null -w "%{http_code}" -H "Host: $DOMAIN" http://$SERVER_IP/css/)" != 200 ]]'
check "Método TRACE desabilitado"        '[[ "$(curl -s -o /dev/null -w "%{http_code}" -X TRACE -H "Host: $DOMAIN" http://$SERVER_IP/)" == 405 ]]'
check "Site identifica a equipe"         'curl -s -H "Host: $DOMAIN" http://$SERVER_IP/ | grep -q "RM $ALUNO_RM"'

section "Firewall"
show "ufw status numbered"
check "UFW ativo" 'ufw status | grep -q "Status: active"'

section "Monitoramento e auditoria"
show "systemctl show citizentech-monitor -p Restart -p MainPID -p ActiveState"
show "tail -n 3 $CT_LOG_DIR/metricas.log"
show "tail -n 5 $CT_LOG_DIR/alertas.log"
show "tail -n 5 $CT_LOG_DIR/audit.log"
check "Monitor configurado com Restart=always" '[[ "$(systemctl show -p Restart --value citizentech-monitor)" == always ]]'
check "Métricas sendo coletadas (último minuto)" '[[ -n "$(find $CT_LOG_DIR/metricas.log -mmin -1 2>/dev/null)" ]]'
check "Regras do auditd carregadas" 'auditctl -l | grep -q citizentech'

section "Resultado"
log INFO "$PASS verificações OK, $FAIL com falha"
audit END "pass=$PASS fail=$FAIL"
(( FAIL == 0 ))
