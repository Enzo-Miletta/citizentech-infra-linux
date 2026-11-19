#!/usr/bin/env bash
# =====================================================================
#  Monitor de infraestrutura CitizenTech
#  Coleta CPU, memória e disco, verifica DNS/HTTP e os serviços, gera
#  alertas e reinicia serviços parados. Roda como serviço systemd
#  (citizentech-monitor.service) com Restart=always.
# =====================================================================
set -uo pipefail     # sem -e: o laço de monitoramento nunca pode morrer por um erro pontual
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_prepare_logs

ALERT_LOG="$CT_LOG_DIR/alertas.log"
METRIC_LOG="$CT_LOG_DIR/metricas.log"
declare -A STATE=()

# ------------------------------------------------------------ métricas
cpu_usage() {   # % de CPU ocupada, amostra de 1 segundo em /proc/stat
  local u n s i w q sq st t1 i1 t2 i2
  read -r _ u n s i w q sq st _ < /proc/stat
  t1=$((u+n+s+i+w+q+sq+st)); i1=$((i+w))
  sleep 1
  read -r _ u n s i w q sq st _ < /proc/stat
  t2=$((u+n+s+i+w+q+sq+st)); i2=$((i+w))
  (( t2 > t1 )) || { echo 0; return; }
  echo $(( 100 * ((t2-t1) - (i2-i1)) / (t2-t1) ))
}
mem_usage()  { awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{printf "%d", (t-a)*100/t}' /proc/meminfo; }
disk_usage() { df -P "$DISK_MOUNT" | awk 'NR==2{sub(/%/,"",$5); print $5}'; }
top_proc()   { ps -eo comm,%"$1" --sort=-%"$1" --no-headers | awk 'NR==1{print $1" ("$2"%)"}'; }

# ------------------------------------------------------------ alertas
alert() {   # alert NIVEL mensagem
  local level="$1"; shift
  local prio="warning"
  case "$level" in CRITICO) prio="crit" ;; RECUPERADO|ACAO) prio="notice" ;; esac
  printf '%s [%s] %s\n' "$(date '+%F %T')" "$level" "$*" >> "$ALERT_LOG"
  log "$level" "$*"
  logger -p "user.$prio" -t citizentech-alerta -- "[$level] $*" 2>/dev/null || true
  if [[ "${MON_WALL:-false}" == "true" ]]; then
    printf 'CitizenTech [%s] %s\n' "$level" "$*" | wall -n 2>/dev/null || true
  fi
}

# Só alerta quando o estado muda (normal -> alerta -> normal), evitando spam.
transition() {   # transition chave ok(1/0) msg_alerta msg_normal [nivel]
  local key="$1" ok="$2" bad="$3" good="$4" level="${5:-ALERTA}"
  local prev="${STATE[$key]:-OK}"
  if (( ok )); then
    [[ "$prev" != "OK" ]] && alert RECUPERADO "$good"
    STATE[$key]="OK"
  else
    [[ "$prev" == "OK" ]] && alert "$level" "$bad"
    STATE[$key]="ALERTA"
  fi
  return 0
}

# ------------------------------------------------------------ verificações
check_service() {
  local svc="$1" st
  if systemctl is-active --quiet "$svc"; then
    transition "svc_$svc" 1 "" "Serviço $svc voltou a operar normalmente"
    return
  fi
  st="$(systemctl is-active "$svc" 2>/dev/null)"
  transition "svc_$svc" 0 "Serviço $svc está FORA DO AR (estado: ${st:-desconhecido})" "" CRITICO
  if [[ "$MON_AUTOHEAL" == "true" ]]; then
    if systemctl restart "$svc"; then
      alert ACAO "Serviço $svc reiniciado automaticamente pelo monitor"
      audit AUTOHEAL "service=$svc result=ok"
    else
      alert CRITICO "Falha ao reiniciar $svc - intervenção manual necessária"
      audit AUTOHEAL "service=$svc result=fail"
    fi
  fi
}

cycle() {
  local cpu mem disk http dns svc
  cpu="$(cpu_usage)"; mem="$(mem_usage)"; disk="$(disk_usage)"

  transition cpu  $(( cpu  < CPU_LIMIT ))  "CPU alta: ${cpu}% (limite ${CPU_LIMIT}%) - maior consumo: $(top_proc cpu)"  "CPU normalizada: ${cpu}%"
  transition mem  $(( mem  < MEM_LIMIT ))  "Memória alta: ${mem}% (limite ${MEM_LIMIT}%) - maior consumo: $(top_proc mem)" "Memória normalizada: ${mem}%"
  transition disk $(( disk < DISK_LIMIT )) "Disco ${DISK_MOUNT} cheio: ${disk}% (limite ${DISK_LIMIT}%)" "Disco ${DISK_MOUNT} normalizado: ${disk}%"

  for svc in $MON_SERVICES; do check_service "$svc"; done

  http="$(curl -s -o /dev/null -m 5 -w '%{http_code}' -H "Host: ${DOMAIN}" "http://127.0.0.1/" 2>/dev/null)"
  transition http $([[ "$http" == "200" ]] && echo 1 || echo 0) \
    "Site http://${DOMAIN}/ não responde (HTTP ${http:-000})" "Site http://${DOMAIN}/ respondendo (HTTP 200)"

  dns="$(dig +short +time=2 +tries=1 @127.0.0.1 "${DOMAIN}" A 2>/dev/null | head -n1)"
  transition dns $([[ "$dns" == "$SERVER_IP" ]] && echo 1 || echo 0) \
    "DNS não resolve ${DOMAIN} (resposta: '${dns}')" "DNS resolvendo ${DOMAIN} -> ${dns}"

  printf '%s cpu=%s%% mem=%s%% disco=%s%% http=%s dns=%s\n' \
    "$(date '+%F %T')" "$cpu" "$mem" "$disk" "${http:-000}" "${dns:-falha}" >> "$METRIC_LOG"
}

# ------------------------------------------------------------ laço principal
trap 'log INFO "Monitor finalizado (sinal recebido)"; audit STOP "pid=$$"; exit 0' TERM INT

log INFO "Monitor iniciado (pid $$) - intervalo ${MON_INTERVAL}s | limites CPU ${CPU_LIMIT}% MEM ${MEM_LIMIT}% DISCO ${DISK_LIMIT}% | serviços: ${MON_SERVICES}"
audit START "pid=$$ interval=${MON_INTERVAL}"

while true; do
  cycle
  sleep "$MON_INTERVAL" & wait $!
done
