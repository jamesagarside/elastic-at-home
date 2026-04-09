#!/usr/bin/env bash
# =============================================================================
# Local Test Runner for Elastic at Home
# =============================================================================
#
# Run the full test suite locally against each deployment mode.
# This script handles environment setup, stack deployment, testing,
# and teardown for whichever mode(s) you specify.
#
# Usage:
#   ./scripts/test-local.sh [mode]      # Test a single mode
#   ./scripts/test-local.sh all         # Test all modes sequentially
#   ./scripts/test-local.sh --help      # Show help
#
# Modes:
#   selfsigned  - Hostname routing with self-signed certificates (default)
#   direct      - Port-based routing via IP address
#   letsencrypt - Config validation, or full deploy if credentials provided
#   all         - Run all modes (letsencrypt uses credentials if available)
#
# Examples:
#   ./scripts/test-local.sh selfsigned
#   ./scripts/test-local.sh direct
#   ./scripts/test-local.sh all
#   STACK_VERSION=8.17.0 ./scripts/test-local.sh selfsigned
#
#   # Full Let's Encrypt test (requires Cloudflare DNS record pointing to your machine):
#   LE_DOMAIN=siem.example.com CF_DNS_API_TOKEN=your-token ./scripts/test-local.sh letsencrypt
#
# Note: On macOS with Docker Desktop, running 'all' mode may experience port
# release delays between stack teardowns. If the second mode fails with
# connection errors, run each mode individually instead.
#
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colours
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configurable via environment
STACK_VERSION="${STACK_VERSION:-9.3.2}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-TestPassword123!}"
KIBANA_PASSWORD="${KIBANA_PASSWORD:-TestPassword123!}"
APM_SECRET_TOKEN="${APM_SECRET_TOKEN:-TestAPMToken123!}"
TIMEOUT="${TIMEOUT:-600}"

# Track results
RESULT_SELFSIGNED=""
RESULT_DIRECT=""
RESULT_LETSENCRYPT=""

# =============================================================================
# Helpers
# =============================================================================

usage() {
    echo "Usage: $0 [mode]"
    echo ""
    echo "Modes:"
    echo "  selfsigned   Test self-signed certificate mode (default)"
    echo "  direct       Test direct port-based access mode"
    echo "  letsencrypt  Validate config, or full deploy if LE_DOMAIN + CF_DNS_API_TOKEN set"
    echo "  all          Run all modes"
    echo ""
    echo "Environment variables:"
    echo "  STACK_VERSION      Elastic Stack version (default: $STACK_VERSION)"
    echo "  ELASTIC_PASSWORD   Elastic user password (default: TestPassword123!)"
    echo "  TIMEOUT            Max wait time in seconds (default: 600)"
    echo "  LE_DOMAIN          Base domain for Let's Encrypt (e.g., siem.example.com)"
    echo "  CF_DNS_API_TOKEN   Cloudflare API token for DNS challenge"
    echo "  ACME_EMAIL         Email for Let's Encrypt registration"
    echo ""
    echo "Examples:"
    echo "  $0 selfsigned"
    echo "  $0 all"
    echo "  STACK_VERSION=8.17.0 $0 direct"
    echo "  LE_DOMAIN=siem.example.com CF_DNS_API_TOKEN=xxx $0 letsencrypt"
}

log_header() {
    echo ""
    echo -e "${BLUE}================================================================${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}================================================================${NC}"
    echo ""
}

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }

check_prerequisites() {
    log_info "Checking prerequisites..."

    if ! command -v docker &>/dev/null; then
        log_error "Docker is not installed"
        exit 1
    fi

    if ! docker compose version &>/dev/null; then
        log_error "Docker Compose is not available"
        exit 1
    fi

    if ! command -v curl &>/dev/null; then
        log_error "curl is not installed"
        exit 1
    fi

    if ! command -v jq &>/dev/null; then
        log_error "jq is not installed (brew install jq / apt install jq)"
        exit 1
    fi

    # Check vm.max_map_count
    local map_count
    if [[ "$(uname)" == "Linux" ]]; then
        map_count=$(sysctl -n vm.max_map_count 2>/dev/null || echo "0")
        if [[ "$map_count" -lt 262144 ]]; then
            log_warn "vm.max_map_count is $map_count (needs >= 262144)"
            log_warn "Run: sudo sysctl -w vm.max_map_count=262144"
            exit 1
        fi
    fi

    # Validate .env.example is complete
    if [[ -f "$PROJECT_DIR/.github/scripts/validate-env.sh" ]]; then
        log_info "Validating .env.example..."
        if bash "$PROJECT_DIR/.github/scripts/validate-env.sh" > /dev/null 2>&1; then
            log_success ".env.example is complete"
        else
            log_error ".env.example has missing variables. Run: bash .github/scripts/validate-env.sh"
            exit 1
        fi
    fi

    log_success "All prerequisites met"
}

