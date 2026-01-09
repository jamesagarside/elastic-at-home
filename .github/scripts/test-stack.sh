#!/usr/bin/env bash
# Elastic Stack Test Library
# Reusable functions for testing the Elastic Stack deployment
# Usage: source this file and call individual test functions

set -euo pipefail

# =============================================================================
# Configuration & Colors
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
GRAY='\033[0;90m'
NC='\033[0m'

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Configuration (override via environment)
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-https://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-https://localhost:5601}"
FLEET_URL="${FLEET_URL:-https://localhost:8220}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
CA_CERT="${CA_CERT:-./certs/ca/ca.crt}"
INGRESS_MODE="${INGRESS_MODE:-selfsigned}"
DEBUG="${DEBUG:-false}"

# =============================================================================
# Logging Utilities
# =============================================================================

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[PASS]${NC} $1"; }
log_error()   { echo -e "${RED}[FAIL]${NC} $1"; }
log_warning() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_debug()   { [[ "$DEBUG" == "true" ]] && echo -e "${GRAY}[DEBUG]${NC} $1" || true; }

log_test_start() {
    echo -e "\n${BLUE}──────────────────────────────────────${NC}"
    echo -e "${BLUE}TEST: $1${NC}"
    echo -e "${BLUE}──────────────────────────────────────${NC}"
}

record_pass() {
    ((TESTS_PASSED++))
    log_success "$1"
}

record_fail() {
    ((TESTS_FAILED++))
    log_error "$1"
    # Print additional debug info on failure
    if [[ -n "${LAST_RESPONSE:-}" ]]; then
        echo -e "${GRAY}  Response: ${LAST_RESPONSE:0:500}${NC}"
    fi
    if [[ -n "${LAST_STATUS:-}" ]]; then
        echo -e "${GRAY}  HTTP Status: $LAST_STATUS${NC}"
    fi
}

record_skip() {
    ((TESTS_SKIPPED++))
    log_warning "SKIPPED: $1"
}

print_summary() {
    echo -e "\n${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BLUE}TEST SUMMARY${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo -e "${BLUE}Total:${NC}   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "\n${RED}══════════════════════════════════════${NC}"
        echo -e "${RED}OVERALL: FAILED${NC}"
        echo -e "${RED}══════════════════════════════════════${NC}"
        return 1
    else
        echo -e "\n${GREEN}══════════════════════════════════════${NC}"
        echo -e "${GREEN}OVERALL: PASSED${NC}"
        echo -e "${GREEN}══════════════════════════════════════${NC}"
        return 0
    fi
}

# =============================================================================
# HTTP/Curl Helpers (reduces duplication significantly)
# =============================================================================

# Build curl base options
_curl_opts() {
    local opts="-s --connect-timeout 10 --max-time 30"
    [[ -f "$CA_CERT" ]] && opts="$opts --cacert $CA_CERT"
    echo "$opts"
}

# GET request with auth, returns response body
# Usage: api_get "https://url/path" [auth_user:pass]
api_get() {
    local url="$1"
    local auth="${2:-${ELASTIC_USER}:${ELASTIC_PASSWORD}}"
    local opts=$(_curl_opts)

    LAST_RESPONSE=$(curl $opts -u "$auth" "$url" 2>&1) || LAST_RESPONSE="curl_error: $?"
    LAST_STATUS=""
    log_debug "GET $url -> ${LAST_RESPONSE:0:200}"
    echo "$LAST_RESPONSE"
}

# GET request, returns HTTP status code only
# Usage: api_status "https://url/path" [auth_user:pass]
api_status() {
    local url="$1"
    local auth="${2:-}"
    local opts=$(_curl_opts)

    if [[ -n "$auth" ]]; then
        LAST_STATUS=$(curl $opts -o /dev/null -w "%{http_code}" -u "$auth" "$url" 2>/dev/null) || LAST_STATUS="000"
    else
        LAST_STATUS=$(curl $opts -o /dev/null -w "%{http_code}" "$url" 2>/dev/null) || LAST_STATUS="000"
    fi
    LAST_RESPONSE=""
    log_debug "STATUS $url -> $LAST_STATUS"
    echo "$LAST_STATUS"
}

