#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  VPN="$REPO/vpn.sh"
}

@test "vpn.sh existe e é executável" {
  [ -x "$VPN" ]
}

@test "vpn.sh --help exibe uso e sai com 0" {
  run "$VPN" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Uso:"* ]]
}

@test "vpn.sh com argumento desconhecido exibe uso e sai com 1" {
  run "$VPN" --inexistente
  [ "$status" -eq 1 ]
  [[ "$output" == *"Uso:"* ]]
}

load_fixture_tsv() {
  TSV="$BATS_TEST_TMPDIR/endpoints.tsv"
  cp "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" "$TSV"
}

@test "endpoint_exists encontra id presente" {
  load_fixture_tsv
  run bash -c "source '$VPN'; TSV='$TSV'; endpoint_exists france; echo \$?"
  [ "$status" -eq 0 ]
  [ "$output" == "0" ]
}

@test "endpoint_exists falha para id ausente" {
  load_fixture_tsv
  run bash -c "source '$VPN'; TSV='$TSV'; endpoint_exists marte; echo \$?"
  [ "$output" == "1" ]
}

@test "endpoint_get devolve host/ip/porta do id" {
  load_fixture_tsv
  run bash -c "source '$VPN'; TSV='$TSV'; endpoint_get france host; endpoint_get france ip; endpoint_get france porta; endpoint_get france proto; endpoint_get france status"
  [ "$status" -eq 0 ]
  [ "$output" == $'fr.jumptoserver.com\n146.70.40.99\n4443\nudp\nok' ]
}

@test "default_endpoint usa VPN_ENDPOINT quando definido" {
  run bash -c "source '$VPN'; VPN_ENDPOINT=france; default_endpoint"
  [ "$status" -eq 0 ]
  [ "$output" == "france" ]
}

@test "default_endpoint cai para australia sem VPN_ENDPOINT" {
  run bash -c "source '$VPN'; unset VPN_ENDPOINT; default_endpoint"
  [ "$status" -eq 0 ]
  [ "$output" == "australia" ]
}

@test "endpoint_get rejeita coluna desconhecida" {
  load_fixture_tsv
  run bash -c "source '$VPN'; TSV='$TSV'; endpoint_get france coluna-x"
  [ "$status" -eq 1 ]
  [[ "$output" == *"coluna desconhecida"* ]]
}

setup_conf() {
  SRC="$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn"
  OUT="$BATS_TEST_TMPDIR"
}

@test "generate_confs custom.conf usa hostname com porta da tsv" {
  setup_conf
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; generate_confs australia '$SRC' '$OUT'"
  [ "$status" -eq 0 ]
  grep -q "^remote auau.jumptoserver.com 4443$" "$OUT/custom.conf"
}

@test "generate_confs custom-ru.conf usa IP literal" {
  setup_conf
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; generate_confs australia '$SRC' '$OUT'"
  [ "$status" -eq 0 ]
  grep -q "^remote 46.102.153.133 4443$" "$OUT/custom-ru.conf"
}

@test "generate_confs aponta auth-user-pass para /gluetun/auth e injeta script-security" {
  setup_conf
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; generate_confs australia '$SRC' '$OUT'"
  grep -q "^auth-user-pass /gluetun/auth$" "$OUT/custom.conf"
  grep -q "^script-security 2$" "$OUT/custom.conf"
}

@test "generate_confs remove CR (\r) das linhas" {
  setup_conf
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; generate_confs australia '$SRC' '$OUT'"
  run grep -q $'\r' "$OUT/custom.conf"
  [ "$status" -ne 0 ]
}

@test "generate_confs falha se id não existe na tsv" {
  setup_conf
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; generate_confs marte '$SRC' '$OUT'"
  [ "$status" -ne 0 ]
}

@test "cmd_switch recusa id desconhecido sem chamar docker" {
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; DOCKER_CMD='echo DOCKER_CHAMADO'; cmd_switch marte"
  [ "$status" -ne 0 ]
  [[ "$output" != *"DOCKER_CHAMADO"* ]]
  [[ "$output" == *"não existe"* ]]
}

@test "cmd_switch aceita id conhecido e invoca docker (stub)" {
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$BATS_TEST_TMPDIR'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch france"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
}

