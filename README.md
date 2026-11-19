# CitizenTech – Infraestrutura Linux (DNS + HTTP)

**FIAP · Global Solution 2026 · Operating Systems · Engenharia de Software**

Servidor Linux provisionado **100% via Shell Script** para publicar o site da CitizenTech **Conecta Cidadão** como se estivesse na Internet: DNS autoritativo (BIND9) + servidor web (Apache), IP fixo, firewall, monitoramento com alertas como serviço systemd, logs de auditoria e teste de falha.

| Integrante | RM |
|---|---|
| Renato Luiz Cordão | 556403 |
| Vitor Victorino Couto | 554965 |
| Victoria Moura | 555474 |
| Fabricio Bettarello | 554638 |
| Enzo Miletta | 98677 |

---

## 1. Arquitetura

```
                 Rede host-only 192.168.56.0/24 (simula a Internet)
   ┌──────────────────────────┐                ┌──────────────────────────────────┐
   │ VM Windows (cliente)     │   DNS  :53     │ VM Debian – srv01                │
   │ DNS = 192.168.56.10      │ ─────────────► │ 192.168.56.10 (IP fixo)          │
   │ navegador / nslookup     │   HTTP :80     │ BIND9   conectacidadao-fiap.com    │
   └──────────────────────────┘ ─────────────► │ Apache  www.conectacidadao-fiap.com│
                                               │ UFW · auditd · citizentech-monitor│
                                               └───────────┬──────────────────────┘
                                                           │ adaptador NAT (só p/ apt)
                                                           ▼  Internet real
```

| Item | Valor (editável em `config/citizentech.conf`) |
|---|---|
| Site publicado em | `/var/www/html` (diretório padrão do Apache) |
| Domínio | `conectacidadao-fiap.com` / `www.conectacidadao-fiap.com` |
| Servidor | `srv01.conectacidadao-fiap.com` / `ns1.conectacidadao-fiap.com` |
| IP fixo | `192.168.56.10/24` |
| Serviços | `named` (BIND9), `apache2`, `citizentech-monitor`, `auditd`, `ufw` |

## 2. Como os critérios da avaliação são atendidos

| Critério (pts) | Onde está |
|---|---|
| Provisionamento de infra – rede, DNS, IP (2) | [`scripts/01-provisionar-infra.sh`](scripts/01-provisionar-infra.sh): IP fixo (netplan, NetworkManager ou ifupdown, detecta sozinho), hostname/FQDN, BIND9 com zona direta e reversa, firewall UFW |
| Provisionamento da aplicação – dependências, configs, orquestração (2) | [`scripts/02-provisionar-app.sh`](scripts/02-provisionar-app.sh) + [`setup.sh`](setup.sh) (orquestra tudo em ordem) |
| Monitoramento com alertas de CPU, disco e memória (2) | [`scripts/monitor.sh`](scripts/monitor.sh): também checa DNS, HTTP e serviços, e reinicia serviço parado |
| Monitoramento como serviço tolerante a falhas (1) | [`systemd/citizentech-monitor.service`](systemd/citizentech-monitor.service): `Restart=always`, `StartLimitIntervalSec=0`; `named` e `apache2` recebem `Restart=on-failure` |
| Logs de auditoria e execução (1) | `/var/log/citizentech/audit.log` (quem, quando, o quê e resultado de cada script), um log por script, `alertas.log`, `metricas.log`, regras do **auditd** e `logrotate` |
| Funcionamento completo (2) | [`scripts/verificar.sh`](scripts/verificar.sh) (checklist automático) + [`scripts/teste-falha.sh`](scripts/teste-falha.sh) |

### Segurança (ambiente "publicado na Internet")
- **DNS:** `allow-transfer { none; }` (transferência de zona bloqueada), `recursion no` (não é resolvedor aberto), `version "nao informado"` (versão oculta), rate limiting e log de segurança em `/var/log/named/security.log`.
- **Web:** `ServerTokens Prod` + `ServerSignature Off` (cabeçalho só mostra `Server: Apache`, sem versão), `TraceEnable Off`, sem listagem de diretórios, `mod_status` desativado, cabeçalhos de segurança (CSP, X-Frame-Options, nosniff…), arquivos ocultos bloqueados.
- **Firewall:** apenas 22/tcp, 53 e 80/tcp liberadas.

### Site acessível (princípios CitizenTech)
Letra base de 18px com botões **A+ / A−**, modo **alto contraste**, cores com contraste ≥ 8:1, linguagem simples, link "pular para o conteúdo", foco visível, alvos de toque de 48px e layout para celular. Não usa fontes nem bibliotecas externas: abre mesmo com internet fraca. Para publicar outro site, troque o conteúdo da pasta [`site/`](site/).