# =============================================================================
# Stack Lifecycle
# =============================================================================

teardown() {
    log_info "Tearing down stack..."
    cd "$PROJECT_DIR"
    docker compose down -v --remove-orphans 2>/dev/null || true
    rm -f "$PROJECT_DIR/.env" "$PROJECT_DIR/ca.crt"
    log_info "Stack torn down"
}

write_env() {
    local mode="$1"
    local es_domain="${2:-es.test.local}"
    local kibana_domain="${3:-kibana.test.local}"
    local fleet_domain="${4:-fleet.test.local}"
    local apm_domain="${5:-apm.test.local}"
    local traefik_domain="${6:-proxy.test.local}"

    local env_example="$PROJECT_DIR/.env.example"

    if [[ ! -f "$env_example" ]]; then
        log_error ".env.example not found - cannot derive test environment"
        return 1
    fi

    # Start from .env.example (strip comments and blank lines, keep all vars)
    grep -E '^[A-Z_]+=' "$env_example" > "$PROJECT_DIR/.env"

    # Apply test overrides using perl for cross-platform compatibility.
    # This ensures we test with every variable from .env.example,
    # and any new variable added there is automatically included.
    local overrides=(
        "INGRESS_MODE=${mode}"
        "ACME_EMAIL=test@example.com"
        "CF_DNS_API_TOKEN="
        "ELASTIC_PASSWORD=${ELASTIC_PASSWORD}"
        "KIBANA_PASSWORD=${KIBANA_PASSWORD}"
        "APM_SECRET_TOKEN=${APM_SECRET_TOKEN}"
        "STACK_VERSION=${STACK_VERSION}"
        "CLUSTER_NAME=test-cluster"
        "LICENSE=basic"
        "ES_DOMAIN_NAME=${es_domain}"
        "KIBANA_DOMAIN_NAME=${kibana_domain}"
        "FLEET_DOMAIN_NAME=${fleet_domain}"
        "APM_DOMAIN_NAME=${apm_domain}"
        "AGENT_DOMAIN_NAME=agent.test.local"
        "TRAEFIK_DOMAIN_NAME=${traefik_domain}"
        "TRAEFIK_IP="
        "ALLOWED_SYSLOG_IPS=10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
        "KB_MEM_LIMIT=1073741824"
        "ES_MEM_LIMIT=2147483648"
        "FLEET_MEM_LIMIT=1073741824"
        "AGENT_MEM_LIMIT=1073741824"
        "KB_SECURITY_ENCRYPTIONKEY=$(openssl rand -hex 16)"
        "KB_REPORTING_ENCRYPTIONKEY=$(openssl rand -hex 16)"
        "KB_OBJECTS_ENCRYPTIONKEY=$(openssl rand -hex 16)"
    )

    # Mode-specific overrides
    if [[ "$mode" == "direct" ]]; then
        overrides+=(
            "EXTERNAL_ES_PORT=9200"
            "EXTERNAL_FLEET_PORT=8220"
            "EXTERNAL_APM_PORT=8200"
        )
    fi

    for override in "${overrides[@]}"; do
        local key="${override%%=*}"
        local value="${override#*=}"
        if grep -q "^${key}=" "$PROJECT_DIR/.env"; then
            perl -pi -e "s|^${key}=.*|${key}=${value}|" "$PROJECT_DIR/.env"
        else
            echo "${key}=${value}" >> "$PROJECT_DIR/.env"
        fi
    done
}