@test "cmd_switch restaura confs quando docker falha" {
  OUT="$BATS_TEST_TMPDIR"
  echo "PRE-CONTEUDO" > "$OUT/custom.conf"
  echo "PRE-CONTEUDO-RU" > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='false'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch france"
  [ "$status" -ne 0 ]
  [[ "$output" == *"restaurando configurações anteriores"* ]]
  [ "$(cat "$OUT/custom.conf")" == "PRE-CONTEUDO" ]
  [ "$(cat "$OUT/custom-ru.conf")" == "PRE-CONTEUDO-RU" ]
  [ ! -e "$OUT/custom.conf.bak" ]
  [ ! -e "$OUT/custom-ru.conf.bak" ]
}

@test "cmd_switch restaura confs e recria container quando health ok mas curl falha" {
  OUT="$BATS_TEST_TMPDIR"
  LOG="$BATS_TEST_TMPDIR/docker.log"
  echo "PRE-CONTEUDO" > "$OUT/custom.conf"
  echo "PRE-CONTEUDO-RU" > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo docker >> $LOG'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 000'; \
    cmd_switch france"
  [ "$status" -ne 0 ]
  [[ "$output" == *"restaurando configurações anteriores"* ]]
  [ "$(cat "$OUT/custom.conf")" == "PRE-CONTEUDO" ]
  [ "$(cat "$OUT/custom-ru.conf")" == "PRE-CONTEUDO-RU" ]
  [ ! -e "$OUT/custom.conf.bak" ]
  [ ! -e "$OUT/custom-ru.conf.bak" ]
  [ "$(grep -c docker "$LOG")" -eq 2 ]
}

@test "troca para endpoint com status falha exige confirmação" {
  OUT="$BATS_TEST_TMPDIR"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch germany-dus1 <<<''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"prosseguir"* ]]
  [[ "$output" == *"cancelada"* ]]
  [[ "$output" != *"DOCKER_CHAMADO"* ]]
  [ ! -e "$OUT/custom.conf" ]
  [ ! -e "$OUT/custom-ru.conf" ]
}

@test "guarda também exige confirmação para status falha na tsv" {
  OUT="$BATS_TEST_TMPDIR"
  TSV_F="$OUT/endpoints-falha.tsv"
  awk -F'\t' -v OFS='\t' '$1=="france" {$6="falha"} 1' \
    "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" > "$TSV_F"
  run bash -c "source '$VPN'; TSV='$TSV_F'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch france <<<''"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cancelada"* ]]
  [[ "$output" != *"DOCKER_CHAMADO"* ]]
  [ ! -e "$OUT/custom.conf" ]
}

@test "confirmação s prossegue com troca de endpoint ambiguo" {
  OUT="$BATS_TEST_TMPDIR"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch germany-dus1 <<< 's'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
  [[ "$output" == *"endpoint ativo: germany-dus1"* ]]
}

@test "--force pula confirmação de endpoint ambiguo" {
  OUT="$BATS_TEST_TMPDIR"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch germany-dus1 --force </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: germany-dus1"* ]]
  [[ "$output" != *"prosseguir"* ]]
}

@test "guarda de endpoint escreve prompt e cancelamento apenas em stderr" {
  OUT="$BATS_TEST_TMPDIR"
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$OUT'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    cmd_switch germany-dus1 1>'$OUT/out' 2>'$OUT/err' <<<''"
  [ "$status" -ne 0 ]
  [ ! -s "$OUT/out" ]
  grep -q "prosseguir" "$OUT/err"
  grep -q "cancelada" "$OUT/err"
  [ ! -e "$OUT/custom.conf" ]
  run grep -q "DOCKER_CHAMADO" "$OUT/err" "$OUT/out"
  [ "$status" -ne 0 ]
}

@test "cmd_status mostra id ativo lido do custom-ru.conf" {
  load_fixture_tsv
  OUT="$BATS_TEST_TMPDIR"
  run bash -c "source '$VPN'; TSV='$TSV'; CUSTOM_RU='$OUT/custom-ru.conf'; HEALTH_CMD='echo healthy'; \
    generate_confs australia '$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn' '$OUT' && cmd_status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: australia"* ]]
  [[ "$output" == *"status: ok"* ]]
  [[ "$output" == *"health: healthy"* ]]
}

