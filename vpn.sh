#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="${TSV:-$SCRIPT_DIR/endpoints.tsv}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"

_load_env_vpn_endpoint() {  # VPN_ENDPOINT da env tem prioridade; senão lê do ENV_FILE
  if [ -n "${VPN_ENDPOINT:-}" ] || [ ! -f "$ENV_FILE" ]; then
    return 0
  fi
  local linha
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    case "$linha" in
      VPN_ENDPOINT=?*)
        VPN_ENDPOINT="${linha#VPN_ENDPOINT=}"
        return 0
        ;;
    esac
  done < "$ENV_FILE"
}
_load_env_vpn_endpoint

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
Uso: vpn.sh [update | <id> [--force] | status | --help]
  (sem argumento)  troca para VPN_ENDPOINT se definido (env ou .env); senão menu interativo
  <id> [--force]   troca para o endpoint; --force pula confirmação de status falha/ambiguo
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
DEFAULT_HEALTH_CMD="docker inspect --format '{{.State.Health.Status}}' fastest-vpn-proxy"
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

cmd_switch() {  # $1=id $2=--force (opcional, pula confirmação de status falha/ambiguo)
  local id="$1" forca="${2:-}"
  local src dest status resp
  endpoint_exists "$id" || { echo "erro: endpoint '$id' não existe em $TSV" >&2; return 1; }
  status="$(endpoint_get "$id" status)"
  case "$status" in
    falha|ambiguo)
      if [ "$forca" != "--force" ]; then
        printf "aviso: endpoint '%s' tem status '%s' — prosseguir? [s/N]\n" "$id" "$status" >&2
        IFS= read -r resp || resp=""
        case "$resp" in
          s|S|sim|Sim|SIM) ;;
          *) echo "erro: troca para '$id' cancelada (status '$status' sem confirmação)" >&2; return 1 ;;
        esac
      fi
      ;;
  esac
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

cmd_status() {
  local conf="${CUSTOM_RU:-$SCRIPT_DIR/custom-ru.conf}"
  local host porta linha_tsv id situacao obs cmd health
  [ -f "$conf" ] || { echo "erro: configuração não encontrada: $conf" >&2; return 1; }
  host="$(tr -d '\r' < "$conf" | awk '$1=="remote" {print $2; exit}')"
  porta="$(tr -d '\r' < "$conf" | awk '$1=="remote" {print $3; exit}')"
  if [ -z "$host" ] || [ -z "$porta" ]; then
    echo "erro: linha remote ausente em $conf" >&2
    return 1
  fi
  if ! linha_tsv="$(awk -F'\t' -v h="$host" -v p="$porta" \
    'NR>1 && ($2==h || $3==h) && $4==p {print $1 "\t" $6 "\t" $7; exit}' "$TSV" 2>/dev/null)"; then
    echo "erro: não foi possível ler $TSV — rode ./vpn.sh update" >&2
    return 1
  fi
  if [ -z "$linha_tsv" ]; then
    echo "erro: endpoint ativo não encontrado em $TSV (remote $host $porta)" >&2
    return 1
  fi
  IFS=$'\t' read -r id situacao obs <<< "$linha_tsv"
  echo "endpoint ativo: $id"
  echo "status: $situacao ($obs)"
  echo "remote: $host $porta"
  cmd="${HEALTH_CMD:-$DEFAULT_HEALTH_CMD}"
  health="$(eval "$cmd" 2>/dev/null)" || health=""
  echo "health: ${health:-indisponível}"
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

DEFAULT_RESOLVE_CMD="dig +short"

parse_ovpn_core() {  # $1=arquivo.ovpn → stdout: host<TAB>porta<TAB>proto
  local arquivo="$1" linha resto host="" porta="" proto=""
  [ -f "$arquivo" ] || { echo "erro: arquivo não encontrado: $arquivo" >&2; return 1; }
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    case "$linha" in
      remote\ *)
        resto="${linha#remote }"
        read -r host porta <<< "$resto"
        ;;
      proto\ *)
        proto="${linha#proto }"
        proto="${proto%%[[:space:]]*}"
        ;;
    esac
  done < "$arquivo"
  [ -n "$host" ] || { echo "erro: linha remote ausente em $arquivo" >&2; return 1; }
  [ -n "$porta" ] || { echo "erro: porta do remote ausente em $arquivo" >&2; return 1; }
  printf '%s\t%s\t%s\n' "$host" "$porta" "$proto"
}

resolve_ip() {  # $1=host → primeiro IP (vazio se resolução falhar)
  local cmd="${RESOLVE_CMD:-$DEFAULT_RESOLVE_CMD}" out
  out="$(eval "$cmd \"\$1\"" 2>/dev/null)" || out=""
  out="${out%%[[:space:]]*}"
  printf '%s\n' "$out"
}

