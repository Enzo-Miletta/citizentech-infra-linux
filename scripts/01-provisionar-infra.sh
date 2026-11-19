#!/usr/bin/env bash
# =====================================================================
#  01 - Provisionamento da infraestrutura
#  IP fixo, hostname/FQDN, DNS autoritativo (BIND9) e firewall (UFW).
#  Seguro para rodar mais de uma vez (idempotente).
# =====================================================================
set -Eeuo pipefail
source "$(dirname "$(readlink -f "$0")")/lib/common.sh"
ct_begin "$@"
validate_config

FQDN="${SERVER_HOSTNAME}.${DOMAIN}"
IFS=. read -r O1 O2 O3 O4 <<< "$SERVER_IP"
REV_ZONE="${O3}.${O2}.${O1}.in-addr.arpa"     # zona reversa /24
ZONE_DIR="/etc/bind/zones"
SERIAL="$(date +%Y%m%d%H)"

# ------------------------------------------------------------ pacotes
section "1/5 Pacotes"
apt_install bind9 bind9-utils bind9-dnsutils ufw curl

# ------------------------------------------------------------ IP fixo
section "2/5 IP fixo"
IFACE="${NET_IFACE:-$(detect_iface)}"
[[ -n "$IFACE" && -d "/sys/class/net/$IFACE" ]] || die "Interface de rede inválida: '$IFACE' (ajuste NET_IFACE)"
log INFO "Interface: $IFACE | IP: $SERVER_IP/$NET_PREFIX | Gateway: ${NET_GATEWAY:-nenhum}"

net_netplan() {
  local f=/etc/netplan/60-citizentech.yaml
  {
    echo "# Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')"
    echo "network:"
    echo "  version: 2"
    echo "  ethernets:"
    echo "    $IFACE:"
    echo "      dhcp4: false"
    echo "      dhcp6: false"
    echo "      addresses: [$SERVER_IP/$NET_PREFIX]"
    if [[ -n "$NET_GATEWAY" ]]; then
      echo "      routes:"
      echo "        - to: default"
      echo "          via: $NET_GATEWAY"
    fi
  } > "$f"
  chmod 600 "$f"
  run netplan apply
}

net_networkmanager() {
  local con="citizentech-$IFACE"
  if nmcli -t -f NAME con show | grep -qx "$con"; then run nmcli con delete "$con"; fi
  local args=(con add type ethernet ifname "$IFACE" con-name "$con"
              ipv4.method manual ipv4.addresses "$SERVER_IP/$NET_PREFIX"
              connection.autoconnect yes connection.autoconnect-priority 100)
  if [[ -n "$NET_GATEWAY" ]]; then args+=(ipv4.gateway "$NET_GATEWAY"); else args+=(ipv4.never-default yes); fi
  run nmcli "${args[@]}"
  run nmcli con up "$con"
}

net_ifupdown() {
  local main=/etc/network/interfaces f=/etc/network/interfaces.d/60-citizentech
  backup_file "$main"
  # Desativa a configuração antiga (DHCP) desta interface no arquivo principal
  sed -i -E "/^[[:space:]]*(auto|allow-hotplug|iface)[[:space:]]+${IFACE}([[:space:]]|$)/ s/^/# [citizentech] /" "$main"
  grep -q '^source /etc/network/interfaces.d/\*' "$main" || echo 'source /etc/network/interfaces.d/*' >> "$main"
  {
    echo "# Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')"
    echo "auto $IFACE"
    echo "iface $IFACE inet static"
    echo "    address $SERVER_IP/$NET_PREFIX"
    if [[ -n "$NET_GATEWAY" ]]; then echo "    gateway $NET_GATEWAY"; fi
  } > "$f"
  ifdown "$IFACE" >/dev/null 2>&1 || true
  pkill -f "dhclient.*[[:space:]]$IFACE" >/dev/null 2>&1 || true
  run ip addr flush dev "$IFACE"
  run ifup --force "$IFACE"
}

net_already_done() {
  ip -o -4 addr show dev "$IFACE" | grep -q "inet $SERVER_IP/$NET_PREFIX " || return 1
  [[ -e /etc/netplan/60-citizentech.yaml || -e /etc/network/interfaces.d/60-citizentech ]] && return 0
  compgen -G "/etc/NetworkManager/system-connections/citizentech-*" >/dev/null
}

if net_already_done; then
  log OK "IP fixo já configurado em $IFACE"
elif command -v netplan >/dev/null && compgen -G "/etc/netplan/*.yaml" >/dev/null; then
  log INFO "Backend de rede: netplan"; net_netplan
elif systemctl is-active --quiet NetworkManager \
     && nmcli -t -f DEVICE,STATE device | grep -q "^$IFACE:" \
     && ! nmcli -t -f DEVICE,STATE device | grep -q "^$IFACE:unmanaged"; then
  log INFO "Backend de rede: NetworkManager"; net_networkmanager
else
  log INFO "Backend de rede: ifupdown (/etc/network/interfaces)"; net_ifupdown
fi

for _ in $(seq 1 10); do
  ip -o -4 addr show dev "$IFACE" | grep -q "inet $SERVER_IP/" && break
  sleep 1
done
ip -o -4 addr show dev "$IFACE" | grep -q "inet $SERVER_IP/" || die "O IP $SERVER_IP não subiu em $IFACE"
log OK "IP fixo ativo: $(ip -br -4 addr show dev "$IFACE")"