## 3. Preparar o laboratório (VirtualBox)

1. **Rede host-only:** *Arquivo → Ferramentas → Gerenciador de Rede* → criar rede host-only `192.168.56.1/24` (DHCP pode ficar ligado, o range dele começa em .100).
2. **VM Linux:** Debian 12 (ou Ubuntu Server). Nome da VM: **`Debian - Enzo Miletta - RM: 98677`**.
   - Adaptador 1: **NAT** (internet para instalar pacotes) · Adaptador 2: **Host-only**.
   - Se o instalador do Debian escolher o host-only (`enp0s8`) como interface principal, o NAT fica desligado e o `apt` falha. Corrija com `printf 'auto enp0s3\niface enp0s3 inet dhcp\n' > /etc/network/interfaces.d/10-nat && ifup enp0s3` e rode o `setup.sh` de novo.
3. **Clone:** desligue a VM → botão direito → *Clonar* → nome **`Debian (clone) - Enzo Miletta - RM: 98677`** → *Gerar novos endereços MAC para todas as placas* → Clone completo. (O clone serve de cópia de segurança/servidor reserva; não ligue os dois com o mesmo IP fixo ao mesmo tempo.)
4. **VM Windows (cliente):** nome **`Windows - Enzo Miletta - RM: 98677`**, com **apenas o adaptador Host-only** (assim ela usa somente o nosso DNS).

> Cada integrante que for enviar prints deve usar o próprio nome e RM no nome das VMs e em `ALUNO_NOME`/`ALUNO_RM`.

## 4. Provisionar o servidor (dentro da VM Linux)

```bash
su -                                   # Debian vem sem sudo por padrão
apt update && apt install -y git
git clone <URL-DO-REPOSITORIO> /root/citizentech
cd /root/citizentech
nano config/citizentech.conf           # confira nome, RM e IP
bash setup.sh
```

O `setup.sh` instala todos os pacotes, roda as etapas 01 → 02 → 03 e termina com o `verificar.sh`. Pode ser executado de novo sem problemas (idempotente). Cada etapa também roda sozinha: `bash scripts/01-provisionar-infra.sh`.

Se a VM tiver só um adaptador (Bridge/Rede NAT), coloque o IP da sua rede em `SERVER_IP` e o roteador em `NET_GATEWAY`.

## 5. Testar pelo cliente Windows

PowerShell **como administrador**:

```powershell
Get-NetAdapter                                     # descubra o nome do adaptador (ex.: Ethernet)
Set-DnsClientServerAddress -InterfaceAlias "Ethernet" -ServerAddresses 192.168.56.10
ipconfig /flushdns
nslookup www.conectacidadao-fiap.com
nslookup conectacidadao-fiap.com
curl.exe -I http://www.conectacidadao-fiap.com       # Server: Apache (sem versão)
```

Transferência de zona (deve ser **recusada**):

```
nslookup
> server 192.168.56.10
> ls -d conectacidadao-fiap.com
*** Can't list domain conectacidadao-fiap.com: Query refused
> exit
```

Abra **http://www.conectacidadao-fiap.com** no Edge. Para mostrar o cabeçalho sem versão: F12 → *Rede* → recarregue → clique no documento → *Cabeçalhos de resposta* → `Server: Apache`.

## 6. Itens do Forms (prints com a tela inteira: VM, barra de tarefas e data/hora visíveis)

| Item | O que pede | Como fazer / o que printar |
|---|---|---|
| 1–3 | VM Linux + clone + VM Windows com nome e RM | Seção 3 (sem print) |
| — | Instalar DNS/HTTP e IP fixo na rede host-only (RFC 1918) | `bash setup.sh` faz os dois → marcar os 2 checks |
| **4** (4 pts) | Zona direta: SOA (serial AAAAMMDDNN, 28800/14400/86400/600), NS ns1 e ns2, MX mail, A ns1/ns2/www/mail | Linux: `cat /etc/bind/zones/db.conectacidadao-fiap.com` |
| **5** (2 pts) | `nslookup` no Windows resolvendo um registro A | Windows: `nslookup www.conectacidadao-fiap.com` (seção 5) |
| 6 | Página CitizenTech no diretório HTML padrão do Apache | `setup.sh` publica `site/` em `/var/www/html` (ou envie a pasta `site/` pelo WinSCP: o SSH já fica instalado) |
| **7** (2 pts) | Site abrindo no navegador do Windows | Edge com `http://www.conectacidadao-fiap.com` na barra de endereço |
| **8** (2 prints) | Bloquear transferência de zona e ocultar versão do Apache | **8a:** `nano /etc/bind/named.conf.options` → marcar `allow-transfer { none; };` · **8b:** `nano /etc/apache2/conf-available/security.conf` → marcar `ServerTokens Prod` |

