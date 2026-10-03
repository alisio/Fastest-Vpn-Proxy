# opencode-fastest-proxy

Projeto para criar o container `opencode-fastest-proxy`. Derivado de `~/docker/opencode-fastest-proxy/` (fonte: `docker-compose.yml:1-26`, `custom-ru.conf`, `custom.conf`).

## Conteúdo
- `vpn.sh`: CLI de endpoints — menu interativo, troca por id, `update` do provedor e `status`.
- `endpoints.tsv`: índice tabulado de endpoints (colunas `id`, `host`, `ip`, `porta`, `proto`, `status`, `obs`); `status` ∈ `ok` | `falha` | `nao-testado` | `ambiguo`.
- `docker-compose.yml`: `gluetun` (`qmcgaw/gluetun:latest`), `container_name: opencode-fastest-proxy`, `VPN_TYPE=openvpn`, `HTTPPROXY=on`, porta `127.0.0.1:8888` (`docker-compose.yml:10,21-22`).
- `custom.conf`: snapshot da conf OpenVPN ativa (`remote auau.jumptoserver.com 4443`, `proto udp` — `custom.conf:2-3`).
- `custom-ru.conf`: mesmo conteúdo, `remote` com IP literal (`46.102.153.133`, resolvido de `auau.jumptoserver.com` — `custom-ru.conf:2`).
- `.env`: `OPENVPN_USER` / `OPENVPN_PASSWORD` / `VPN_ENDPOINT`. Não versionado; credenciais preenchidas a partir de `~/.secrets/fastestvpn-user.txt` e `~/.secrets/fastestvpn-password.txt`.
- `tests/vpn.bats` + `tests/fixtures/`: testes automatizados do `vpn.sh` (bats).

## Pré-requisitos
- `docker` + `docker compose`
- `bash`, `curl`, `unzip`, `dig` (usados por `./vpn.sh`)
- Credenciais FastestVPN em `~/.secrets/fastestvpn-user.txt` / `fastestvpn-password.txt` (`.env` gerado a partir deles)

## Uso
```bash
cp .env.example .env
# preencher .env a partir de ~/.secrets/fastestvpn-user.txt / fastestvpn-password.txt

./vpn.sh update        # baixa as configs do provedor e regenera endpoints.tsv
./vpn.sh               # sem argumento: troca para VPN_ENDPOINT se definido (env ou .env), senão menu numerado de endpoints com status
./vpn.sh france        # troca para o endpoint 'france'
./vpn.sh status        # endpoint ativo e health do container
```

- `endpoints.tsv`: tabela tab-separada com `id`, `host`, `ip`, `porta`, `proto`, `status` e `obs`; o `status` segue a semântica do `vpn.sh` (`curl_test` 200/302 + health: `ok` | `ambiguo` | `falha` | `nao-testado`), enquanto `resultados-teste-udp.md` é o relatório bruto dos testes, com vocabulário próprio (ex.: `FALHA`) e cobertura parcial dos endpoints.
- Endpoints com status `falha`/`ambiguo` pedem confirmação antes da troca; `./vpn.sh <id> --force` pula a confirmação.
- `VPN_ENDPOINT` (exemplo em `.env.example`): valor devolvido por `default_endpoint` (`vpn.sh`), com fallback `australia1`.
- Teste manual do proxy: `curl -x 127.0.0.1:8888 https://ifconfig.me`

Ciclo de vida do container:
```bash
docker compose up -d
docker compose logs --tail=50
docker compose down
```

Porta exposta: `127.0.0.1:8888`. Container precisa `NET_ADMIN` e `/dev/net/tun` (`docker-compose.yml:5-8`).

## Estado atual (verificado em 2026-10-02)
Container `opencode-fastest-proxy` `healthy` (`docker ps`) com o endpoint `australia1` ativo (`custom.conf:2` — `remote auau.jumptoserver.com 4443`); resultados dos testes de endpoint em `resultados-teste-udp.md`.
