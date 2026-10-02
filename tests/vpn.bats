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