merge_tsv() {  # $1=tsv_velho $2=dir_ovpn → nova tabela no stdout (sem tsv antigo, gera tudo como nao-testado)
  local tsv="$1" dir="$2"
  local arq id core host porta proto ip status obs antigo
  [ -d "$dir" ] || { echo "erro: diretório de .ovpn não encontrado: $dir" >&2; return 1; }
  if [ -f "$tsv" ]; then
    head -n 1 "$tsv"
  else
    printf 'id\thost\tip\tporta\tproto\tstatus\tobs\n'
  fi
  for arq in "$dir"/*.ovpn; do
    [ -e "$arq" ] || { echo "erro: nenhum arquivo .ovpn em $dir" >&2; return 1; }
    id="${arq##*/}"
    id="${id%.ovpn}"
    id="${id%-udp}"
    core="$(parse_ovpn_core "$arq")" || return 1
    IFS=$'\t' read -r host porta proto <<< "$core"
    ip="$(resolve_ip "$host")"
    if [ -f "$tsv" ]; then
      antigo="$(awk -F'\t' -v id="$id" -v h="$host" -v p="$porta" '
        NR > 1 && $1 == id {
          if ($2 == h && $4 == p) { print $6; print $7 } else { print "nao-testado"; print "-" }
          exit
        }' "$tsv")"
    else
      antigo=""
    fi
    if [ -n "$antigo" ]; then
      status="${antigo%%$'\n'*}"
      obs="${antigo#*$'\n'}"
    else
      status="nao-testado"
      obs="-"
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$host" "$ip" "$porta" "$proto" "$status" "$obs"
  done
}

PROVIDER_URL="${PROVIDER_URL:-https://support.fastestvpn.com/download/fastestvpn_ovpn/}"
OVPN_CACHE_DIR="${OVPN_CACHE_DIR:-$SCRIPT_DIR/.ovpn-cache}"
DEFAULT_DOWNLOAD_CMD="curl -sL $PROVIDER_URL -o"

download_provider_zip() {  # $1=destino.zip
  local cmd="${DOWNLOAD_CMD:-$DEFAULT_DOWNLOAD_CMD}"
  eval "$cmd \"\$1\""
}

cmd_update() {
  local tmpdir zip extracao dir_ovpn tsv_tmp cache
  local n_total n_ok n_nao situacao_tsv
  tmpdir="$(mktemp -d)" || { echo "erro: não foi possível criar diretório temporário" >&2; return 1; }
  zip="$tmpdir/provider.zip"
  extracao="$tmpdir/extracao"
  if [ -f "$TSV" ]; then
    situacao_tsv="tabela $TSV preservada"
  else
    situacao_tsv="tabela $TSV inexistente"
  fi
  if ! download_provider_zip "$zip"; then
    echo "erro: download do provedor falhou — $situacao_tsv" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  if ! unzip -q "$zip" -d "$extracao" 2>/dev/null; then
    echo "erro: extração do zip falhou — $situacao_tsv" >&2
    rm -rf "$tmpdir"
    return 1
  fi
  dir_ovpn="$extracao"
  if [ -d "$extracao/udp_files" ]; then
    dir_ovpn="$extracao/udp_files"
  fi
  tsv_tmp="$TSV.tmp"
  if ! merge_tsv "$TSV" "$dir_ovpn" > "$tsv_tmp"; then
    echo "erro: merge dos endpoints falhou — $situacao_tsv" >&2
    rm -f "$tsv_tmp"
    rm -rf "$tmpdir"
    return 1
  fi
  if ! mv -f "$tsv_tmp" "$TSV"; then
    echo "erro: falha ao gravar $TSV" >&2
    rm -f "$tsv_tmp"
    rm -rf "$tmpdir"
    return 1
  fi
  cache="${OVPN_CACHE_DIR:-$SCRIPT_DIR/.ovpn-cache}"
  if rm -rf "$cache" 2>/dev/null && mkdir -p "$cache" 2>/dev/null; then
    cp "$dir_ovpn"/*.ovpn "$cache/" 2>/dev/null \
      || echo "aviso: falha ao copiar .ovpn para $cache" >&2
  else
    echo "aviso: falha ao atualizar cache $cache" >&2
  fi
  n_total="$(awk 'END {print NR-1}' "$TSV")"
  n_ok="$(awk -F'\t' 'NR>1 && $6=="ok" {n++} END {print n+0}' "$TSV")"
  n_nao="$(awk -F'\t' 'NR>1 && $6=="nao-testado" {n++} END {print n+0}' "$TSV")"
  echo "endpoints.tsv atualizada: total=$n_total ok=$n_ok nao-testado=$n_nao"
  rm -rf "$tmpdir"
}

main() {
  case "${1:-}" in
    -h|--help) uso ;;
    "")
      if [ -n "${VPN_ENDPOINT:-}" ]; then
        cmd_switch "$(default_endpoint)"
      else
        menu_interativo
      fi
      ;;
    -*) uso >&2; return 1 ;;
    update) cmd_update ;;
    status) cmd_status ;;
    *) cmd_switch "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
