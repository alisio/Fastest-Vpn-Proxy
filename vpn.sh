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
