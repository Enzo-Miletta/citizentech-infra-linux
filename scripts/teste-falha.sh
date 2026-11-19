#!/usr/bin/env bash
# =====================================================================
#  Teste de falha CitizenTech
#  Provoca falhas reais e mostra o ambiente se recuperando sozinho.
#  Uso: sudo ./teste-falha.sh [todos|web|dns|monitor|cpu|memoria|disco]
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_begin "$@"

ALERT_LOG="$CT_LOG_DIR/alertas.log"
MON_UNIT="citizentech-monitor.service"
DNS_UNIT="$(unit_id "$DNS_SERVICE")"
WEB_UNIT="$(unit_id "$WEB_SERVICE")"
WAIT_MON=$(( MON_INTERVAL * 3 + 15 ))
declare -a RESULTS=()
touch "$ALERT_LOG"
CT_CLEANUP_CMDS+=('jobs -p | xargs -r kill 2>/dev/null')

systemctl is-active --quiet "$MON_UNIT" || die "$MON_UNIT não está ativo. Rode antes: sudo ./setup.sh"

# ------------------------------------------------------------ utilitários
# wait_for TIMEOUT DESCRIÇÃO comando...  -> espera o comando dar certo
wait_for() {
  local timeout="$1" desc="$2" t0; shift 2
  t0="$(date +%s)"
  until "$@" >/dev/null 2>&1; do
    if (( $(date +%s) - t0 >= timeout )); then
      log FALHA "$desc: não aconteceu em ${timeout}s"
      return 1
    fi
    sleep 1
  done
  log OK "$desc (em $(( $(date +%s) - t0 ))s)"
}

result() {   # result CENÁRIO OK|FALHA
  RESULTS+=("$(printf '%-22s %s' "$1" "$2")")
  audit TEST "scenario=$1 result=$2"
}

alert_lines() { wc -l < "$ALERT_LOG"; }
alert_since() { tail -n +"$(( $1 + 1 ))" "$ALERT_LOG" | grep -q -- "$2"; }
show_alerts_since() {
  log INFO "Alertas registrados em $ALERT_LOG:"
  tail -n +"$(( $1 + 1 ))" "$ALERT_LOG" | sed 's/^/      /'
}
main_pid() { systemctl show -p MainPID --value "$1"; }
restarted() { systemctl is-active --quiet "$1" && [[ "$(main_pid "$1")" != "$2" && "$(main_pid "$1")" != "0" ]]; }
http_code() { curl -s -o /dev/null -m 3 -w '%{http_code}' -H "Host: ${DOMAIN}" "http://127.0.0.1/" || true; }

# ------------------------------------------------------------ cenários
teste_web() {
  section "Cenário: servidor web parado (systemctl stop $WEB_UNIT)"
  local n0; n0="$(alert_lines)"
  run systemctl stop "$WEB_UNIT"
  log WARN "Site fora do ar: HTTP $(http_code). Aguardando o monitor detectar e recuperar..."
  if wait_for "$WAIT_MON" "Monitor detectou e reiniciou o $WEB_UNIT" systemctl is-active --quiet "$WEB_UNIT"; then
    log OK "Site de volta: HTTP $(http_code)"
    result "web parado" OK
  else
    result "web parado" FALHA
  fi
  show_alerts_since "$n0"
}

teste_dns() {
  section "Cenário: processo do DNS morto (kill -9)"
  local pid; pid="$(main_pid "$DNS_UNIT")"
  run kill -9 "$pid"
  log WARN "Processo $pid do $DNS_UNIT finalizado à força"
  if wait_for 30 "systemd reiniciou o $DNS_UNIT (Restart=on-failure) - novo PID" restarted "$DNS_UNIT" "$pid"; then
    log OK "Novo PID: $(main_pid "$DNS_UNIT") | www.${DOMAIN} -> $(dig +short @127.0.0.1 "www.${DOMAIN}" A || true)"
    result "dns kill -9" OK
  else
    result "dns kill -9" FALHA
  fi
}

teste_monitor() {
  section "Cenário: o próprio monitor morre (kill -9)"
  local pid; pid="$(main_pid "$MON_UNIT")"
  run kill -9 "$pid"
  log WARN "Monitor (PID $pid) finalizado à força"
  if wait_for 30 "systemd reiniciou o monitor (Restart=always) - novo PID" restarted "$MON_UNIT" "$pid"; then
    log OK "Novo PID do monitor: $(main_pid "$MON_UNIT")"
    result "monitor kill -9" OK
  else
    result "monitor kill -9" FALHA
  fi
}

