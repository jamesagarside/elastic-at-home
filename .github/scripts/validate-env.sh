#!/usr/bin/env bash
# =============================================================================
# Validate .env.example completeness
# =============================================================================
#
# Checks that every ${VAR} referenced in Docker Compose files and
# configuration templates has a corresponding entry in .env.example.
#
# Usage:
#   bash .github/scripts/validate-env.sh
#
# Exit codes:
#   0 - All variables accounted for
#   1 - Missing variables found
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

ENV_EXAMPLE="$PROJECT_DIR/.env.example"

if [[ ! -f "$ENV_EXAMPLE" ]]; then
    echo -e "${RED}[FAIL]${NC} .env.example not found"
    exit 1
fi

# Extract variable names defined in .env.example (uncommented lines with KEY=value)
defined_vars=$(grep -E '^[A-Z_]+=' "$ENV_EXAMPLE" | cut -d= -f1 | sort -u)

# Extract variable names referenced in compose files and configs
# Matches ${VAR_NAME} and ${VAR_NAME:-default} patterns
referenced_vars=$(grep -rohE '\$\{[A-Z_]+' \
    "$PROJECT_DIR"/docker-compose*.yaml \
    "$PROJECT_DIR"/configurations/elastic/fleet-configuration.yaml \
    2>/dev/null \
    | sed 's/\${//' \
    | sort -u)

# Variables that have inline defaults (${VAR:-default}) are optional in .env.example
# but we still want to document them. Collect vars with defaults for reporting.
vars_with_defaults=$(grep -rohE '\$\{[A-Z_]+:-' \
    "$PROJECT_DIR"/docker-compose*.yaml \
    "$PROJECT_DIR"/configurations/elastic/fleet-configuration.yaml \
    2>/dev/null \
    | sed 's/\${//; s/:-$//' \
    | sort -u)

missing=()
optional_missing=()
result=0

for var in $referenced_vars; do
    if ! echo "$defined_vars" | grep -qx "$var"; then
        # Check if it has an inline default
        if echo "$vars_with_defaults" | grep -qx "$var"; then
            optional_missing+=("$var")
        else
            missing+=("$var")
        fi
    fi
done

# Report results
echo -e "${GREEN}[INFO]${NC} Validating .env.example completeness"
echo ""
echo "  Variables in .env.example:  $(echo "$defined_vars" | wc -l | tr -d ' ')"
echo "  Variables in compose files: $(echo "$referenced_vars" | wc -l | tr -d ' ')"
echo ""

if [[ ${#missing[@]} -gt 0 ]]; then
    echo -e "${RED}[FAIL]${NC} Missing from .env.example (no default in compose):"
    for var in "${missing[@]}"; do
        echo -e "  ${RED}-${NC} $var"
        # Show where it's used
        grep -rn "\${${var}" "$PROJECT_DIR"/docker-compose*.yaml "$PROJECT_DIR"/configurations/ 2>/dev/null \
            | head -2 | sed 's/^/    /'
    done
    result=1
    echo ""
fi

if [[ ${#optional_missing[@]} -gt 0 ]]; then
    echo -e "${YELLOW}[WARN]${NC} Missing from .env.example (has inline default):"
    for var in "${optional_missing[@]}"; do
        echo -e "  ${YELLOW}-${NC} $var"
    done
    echo ""
fi

# Also check for vars in .env.example that aren't used anywhere (stale)
stale=()
for var in $defined_vars; do
    if ! echo "$referenced_vars" | grep -qx "$var"; then
        stale+=("$var")
    fi
done

if [[ ${#stale[@]} -gt 0 ]]; then
    echo -e "${YELLOW}[WARN]${NC} Defined in .env.example but not referenced in compose:"
    for var in "${stale[@]}"; do
        echo -e "  ${YELLOW}-${NC} $var"
    done
    echo ""
fi

# -----------------------------------------------------------------------------
# ALLOWED_SYSLOG_IPS must be a single IP or CIDR
# -----------------------------------------------------------------------------
# It is interpolated into Traefik's ClientIP matcher:
#     traefik.tcp.routers.agent-tcp.rule=ClientIP(`${ALLOWED_SYSLOG_IPS}`)
# Traefik v3's ClientIP matcher accepts exactly one value. A comma-separated
# list fails to parse, so Traefik drops the syslog-tcp router and syslog stops
# being routed — with no failure visible from the stack's own tests. Catch it
# here instead.
# -----------------------------------------------------------------------------
validate_syslog_ips() {
    local env_file="$1"
    [[ -f "$env_file" ]] || return 0

    local value
    value=$(grep -E '^ALLOWED_SYSLOG_IPS=' "$env_file" | tail -1 | cut -d= -f2- | tr -d '[:space:]' || true)
    [[ -n "$value" ]] || return 0

    if [[ "$value" == *,* || "$value" == *" "* ]]; then
        echo -e "${RED}[FAIL]${NC} $(basename "$env_file"): ALLOWED_SYSLOG_IPS must be a single IP or CIDR"
        echo -e "  got: ${RED}${value}${NC}"
        echo "  Traefik's ClientIP matcher takes one value — use a supernet (e.g. 10.0.0.0/8)."
        return 1
    fi

    # Basic shape check: IPv4 address with an optional /prefix.
    if [[ ! "$value" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$ ]]; then
        echo -e "${YELLOW}[WARN]${NC} $(basename "$env_file"): ALLOWED_SYSLOG_IPS='${value}' is not a plain IPv4 address or CIDR"
        echo "  Traefik will reject it and drop the syslog-tcp router if it cannot be parsed."
    fi

    return 0
}

for env_file in "$ENV_EXAMPLE" "$PROJECT_DIR/.env"; do
    validate_syslog_ips "$env_file" || result=1
done
echo ""

if [[ $result -eq 0 ]]; then
    echo -e "${GREEN}[PASS]${NC} Environment configuration looks good"
else
    echo -e "${RED}[FAIL]${NC} Environment configuration is invalid — see the failures above"
fi

exit $result
