#!/usr/bin/env bash
# Biblioteca compartilhada pelos scripts CitizenTech:
# carrega a configuração e oferece funções de log, auditoria e utilitários.

CT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CT_BASE_DIR="$(cd "$CT_LIB_DIR/../.." && pwd)"
CT_CONF="${CITIZENTECH_CONF:-$CT_BASE_DIR/config/citizentech.conf}"
CT_LOG_DIR="/var/log/citizentech"
CT_SCRIPT="$(basename "${0%.sh}")"
CT_START="$(date +%s)"
CT_CLEANUP_CMDS=()
CT_PACKAGES=(bind9 bind9-utils bind9-dnsutils apache2 openssh-server curl ufw auditd stress-ng)

if [[ ! -r "$CT_CONF" ]]; then
  echo "ERRO: arquivo de configuração não encontrado: $CT_CONF" >&2
  exit 1
fi
# shellcheck source=../../config/citizentech.conf
source "$CT_CONF"

if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_BLU=$'\e[36m'; C_BLD=$'\e[1m'; C_RST=$'\e[0m'
else
  C_RED=""; C_GRN=""; C_YLW=""; C_BLU=""; C_BLD=""; C_RST=""
fi

# ---------------------------------------------------------------- logs
ct_prepare_logs() {
  if [[ $EUID -eq 0 ]]; then
    install -d -m 0750 -o root -g adm "$CT_LOG_DIR"
  fi
}

# log NIVEL mensagem  -> tela + /var/log/citizentech/<script>.log + syslog
log() {
  local level="$1"; shift
  local line color="$C_BLU"
  line="$(date '+%F %T') [$level] [$CT_SCRIPT] $*"
  case "$level" in
    OK|RECUPERADO) color="$C_GRN" ;;
    WARN|ALERTA|ACAO) color="$C_YLW" ;;
    ERRO|CRITICO|FALHA) color="$C_RED" ;;
  esac
  printf '%s%s%s\n' "$color" "$line" "$C_RST"
  if [[ -w "$CT_LOG_DIR" ]]; then
    printf '%s\n' "$line" >> "$CT_LOG_DIR/$CT_SCRIPT.log"
  fi
  # Sob o systemd a saída padrão já vai para o journal; evita duplicar.
  if [[ -z "${INVOCATION_ID:-}" ]]; then
    logger -t "citizentech-$CT_SCRIPT" -- "[$level] $*" 2>/dev/null || true
  fi
}

# audit EVENTO detalhes  -> trilha de auditoria (quem, quando, o quê, resultado)
audit() {
  local event="$1"; shift
  [[ -w "$CT_LOG_DIR" ]] || return 0
  local term="none"
  tty -s 2>/dev/null && term="$(tty)"
  printf '%s user=%s uid=%s tty=%s pid=%s host=%s script=%s event=%s %s\n' \
    "$(date '+%F %T %z')" "${SUDO_USER:-$(id -un)}" "$EUID" "$term" "$$" \
    "$(hostname)" "$CT_SCRIPT" "$event" "$*" >> "$CT_LOG_DIR/audit.log"
}

die() { log ERRO "$*"; exit 1; }

section() { printf '\n%s==== %s ====%s\n' "$C_BLD" "$*" "$C_RST"; }

# run comando...  -> registra o comando executado antes de rodá-lo
run() {
  log INFO "\$ $*"
  "$@" || { local rc=$?; log ERRO "Comando falhou (rc=$rc): $*"; return "$rc"; }
}

require_root() {
  [[ $EUID -eq 0 ]] || { echo "Execute como root: sudo $0" >&2; exit 1; }
}

# ---------------------------------------------- ciclo de vida do script
ct_begin() {
  require_root
  ct_prepare_logs
  audit START "args='$*' conf=$CT_CONF"
  log INFO "Início da execução (usuário: ${SUDO_USER:-$(id -un)})"
  trap 'ct_on_error $LINENO "$BASH_COMMAND"' ERR
  trap 'ct_on_exit $?' EXIT
}