teste_cpu() {
  section "Cenário: CPU sobrecarregada"
  local n0 dur=$(( MON_INTERVAL * 2 + 10 )) i
  n0="$(alert_lines)"
  if command -v stress-ng >/dev/null; then
    log INFO "\$ stress-ng --cpu 0 --timeout ${dur}s"
    stress-ng --cpu 0 --timeout "${dur}s" --quiet &
  else
    log INFO "Gerando carga com 'yes' em $(nproc) núcleo(s) por ${dur}s"
    for i in $(seq "$(nproc)"); do timeout "$dur" yes >/dev/null & done
  fi
  if wait_for "$dur" "Alerta de CPU alta gerado" alert_since "$n0" "CPU alta"; then result "cpu alta" OK; else result "cpu alta" FALHA; fi
  wait || true
  wait_for "$WAIT_MON" "CPU normalizada" alert_since "$n0" "CPU normalizada" || true
  show_alerts_since "$n0"
}

teste_memoria() {
  section "Cenário: memória quase esgotada"
  command -v stress-ng >/dev/null || { log WARN "stress-ng não instalado - cenário ignorado"; result "memoria alta" IGNORADO; return; }
  local total avail need n0 dur=$(( MON_INTERVAL * 2 + 10 ))
  read -r total avail < <(awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t, a}' /proc/meminfo)
  need=$(( total * (MEM_LIMIT + 8) / 100 - (total - avail) ))
  (( need > 0 )) || need=$(( total / 20 ))
  if (( need >= avail - 51200 )); then
    log WARN "Memória livre insuficiente para o teste com segurança - ignorado"; result "memoria alta" IGNORADO; return
  fi
  n0="$(alert_lines)"
  log INFO "\$ stress-ng --vm 1 --vm-bytes ${need}k --vm-keep --timeout ${dur}s"
  stress-ng --vm 1 --vm-bytes "${need}k" --vm-keep --timeout "${dur}s" --quiet &
  if wait_for "$dur" "Alerta de memória alta gerado" alert_since "$n0" "Memória alta"; then result "memoria alta" OK; else result "memoria alta" FALHA; fi
  wait || true
  wait_for "$WAIT_MON" "Memória normalizada" alert_since "$n0" "Memória normalizada" || true
  show_alerts_since "$n0"
}

teste_disco() {
  section "Cenário: disco cheio"
  local size used avail need n0 file="${DISK_MOUNT%/}/citizentech-teste-disco.img"
  read -r size used avail < <(df -P -B1 "$DISK_MOUNT" | awk 'NR==2{print $2, $3, $4}')
  need=$(( size * (DISK_LIMIT + 2) / 100 - used ))
  (( need > 0 )) || need=$(( 50 * 1024 * 1024 ))
  if (( need >= avail - 300 * 1024 * 1024 )); then
    log WARN "Espaço livre insuficiente para o teste com segurança - ignorado"; result "disco cheio" IGNORADO; return
  fi
  n0="$(alert_lines)"
  CT_CLEANUP_CMDS+=("rm -f '$file'")
  run fallocate -l "$need" "$file"
  log WARN "Arquivo de $(( need / 1024 / 1024 )) MB criado: disco em $(df -P "$DISK_MOUNT" | awk 'NR==2{print $5}')"
  if wait_for "$WAIT_MON" "Alerta de disco cheio gerado" alert_since "$n0" "Disco ${DISK_MOUNT} cheio"; then result "disco cheio" OK; else result "disco cheio" FALHA; fi
  run rm -f "$file"
  wait_for "$WAIT_MON" "Disco normalizado" alert_since "$n0" "Disco ${DISK_MOUNT} normalizado" || true
  show_alerts_since "$n0"
}

# ------------------------------------------------------------ execução
case "${1:-todos}" in
  web)     teste_web ;;
  dns)     teste_dns ;;
  monitor) teste_monitor ;;
  cpu)     teste_cpu ;;
  memoria) teste_memoria ;;
  disco)   teste_disco ;;
  todos)   teste_web; teste_dns; teste_monitor; teste_cpu; teste_memoria; teste_disco ;;
  *) echo "Uso: $0 [todos|web|dns|monitor|cpu|memoria|disco]"; exit 2 ;;
esac

section "Resumo do teste de falha"
printf '  %s\n' "${RESULTS[@]}"
if printf '%s\n' "${RESULTS[@]}" | grep -q 'FALHA$'; then exit 1; fi