Registros da zona: `ns1` e `www` = `192.168.56.10` (este servidor); `ns2` e `mail` = `192.168.56.11` (DNS secundário fictício, configurável em `NS2_IP`).

No item 8, depois de tirar o print com a Ferramenta de Captura (Win+Shift+S), use a caneta vermelha para sublinhar a linha. Para provar que funciona, você pode mostrar também: `dig @192.168.56.10 conectacidadao-fiap.com AXFR` → *Transfer failed* e `curl.exe -I http://www.conectacidadao-fiap.com` → `Server: Apache`.

No item 7, digite o endereço com `http://` na frente para o navegador não tentar HTTPS.

**Enviar o site pelo WinSCP (opcional, como na aula):** protocolo SFTP, host `192.168.56.10`, porta 22, seu usuário do Debian. Copie o conteúdo de `site/` para `/var/www/html` (o usuário precisa ter permissão de escrita, ou envie para a pasta pessoal e copie com `sudo cp -r ~/site/. /var/www/html/`). Pelo `setup.sh` isso já é feito automaticamente.

Os prints deste laboratório estão em [`evidencias/prints/`](evidencias/prints/) (índice em [`evidencias/README.md`](evidencias/README.md)).

## 7. Teste de falha

```bash
bash /opt/citizentech/scripts/teste-falha.sh          # todos os cenários
bash /opt/citizentech/scripts/teste-falha.sh web      # só um: web|dns|monitor|cpu|memoria|disco
```

| Cenário | O que acontece | Recuperação esperada |
|---|---|---|
| web | `systemctl stop apache2` | monitor detecta, alerta e reinicia |
| dns | `kill -9` no `named` | systemd reinicia (`Restart=on-failure`) |
| monitor | `kill -9` no próprio monitor | systemd reinicia (`Restart=always`) |
| cpu | `stress-ng` em todos os núcleos | alerta "CPU alta" e depois "normalizada" |
| memoria | `stress-ng --vm` até passar o limite | alerta "Memória alta" e depois "normalizada" |
| disco | arquivo temporário até passar o limite | alerta "Disco cheio" e depois "normalizado" (arquivo é apagado) |

Acompanhe ao vivo em outro terminal: `tail -f /var/log/citizentech/alertas.log` (os alertas também aparecem em todos os terminais via `wall`).

## 8. Logs

| Arquivo | Conteúdo |
|---|---|
| `/var/log/citizentech/audit.log` | trilha de auditoria: usuário, TTY, PID, script, início/fim, código de saída, ações automáticas |
| `/var/log/citizentech/<script>.log` | saída de cada execução (comandos executados com timestamp) |
| `/var/log/citizentech/alertas.log` | alertas e recuperações |
| `/var/log/citizentech/metricas.log` | CPU, memória, disco, HTTP e DNS a cada 10 s |
| `/var/log/named/security.log` | tentativas de transferência de zona negadas |
| `ausearch -k citizentech_dns -i` | alterações nos arquivos de configuração (auditd) |
| `journalctl -u citizentech-monitor` | log do serviço de monitoramento |

## 9. Roteiro do vídeo (até 7 min)

1. **0:00–0:45** Equipe, problema CitizenTech e arquitetura (seção 1).
2. **0:45–1:30** Estrutura do repositório e `config/citizentech.conf`.
3. **1:30–3:30** `bash setup.sh` rodando: pacotes, IP fixo, DNS, Apache, monitor.
4. **3:30–4:30** Cliente Windows: `nslookup`, `ls -d` recusado, site no navegador e cabeçalho sem versão.
5. **4:30–6:15** `teste-falha.sh` com `tail -f alertas.log` ao lado.
6. **6:15–7:00** `audit.log`, `verificar.sh` com tudo OK e conclusão.

## 10. Estrutura

```
setup.sh                          orquestrador (rodar este)
config/citizentech.conf           todas as variáveis do ambiente
scripts/01-provisionar-infra.sh   IP fixo, hostname, BIND9, UFW
scripts/02-provisionar-app.sh     Apache endurecido + publicação do site
scripts/03-instalar-monitoramento.sh  serviço systemd, logrotate, auditd
scripts/monitor.sh                monitor (roda como serviço)
scripts/teste-falha.sh            simulação de falhas
scripts/verificar.sh              checklist de evidências
scripts/lib/common.sh             log, auditoria e funções comuns
systemd/citizentech-monitor.service
site/                             site acessível publicado
evidencias/                       prints e saídas para a entrega
```
