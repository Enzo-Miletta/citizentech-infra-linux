# Evidências técnicas

Coloque aqui os prints enviados no Forms e as saídas dos scripts:

- `item4-zona-direta.png`: `cat /etc/bind/zones/db.conectacidadao-fiap.com`
- `item5-nslookup-windows.png`: `nslookup www.conectacidadao-fiap.com` no Windows
- `item7-site-no-cliente.png`: Edge no Windows em `http://www.conectacidadao-fiap.com`
- `item8a-allow-transfer.png`: `named.conf.options` com `allow-transfer { none; };` marcado
- `item8b-servertokens.png`: `security.conf` com `ServerTokens Prod` marcado
- `verificar.txt`: `bash scripts/verificar.sh | tee evidencias/verificar.txt`
- `teste-falha.txt`: `bash scripts/teste-falha.sh | tee evidencias/teste-falha.txt`
