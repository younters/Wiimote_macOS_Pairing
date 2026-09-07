#!/bin/zsh
set -euo pipefail
PROJECT_DIR="${0:A:h:h}"
TEST_DIR=$(mktemp -d /tmp/wiimotepair-tests.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun clang -fobjc-arc -Wall -Wextra -Werror -framework Foundation \
    "${PROJECT_DIR}/Tests/RemotePolicyTests.m" -o "${TEST_DIR}/remote-policy-tests"
"${TEST_DIR}/remote-policy-tests"

if (( $+commands[python3] )); then
    python3 -m unittest "${PROJECT_DIR}/Tests/test_discovery.py"
else
    print -u2 "python3 is unavailable; skipping discovery helper tests"
fi
