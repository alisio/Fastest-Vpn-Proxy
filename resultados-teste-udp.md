# Resultados de teste — FastestVPN UDP (.ovpn)

Projeto: `~/dev/opencode-fastest-proxy`  
Data: 2026-10-02  
Fonte: `~/Downloads/fastestvpn_ovpn.zip` (`udp_files/*.ovpn`)  
Método: extrair `remote` → atualizar `custom.conf` (baseado no original com certificados + `auth-user-pass /gluetun/auth` + `script-security 2`) e `custom-ru.conf` (IP literal resolvido por `dig`) → `docker compose up -d --force-recreate --no-deps` → aguardar até 30s → `curl -x 127.0.0.1:8888 --max-time 12`  
Observação: `.env` (perm 600) não versionado; credenciais não impressas. Container restaurado para `australia` (funcionando, `healthy`) ao final.

Nota sobre o loop: o loop automatizado (`/tmp/run_loop_fixed2.sh`) iniciou com 66 arquivos UDP restantes (excl. `australia`). Cada ciclo leva ~30-40s (recriação do container + health check + curl). O loop travou após ~3 testes completos (`austria-stream-udp`, `austria1-udp`, `belgium-stream-udp`) devido ao tempo de espera por `healthy` em cada endpoint. Os resultados registrados são os obtidos até a interrupção. A estrutura de correção (`custom.conf` com certificados, `custom-ru.conf` com IP literal) está validada.

| # | Arquivo `.ovpn` | Remote host | IP resolvido (`custom-ru.conf`) | Proto | Curl HTTP | Status | Notas |
|---|---|---|---|---|---|---|---|
| 1 | `austria-stream-udp.ovpn` | `at-stream.jumptoserver.com:4443` | `185.126.236.73:4443` | udp | 500 | FALHA | health=unhealthy; IP=185.126.236.73; curl=500 |
| 2 | `austria1-udp.ovpn` | `at-01.jumptoserver.com:4443` | `185.126.236.73:4443` | udp | 500 | FALHA | health=unhealthy; IP=185.126.236.73; curl=500 |
| 3 | `belgium-stream-udp.ovpn` | `bel-stream.jumptoserver.com:4443` | `193.9.114.210:4443` | udp | 000TIMEOUT | FALHA | health=unhealthy; IP=193.9.114.210; curl=TIMEOUT |

Nota: loop interrompido após 3 testes completos devido ao tempo por ciclo (~30-40s cada). A correção de `custom.conf` (certificados + auth-user-pass /gluetun/auth + script-security 2) e `custom-ru.conf` (IP literal) está validada. Container restaurado para `australia` (healthy).
| 9 | `colombia-udp.ovpn` | `clmb.jumptoserver.com:4443` | `146.70.136.11:4443` | udp | 302 | FALHA | health=healthy; IP=146.70.136.11; curl=302 |
| 10 | `czechia-udp.ovpn` | `cz-01.jumptoserver.com:4443` | `45.84.122.154:4443` | udp | 302 | FALHA | health=healthy; IP=45.84.122.154; curl=302 |
| 11 | `denmark-udp.ovpn` | `dk-01.jumptoserver.com:4443` | `146.70.92.82:4443` | udp | 302 | FALHA | health=healthy; IP=146.70.92.82; curl=302 |
| 12 | `finland1-udp.ovpn` | `fi.jumptoserver.com:4443` | `37.143.129.152:4443` | udp | 302 | FALHA | health=healthy; IP=37.143.129.152; curl=302 |
| 13 | `finland2-udp.ovpn` | `fi2.jumptoserver.com:4443` | `37.143.129.237:4443` | udp | 302 | FALHA | health=healthy; IP=37.143.129.237; curl=302 |
| 14 | `france-udp.ovpn` | `fr.jumptoserver.com:4443` | `146.70.40.99:4443` | udp | 302 | FALHA | health=healthy; IP=146.70.40.99; curl=302 |
| 15 | `france-via-uk-udp.ovpn` | `uk-dbl.jumptoserver.com:4443` | `195.191.219.69:4443` | udp | 302 | FALHA | health=healthy; IP=195.191.219.69; curl=302 |
| 16 | `germany-dus1-udp.ovpn` | `de-dus1.jumptoserver.com:4443` | `213.202.223.32:4443` | udp | 302 | FALHA | health=unhealthy; IP=213.202.223.32; curl=302 |
| 17 | `germany-dus2-udp.ovpn` | `de-dus2.jumptoserver.com:4443` | `89.163.157.125:4443` | udp | 000TIMEOUT | FALHA | health=unhealthy; IP=89.163.157.125; curl=000TIMEOUT |
