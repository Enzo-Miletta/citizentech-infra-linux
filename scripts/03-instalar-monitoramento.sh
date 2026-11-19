#!/usr/bin/env bash
# =====================================================================
#  03 - Monitoramento e auditoria
#  Instala o monitor como serviço systemd tolerante a falhas, a rotação
#  de logs e as regras do auditd que vigiam os arquivos de configuração.
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_begin "$@"

INSTALL_DIR="/opt/citizentech"
UNIT="citizentech-monitor.service"

# ------------------------------------------------------------ dependências
section "1/4 Dependências"
apt_install auditd stress-ng curl bind9-dnsutils

# ------------------------------------------------------------ instalação
section "2/4 Instalação em $INSTALL_DIR"
install -d -m 0755 "$INSTALL_DIR/scripts/lib" "$INSTALL_DIR/config"
install -m 0750 "$CT_BASE_DIR"/scripts/*.sh "$INSTALL_DIR/scripts/"
install -m 0640 "$CT_BASE_DIR/scripts/lib/common.sh" "$INSTALL_DIR/scripts/lib/"
install -m 0640 "$CT_CONF" "$INSTALL_DIR/config/citizentech.conf"
if [[ -f "$CT_BASE_DIR/README.md" ]]; then install -m 0644 "$CT_BASE_DIR/README.md" "$INSTALL_DIR/"; fi
log OK "Scripts copiados para $INSTALL_DIR"

# ------------------------------------------------------------ serviço
section "3/4 Serviço $UNIT"
install -m 0644 "$CT_BASE_DIR/systemd/$UNIT" "/etc/systemd/system/$UNIT"
run systemctl daemon-reload
run systemctl enable "$UNIT"
run systemctl restart "$UNIT"
sleep 3
systemctl is-active --quiet "$UNIT" || die "$UNIT não iniciou (veja: journalctl -u $UNIT)"
log OK "$UNIT ativo (PID $(systemctl show -p MainPID --value "$UNIT")) com Restart=always"

cat > /etc/logrotate.d/citizentech <<'EOF'
/var/log/citizentech/*.log {
    weekly
    rotate 8
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
log OK "Rotação de logs configurada (/etc/logrotate.d/citizentech)"

# ------------------------------------------------------------ auditoria
section "4/4 Auditoria (auditd)"
RULES=/etc/audit/rules.d/citizentech.rules
{
  echo "# Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')"
  echo "# Consulte com: ausearch -k citizentech -i   |   aureport -f -i"
  for entry in \
      "/etc/bind:citizentech_dns" \
      "/etc/apache2:citizentech_web" \
      "$WEB_ROOT:citizentech_site" \
      "/etc/network:citizentech_rede" \
      "/etc/netplan:citizentech_rede" \
      "/etc/NetworkManager/system-connections:citizentech_rede" \
      "/etc/hosts:citizentech_rede" \
      "$INSTALL_DIR:citizentech_scripts" \
      "/etc/systemd/system/$UNIT:citizentech_monitor"; do
    path="${entry%%:*}"; key="${entry##*:}"
    if [[ -e "$path" ]]; then echo "-w $path -p wa -k $key"; fi
  done
} > "$RULES"
chmod 0640 "$RULES"
run systemctl enable --now auditd
if augenrules --load >/dev/null 2>&1; then
  log OK "Regras do auditd carregadas: $(grep -c '^-w' "$RULES") arquivos/pastas vigiados"
else
  log WARN "Não foi possível carregar as regras do auditd agora (serão aplicadas no próximo boot)"
fi

audit CONFIG "unit=$UNIT install_dir=$INSTALL_DIR audit_rules=$RULES"