wait_for_healthy() {
    local container="$1"
    local label="$2"
    local timeout_secs="${3:-$TIMEOUT}"

    log_info "Waiting for $label to be healthy (timeout: ${timeout_secs}s)..."

    local elapsed=0
    while [[ $elapsed -lt $timeout_secs ]]; do
        local health
        health=$(docker inspect --format="{{.State.Health.Status}}" "$container" 2>/dev/null || echo "not_found")

        case "$health" in
            healthy)
                log_success "$label is healthy"
                return 0
                ;;
            not_found)
                # Container might not exist yet
                ;;
            *)
                if (( elapsed % 30 == 0 )); then
                    log_info "$label status: $health (${elapsed}s elapsed)"
                fi
                ;;
        esac

        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "$label did not become healthy within ${timeout_secs}s"
    return 1
}

deploy_and_wait() {
    log_info "Starting Elastic Stack (version: $STACK_VERSION)..."
    cd "$PROJECT_DIR"
    docker compose up -d

    wait_for_healthy "elastic-at-home-es01-1" "Elasticsearch" || return 1
    wait_for_healthy "elastic-at-home-kibana-1" "Kibana" || return 1
    wait_for_healthy "elastic-at-home-fleet-server-1" "Fleet Server" || return 1

    log_info "Waiting 30s for agent enrolment..."
    sleep 30

    # Extract CA certificate
    docker compose cp setup:/usr/share/elasticsearch/config/certs/ca/ca.crt "$PROJECT_DIR/ca.crt" 2>/dev/null || true

    # When LLM is enabled, the setup container has extra work to do: wait for
    # Ollama to pull the model, register the ES inference endpoint, activate
    # the trial licence, and create the Kibana GenAI connector. The first-run
    # model pull can take several minutes on a cold volume, so the LLM tests
    # will fail if they run before setup finishes. Block until the inference
    # endpoint exists in ES (or give up after 10 minutes).
    local enable_llm="false"
    if [[ -f "$PROJECT_DIR/.env" ]]; then
        enable_llm=$(grep -E '^ENABLE_LLM=' "$PROJECT_DIR/.env" | cut -d= -f2 || echo "false")
    fi
    if [[ "$enable_llm" == "true" ]]; then
        log_info "LLM enabled — waiting for Ollama model pull and setup to register the inference endpoint..."
        local llm_waited=0
        local llm_timeout=600
        local ca="$PROJECT_DIR/ca.crt"
        while [[ $llm_waited -lt $llm_timeout ]]; do
            # Authoritative signal: the endpoint is actually queryable in ES.
            # The setup container's log line "already exists or pending" is
            # emitted for both success and silent failure, so don't trust it.
            local status
            status=$(curl -s -o /dev/null -w "%{http_code}" \
                --cacert "$ca" \
                -u "elastic:${ELASTIC_PASSWORD}" \
                --connect-timeout 5 \
                "https://localhost:9200/_inference/completion/local-llm" 2>/dev/null || echo "000")
            # Fallback for direct mode where 9200 goes via Traefik but curl to
            # Traefik's ES entrypoint still works with the same CA.
            if [[ "$status" == "200" ]]; then
                log_success "ES inference endpoint ready after ${llm_waited}s"
                break
            fi
            sleep 15
            llm_waited=$((llm_waited + 15))
            if (( llm_waited % 60 == 0 )); then
                log_info "Still waiting for LLM setup (${llm_waited}s/${llm_timeout}s, last ES status: $status)..."
            fi
        done
        if [[ $llm_waited -ge $llm_timeout ]]; then
            log_warn "LLM setup did not complete within ${llm_timeout}s — LLM tests may fail"
            log_info "Setup container tail:"
            docker compose logs setup --tail=20 2>&1 | tail -20
        fi
    fi

    log_success "Stack is running"
}

