#!/usr/bin/env bash
# Smoke test pentru framework.sh — verifica fiecare assertion helper.
source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"

assert_eq "abc" "abc" "string equal"
assert_eq 42 42 "int equal"
assert_neq "abc" "def" "string not equal"
assert_contains "hello world" "world" "substring present"
assert_not_contains "hello world" "xyz" "substring absent"
assert_match "v42.1" "^v[0-9]+\.[0-9]+$" "regex match"
assert_zero 0 "exit 0"
assert_nonzero 1 "exit 1"

# File assertions on a temp file
tmp=$(mktemp)
assert_file_exists "$tmp" "tempfile created"
rm -f "$tmp"
assert_file_not_exists "$tmp" "tempfile removed"
assert_dir_exists "$(dirname "${BASH_SOURCE[0]}")" "tests dir exists"
