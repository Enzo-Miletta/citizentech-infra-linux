# Evidências técnicas

Prints capturados direto das VMs (VirtualBox) em 19/11/2026. Data e hora aparecem na barra de tarefas do Windows ou no cabeçalho de cada tela do Debian.

| Item do Forms | Arquivo | O que mostra |
|---|---|---|
| 1–3 | [`vms-virtualbox.txt`](vms-virtualbox.txt) | As 3 VMs com nome e RM (Debian, Debian clone, Windows) |
| 4 | [`prints/item4-zona-direta.png`](prints/item4-zona-direta.png) | `cat` da zona direta: SOA, NS ns1/ns2, MX mail, registros A, e `named-checkzone` OK |
| 5 | [`prints/item5-nslookup-windows.png`](prints/item5-nslookup-windows.png) | `nslookup www.conectacidadao-fiap.com` no cliente Windows |
| 7 | [`prints/item7-site-no-edge-windows.png`](prints/item7-site-no-edge-windows.png) | Site Conecta Cidadão aberto no Edge do Windows |
| 8a | [`prints/item8a-allow-transfer-none.png`](prints/item8a-allow-transfer-none.png) | `named.conf.options` com `allow-transfer { none; };` destacado e AXFR falhando |
| 8b | [`prints/item8b-servertokens-prod.png`](prints/item8b-servertokens-prod.png) | `security.conf` com `ServerTokens Prod` e `ServerSignature Off` destacados, e `Server: Apache` sem versão |
| 8 (prova) | [`prints/item8-prova-windows-transferencia-recusada-e-server-apache.png`](prints/item8-prova-windows-transferencia-recusada-e-server-apache.png) | Pelo Windows: `ls -d` recusado (Query refused) e `Server: Apache` |

Saídas dos scripts:

- [`verificar.txt`](verificar.txt): `bash scripts/verificar.sh` (24/24 OK)
- [`teste-falha.txt`](teste-falha.txt): `bash scripts/teste-falha.sh` (6/6 cenários recuperados)
- [`zona-direta.txt`](zona-direta.txt): zona publicada no servidor
