#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TSV="${TSV:-$SCRIPT_DIR/endpoints.tsv}"
ENV_FILE="${ENV_FILE:-$SCRIPT_DIR/.env}"
VERSION_FILE="${VERSION_FILE:-$SCRIPT_DIR/VERSION}"
VERSION_DEFAULT="1.0.0"

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
Uso: vpn.sh [init [--force] | update | <id> [--force] | rotate [--interval MIN] [--once] [--force] | status | version | --version | --help]
  (sem argumento)  troca para VPN_ENDPOINT se definido (env ou .env); senão menu interativo
  <id> [--force]   troca para o endpoint; --force pula confirmação de status falha/ambiguo
  init [--force]  primeira subida: checa pré-reqs e .env, roda update e sobe o container
  update           baixa configs do provedor e regenera endpoints.tsv
  rotate [--interval MIN] [--once] [--force]  chaveia periodicamente entre endpoints ok (padrão 30 min; Ctrl+C para parar)
  status           mostra endpoint ativo, health e versão
  version          mostra a versão do vpn.sh
EOF
}

cmd_version() {
  local ver=""
  if [ -f "$VERSION_FILE" ]; then
    ver="$(tr -d ' \t\r\n' < "$VERSION_FILE" 2>/dev/null)"
  fi
  [ -n "$ver" ] || ver="$VERSION_DEFAULT"
  echo "vpn.sh $ver"
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

_spinner_pid=""

_spinner_start() {  # $1=mensagem (stderr, só em TTY)
  local msg="$1"
  if [ -t 2 ]; then
    printf '%s ' "$msg" >&2
    ( while :; do for c in '.' 'o' 'O' '@'; do printf '\b%s' "$c" >&2; sleep 0.2; done; done ) &
    _spinner_pid=$!
  fi
}

_spinner_stop() {
  if [ -n "${_spinner_pid:-}" ]; then
    kill "$_spinner_pid" 2>/dev/null || true
    wait "$_spinner_pid" 2>/dev/null || true
    _spinner_pid=""
    printf '\b \n' >&2
  fi
}

cmd_switch() {  # $1=id $2=--force (opcional, pula confirmação de status falha/ambiguo)
  local id="$1" forca="${2:-}"
  local src dest status resp rc=0
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
  echo "trocando para '$id'..." >&2
  _spinner_start "subindo container..."
  run_docker_up; rc=$?
  _spinner_stop
  if [ "$rc" -ne 0 ]; then
    echo "erro: troca para '$id' falhou — restaurando configurações anteriores" >&2
    _restore_confs "$dest" || echo "aviso: falha ao restaurar configurações em $dest" >&2
    run_docker_up || echo "aviso: falha ao recriar container com confs restauradas" >&2
    return 1
  fi
  _spinner_start "aguardando healthy..."
  wait_healthy; rc=$?
  _spinner_stop
  if [ "$rc" -ne 0 ]; then
    echo "erro: troca para '$id' falhou — restaurando configurações anteriores" >&2
    _restore_confs "$dest" || echo "aviso: falha ao restaurar configurações em $dest" >&2
    run_docker_up || echo "aviso: falha ao recriar container com confs restauradas" >&2
    return 1
  fi
  _spinner_start "testando proxy..."
  curl_test; rc=$?
  _spinner_stop
  if [ "$rc" -ne 0 ]; then
    echo "erro: troca para '$id' falhou — restaurando configurações anteriores" >&2
    _restore_confs "$dest" || echo "aviso: falha ao restaurar configurações em $dest" >&2
    run_docker_up || echo "aviso: falha ao recriar container com confs restauradas" >&2
    return 1
  fi
  _cleanup_backups "$dest"
  echo "endpoint ativo: $id"
}

_conf_remote() {  # $1=arquivo.conf → stdout: "host porta" (rc 1 se ausente)
  local conf="$1" host porta
  [ -f "$conf" ] || return 1
  host="$(tr -d '\r' < "$conf" | awk '$1=="remote" {print $2; exit}')"
  porta="$(tr -d '\r' < "$conf" | awk '$1=="remote" {print $3; exit}')"
  [ -n "$host" ] && [ -n "$porta" ] || return 1
  printf '%s %s\n' "$host" "$porta"
}

cmd_status() {
  local conf="${CUSTOM_RU:-$SCRIPT_DIR/custom-ru.conf}"
  local remote host porta linha_tsv id situacao obs cmd health
  [ -f "$conf" ] || { echo "erro: configuração não encontrada: $conf" >&2; return 1; }
  remote="$(_conf_remote "$conf")" \
    || { echo "erro: linha remote ausente em $conf" >&2; return 1; }
  read -r host porta <<< "$remote"
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
  echo "versão: $(cmd_version | awk '{print $2}')"
}

list_ok_ids() {  # imprime um id por linha com status == ok
  awk -F'\t' 'NR>1 && $6=="ok" {print $1}' "$TSV"
}

active_id() {  # imprime o id do endpoint ativo (vazio se não detectável)
  local conf remote host porta
  if [ -n "${CUSTOM_RU:-}" ]; then
    conf="$CUSTOM_RU"
  elif [ -n "${CONF_DEST:-}" ]; then
    conf="$CONF_DEST/custom-ru.conf"
  else
    conf="$SCRIPT_DIR/custom-ru.conf"
  fi
  [ -f "$conf" ] || return 0
  remote="$(_conf_remote "$conf")" || return 0
  read -r host porta <<< "$remote"
  awk -F'\t' -v h="$host" -v p="$porta" \
    'NR>1 && ($2==h || $3==h) && $4==p {print $1; exit}' "$TSV" 2>/dev/null || return 0
}

pick_next_id() {  # $1=excluir (opcional) → sorteia entre os ok menos o excluído
  local excluir="${1:-}" todos candidatos n idx
  todos="$(list_ok_ids)" || return 1
  [ -n "$todos" ] || { echo "erro: nenhum endpoint ok em $TSV — rode ./vpn.sh update" >&2; return 1; }
  if [ -n "$excluir" ]; then
    candidatos="$(printf '%s\n' "$todos" | grep -vxF "$excluir" || true)"
    if [ -z "$candidatos" ]; then
      echo "aviso: único endpoint ok é o ativo ('$excluir') — aguardando próximo ciclo" >&2
      return 2
    fi
  else
    candidatos="$todos"
  fi
  n="$(printf '%s\n' "$candidatos" | wc -l)"
  idx=$((RANDOM % n + 1))
  printf '%s\n' "$candidatos" | sed -n "${idx}p"
}

cmd_rotate() {  # [--interval MIN] [--once] [--force] — rodízio entre endpoints ok
  local intervalo="${ROTATE_INTERVAL:-30}" uma_vez="" forca="" secs id ativo rc
  while [ $# -gt 0 ]; do
    case "$1" in
      --interval)
        intervalo="${2:-}"; shift 2 || { echo "erro: --interval exige valor em minutos" >&2; return 1; }
        ;;
      --interval=?*)
        intervalo="${1#--interval=}"; shift ;;
      --once) uma_vez=1; shift ;;
      --force) forca="--force"; shift ;;
      -h|--help) uso; return 0 ;;
      *) echo "erro: opção desconhecida: $1" >&2; return 1 ;;
    esac
  done
  case "$intervalo" in
    ''|*[!0-9]*|0) echo "erro: intervalo inválido: $intervalo (esperado inteiro positivo em minutos)" >&2; return 1 ;;
  esac
  if [ -n "$uma_vez" ]; then
    ativo="$(active_id)"
    if ! id="$(pick_next_id "$ativo")"; then
      rc=$?
      [ "$rc" -eq 2 ] && { echo "já no único endpoint ok: $ativo" >&2; return 0; }
      return 1
    fi
    cmd_switch "$id" "$forca"
    return $?
  fi
  trap 'echo "rodízio parado" >&2; exit 0' INT TERM
  while true; do
    ativo="$(active_id)"
    if ! id="$(pick_next_id "$ativo")"; then
      rc=$?
      if [ "$rc" -eq 2 ]; then
        : # só o ativo disponível — apenas aguarda
      else
        return 1
      fi
    elif ! cmd_switch "$id" "$forca"; then
      echo "aviso: ciclo para '$id' falhou — mantido endpoint anterior; nova tentativa em ${intervalo} min" >&2
    fi
    secs=$((intervalo * 60))
    eval "${SLEEP_CMD:-sleep $secs}" || true
  done
}