ct_on_error() {
  log ERRO "Falha na linha $1: $2"
  audit ERROR "line=$1 cmd='$2'"
}

ct_on_exit() {
  local rc="$1" dur cmd
  for cmd in "${CT_CLEANUP_CMDS[@]}"; do eval "$cmd" || true; done
  dur=$(( $(date +%s) - CT_START ))
  if (( rc == 0 )); then
    log OK "Concluído com sucesso em ${dur}s"
  else
    log ERRO "Terminou com erro (código $rc) após ${dur}s"
  fi
  audit END "rc=$rc dur=${dur}s"
}

validate_config() {
  local ipre='^([0-9]{1,3}\.){3}[0-9]{1,3}$'
  [[ "$SERVER_IP" =~ $ipre ]] || die "SERVER_IP inválido: $SERVER_IP"
  [[ -z "$NET_GATEWAY" || "$NET_GATEWAY" =~ $ipre ]] || die "NET_GATEWAY inválido: $NET_GATEWAY"
  [[ "$NS2_IP" =~ $ipre ]] || die "NS2_IP inválido: $NS2_IP"
  [[ "$NET_PREFIX" =~ ^[0-9]+$ ]] && (( NET_PREFIX >= 8 && NET_PREFIX <= 30 )) || die "NET_PREFIX inválido: $NET_PREFIX"
  [[ "$DOMAIN" =~ ^[a-z0-9.-]+\.[a-z]{2,}$ ]] || die "DOMAIN inválido: $DOMAIN"
  [[ -n "$ALUNO_NOME" && -n "$ALUNO_RM" ]] || die "Preencha ALUNO_NOME e ALUNO_RM em $CT_CONF"
}

# --------------------------------------------------------- utilitários
CT_APT_UPDATED=0
apt_install() {
  local p missing=()
  for p in "$@"; do
    dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed' || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    log OK "Pacotes já instalados: $*"
    return 0
  fi
  export DEBIAN_FRONTEND=noninteractive
  if (( CT_APT_UPDATED == 0 )); then
    run apt-get update -qq
    CT_APT_UPDATED=1
  fi
  run apt-get install -y -qq "${missing[@]}"
}

# Guarda uma cópia do arquivo original (somente na primeira alteração).
backup_file() {
  local f="$1"
  if [[ -e "$f" && ! -e "$f.orig-citizentech" ]]; then
    cp -a "$f" "$f.orig-citizentech"
    log INFO "Backup criado: $f.orig-citizentech"
  fi
}

# Interface do servidor: a que já tem o SERVER_IP, senão a primeira
# interface física sem rota padrão (host-only), senão a da rota padrão.
detect_iface() {
  local def i
  i="$(ip -o -4 addr show 2>/dev/null | awk -v ip="$SERVER_IP" '$4 ~ "^"ip"/" {print $2; exit}')"
  if [[ -n "$i" ]]; then echo "$i"; return; fi
  def="$(ip -o -4 route show default 2>/dev/null | awk '{print $5; exit}')"
  for i in $(ls /sys/class/net); do
    [[ "$i" == "lo" || "$i" == "$def" || ! -e "/sys/class/net/$i/device" ]] && continue
    echo "$i"; return
  done
  echo "$def"
}

unit_id() { systemctl show -p Id --value "$1" 2>/dev/null; }

# Faz o systemd reiniciar o serviço sozinho caso o processo morra.
systemd_restart_policy() {
  local unit dir
  unit="$(unit_id "$1")"
  dir="/etc/systemd/system/${unit}.d"
  install -d -m 0755 "$dir"
  cat > "$dir/10-citizentech-restart.conf" <<EOF
# Gerado por CitizenTech: reinício automático em caso de falha
[Service]
Restart=on-failure
RestartSec=3
EOF
  systemctl daemon-reload
  log OK "Política Restart=on-failure aplicada em $unit"
}

# Escapa texto para uso no lado direito de um sed s|...|...|
sed_escape() { printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'; }
