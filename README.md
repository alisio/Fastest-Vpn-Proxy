# opencode-fastest-proxy

Projeto para criar o container `opencode-fastest-proxy`. Derivado de `~/docker/opencode-fastest-proxy/` (fonte: `docker-compose.yml:1-26`, `custom-ru.conf`, `custom.conf`).

## Conteúdo
- `docker-compose.yml`: `gluetun` (`qmcgaw/gluetun:latest`), `container_name: opencode-fastest-proxy`, `VPN_TYPE=openvpn`, `HTTPPROXY=on`, porta `127.0.0.1:8888` (`docker-compose.yml:10,21-22`).
- `custom.conf`: OpenVPN (`remote russia.jumptoserver.com 4443`, `proto udp` — conforme `default.ovpn`).
- `custom-ru.conf`: mesmo conteúdo, `remote` com IP literal (`91.226.58.100`, resolvido de `russia.jumptoserver.com`).
- `.env`: `OPENVPN_USER` / `OPENVPN_PASSWORD`. Não versionado; preenchido a partir de `~/.secrets/fastestvpn-user.txt` e `~/.secrets/fastestvpn-password.txt`.

## Pré-requisitos
- `docker` + `docker compose`
- Credenciais FastestVPN em `~/.secrets/fastestvpn-user.txt` / `fastestvpn-password.txt` (`.env` gerado a partir deles)

## Uso
```bash
cp .env.example .env
# preencher .env a partir de ~/.secrets/fastestvpn-user.txt / fastestvpn-password.txt

docker compose up -d
docker compose logs --tail=50
docker compose down
```

Porta exposta: `127.0.0.1:8888`. Container precisa `NET_ADMIN` e `/dev/net/tun` (`docker-compose.yml:5-8`).

## Estado atual (verificado)
O container original (`~/docker/`) está `unhealthy` com falha `AUTH_FAILED` repetida no OpenVPN; o `.env` contém a credencial mas não é suficiente para o túnel subir (`docker logs` verificado). O projeto apenas replica os artefatos.