_menu_id_by_number() {  # $1=n → id na ordem de exibição (ok primeiro)
  awk -F'\t' -v n="$1" '
    NR>1 { if ($6=="ok") ok[++c_ok]=$1; else resto[++c_resto]=$1 }
    END {
      if (n >= 1 && n <= c_ok) print ok[n];
      else if (n > c_ok && n <= c_ok+c_resto) print resto[n-c_ok];
    }' "$TSV"
}

_menu_total() {
  awk -F'\t' 'NR>1 {n++} END {print n+0}' "$TSV"
}

render_menu() {  # menu compacto (ok primeiro, 4 colunas), pulando o cabeçalho
  awk -F'\t' '
    NR>1 {
      label=$1
      if ($6=="ambiguo" || $6=="falha") label=$1 " [" $6 "]"
      if ($6=="ok") ok[++n_ok]=label
      else resto[++n_resto]=label
    }
    END {
      if (n_ok+n_resto == 0) exit 1
      if (n_ok > 0) {
        print "Endpoints saudáveis (ok) — recomendados:"
        for (i=1; i<=n_ok; i++) {
          ++n
          printf " %3d) %-20s", n, ok[i]
          if (n % 4 == 0) printf "\n"
        }
        if (n % 4 != 0) printf "\n"
        if (n_resto > 0) printf "\n"
      }
      if (n_resto > 0) {
        print "Outros:"
        base=n
        for (i=1; i<=n_resto; i++) {
          ++n
          printf " %3d) %-20s", n, resto[i]
          if ((n-base) % 4 == 0) printf "\n"
        }
        if ((n-base) % 4 != 0) printf "\n"
      }
    }' "$TSV"
}

