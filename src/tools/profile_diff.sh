#!/usr/bin/env bash
# ═══════════════════════════════════════════════════════════════
#  profile_diff.sh — compara doua profile .conf
#  Usage: profile_diff.sh <profileA.conf> <profileB.conf>
#  Output: sectiuni "doar in A", "doar in B", "valori diferite".
# ═══════════════════════════════════════════════════════════════

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <profileA.conf> <profileB.conf>" >&2
    exit 2
fi

A="$1"
B="$2"

for f in "$A" "$B"; do
    [[ -f "$f" ]] || { echo "Eroare: fisier inexistent: $f" >&2; exit 2; }
done

# Parse KEY=VALUE / KEY="VALUE" into associative array (bash 4+)
declare -A MAP_A MAP_B
declare -a KEYS_A_ORDER KEYS_B_ORDER

parse_conf() {
    local file="$1" map_name="$2" order_name="$3"
    local lineno=0 key value line
    while IFS= read -r line || [[ -n "$line" ]]; do
        lineno=$((lineno+1))
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$ ]]; then
            key="${BASH_REMATCH[1]}"
            value="${BASH_REMATCH[2]}"
            printf -v "${map_name}[$key]" '%s' "$value"
            eval "$order_name+=(\"\$key\")"
        fi
    done < "$file"
}

parse_conf "$A" MAP_A KEYS_A_ORDER
parse_conf "$B" MAP_B KEYS_B_ORDER

NAME_A="$(basename "$A" .conf)"
NAME_B="$(basename "$B" .conf)"

echo "════════════════════════════════════════════════════════════"
echo "  Profile diff"
echo "    A: $NAME_A  ($A)"
echo "    B: $NAME_B  ($B)"
echo "════════════════════════════════════════════════════════════"

# Section 1: only in A
only_a=()
for k in "${KEYS_A_ORDER[@]}"; do
    if [[ -z "${MAP_B[$k]+x}" ]]; then
        only_a+=("$k")
    fi
done

# Section 2: only in B
only_b=()
for k in "${KEYS_B_ORDER[@]}"; do
    if [[ -z "${MAP_A[$k]+x}" ]]; then
        only_b+=("$k")
    fi
done

# Section 3: different values
diff_keys=()
for k in "${KEYS_A_ORDER[@]}"; do
    if [[ -n "${MAP_B[$k]+x}" ]] && [[ "${MAP_A[$k]}" != "${MAP_B[$k]}" ]]; then
        diff_keys+=("$k")
    fi
done

if [[ ${#only_a[@]} -gt 0 ]]; then
    echo ""
    echo "── Doar in A ($NAME_A) ──"
    for k in "${only_a[@]}"; do
        printf "  %-25s = \"%s\"\n" "$k" "${MAP_A[$k]}"
    done
fi

if [[ ${#only_b[@]} -gt 0 ]]; then
    echo ""
    echo "── Doar in B ($NAME_B) ──"
    for k in "${only_b[@]}"; do
        printf "  %-25s = \"%s\"\n" "$k" "${MAP_B[$k]}"
    done
fi

if [[ ${#diff_keys[@]} -gt 0 ]]; then
    echo ""
    echo "── Valori diferite ──"
    printf "  %-25s %-30s %-30s\n" "KEY" "A ($NAME_A)" "B ($NAME_B)"
    printf "  %-25s %-30s %-30s\n" "---" "---" "---"
    for k in "${diff_keys[@]}"; do
        printf "  %-25s %-30s %-30s\n" "$k" "\"${MAP_A[$k]}\"" "\"${MAP_B[$k]}\""
    done
fi

if [[ ${#only_a[@]} -eq 0 ]] && [[ ${#only_b[@]} -eq 0 ]] && [[ ${#diff_keys[@]} -eq 0 ]]; then
    echo ""
    echo "  Profilele sunt identice."
    exit 0
fi

echo ""
echo "── Sumar ──"
echo "  Doar in A:        ${#only_a[@]}"
echo "  Doar in B:        ${#only_b[@]}"
echo "  Valori diferite:  ${#diff_keys[@]}"

# Exit 1 daca exista diferente (util in scripturi)
[[ ${#only_a[@]} -gt 0 || ${#only_b[@]} -gt 0 || ${#diff_keys[@]} -gt 0 ]] && exit 1
exit 0