run_test_suite() {
    local es_url="$1"
    local kibana_url="$2"
    local fleet_url="$3"
    local mode="$4"
    local llm_url="${5:-}"

    export ELASTICSEARCH_URL="$es_url"
    export KIBANA_URL="$kibana_url"
    export FLEET_URL="$fleet_url"
    export ELASTIC_PASSWORD
    export CA_CERT="$PROJECT_DIR/ca.crt"
    export INGRESS_MODE="$mode"

    # When a caller supplies an LLM URL, expose it to the test-stack harness
    # so the Ollama / ingress tests can actually probe the endpoint instead of
    # falling back to skip/fail.
    if [[ -n "$llm_url" ]]; then
        # Propagate ENABLE_LLM / ENABLE_LLM_INGRESS from .env so test-stack
        # decides whether to run or skip the LLM-specific tests.
        if [[ -f "$PROJECT_DIR/.env" ]]; then
            local enable_llm enable_llm_ingress
            enable_llm=$(grep -E '^ENABLE_LLM=' "$PROJECT_DIR/.env" | cut -d= -f2)
            enable_llm_ingress=$(grep -E '^ENABLE_LLM_INGRESS=' "$PROJECT_DIR/.env" | cut -d= -f2)
            export ENABLE_LLM="${enable_llm:-false}"
            export ENABLE_LLM_INGRESS="${enable_llm_ingress:-false}"
        fi
        export OLLAMA_URL="$llm_url"
        export LLM_INGRESS_URL="$llm_url"
    fi

    bash "$PROJECT_DIR/.github/scripts/test-stack.sh" all
}

collect_logs_on_failure() {
    echo ""
    log_error "Collecting failure logs..."
    echo ""
    echo "--- Container Status ---"
    docker compose ps -a 2>/dev/null || true
    echo ""
    echo "--- Recent Logs (last 30 lines per service) ---"
    for svc in setup es01 kibana fleet-server agent traefik; do
        echo ""
        echo "=== $svc ==="
        docker compose logs "$svc" --tail=30 2>/dev/null || echo "(no logs)"
    done
}

# =============================================================================
# Mode Tests
# =============================================================================

wait_for_ports_free() {
    log_info "Waiting for ports to be released (Docker Desktop can be slow)..."
    local max_wait=90
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local busy=false
        for port in 443 80 9200 5601 8220 8200 514 8080; do
            if lsof -i ":$port" -sTCP:LISTEN > /dev/null 2>&1; then
                busy=true
                break
            fi
        done
        if ! $busy; then
            log_success "All ports free after ${waited}s"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
        if (( waited % 15 == 0 )); then
            log_info "Still waiting for ports (${waited}s/${max_wait}s)..."
        fi
    done
    log_warn "Some ports may still be in use after ${max_wait}s - proceeding anyway"
    return 0
}

test_selfsigned() {
    log_header "Testing Self-Signed Mode"

    # Check /etc/hosts
    local needs_hosts=false
    for domain in es.test.local kibana.test.local fleet.test.local apm.test.local proxy.test.local; do
        if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
            needs_hosts=true
            break
        fi
    done

    if $needs_hosts; then
        log_warn "Self-signed mode requires /etc/hosts entries for hostname routing."
        log_warn "Adding entries (requires sudo)..."
        echo ""
        echo "  127.0.0.1 es.test.local kibana.test.local fleet.test.local apm.test.local proxy.test.local"
        echo ""
        if echo "127.0.0.1 es.test.local kibana.test.local fleet.test.local apm.test.local proxy.test.local" \
            | sudo tee -a /etc/hosts > /dev/null 2>&1; then
            log_success "Hosts entries added"
        else
            log_error "Cannot test self-signed mode without /etc/hosts entries"
            log_warn "Run manually: echo '127.0.0.1 es.test.local kibana.test.local fleet.test.local apm.test.local proxy.test.local' | sudo tee -a /etc/hosts"
            return 1
        fi
    fi

    teardown
    wait_for_ports_free
    write_env "selfsigned" "es.test.local" "kibana.test.local" "fleet.test.local" "apm.test.local" "proxy.test.local"

    if ! deploy_and_wait; then
        collect_logs_on_failure
        teardown
        return 1
    fi

    local result=0
    run_test_suite "https://es.test.local" "https://kibana.test.local" "https://fleet.test.local" "selfsigned" || result=1

    teardown

    if [[ $result -eq 0 ]]; then
        log_success "Self-signed mode: ALL TESTS PASSED"
    else
        log_error "Self-signed mode: SOME TESTS FAILED"
    fi
    return $result
}