menu_interativo() {  # sem argumento: mostra o menu e troca para a escolha
  local escolha id total padrao
  render_menu || { echo "erro: não foi possível ler $TSV — rode ./vpn.sh update" >&2; return 1; }
  total="$(_menu_total)"
  padrao="$(default_endpoint)"
  printf 'Escolha [1-%s, padrão=%s]: ' "$total" "$padrao" >&2
  if ! IFS= read -r escolha; then
    echo "erro: entrada inválida" >&2
    return 1
  fi
  escolha="$(printf '%s' "$escolha" | tr -d ' \t\r\n')"
  if [ -z "$escolha" ]; then
    echo "usando padrão: $padrao" >&2
    id="$padrao"
    endpoint_exists "$id" || { echo "erro: endpoint '$id' não existe em $TSV" >&2; return 1; }
    cmd_switch "$id"
    return $?
  fi
  case "$escolha" in
    *[!0-9]*|"") echo "erro: entrada inválida: $escolha (esperado 1-$total)" >&2; return 1 ;;
  esac
  if [ "$escolha" -lt 1 ] || [ "$escolha" -gt "$total" ]; then
    echo "erro: entrada inválida: $escolha (esperado 1-$total)" >&2
    return 1
  fi
  id="$(_menu_id_by_number "$escolha")"
  if [ -z "$id" ]; then
    echo "erro: entrada inválida: $escolha (esperado 1-$total)" >&2
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

check_bin() {  # $1=rótulo $2=comando de verificação
  local rotulo="$1" verif="$2"
  if ! eval "$verif" >/dev/null 2>&1; then
    echo "erro: pré-requisito ausente: $rotulo" >&2
    return 1
  fi
}

check_prereqs() {
  local ret=0
  check_bin docker "command -v docker" || ret=1
  check_bin "docker compose" "docker compose version" || ret=1
  check_bin curl "command -v curl" || ret=1
  check_bin unzip "command -v unzip" || ret=1
  check_bin dig "command -v dig" || ret=1
  return "$ret"
}

_env_val() {  # $1=VAR → 0 se presente e não vazia em $ENV_FILE (o valor nunca é impresso)
  local var="$1" linha val=""
  [ -f "$ENV_FILE" ] || return 1
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    case "$linha" in
      "$var"=?*) val="${linha#"$var"=}" ;;
    esac
  done < "$ENV_FILE"
  [ -n "$val" ]
}

_init_ready() {  # $1=id → 0 se as confs casam com o id e o container está healthy
  local id="$1" dest remote host porta linha saude
  dest="${CONF_DEST:-$SCRIPT_DIR}"
  remote="$(_conf_remote "$dest/custom-ru.conf")" || return 1
  read -r host porta <<< "$remote"
  linha="$(awk -F'\t' -v h="$host" -v p="$porta" \
    'NR>1 && ($2==h || $3==h) && $4==p {print $1; exit}' "$TSV" 2>/dev/null)"
  [ "$linha" = "$id" ] || return 1
  saude="$(eval "${HEALTH_CMD:-$DEFAULT_HEALTH_CMD}" 2>/dev/null)" || saude=""
  [ "$saude" = "healthy" ]
}

cmd_init() {  # [--force]
  local forca="${1:-}" id cache
  check_prereqs || return 1
  if [ ! -f "$ENV_FILE" ]; then
    echo "erro: $ENV_FILE não encontrado — rode: cp .env.example .env" >&2
    return 1
  fi
  _env_val OPENVPN_USER \
    || { echo "erro: OPENVPN_USER ausente ou vazio em $ENV_FILE" >&2; return 1; }
  _env_val OPENVPN_PASSWORD \
    || { echo "erro: OPENVPN_PASSWORD ausente ou vazio em $ENV_FILE" >&2; return 1; }
  id="$(default_endpoint)"
  if [ "$forca" != "--force" ] && [ -f "$TSV" ] \
    && endpoint_exists "$id" && _init_ready "$id"; then
    echo "já pronto: $id"
    return 0
  fi
  if ! cmd_update; then
    cache="${OVPN_CACHE_DIR:-$SCRIPT_DIR/.ovpn-cache}/${id}-udp.ovpn"
    if [ -f "$cache" ]; then
      echo "aviso: update falhou — prosseguindo com cache existente ($cache)" >&2
    else
      echo "erro: update falhou e não há cache para '$id' — verifique a rede e rode ./vpn.sh init de novo" >&2
      return 1
    fi
  fi
  endpoint_exists "$id" || { echo "erro: endpoint '$id' não existe em $TSV" >&2; return 1; }
  cmd_switch "$id"
}

main() {
  case "${1:-}" in
    -h|--help) uso ;;
    --version|-V) cmd_version ;;
    "")
      if [ -n "${VPN_ENDPOINT:-}" ]; then
        cmd_switch "$(default_endpoint)"
      else
        menu_interativo
      fi
      ;;
    -*) uso >&2; return 1 ;;
    init) cmd_init "${2:-}" ;;
    update) cmd_update ;;
    rotate) shift; cmd_rotate "$@" ;;
    status) cmd_status ;;
    version) cmd_version ;;
    *) cmd_switch "$@" ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  main "$@"
fi
