#!/bin/sh
script_dir="$(dirname -- "$(readlink -f -- "$0")")"

(
  cd "$script_dir" || exit 1
  if ! command -v cbindgen >/dev/null 2>&1; then
    cargo install --force cbindgen
  fi
  cbindgen \
    --config cbindgen.toml \
    --crate socket_connector \
    --output ../../abi/socket_connector.h
)
