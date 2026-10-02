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

main() {
  case "${1:-}" in
    -h|--help) uso ;;
    *) uso >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
