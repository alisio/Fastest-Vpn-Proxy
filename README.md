# fastest-vpn-proxy

Ferramenta que protege a sua conexão com a internet por meio de uma rede privada (VPN) e permite trocar o servidor de saída quando quiser. Na prática: um container com proxy HTTP local (`127.0.0.1:8888`) mais um CLI (`vpn.sh`) para escolher o endpoint.

## Como funciona

1. Você escolhe um país na lista de endpoints.
2. A ferramenta cria um caminho seguro (túnel VPN) até esse país.
3. Os seus programas passam a navegar com o endereço de internet desse país — basta apontá-los para `127.0.0.1:8888`. Esse endereço só funciona no seu próprio computador.

A ferramenta também verifica se a conexão está funcionando a cada troca e atualiza a lista de endpoints quando o provedor muda as configurações.

## Conteúdo
- `vpn.sh`: CLI de endpoints — menu interativo, troca por id, `update` do provedor e `status`.
- `endpoints.tsv`: índice tabulado de endpoints (colunas `id`, `host`, `ip`, `porta`, `proto`, `status`, `obs`); `status` ∈ `ok` | `falha` | `nao-testado` | `ambiguo`.
- `docker-compose.yml`: `gluetun` (`qmcgaw/gluetun:latest`), `container_name: fastest-vpn-proxy`, `VPN_TYPE=openvpn`, `HTTPPROXY=on`, porta `127.0.0.1:8888` (`docker-compose.yml:10,20`).
- `custom.conf`: snapshot da conf OpenVPN ativa (`remote auau.jumptoserver.com 4443`, `proto udp` — `custom.conf:2-3`).
- `custom-ru.conf`: mesmo conteúdo, `remote` com IP literal (`46.102.153.133`, resolvido de `auau.jumptoserver.com` — `custom-ru.conf:2`).
- `.env`: `OPENVPN_USER` / `OPENVPN_PASSWORD` / `VPN_ENDPOINT`. Não versionado; credenciais FastestVPN preenchidas manualmente.
- `tests/vpn.bats` + `tests/fixtures/`: testes automatizados do `vpn.sh` (bats).

## Pré-requisitos
- `docker` + `docker compose`
- `bash`, `curl`, `unzip`, `dig` (usados por `./vpn.sh`)
- Credenciais FastestVPN (usuário e senha) para o `.env`

## Uso
```bash
cp .env.example .env
# preencher .env com as credenciais FastestVPN

./vpn.sh update        # baixa as configs do provedor e regenera endpoints.tsv
./vpn.sh               # sem argumento: troca para VPN_ENDPOINT se definido (env ou .env), senão menu numerado de endpoints com status
./vpn.sh france        # troca para o endpoint 'france'
./vpn.sh status        # endpoint ativo e health do container
```

- `endpoints.tsv`: tabela tab-separada com `id`, `host`, `ip`, `porta`, `proto`, `status` e `obs`; o `status` segue a semântica do `vpn.sh` (`curl_test` 200/302 + health: `ok` | `ambiguo` | `falha` | `nao-testado`).
- Endpoints com status `falha`/`ambiguo` pedem confirmação antes da troca; `./vpn.sh <id> --force` pula a confirmação.
- `VPN_ENDPOINT` (exemplo em `.env.example`): valor devolvido por `default_endpoint` (`vpn.sh`), com fallback `australia`.
- Teste manual do proxy: `curl -x 127.0.0.1:8888 https://ifconfig.me`

Ciclo de vida do container:
```bash
docker compose up -d
docker compose logs --tail=50
docker compose down
```

Porta exposta: `127.0.0.1:8888`. Container precisa `NET_ADMIN` e `/dev/net/tun` (`docker-compose.yml:5-8`).