test_direct() {
    log_header "Testing Direct Access Mode"

    teardown
    wait_for_ports_free
    write_env "direct" "es.local" "kibana.local" "fleet.local" "apm.local" "traefik.local"

    if ! deploy_and_wait; then
        collect_logs_on_failure
        teardown
        return 1
    fi

    # Verify direct port access works before running full suite
    log_info "Verifying direct port connectivity..."
    local ca="$PROJECT_DIR/ca.crt"
    log_info "CA cert exists: $(test -f "$ca" && echo "yes ($(wc -c < "$ca") bytes)" || echo "no")"

    local retries=12
    for ((i=1; i<=retries; i++)); do
        local es_status
        # Try with CA cert first, then insecure as fallback
        es_status=$(curl -s -o /dev/null -w "%{http_code}" --cacert "$ca" --connect-timeout 5 https://localhost:9200 2>/dev/null || echo "000")
        if [[ "$es_status" == "000" ]]; then
            es_status=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 https://localhost:9200 2>/dev/null || echo "000")
        fi
        if [[ "$es_status" =~ ^[1-5][0-9][0-9]$ ]]; then
            log_success "Direct port access confirmed (ES returned HTTP $es_status)"
            break
        fi
        if [[ $i -lt $retries ]]; then
            log_info "Port not ready yet (attempt $i/$retries, got $es_status), waiting 10s..."
            sleep 10
        else
            log_error "Direct port access not working after ${retries} attempts"
            log_warn "Traefik entrypoints:"
            docker compose logs traefik 2>/dev/null | grep -i "entrypoint\|listen\|error" | tail -10
            collect_logs_on_failure
            teardown
            return 1
        fi
    done

    local result=0
    run_test_suite "https://localhost:9200" "https://localhost:5601" "https://localhost:8220" "direct" "https://localhost:11434" || result=1

    teardown

    if [[ $result -eq 0 ]]; then
        log_success "Direct mode: ALL TESTS PASSED"
    else
        log_error "Direct mode: SOME TESTS FAILED"
    fi
    return $result
}

test_letsencrypt() {
    log_header "Testing Let's Encrypt Mode"

    # Check if credentials are provided for a full deploy test
    local le_domain="${LE_DOMAIN:-}"
    local cf_token="${CF_DNS_API_TOKEN:-}"
    local acme_email="${ACME_EMAIL:-test@example.com}"

    if [[ -n "$le_domain" && -n "$cf_token" ]]; then
        log_info "Credentials provided - running full Let's Encrypt deploy and test"
        log_info "Domain: $le_domain"
        _test_letsencrypt_full "$le_domain" "$cf_token" "$acme_email"
    else
        log_info "No LE_DOMAIN or CF_DNS_API_TOKEN set - running config validation only."
        log_info "For a full test, run:"
        log_info "  LE_DOMAIN=siem.example.com CF_DNS_API_TOKEN=your-token ./scripts/test-local.sh letsencrypt"
        _test_letsencrypt_config_only
    fi
}

_test_letsencrypt_config_only() {
    teardown

    # Write a dummy env for config validation
    write_env "letsencrypt" "es.example.com" "kibana.example.com" "fleet.example.com" "apm.example.com" "proxy.example.com"
    # letsencrypt needs a non-empty token to avoid compose warnings
    perl -pi -e 's/^CF_DNS_API_TOKEN=$/CF_DNS_API_TOKEN=placeholder/' "$PROJECT_DIR/.env"

    cd "$PROJECT_DIR"
    local result=0

    # Validate compose config parses
    log_info "Validating Docker Compose configuration..."
    if docker compose config > /dev/null 2>&1; then
        log_success "Docker Compose configuration is valid"
    else
        log_error "Docker Compose configuration is invalid"
        result=1
    fi

    # Verify correct Traefik config is referenced
    if grep -q "INGRESS_MODE=letsencrypt" "$PROJECT_DIR/.env" && \
       [[ -f "$PROJECT_DIR/configurations/traefik/traefik-letsencrypt.yml" ]]; then
        log_success "Correct Traefik configuration file selected (traefik-letsencrypt.yml)"
    else
        log_error "Wrong Traefik configuration or INGRESS_MODE"
        result=1
    fi

    # Verify ACME resolver exists
    if grep -q "certificatesResolvers" "$PROJECT_DIR/configurations/traefik/traefik-letsencrypt.yml"; then
        log_success "ACME certificate resolver configured"
    else
        log_error "ACME certificate resolver missing"
        result=1
    fi

    # Verify dynamic config exists
    if [[ -f "$PROJECT_DIR/configurations/traefik/traefik-letsencrypt-dynamic.yaml" ]]; then
        log_success "Dynamic configuration file exists"
    else
        log_error "Dynamic configuration file missing"
        result=1
    fi

    # Verify mode-specific env file exists
    if [[ -f "$PROJECT_DIR/configurations/elastic/env_files/.env.letsencrypt" ]]; then
        log_success "Mode-specific environment file exists"
    else
        log_error "Mode-specific environment file missing"
        result=1
    fi

    rm -f "$PROJECT_DIR/.env"

    if [[ $result -eq 0 ]]; then
        log_success "Let's Encrypt config: ALL CHECKS PASSED"
    else
        log_error "Let's Encrypt config: SOME CHECKS FAILED"
    fi
    return $result
}

_test_letsencrypt_full() {
    local base_domain="$1"
    local cf_token="$2"
    local acme_email="$3"

    local es_domain="elasticsearch.${base_domain}"
    local kibana_domain="kibana.${base_domain}"
    local fleet_domain="fleet.${base_domain}"
    local apm_domain="apm.${base_domain}"
    local traefik_domain="proxy.${base_domain}"

    # Set up /etc/hosts for the domains
    local needs_hosts=false
    for domain in "$es_domain" "$kibana_domain" "$fleet_domain" "$apm_domain" "$traefik_domain"; do
        if ! grep -q "$domain" /etc/hosts 2>/dev/null; then
            needs_hosts=true
            break
        fi
    done

    if $needs_hosts; then
        log_warn "Adding /etc/hosts entries for Let's Encrypt domains (requires sudo)..."
        echo "127.0.0.1 ${es_domain} ${kibana_domain} ${fleet_domain} ${apm_domain} ${traefik_domain}" \
            | sudo tee -a /etc/hosts > /dev/null 2>&1 || {
            log_error "Failed to add /etc/hosts entries"
            return 1
        }
        log_success "Hosts entries added"
    fi

    teardown
    wait_for_ports_free

    # Write env with real credentials
    write_env "letsencrypt" "$es_domain" "$kibana_domain" "$fleet_domain" "$apm_domain" "$traefik_domain"
    # Override the CF token and ACME email with real values
    perl -pi -e "s/^CF_DNS_API_TOKEN=$/CF_DNS_API_TOKEN=${cf_token}/" "$PROJECT_DIR/.env"
    perl -pi -e "s/^ACME_EMAIL=.*/ACME_EMAIL=${acme_email}/" "$PROJECT_DIR/.env"

    if ! deploy_and_wait; then
        collect_logs_on_failure
        teardown
        return 1
    fi

    # Wait for certificate issuance
    log_info "Waiting for Let's Encrypt certificate (this may take a few minutes)..."
    local cert_timeout=300
    local cert_waited=0
    local cert_obtained=false

    while [[ $cert_waited -lt $cert_timeout ]]; do
        # Detect issuance via log message (best-effort; phrasing varies between
        # Traefik versions) OR by probing TLS and checking for a real LE issuer.
        if docker compose logs traefik 2>&1 | grep -qE "Certificate obtained|Adding certificate|Register.*account|Domains.*certif"; then
            log_success "Let's Encrypt certificate obtained (log match)"
            cert_obtained=true
            break
        fi
        if echo | openssl s_client -connect "${kibana_domain}:443" -servername "${kibana_domain}" 2>/dev/null \
            | openssl x509 -noout -issuer 2>/dev/null | grep -qiE "let.?s.?encrypt|O=Let's Encrypt"; then
            log_success "Let's Encrypt certificate obtained (TLS probe)"
            cert_obtained=true
            break
        fi
        if docker compose logs traefik 2>&1 | grep -qE "(unable to obtain|ACME error|challenge failed)"; then
            log_error "Certificate issuance failed"
            docker compose logs traefik 2>&1 | grep -iE "(acme|cert|error)" | tail -10
            teardown
            return 1
        fi
        sleep 15
        cert_waited=$((cert_waited + 15))
        if (( cert_waited % 60 == 0 )); then
            log_info "Still waiting for certificate (${cert_waited}s/${cert_timeout}s)..."
        fi
    done

    if ! $cert_obtained; then
        log_warn "Certificate not confirmed in logs, but proceeding with test..."
    fi

    # Verify the certificate is from Let's Encrypt
    local issuer
    issuer=$(echo | openssl s_client -connect "${kibana_domain}:443" -servername "${kibana_domain}" 2>/dev/null \
        | openssl x509 -noout -issuer 2>/dev/null || echo "unknown")
    log_info "Certificate issuer: $issuer"

    if echo "$issuer" | grep -qiE "(let.?s.?encrypt|letsencrypt|R[0-9]+|E[0-9]+)"; then
        log_success "Certificate is from Let's Encrypt"
    else
        log_warn "Certificate may not be from Let's Encrypt (could be staging or self-signed fallback)"
    fi

    local result=0
    # No CA_CERT needed - Let's Encrypt certs are publicly trusted
    export CA_CERT=""
    run_test_suite "https://${es_domain}" "https://${kibana_domain}" "https://${fleet_domain}" "letsencrypt" || result=1

    teardown

    if [[ $result -eq 0 ]]; then
        log_success "Let's Encrypt mode: ALL TESTS PASSED"
    else
        log_error "Let's Encrypt mode: SOME TESTS FAILED"
    fi
    return $result
}

# =============================================================================
# Main
# =============================================================================

main() {
    local mode="${1:-selfsigned}"

    if [[ "$mode" == "--help" || "$mode" == "-h" ]]; then
        usage
        exit 0
    fi

    log_header "Elastic at Home - Local Test Runner"
    echo "  Stack Version: $STACK_VERSION"
    echo "  Test Mode:     $mode"
    echo ""

    check_prerequisites

    # Ensure we clean up on exit
    trap 'teardown 2>/dev/null || true' EXIT

    local overall_result=0

    case "$mode" in
        selfsigned)
            test_selfsigned && RESULT_SELFSIGNED=0 || { RESULT_SELFSIGNED=1; overall_result=1; }
            ;;
        direct)
            test_direct && RESULT_DIRECT=0 || { RESULT_DIRECT=1; overall_result=1; }
            ;;
        letsencrypt)
            test_letsencrypt && RESULT_LETSENCRYPT=0 || { RESULT_LETSENCRYPT=1; overall_result=1; }
            ;;
        all)
            # Run direct first - it doesn't need /etc/hosts and avoids the
            # Docker Desktop macOS port release delay that occurs when switching
            # from selfsigned (hostname routing on :443) to direct (port routing).
            test_direct && RESULT_DIRECT=0 || { RESULT_DIRECT=1; overall_result=1; }
            test_selfsigned && RESULT_SELFSIGNED=0 || { RESULT_SELFSIGNED=1; overall_result=1; }
            test_letsencrypt && RESULT_LETSENCRYPT=0 || { RESULT_LETSENCRYPT=1; overall_result=1; }
            ;;
        *)
            log_error "Unknown mode: $mode"
            usage
            exit 1
            ;;
    esac

    # Print summary
    log_header "Test Summary"
    for m in selfsigned direct letsencrypt; do
        eval "result=\$RESULT_$(echo "$m" | tr '[:lower:]' '[:upper:]')"
        if [[ -z "$result" ]]; then
            continue
        elif [[ "$result" -eq 0 ]]; then
            log_success "$m"
        else
            log_error "$m"
        fi
    done

    echo ""
    if [[ $overall_result -eq 0 ]]; then
        echo -e "${GREEN}All tests passed.${NC}"
    else
        echo -e "${RED}Some tests failed.${NC}"
    fi

    # Disable the trap since we already cleaned up
    trap - EXIT
    exit $overall_result
}

main "$@"
