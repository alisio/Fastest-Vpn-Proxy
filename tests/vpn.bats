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
  run "$VPN" argumento-inexistente
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
  run bash -c "TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv' timeout 5 '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"entrada inválida"* ]]
}

@test "menu com TSV inexistente falha com erro de leitura sem loop" {
  run bash -c "TSV=/nonexistent/x.tsv '$VPN' </dev/null"
  [ "$status" -eq 1 ]
  [[ "$output" == *"não foi possível ler"* ]]
}

@test "menu_interativo caminho feliz: escolha numérica troca endpoint" {
  run bash -c "source '$VPN'; TSV='$BATS_TEST_DIRNAME/fixtures/endpoints.tsv'; OVPN_SRC='$BATS_TEST_DIRNAME/fixtures/sample-udp.ovpn'; CONF_DEST='$BATS_TEST_TMPDIR'; \
    DOCKER_CMD='echo DOCKER_CHAMADO'; HEALTH_CMD='echo healthy'; CURL_CMD='echo 200'; \
    menu_interativo <<< '2'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"endpoint ativo: france"* ]]
  [[ "$output" == *"DOCKER_CHAMADO"* ]]
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
}

@test "cmd_update com download falho preserva a tsv antiga" {
  TSV_UP="$BATS_TEST_TMPDIR/endpoints.tsv"
  cp "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv" "$TSV_UP"
  run bash -c "source '$VPN'; TSV='$TSV_UP'; OVPN_CACHE_DIR='$BATS_TEST_TMPDIR/cache'; DOWNLOAD_CMD='false'; cmd_update"
  [ "$status" -ne 0 ]
  [[ "$output" == *"download"* ]]
  cmp -s "$TSV_UP" "$BATS_TEST_DIRNAME/fixtures/endpoints.tsv"
}
