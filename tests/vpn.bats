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
