#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  framework.sh — minimal assertion library for AV Encoder Suite tests
#  Source this file at the top of every test_*.sh:
#      source "$(dirname "${BASH_SOURCE[0]}")/../framework.sh"
# ═══════════════════════════════════════════════════════════════

# Globals (overridable by runner)
: "${TEST_NAME:=$(basename "${BASH_SOURCE[1]:-unknown}" .sh)}"

_assertions=0
_failures=0
declare -a _failure_msgs=()

_pass() { _assertions=$((_assertions+1)); }
_fail() {
    _assertions=$((_assertions+1))
    _failures=$((_failures+1))
    _failure_msgs+=("$1")
}

assert_eq() {
    local expected="$1" actual="$2" msg="${3:-assert_eq}"
    if [[ "$expected" == "$actual" ]]; then _pass
    else _fail "$msg: expected '$expected' got '$actual'"
    fi
}

assert_neq() {
    local a="$1" b="$2" msg="${3:-assert_neq}"
    if [[ "$a" != "$b" ]]; then _pass
    else _fail "$msg: both equal '$a'"
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" msg="${3:-assert_contains}"
    if [[ "$haystack" == *"$needle"* ]]; then _pass
    else _fail "$msg: '$needle' not found"
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" msg="${3:-assert_not_contains}"
    if [[ "$haystack" != *"$needle"* ]]; then _pass
    else _fail "$msg: '$needle' was found but should not be"
    fi
}

assert_match() {
    local str="$1" pat="$2" msg="${3:-assert_match}"
    if [[ "$str" =~ $pat ]]; then _pass
    else _fail "$msg: '$str' does not match /$pat/"
    fi
}

assert_file_exists() {
    local f="$1" msg="${2:-file should exist}"
    if [[ -f "$f" ]]; then _pass
    else _fail "$msg: '$f'"
    fi
}

assert_file_not_exists() {
    local f="$1" msg="${2:-file should NOT exist}"
    if [[ ! -f "$f" ]]; then _pass
    else _fail "$msg: '$f'"
    fi
}

assert_dir_exists() {
    local d="$1" msg="${2:-dir should exist}"
    if [[ -d "$d" ]]; then _pass
    else _fail "$msg: '$d'"
    fi
}

assert_zero() {
    local code="$1" msg="${2:-expected exit 0}"
    if [[ "$code" -eq 0 ]]; then _pass
    else _fail "$msg: got exit $code"
    fi
}

assert_nonzero() {
    local code="$1" msg="${2:-expected nonzero exit}"
    if [[ "$code" -ne 0 ]]; then _pass
    else _fail "$msg: got exit 0"
    fi
}

# skip_test <reason>
# Honored by runner via TEST_SKIPPED env var.
skip_test() {
    echo "SKIP $TEST_NAME — $1" >&2
    export TEST_SKIPPED=1
    exit 77
}

# Auto-summary on exit
_test_summary() {
    local rc=$?
    # If skip path, exit was already 77
    [[ "${TEST_SKIPPED:-0}" == "1" ]] && exit 77
    if [[ $_failures -eq 0 ]] && [[ $rc -eq 0 ]]; then
        echo "PASS $TEST_NAME ($_assertions assertions)"
        exit 0
    else
        echo "FAIL $TEST_NAME ($_failures/$_assertions failed; script_rc=$rc)"
        local m
        for m in "${_failure_msgs[@]}"; do echo "  - $m"; done
        exit 1
    fi
}
trap _test_summary EXIT