@test "cmd_status falha quando remote não corresponde a nenhum endpoint" {
  load_fixture_tsv
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote 9.9.9.9 4443\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$TSV'; CUSTOM_RU='$OUT/custom-ru.conf'; HEALTH_CMD='echo healthy'; cmd_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"não encontrado"* ]]
  [[ "$output" == *"9.9.9.9"* ]]
}

@test "cmd_status falha quando custom-ru.conf não existe" {
  load_fixture_tsv
  run bash -c "source '$VPN'; TSV='$TSV'; CUSTOM_RU='$BATS_TEST_TMPDIR/nao-existe.conf'; HEALTH_CMD='echo healthy'; cmd_status"
  [ "$status" -ne 0 ]
  [[ "$output" == *"não encontrada"* ]]
}

@test "status real-mode com tsv inexistente sai com 1 e erro amigável sem vazar awk" {
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote 46.102.153.133 4443\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "TSV='$OUT/endpoints.tsv' CUSTOM_RU='$OUT/custom-ru.conf' HEALTH_CMD='echo healthy' '$VPN' status 1>'$OUT/out' 2>'$OUT/err'"
  [ "$status" -eq 1 ]
  grep -q "não foi possível ler" "$OUT/err"
  [ ! -s "$OUT/out" ]
  run grep -q "awk" "$OUT/err"
  [ "$status" -ne 0 ]
}

@test "cmd_status com tsv inexistente falha com 1 e não vaza o erro bruto do awk" {
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote 46.102.153.133 4443\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$OUT/endpoints.tsv'; CUSTOM_RU='$OUT/custom-ru.conf'; HEALTH_CMD='echo healthy'; cmd_status 1>'$OUT/out' 2>'$OUT/err'"
  [ "$status" -eq 1 ]
  grep -q "não foi possível ler" "$OUT/err"
  [ ! -s "$OUT/out" ]
  run grep -q "awk" "$OUT/err"
  [ "$status" -ne 0 ]
}

@test "cmd_status casa o endpoint pelo hostname do remote" {
  load_fixture_tsv
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote auau.jumptoserver.com 4443\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$TSV'; CUSTOM_RU='$OUT/custom-ru.conf'; HEALTH_CMD='echo healthy'; cmd_status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: australia"* ]]
}

@test "cmd_status não casa endpoint com porta divergente" {
  load_fixture_tsv
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote 46.102.153.133 9999\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "source '$VPN'; TSV='$TSV'; CUSTOM_RU='$OUT/custom-ru.conf'; HEALTH_CMD='echo healthy'; cmd_status"
  [ "$status" -eq 1 ]
  [[ "$output" == *"não encontrado"* ]]
}

@test "render_menu lista ids numerados com status" {
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; render_menu"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1) australia"* ]]
  [[ "$output" == *"2) france"* ]]
  [[ "$output" == *"ok"* ]]
  [[ "$output" == *"ambiguo"* ]]
}

@test "main sem argumento e com stdin fechado não loopa infinito" {
  # TSV fixture garante que render_menu passa e o caminho real de EOF (read) é exercitado;
  # timeout 5 aborta num eventual loop de EOF (rc 124 ≠ 1 → falha).
  run bash -c "unset VPN_ENDPOINT; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE=/nonexistent timeout 5 '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entrada inválida"* ]]
}

@test "menu com TSV inexistente falha com erro de leitura sem loop" {
  run bash -c "unset VPN_ENDPOINT; TSV=/nonexistent/x.tsv ENV_FILE=/nonexistent '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"não foi possível ler"* ]]
}

@test "main despacha update para cmd_update" {
  TSV_UP="$BATS_TEST_TMPDIR/endpoints.tsv"
  cp "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" "$TSV_UP"
  run bash -c "TSV='$TSV_UP' DOWNLOAD_CMD='false' '$VPN' update"
  [ "$status" -ne 0 ]
  [[ "$output" == *"download"* ]]
  [[ "$output" != *"Uso:"* ]]
}

@test "main despacha status para cmd_status" {
  load_fixture_tsv
  OUT="$BATS_TEST_TMPDIR"
  printf 'client\nremote 46.102.153.133 4443\nproto udp\n' > "$OUT/custom-ru.conf"
  run bash -c "TSV='$TSV' CUSTOM_RU='$OUT/custom-ru.conf' HEALTH_CMD='echo healthy' '$VPN' status"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: australia"* ]]
  [[ "$output" == *"health: healthy"* ]]
  [[ "$output" != *"Uso:"* ]]
}

