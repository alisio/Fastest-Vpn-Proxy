#!/usr/bin/env bash
set -euo pipefail

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
    *) uso; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