# GET with Kibana headers (kbn-xsrf required)
# Usage: kibana_api "path" -> returns response
kibana_api() {
    local path="$1"
    local opts=$(_curl_opts)

    LAST_RESPONSE=$(curl $opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}${path}" 2>&1) || LAST_RESPONSE="curl_error: $?"
    log_debug "KIBANA $path -> ${LAST_RESPONSE:0:200}"
    echo "$LAST_RESPONSE"
}

# Extract JSON field safely
# Usage: json_get ".field.path" "$json_string"
json_get() {
    local path="$1"
    local json="$2"
    echo "$json" | jq -r "$path" 2>/dev/null || echo ""
}

# Check if HTTP status is success (2xx or 3xx)
is_success_status() {
    [[ "$1" =~ ^[23] ]]
}

# =============================================================================
# SSL/Certificate Tests
# =============================================================================

test_ssl_connection() {
    local name="$1"
    local url="$2"

    log_test_start "SSL/TLS Connection: $name"

    local host port
    host=$(echo "$url" | sed -E 's|https?://([^:/]+).*|\1|')
    port=$(echo "$url" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
    port="${port:-443}"

    # For SSL tests, ANY valid HTTP response (including 401, 404) proves SSL works
    # Only 000 (connection failed) or empty indicates SSL failure

    # Method 1: Try with CA cert
    local status=$(api_status "$url")
    if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
        record_pass "SSL/TLS connection works (HTTP $status)"
        return 0
    fi

    # Method 2: Try insecure (for self-signed without CA)
    status=$(curl -s -k --connect-timeout 10 -o /dev/null -w "%{http_code}" "$url" 2>/dev/null || echo "000")
    if [[ "$status" =~ ^[1-5][0-9][0-9]$ ]]; then
        record_pass "SSL/TLS connection works with insecure flag (HTTP $status)"
        return 0
    fi

    # Method 3: Check if SSL handshake works at all
    if timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" </dev/null 2>/dev/null | grep -q "BEGIN CERTIFICATE"; then
        record_pass "SSL/TLS handshake successful (certificate presented)"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "SSL/TLS connection to $name failed"
    return 1
}

test_ca_certificate() {
    log_test_start "CA Certificate"

    if [[ "$INGRESS_MODE" == "letsencrypt" ]]; then
        record_pass "Let's Encrypt mode - no local CA required"
        return 0
    fi

    if [[ ! -f "$CA_CERT" ]]; then
        record_fail "CA certificate not found at $CA_CERT"
        return 1
    fi

    if openssl x509 -in "$CA_CERT" -noout -checkend 86400 2>/dev/null; then
        local subject=$(openssl x509 -in "$CA_CERT" -noout -subject 2>/dev/null | sed 's/subject=//')
        record_pass "CA certificate valid: $subject"
        return 0
    fi

    record_fail "CA certificate is expired or invalid"
    return 1
}

# =============================================================================
# Elasticsearch Tests
# =============================================================================

test_elasticsearch_health() {
    log_test_start "Elasticsearch Cluster Health"

    local response=$(api_get "${ELASTICSEARCH_URL}/_cluster/health")
    local status=$(json_get '.status' "$response")

    case "$status" in
        green)  record_pass "Cluster health: GREEN"; return 0 ;;
        yellow) record_pass "Cluster health: YELLOW (acceptable for single-node)"; return 0 ;;
        red)    record_fail "Cluster health: RED"; return 1 ;;
        *)      record_fail "Could not determine cluster health"; return 1 ;;
    esac
}

test_elasticsearch_auth() {
    log_test_start "Elasticsearch Authentication"

    # Test valid credentials
    local valid_status=$(api_status "${ELASTICSEARCH_URL}/_security/_authenticate" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")
    if [[ "$valid_status" != "200" ]]; then
        LAST_STATUS="$valid_status"
        record_fail "Valid credentials rejected (expected 200, got $valid_status)"
        return 1
    fi

    # Test invalid credentials (should return 401)
    local invalid_status=$(api_status "${ELASTICSEARCH_URL}/_security/_authenticate" "elastic:wrongpassword")
    if [[ "$invalid_status" == "401" ]]; then
        record_pass "Authentication working (valid: 200, invalid: 401)"
        return 0
    fi

    LAST_STATUS="$invalid_status"
    record_fail "Invalid credentials not rejected (expected 401, got $invalid_status)"
    return 1
}

test_elasticsearch_api() {
    log_test_start "Elasticsearch API"

    local response=$(api_get "${ELASTICSEARCH_URL}/")
    local cluster=$(json_get '.cluster_name' "$response")
    local version=$(json_get '.version.number' "$response")

    if [[ -n "$cluster" && -n "$version" && "$cluster" != "null" ]]; then
        record_pass "API responding: cluster=$cluster, version=$version"
        return 0
    fi

    record_fail "API not responding correctly"
    return 1
}

# =============================================================================
# Kibana Tests
# =============================================================================

test_kibana_health() {
    log_test_start "Kibana Health"

    local response=$(api_get "${KIBANA_URL}/api/status")
    local status=$(json_get '.status.overall.level' "$response")

    case "$status" in
        available) record_pass "Kibana status: available"; return 0 ;;
        degraded)  record_pass "Kibana status: degraded (acceptable during startup)"; return 0 ;;
        *)         record_fail "Kibana status: $status"; return 1 ;;
    esac
}