@test "main despacha id para cmd_switch" {
  run bash -c "TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn' CONF_DEST='$BATS_TEST_TMPDIR' \
    DOCKER_CMD='echo DOCKER_CHAMADO' HEALTH_CMD='echo healthy' CURL_CMD='echo 200' \
    '$VPN' france"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: france"* ]]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
}

@test "menu_interativo caminho feliz: escolha numérica troca endpoint" {
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$BATS_TEST_TMPDIR'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    menu_interativo <<< '2'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: france"* ]]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
}

@test "main sem argumento usa VPN_ENDPOINT do ambiente e troca endpoint sem menu" {
  run bash -c "TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE=/nonexistent VPN_ENDPOINT=france OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn' CONF_DEST='$BATS_TEST_TMPDIR' \
    DOCKER_CMD='echo DOCKER_CHAMADO' HEALTH_CMD='echo healthy' CURL_CMD='echo 200' \
    '$VPN' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: france"* ]]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
  [[ "$output" != *"entrada inválida"* ]]
}

@test "main sem argumento usa VPN_ENDPOINT do ENV_FILE e troca endpoint sem menu" {
  ENVF="$BATS_TEST_TMPDIR/env-com-endpoint"
  printf 'OPENVPN_USER=x\nOPENVPN_PASSWORD=y\nVPN_ENDPOINT=france\n' > "$ENVF"
  run bash -c "unset VPN_ENDPOINT; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE='$ENVF' OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn' CONF_DEST='$BATS_TEST_TMPDIR' \
    DOCKER_CMD='echo DOCKER_CHAMADO' HEALTH_CMD='echo healthy' CURL_CMD='echo 200' \
    '$VPN' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: france"* ]]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
  [[ "$output" != *"entrada inválida"* ]]
}

@test "main sem argumento prioriza VPN_ENDPOINT do ambiente sobre o ENV_FILE" {
  ENVF="$BATS_TEST_TMPDIR/env-com-endpoint-diferente"
  printf 'OPENVPN_USER=x\nOPENVPN_PASSWORD=y\nVPN_ENDPOINT=germany-dus1\n' > "$ENVF"
  run bash -c "TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE='$ENVF' VPN_ENDPOINT=australia OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn' CONF_DEST='$BATS_TEST_TMPDIR' \
    DOCKER_CMD='echo DOCKER_CHAMADO' HEALTH_CMD='echo healthy' CURL_CMD='echo 200' \
    '$VPN' </dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: australia"* ]]
  [[ "$output" != *"germany-dus1"* ]]
  [[ "$output" != *"entrada inválida"* ]]
}

@test "main sem argumento e sem VPN_ENDPOINT mostra o menu e falha no EOF" {
  run bash -c "TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE=/nonexistent timeout 5 '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entrada inválida"* ]]
  [[ "$output" != *"endpoint ativo"* ]]
}

@test "main sem argumento com ENV_FILE sem VPN_ENDPOINT mostra o menu" {
  ENVF="$BATS_TEST_TMPDIR/env-sem-endpoint"
  printf 'OPENVPN_USER=x\nOPENVPN_PASSWORD=y\n' > "$ENVF"
  run bash -c "unset VPN_ENDPOINT; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' ENV_FILE='$ENVF' timeout 5 '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entrada inválida"* ]]
  [[ "$output" != *"endpoint ativo"* ]]
}

@test "merge_tsv preserva status de host inalterado" {
  run bash -c "source '$VPN'; RESOLVE_CMD='echo 1.2.3.4'; merge_tsv '$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' '$BATS_TEST_DIRNAME/fixtures/ovpn_novo'"
  [ "$status" -eq 0 ]
  # australia não aparece nos novos .ovpn? (aparece — fixture contém) → status ok preservado
  [[ "$output" == *$'australia\tauau.jumptoserver.com'*"ok"* ]]
}

