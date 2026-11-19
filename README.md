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
   │ navegador / nslookup     │   HTTP :80     │ BIND9   conectacidadao.com.br    │
   └──────────────────────────┘ ─────────────► │ Apache  www.conectacidadao.com.br│
                                               │ UFW · auditd · citizentech-monitor│
                                               └───────────┬──────────────────────┘
                                                           │ adaptador NAT (só p/ apt)
                                                           ▼  Internet real
```

| Item | Valor (editável em `config/citizentech.conf`) |
|---|---|
| Domínio | `conectacidadao.com.br` / `www.conectacidadao.com.br` |
| Servidor | `srv01.conectacidadao.com.br` / `ns1.conectacidadao.com.br` |
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
nslookup www.conectacidadao.com.br
nslookup conectacidadao.com.br
curl.exe -I http://www.conectacidadao.com.br       # Server: Apache (sem versão)
```

Transferência de zona (deve ser **recusada**):

```
nslookup
> server 192.168.56.10
> ls -d conectacidadao.com.br
*** Can't list domain conectacidadao.com.br: Query refused
> exit
```

Abra **http://www.conectacidadao.com.br** no Edge. Para mostrar o cabeçalho sem versão: F12 → *Rede* → recarregue → clique no documento → *Cabeçalhos de resposta* → `Server: Apache`.

## 6. Prints para o Forms (tela inteira: VM, barra de tarefas e data/hora visíveis)

Confira no Forms o texto exato de cada print. Sugestão do que capturar:

| # | Print | Como |
|---|---|---|
| 1 | Laboratório: VMs Linux, clone e Windows com nome + RM | Janela do VirtualBox com as 3 VMs listadas |
| 2 | DNS funcionando + IP fixo | Windows: `nslookup www.conectacidadao.com.br` · Linux: `bash scripts/verificar.sh` (parte DNS/IP) |
| 3 | DNS com transferência de zona restrita | Windows: `ls -d` → *Query refused* (ou Linux: `dig @192.168.56.10 conectacidadao.com.br AXFR` → *Transfer failed*) |
| 4 | Site publicado sem mostrar versão | Edge em `http://www.conectacidadao.com.br` com F12 mostrando `Server: Apache` |

Guarde os prints em [`evidencias/`](evidencias/) para o repositório.

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
