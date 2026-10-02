#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="${TSV:-$SCRIPT_DIR/endpoints.tsv}"

endpoint_exists() {
  awk -F'\t' -v id="$1" 'NR>1 && $1==id {found=1} END {exit !found}' "$TSV"
}

endpoint_get() {  # $1=id $2=coluna(host|ip|porta|proto|status)
  local col
  case "$2" in
    host) col=2 ;; ip) col=3 ;; porta) col=4 ;; proto) col=5 ;; status) col=6 ;;
    *) echo "coluna desconhecida: $2" >&2; return 1 ;;
  esac
  awk -F'\t' -v id="$1" -v c="$col" 'NR>1 && $1==id {print $c}' "$TSV"
}

uso() {
  cat <<'EOF'
Uso: vpn.sh [update | <id> | status | --help]
  (sem argumento)  menu interativo
  <id>             troca para o endpoint
  update           baixa configs do provedor e regenera endpoints.tsv
  status           mostra endpoint ativo e health
EOF
}

DEFAULT_ENDPOINT="australia"

generate_confs() {  # $1=id $2=origem.ovpn $3=dir_destino
  local id="$1" src="$2" dest="$3"
  local host ip porta
  endpoint_exists "$id" || { echo "erro: endpoint '$id' não existe em $TSV" >&2; return 1; }
  [ -f "$src" ] || { echo "erro: origem não encontrada: $src" >&2; return 1; }
  host=$(endpoint_get "$id" host)
  ip=$(endpoint_get "$id" ip)
  porta=$(endpoint_get "$id" porta)
  mkdir -p "$dest"
  _render_conf "$src" "$dest/custom.conf" "$host" "$porta"
  _render_conf "$src" "$dest/custom-ru.conf" "$ip" "$porta"
}

_render_conf() {  # $1=src $2=out $3=host_ou_ip $4=porta
  tr -d '\r' < "$1" \
    | sed -e "s/^remote .*/remote $3 $4/" \
          -e "s|^auth-user-pass$|auth-user-pass /gluetun/auth|" \
    | awk '!seen_security && $0=="tls-client" {print; print "script-security 2"; seen_security=1; next} {print}' > "$2"
}

default_endpoint() {
  echo "${VPN_ENDPOINT:-$DEFAULT_ENDPOINT}"
}

DEFAULT_DOCKER_CMD="docker compose up -d --force-recreate --no-deps"
DEFAULT_HEALTH_CMD="docker inspect --format '{{.State.Health.Status}}' opencode-fastest-proxy"
DEFAULT_CURL_CMD="curl -x 127.0.0.1:8888 --max-time 12 -o /dev/null -w '%{http_code}' https://ifconfig.me"

run_docker_up() {
  local cmd="${DOCKER_CMD:-$DEFAULT_DOCKER_CMD}"
  (cd "$SCRIPT_DIR" && eval "$cmd")
}

wait_healthy() {
  local cmd="${HEALTH_CMD:-$DEFAULT_HEALTH_CMD}"
  local i out
  i=0
  while [ "$i" -lt 30 ]; do
    out=$(eval "$cmd" 2>/dev/null) || out=""
    case "$out" in
      healthy) return 0 ;;
    esac
    i=$((i + 1))
    sleep 2
  done
  echo "erro: container não ficou healthy em 60s" >&2
  return 1
}

curl_test() {
  local cmd="${CURL_CMD:-$DEFAULT_CURL_CMD}"
  local out code
  out=$(eval "$cmd" 2>/dev/null) || out=""
  code="${out%%[[:space:]]*}"
  case "$code" in
    200|302) return 0 ;;
    *) echo "erro: teste curl via proxy falhou (resposta: ${out:-vazia}; esperado 200/302)" >&2; return 1 ;;
  esac
}

_backup_confs() {  # $1=dir_destino
  local f ret=0
  for f in custom.conf custom-ru.conf; do
    if [ -f "$1/$f" ]; then
      cp "$1/$f" "$1/$f.bak" || ret=1
    else
      rm -f "$1/$f.bak" || ret=1
    fi
  done
  return "$ret"
}

_restore_confs() {  # $1=dir_destino
  local f
  for f in custom.conf custom-ru.conf; do
    if [ -f "$1/$f.bak" ]; then
      mv -f "$1/$f.bak" "$1/$f"
    else
      rm -f "$1/$f"
    fi
  done
}

_cleanup_backups() {  # $1=dir_destino
  rm -f "$1/custom.conf.bak" "$1/custom-ru.conf.bak"
}

cmd_switch() {  # $1=id
  local id="$1"
  local src dest
  endpoint_exists "$id" || { echo "erro: endpoint '$id' não existe em $TSV" >&2; return 1; }
  src="${OVPN_SRC:-$SCRIPT_DIR/.ovpn-cache/${id}-udp.ovpn}"
  dest="${CONF_DEST:-$SCRIPT_DIR}"
  [ -f "$src" ] || { echo "erro: cache não encontrado: $src — rode ./vpn.sh update" >&2; return 1; }
  mkdir -p "$dest"
  if ! _backup_confs "$dest"; then
    echo "erro: falha ao criar backup em $dest" >&2
    return 1
  fi
  if ! generate_confs "$id" "$src" "$dest"; then
    _restore_confs "$dest" || echo "aviso: falha ao restaurar configurações em $dest" >&2
    return 1
  fi
  if ! run_docker_up || ! wait_healthy || ! curl_test; then
    echo "erro: troca para '$id' falhou — restaurando configurações anteriores" >&2
    _restore_confs "$dest" || echo "aviso: falha ao restaurar configurações em $dest" >&2
    run_docker_up || echo "aviso: falha ao recriar container com confs restauradas" >&2
    return 1
  fi
  _cleanup_backups "$dest"
  echo "endpoint ativo: $id"
}

render_menu() {  # imprime menu numerado (id + status), pulando o cabeçalho
  awk -F'\t' 'NR>1 {printf "%d) %s\t%s\n", ++n, $1, $6}' "$TSV"
}

menu_interativo() {  # sem argumento: mostra o menu e troca para a escolha
  local escolha id
  render_menu || { echo "erro: não foi possível ler $TSV — rode ./vpn.sh update" >&2; return 1; }
  if ! IFS= read -r escolha; then
    echo "erro: entrada inválida" >&2
    return 1
  fi
  id=$(awk -F'\t' -v n="$escolha" 'NR>1 && ++c==n {print $1; exit}' "$TSV")
  if [ -z "$id" ]; then
    echo "erro: entrada inválida: $escolha" >&2
    return 1
  fi
  cmd_switch "$id"
}

main() {
  case "${1:-}" in
    -h|--help) uso ;;
    "") menu_interativo ;;
    *) uso >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