@test "merge_tsv marca altered como nao-testado" {
  run bash -c "source '$VPN'; RESOLVE_CMD='echo 1.2.3.4'; merge_tsv '$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' '$BATS_TEST_DIRNAME/fixtures/ovpn_novo'"
  [[ "$output" == *$'france\t'*"nao-testado"* ]]   # host novo na fixture
}

@test "merge_tsv adiciona id inédito como nao-testado" {
  run bash -c "source '$VPN'; RESOLVE_CMD='echo 1.2.3.4'; merge_tsv '$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' '$BATS_TEST_DIRNAME/fixtures/ovpn_novo'"
  [[ "$output" == *"noruega"* ]]
  [[ "$output" == *"nao-testado"* ]]
}

setup_provider_zip() {
  local build="$BATS_TEST_TMPDIR/zipbuild"
  mkdir -p "$build/udp_files"
  cp "$BATS_TEST_DIRNAME/fixtures/ovpn_novo/"*.ovpn "$build/udp_files/"
  ZIP_FIX="$BATS_TEST_TMPDIR/provider.zip"
  (cd "$build" && zip -qr "$ZIP_FIX" udp_files)
}

@test "cmd_update baixa zip, regenera tsv e descarta ids sem ovpn" {
  setup_provider_zip
  TSV_UP="$BATS_TEST_TMPDIR/endpoints.tsv"
  cp "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" "$TSV_UP"
  run bash -c "source '$VPN'; TSV='$TSV_UP'; OVPN_CACHE_DIR='$BATS_TEST_TMPDIR/cache'; RESOLVE_CMD='echo 1.2.3.4'; DOWNLOAD_CMD=\"cp '$ZIP_FIX'\"; cmd_update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok=1"* ]]
  [[ "$output" == *"nao-testado=2"* ]]
  grep -q $'^noruega\t' "$TSV_UP"
  run grep -q "germany-dus1" "$TSV_UP"
  [ "$status" -ne 0 ]
  # cobre população do cache: invariante id → ${id}-udp.ovpn (nomenclatura lida pelo cmd_switch)
  CACHE="$BATS_TEST_TMPDIR/cache"
  while IFS=$'\t' read -r id _; do
    if [ "$id" != "id" ]; then
      [ -f "$CACHE/${id}-udp.ovpn" ]
    fi
  done < "$TSV_UP"
  [ ! -e "$CACHE/germany-dus1-udp.ovpn" ]
}

@test "cmd_update na primeira execução gera a tsv e não mente sobre preservação" {
  setup_provider_zip
  TSV_UP="$BATS_TEST_TMPDIR/endpoints.tsv"   # inexistente: clone novo
  run bash -c "source '$VPN'; TSV='$TSV_UP'; OVPN_CACHE_DIR='$BATS_TEST_TMPDIR/cache'; DOWNLOAD_CMD='false'; cmd_update"
  [ "$status" -ne 0 ]
  [[ "$output" == *"download"* ]]
  [[ "$output" != *"preservada"* ]]
  run bash -c "source '$VPN'; TSV='$TSV_UP'; OVPN_CACHE_DIR='$BATS_TEST_TMPDIR/cache'; RESOLVE_CMD='echo 1.2.3.4'; DOWNLOAD_CMD=\"cp '$ZIP_FIX'\"; cmd_update"
  [ "$status" -eq 0 ]
  [ -f "$TSV_UP" ]
  [[ "$(head -n 1 "$TSV_UP")" == $'id\thost\tip\tporta\tproto\tstatus\tobs' ]]
  grep -q $'^australia\t' "$TSV_UP"
  grep -q $'^france\t' "$TSV_UP"
  grep -q $'^noruega\t' "$TSV_UP"
  run awk -F'\t' 'NR>1 && $6!="nao-testado" {exit 1}' "$TSV_UP"
  [ "$status" -eq 0 ]
}

@test "cmd_update com download falho preserva a tsv antiga" {
  TSV_UP="$BATS_TEST_TMPDIR/endpoints.tsv"
  cp "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" "$TSV_UP"
  run bash -c "source '$VPN'; TSV='$TSV_UP'; OVPN_CACHE_DIR='$BATS_TEST_TMPDIR/cache'; DOWNLOAD_CMD='false'; cmd_update"
  [ "$status" -ne 0 ]
  [[ "$output" == *"download"* ]]
  cmp -s "$TSV_UP" "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv"
}
