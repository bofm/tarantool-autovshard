#!/usr/bin/env bash

set -e

ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && cd .. && pwd )"
cd "$ROOT"

tarantool "scripts/run_tests.lua" --verbose --coverage --pattern "^test_.*%.lua$" "${ROOT}/tests"
