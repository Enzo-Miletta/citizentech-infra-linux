#!/usr/bin/env bash
# =====================================================================
#  CitizenTech - Provisionamento completo e automatizado do servidor
#  Uso (dentro da VM Linux, como root):  sudo ./setup.sh
# =====================================================================
set -Eeuo pipefail
cd "$(dirname "$(readlink -f "$0")")"
source scripts/lib/common.sh
ct_begin "$@"
validate_config

chmod +x setup.sh scripts/*.sh

# Instala tudo antes de mexer na rede, enquanto a internet da VM está garantida.
section "Pacotes necessários"
apt_install "${CT_PACKAGES[@]}"

for step in 01-provisionar-infra 02-provisionar-app 03-instalar-monitoramento; do
  section ">>> Etapa ${step}"
  run "scripts/${step}.sh"
done

section ">>> Verificação final"
scripts/verificar.sh || log WARN "Algumas verificações falharam - veja a saída acima"

log OK "Ambiente pronto: http://www.${DOMAIN}/ (DNS ${SERVER_IP})"
