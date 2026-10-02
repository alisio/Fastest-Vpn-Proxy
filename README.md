# opencode-fastest-proxy

Projeto para criar o container `opencode-fastest-proxy`. Derivado de `~/docker/opencode-fastest-proxy/` (fonte: `docker-compose.yml:1-26`, `custom-ru.conf`, `custom.conf`).

## Conteúdo
- `docker-compose.yml`: `gluetun` (`qmcgaw/gluetun:latest`), `container_name: opencode-fastest-proxy`, `VPN_TYPE=openvpn`, `HTTPPROXY=on`, porta `127.0.0.1:8888` (`docker-compose.yml:10,21-22`).
- `custom.conf`, `custom-ru.conf`: config OpenVPN (`remote 91.226.58.5 4443` em `custom-ru.conf:2`, `remote ru-vr.jumptoserver.com 4443` em `custom.conf:2`).
- `.env`: `OPENVPN_USER` e `OPENVPN_PASSWORD` (`.env` no original). Não versionado — ver `.env.example`.

## Pré-requisitos
- `docker` + `docker compose`
- Credenciais FastestVPN em `~/.secrets/fastestvpn.txt` (referência: `docker-compose.yml:20`)

## Uso
```bash
cp .env.example .env
# preencher .env com valores de ~/.secrets/fastestvpn.txt

docker compose up -d
docker compose logs --tail=50
docker compose down
```

Porta exposta: `127.0.0.1:8888`. Container precisa `NET_ADMIN` e `/dev/net/tun` (`docker-compose.yml:5-8`).

## Estado atual (verificado)
O container original (`~/docker/`) está `unhealthy` com falha `AUTH_FAILED` repetida no OpenVPN; o `.env` contém a credencial mas não é suficiente para o túnel subir (`docker logs` verificado). O projeto apenas replica os artefatos.
