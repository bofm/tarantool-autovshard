#!/usr/bin/env bash

set -e

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"
cd "$ROOT"

consul_config_file=/etc/consul/consul.hcl
mkdir -p /etc/consul

cat > "$consul_config_file" <<"EEE"
disable_anonymous_signature = true
disable_update_check = true
EEE

tarantool "scripts/run_tests.lua" --pattern "^test_.*%.lua$" "${ROOT}/tests"