# ------------------------------------------------------------ hostname
section "3/5 Hostname"
run hostnamectl set-hostname "$SERVER_HOSTNAME"
backup_file /etc/hosts
sed -i -e '/# citizentech$/d' -e '/^127\.0\.1\.1[[:space:]]/d' /etc/hosts
printf '%s\t%s %s # citizentech\n' "$SERVER_IP" "$FQDN" "$SERVER_HOSTNAME" >> /etc/hosts
log OK "Hostname: $(hostname) | FQDN: $(hostname -f 2>/dev/null || echo "$FQDN")"

# ------------------------------------------------------------ DNS
section "4/5 DNS (BIND9)"
install -d -m 0755 -o root -g bind "$ZONE_DIR"
install -d -m 0750 -o bind -g bind /var/log/named
backup_file /etc/bind/named.conf.options
backup_file /etc/bind/named.conf.local

cat > /etc/bind/named.conf.options <<EOF
// Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')
// Servidor DNS AUTORITATIVO exposto na Internet: boas práticas aplicadas.
options {
    directory "/var/cache/bind";
    listen-on { any; };
    listen-on-v6 { any; };

    allow-query { any; };        // qualquer um pode consultar o domínio
    recursion no;                // não é resolvedor aberto (evita amplificação/DDoS)
    allow-transfer { none; };    // BLOQUEIA transferência de zona (AXFR/IXFR)
    allow-update { none; };      // sem atualização dinâmica
    notify no;

    version "nao informado";     // oculta a versão do BIND
    hostname none;
    server-id none;

    dnssec-validation auto;
    minimal-responses yes;
    rate-limit { responses-per-second 10; };   // mitiga abuso/amplificação
};

logging {
    channel seguranca {
        file "/var/log/named/security.log" versions 3 size 5m;
        severity info;
        print-time yes;
        print-category yes;
        print-severity yes;
    };
    category security { seguranca; };   // registra tentativas de AXFR negadas
    category xfer-out { seguranca; };
};
EOF

cat > /etc/bind/named.conf.local <<EOF
// Gerado por CitizenTech ($CT_SCRIPT) em $(date '+%F %T')
zone "${DOMAIN}" {
    type master;
    file "${ZONE_DIR}/db.${DOMAIN}";
    allow-transfer { none; };
    allow-update { none; };
};

zone "${REV_ZONE}" {
    type master;
    file "${ZONE_DIR}/db.${REV_ZONE}";
    allow-transfer { none; };
    allow-update { none; };
};
EOF

cat > "${ZONE_DIR}/db.${DOMAIN}" <<EOF
; Zona direta ${DOMAIN} - gerada por CitizenTech em $(date '+%F %T')
\$TTL 3600
@       IN  SOA ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
            ${SERIAL}  ; serial (AAAAMMDDHH)
            3600        ; refresh
            900         ; retry
            604800      ; expire
            300 )       ; TTL negativo
@       IN  NS      ns1.${DOMAIN}.
@       IN  A       ${SERVER_IP}
ns1     IN  A       ${SERVER_IP}
${SERVER_HOSTNAME}   IN  A       ${SERVER_IP}
www     IN  A       ${SERVER_IP}
@       IN  TXT     "v=spf1 -all"
EOF

cat > "${ZONE_DIR}/db.${REV_ZONE}" <<EOF
; Zona reversa ${REV_ZONE} - gerada por CitizenTech em $(date '+%F %T')
\$TTL 3600
@       IN  SOA ns1.${DOMAIN}. hostmaster.${DOMAIN}. (
            ${SERIAL} 3600 900 604800 300 )
@       IN  NS      ns1.${DOMAIN}.
${O4}   IN  PTR     ${FQDN}.
EOF

chown root:bind /etc/bind/named.conf.options /etc/bind/named.conf.local "$ZONE_DIR"/db.*
chmod 0644 "$ZONE_DIR"/db.*

run named-checkconf
run named-checkzone "$DOMAIN" "${ZONE_DIR}/db.${DOMAIN}"
run named-checkzone "$REV_ZONE" "${ZONE_DIR}/db.${REV_ZONE}"

systemd_restart_policy "$DNS_SERVICE"
run systemctl enable "$DNS_SERVICE"
run systemctl restart "$DNS_SERVICE"
sleep 2

got="$(dig +short +time=2 +tries=2 @127.0.0.1 "www.${DOMAIN}" A || true)"
[[ "$got" == "$SERVER_IP" ]] || die "DNS não respondeu corretamente para www.${DOMAIN} (obtido: '${got}')"
log OK "DNS: www.${DOMAIN} -> ${got}"
axfr="$(dig @127.0.0.1 "$DOMAIN" AXFR 2>&1 || true)"
if grep -q "Transfer failed" <<< "$axfr"; then
  log OK "Transferência de zona (AXFR) bloqueada"
else
  die "Transferência de zona NÃO está bloqueada"
fi

# ------------------------------------------------------------ firewall
section "5/5 Firewall (UFW)"
if [[ "$UFW_ENABLE" == "true" ]]; then
  run ufw default deny incoming
  run ufw default allow outgoing
  run ufw allow 22/tcp comment 'SSH'
  run ufw allow 53 comment 'DNS'
  run ufw allow 80/tcp comment 'HTTP'
  run ufw --force enable
  log OK "Firewall ativo: somente 22/tcp, 53 e 80/tcp liberadas"
else
  log WARN "UFW_ENABLE=false - firewall não configurado"
fi

audit CONFIG "iface=$IFACE ip=$SERVER_IP/$NET_PREFIX fqdn=$FQDN zone=$DOMAIN rev=$REV_ZONE serial=$SERIAL"