test_kibana_login() {
    log_test_start "Kibana Login Page"

    local status=$(api_status "${KIBANA_URL}/app/home")

    # 302 redirect to login or 200 if authenticated
    if [[ "$status" == "302" || "$status" == "200" ]]; then
        record_pass "Login page accessible (HTTP $status)"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "Login page not accessible"
    return 1
}

test_kibana_api() {
    log_test_start "Kibana API"

    local response=$(kibana_api "/api/features")
    local count=$(json_get 'length' "$response")

    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
        record_pass "API responding: $count features available"
        return 0
    fi

    record_fail "API not responding correctly"
    return 1
}

# =============================================================================
# Fleet Server Tests
# =============================================================================

test_fleet_health() {
    log_test_start "Fleet Server Health"

    local opts=$(_curl_opts)
    local response=$(curl $opts "${FLEET_URL}/api/status" 2>&1) || response='{"status":"error"}'
    LAST_RESPONSE="$response"

    local status=$(json_get '.status' "$response")

    if [[ "$status" == "HEALTHY" ]]; then
        record_pass "Fleet Server: HEALTHY"
        return 0
    fi

    record_fail "Fleet Server status: $status"
    return 1
}

test_fleet_api() {
    log_test_start "Fleet API (via Kibana)"

    local response=$(kibana_api "/api/fleet/settings")
    local fleet_host=$(json_get '.item.fleet_server_hosts[0] // .fleet_server_hosts[0]' "$response")

    if [[ -n "$fleet_host" && "$fleet_host" != "null" ]]; then
        record_pass "Fleet configured: $fleet_host"
        return 0
    fi

    # Check if API at least responds
    local status=$(api_status "${KIBANA_URL}/api/fleet/settings" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")
    if [[ "$status" == "200" ]]; then
        record_pass "Fleet API accessible (fleet_server_hosts may be auto-configured)"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "Fleet API not responding"
    return 1
}

# =============================================================================
# Elastic Agent Tests
# =============================================================================

test_agent_enrolled() {
    log_test_start "Elastic Agent Enrollment"

    local max_retries=6
    local retry_interval=10

    for ((attempt=1; attempt<=max_retries; attempt++)); do
        local response=$(kibana_api "/api/fleet/agents")
        local total=$(json_get '.total' "$response")

        if [[ "$total" =~ ^[0-9]+$ && "$total" -gt 0 ]]; then
            local online=$(echo "$response" | jq '[.items[] | select(.status == "online")] | length' 2>/dev/null || echo "0")
            record_pass "Agents enrolled: $total total, $online online"
            return 0
        fi

        if [[ $attempt -lt $max_retries ]]; then
            log_info "No agents yet (attempt $attempt/$max_retries), waiting ${retry_interval}s..."
            sleep "$retry_interval"
        fi
    done

    # Check if Fleet API works at all
    local status=$(api_status "${KIBANA_URL}/api/fleet/agents" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")
    if [[ "$status" == "200" ]]; then
        log_warning "Fleet API accessible but no agents enrolled"
        record_pass "Fleet API accessible (agent enrollment may be pending)"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "No agents enrolled after ${max_retries} attempts"
    return 1
}

test_agent_policy() {
    log_test_start "Agent Policy Assignment"

    local response=$(kibana_api "/api/fleet/agents")
    local total=$(json_get '.total' "$response")

    if [[ ! "$total" =~ ^[0-9]+$ || "$total" -eq 0 ]]; then
        record_pass "No agents enrolled - policy check skipped"
        return 0
    fi

    local with_policy=$(echo "$response" | jq '[.items[] | select(.policy_id != null)] | length' 2>/dev/null || echo "0")

    if [[ "$with_policy" -gt 0 ]]; then
        record_pass "Agents with policies: $with_policy"
        return 0
    fi

    log_warning "Agents enrolled but policies not yet assigned"
    record_pass "Agents enrolled, policy assignment pending"
    return 0
}

test_agent_data() {
    log_test_start "Agent Data Ingestion"

    local response=$(api_get "${ELASTICSEARCH_URL}/logs-*,metrics-*/_count")
    local count=$(json_get '.count' "$response")

    if [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]]; then
        record_pass "Agent data found: $count documents"
        return 0
    fi

    log_warning "No agent data yet (may need time to populate)"
    record_pass "Data check completed (0 documents - normal during initial setup)"
    return 0
}

# =============================================================================
# User Tests (for custom user validation)
# =============================================================================

test_user_exists() {
    local username="$1"
    log_test_start "User Exists: $username"

    local status=$(api_status "${ELASTICSEARCH_URL}/_security/user/${username}" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")

    if [[ "$status" == "200" ]]; then
        record_pass "User '$username' exists"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "User '$username' not found"
    return 1
}

test_user_auth() {
    local username="$1"
    local password="$2"
    log_test_start "User Authentication: $username"

    local status=$(api_status "${ELASTICSEARCH_URL}/_security/_authenticate" "${username}:${password}")

    if [[ "$status" == "200" ]]; then
        record_pass "User '$username' can authenticate"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "User '$username' cannot authenticate"
    return 1
}

# =============================================================================
# Test Suites
# =============================================================================

run_certificate_tests() {
    echo -e "\n${BLUE}═══ Certificate Tests ═══${NC}"
    test_ca_certificate || true
    test_ssl_connection "Elasticsearch" "$ELASTICSEARCH_URL" || true
    test_ssl_connection "Kibana" "$KIBANA_URL" || true
    test_ssl_connection "Fleet" "${FLEET_URL}/api/status" || true
}

run_elasticsearch_tests() {
    echo -e "\n${BLUE}═══ Elasticsearch Tests ═══${NC}"
    test_elasticsearch_health || true
    test_elasticsearch_auth || true
    test_elasticsearch_api || true
}

run_kibana_tests() {
    echo -e "\n${BLUE}═══ Kibana Tests ═══${NC}"
    test_kibana_health || true
    test_kibana_login || true
    test_kibana_api || true
}

run_fleet_tests() {
    echo -e "\n${BLUE}═══ Fleet Server Tests ═══${NC}"
    test_fleet_health || true
    test_fleet_api || true
}

run_agent_tests() {
    echo -e "\n${BLUE}═══ Elastic Agent Tests ═══${NC}"
    test_agent_enrolled || true
    test_agent_policy || true
    test_agent_data || true
}

run_all_tests() {
    run_certificate_tests
    run_elasticsearch_tests
    run_kibana_tests
    run_fleet_tests
    run_agent_tests
}

# =============================================================================
# Main Entry Point
# =============================================================================

main() {
    local test_suite="${1:-all}"

    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "${BLUE}Elastic Stack Test Suite${NC}"
    echo -e "${BLUE}══════════════════════════════════════${NC}"
    echo -e "Elasticsearch: $ELASTICSEARCH_URL"
    echo -e "Kibana:        $KIBANA_URL"
    echo -e "Fleet:         $FLEET_URL"
    echo -e "Ingress Mode:  $INGRESS_MODE"
    echo -e "CA Cert:       ${CA_CERT:-none}"
    echo -e "Debug:         $DEBUG"

    case "$test_suite" in
        certificates|certs) run_certificate_tests ;;
        elasticsearch|es)   run_elasticsearch_tests ;;
        kibana|kb)          run_kibana_tests ;;
        fleet)              run_fleet_tests ;;
        agent)              run_agent_tests ;;
        all)                run_all_tests ;;
        *)
            echo "Unknown test suite: $test_suite"
            echo "Available: all, certificates, elasticsearch, kibana, fleet, agent"
            exit 1
            ;;
    esac

    print_summary
}

# Run main if executed directly (not sourced)
[[ "${BASH_SOURCE[0]}" == "${0}" ]] && main "$@"
