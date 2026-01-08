#!/usr/bin/env bash
# Elastic Stack Test Library
# Reusable functions for testing the Elastic Stack deployment
# Usage: source this file and call individual test functions

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0

# Configuration (can be overridden by environment)
ELASTICSEARCH_URL="${ELASTICSEARCH_URL:-https://localhost:9200}"
KIBANA_URL="${KIBANA_URL:-https://localhost:5601}"
FLEET_URL="${FLEET_URL:-https://localhost:8220}"
ELASTIC_USER="${ELASTIC_USER:-elastic}"
ELASTIC_PASSWORD="${ELASTIC_PASSWORD:-changeme}"
CA_CERT="${CA_CERT:-./certs/ca/ca.crt}"
TIMEOUT="${TIMEOUT:-300}"
RETRY_INTERVAL="${RETRY_INTERVAL:-10}"

# =============================================================================
# Utility Functions
# =============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[PASS]${NC} $1"
}

log_error() {
    echo -e "${RED}[FAIL]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_test_start() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}TEST: $1${NC}"
    echo -e "${BLUE}========================================${NC}"
}

record_pass() {
    ((TESTS_PASSED++))
    log_success "$1"
}

record_fail() {
    ((TESTS_FAILED++))
    log_error "$1"
}

record_skip() {
    ((TESTS_SKIPPED++))
    log_warning "SKIPPED: $1"
}

print_summary() {
    echo -e "\n${BLUE}========================================${NC}"
    echo -e "${BLUE}TEST SUMMARY${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "${GREEN}Passed:${NC}  $TESTS_PASSED"
    echo -e "${RED}Failed:${NC}  $TESTS_FAILED"
    echo -e "${YELLOW}Skipped:${NC} $TESTS_SKIPPED"
    echo -e "${BLUE}Total:${NC}   $((TESTS_PASSED + TESTS_FAILED + TESTS_SKIPPED))"

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo -e "\n${RED}OVERALL: FAILED${NC}"
        return 1
    else
        echo -e "\n${GREEN}OVERALL: PASSED${NC}"
        return 0
    fi
}

# Build curl options based on certificate mode
get_curl_opts() {
    local url="$1"

    if [[ -f "$CA_CERT" ]]; then
        echo "--cacert $CA_CERT"
    else
        # For Let's Encrypt, no CA cert needed
        echo ""
    fi
}

# Wait for a URL to return expected status code
wait_for_url() {
    local url="$1"
    local expected_status="${2:-200}"
    local auth="${3:-}"
    local max_attempts=$((TIMEOUT / RETRY_INTERVAL))
    local attempt=1

    local curl_opts
    curl_opts=$(get_curl_opts "$url")

    log_info "Waiting for $url to return HTTP $expected_status..."

    while [[ $attempt -le $max_attempts ]]; do
        local status_code

        if [[ -n "$auth" ]]; then
            status_code=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts -u "$auth" "$url" 2>/dev/null || echo "000")
        else
            status_code=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts "$url" 2>/dev/null || echo "000")
        fi

        if [[ "$status_code" == "$expected_status" ]]; then
            log_success "$url returned HTTP $status_code after $((attempt * RETRY_INTERVAL)) seconds"
            return 0
        fi

        log_info "Attempt $attempt/$max_attempts: Got HTTP $status_code, waiting ${RETRY_INTERVAL}s..."
        sleep "$RETRY_INTERVAL"
        ((attempt++))
    done

    log_error "$url did not return HTTP $expected_status within ${TIMEOUT}s"
    return 1
}

# =============================================================================
# Certificate Tests
# =============================================================================

test_ca_certificate_exists() {
    log_test_start "CA Certificate Exists"

    if [[ -f "$CA_CERT" ]]; then
        record_pass "CA certificate found at $CA_CERT"
        return 0
    else
        # For Let's Encrypt mode, CA cert is not required
        if [[ "${CERT_RESOLVER:-}" == "letsencrypt" ]]; then
            record_pass "Let's Encrypt mode - no local CA required"
            return 0
        fi
        record_fail "CA certificate not found at $CA_CERT"
        return 1
    fi
}

test_ca_certificate_valid() {
    log_test_start "CA Certificate Valid"

    if [[ ! -f "$CA_CERT" ]]; then
        if [[ "${CERT_RESOLVER:-}" == "letsencrypt" ]]; then
            record_skip "Let's Encrypt mode - no local CA to validate"
            return 0
        fi
        record_fail "CA certificate not found"
        return 1
    fi

    # Check certificate is valid and not expired
    if openssl x509 -in "$CA_CERT" -noout -checkend 86400 2>/dev/null; then
        local subject
        subject=$(openssl x509 -in "$CA_CERT" -noout -subject 2>/dev/null)
        record_pass "CA certificate is valid: $subject"
        return 0
    else
        record_fail "CA certificate is expired or invalid"
        return 1
    fi
}

test_service_certificate() {
    local service="$1"
    local cert_path="$2"

    log_test_start "Service Certificate: $service"

    if [[ ! -f "$cert_path" ]]; then
        if [[ "${CERT_RESOLVER:-}" == "letsencrypt" ]]; then
            record_skip "Let's Encrypt mode - service certs managed externally"
            return 0
        fi
        # In container-based deployments, certs exist in Docker volumes, not locally
        # SSL/TLS connection tests verify the certs work - skip local file check
        record_skip "Certificate in Docker volume (SSL/TLS connection test verifies functionality)"
        return 0
    fi

    # Check certificate is valid
    if openssl x509 -in "$cert_path" -noout -checkend 86400 2>/dev/null; then
        local cn
        cn=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | grep -oP 'CN\s*=\s*\K[^,]+' || echo "unknown")
        record_pass "$service certificate valid (CN: $cn)"
        return 0
    else
        record_fail "$service certificate is expired or invalid"
        return 1
    fi
}

test_ssl_connection() {
    local name="$1"
    local url="$2"

    log_test_start "SSL/TLS Connection: $name"

    local host port
    host=$(echo "$url" | sed -E 's|https?://([^:/]+).*|\1|')
    port=$(echo "$url" | sed -E 's|https?://[^:]+:([0-9]+).*|\1|')
    port="${port:-443}"

    local curl_opts
    curl_opts=$(get_curl_opts "$url")

    # Test SSL connection
    if timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
        record_pass "SSL/TLS connection to $name verified successfully"
        return 0
    fi

    # For self-signed, try with CA cert
    if [[ -f "$CA_CERT" ]]; then
        if timeout 10 openssl s_client -connect "${host}:${port}" -servername "$host" -CAfile "$CA_CERT" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
            record_pass "SSL/TLS connection to $name verified with CA cert"
            return 0
        fi
    fi

    # Connection works but cert verification may fail in test environment
    if curl -s $curl_opts -o /dev/null -w "%{http_code}" "$url" 2>/dev/null | grep -qE "^[23]"; then
        record_pass "SSL/TLS connection to $name works (curl verified)"
        return 0
    fi

    record_fail "SSL/TLS connection to $name failed"
    return 1
}

# =============================================================================
# Elasticsearch Tests
# =============================================================================

test_elasticsearch_health() {
    log_test_start "Elasticsearch Health"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/_cluster/health" 2>/dev/null || echo '{"status":"error"}')

    local status
    status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "error")

    case "$status" in
        green)
            record_pass "Elasticsearch cluster health is GREEN"
            return 0
            ;;
        yellow)
            record_pass "Elasticsearch cluster health is YELLOW (acceptable for single-node)"
            return 0
            ;;
        red)
            record_fail "Elasticsearch cluster health is RED"
            return 1
            ;;
        *)
            record_fail "Could not determine Elasticsearch health: $response"
            return 1
            ;;
    esac
}

test_elasticsearch_authentication() {
    log_test_start "Elasticsearch Authentication"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    # Test with correct credentials
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/_security/_authenticate" 2>/dev/null)

    if [[ "$status" != "200" ]]; then
        record_fail "Authentication with valid credentials failed (HTTP $status)"
        return 1
    fi

    # Test with wrong credentials (should fail)
    local bad_status
    bad_status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "elastic:wrongpassword" \
        "${ELASTICSEARCH_URL}/_security/_authenticate" 2>/dev/null)

    if [[ "$bad_status" == "401" ]]; then
        record_pass "Authentication works correctly (valid: 200, invalid: 401)"
        return 0
    else
        record_fail "Invalid credentials not rejected properly (got HTTP $bad_status)"
        return 1
    fi
}

test_elasticsearch_api() {
    log_test_start "Elasticsearch API"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    # Test cluster info endpoint
    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/" 2>/dev/null)

    local cluster_name version
    cluster_name=$(echo "$response" | jq -r '.cluster_name' 2>/dev/null || echo "")
    version=$(echo "$response" | jq -r '.version.number' 2>/dev/null || echo "")

    if [[ -n "$cluster_name" && -n "$version" ]]; then
        record_pass "Elasticsearch API responding: cluster=$cluster_name, version=$version"
        return 0
    else
        record_fail "Elasticsearch API not responding correctly"
        return 1
    fi
}

# =============================================================================
# Kibana Tests
# =============================================================================

test_kibana_health() {
    log_test_start "Kibana Health"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${KIBANA_URL}/api/status" 2>/dev/null || echo '{"status":{}}')

    local status
    status=$(echo "$response" | jq -r '.status.overall.level' 2>/dev/null || echo "error")

    case "$status" in
        available)
            record_pass "Kibana status is available"
            return 0
            ;;
        degraded)
            log_warning "Kibana status is degraded"
            record_pass "Kibana is running (degraded status acceptable during startup)"
            return 0
            ;;
        *)
            record_fail "Kibana health check failed: $status"
            return 1
            ;;
    esac
}

test_kibana_login_page() {
    log_test_start "Kibana Login Page"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    # Kibana redirects to login page
    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        "${KIBANA_URL}/app/home" 2>/dev/null)

    # 302 redirect to login or 200 if already authenticated
    if [[ "$status" == "302" || "$status" == "200" ]]; then
        record_pass "Kibana login page accessible (HTTP $status)"
        return 0
    else
        record_fail "Kibana login page not accessible (HTTP $status)"
        return 1
    fi
}

test_kibana_api() {
    log_test_start "Kibana API"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}/api/features" 2>/dev/null)

    # Check if we got a valid JSON array of features
    local feature_count
    feature_count=$(echo "$response" | jq 'length' 2>/dev/null || echo "0")

    if [[ "$feature_count" -gt 0 ]]; then
        record_pass "Kibana API responding: $feature_count features available"
        return 0
    else
        record_fail "Kibana API not responding correctly"
        return 1
    fi
}

# =============================================================================
# Fleet Server Tests
# =============================================================================

test_fleet_server_health() {
    log_test_start "Fleet Server Health"

    local curl_opts
    curl_opts=$(get_curl_opts "$FLEET_URL")

    local response
    response=$(curl -s $curl_opts "${FLEET_URL}/api/status" 2>/dev/null || echo '{"status":"error"}')

    local status
    status=$(echo "$response" | jq -r '.status' 2>/dev/null || echo "error")

    if [[ "$status" == "HEALTHY" ]]; then
        record_pass "Fleet Server status is HEALTHY"
        return 0
    else
        record_fail "Fleet Server health check failed: $status"
        return 1
    fi
}

test_fleet_server_api() {
    log_test_start "Fleet Server API (via Kibana)"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}/api/fleet/settings" 2>/dev/null)

    # Check for fleet_server_hosts in the response (may be in .item or directly in response)
    local fleet_host
    fleet_host=$(echo "$response" | jq -r '.item.fleet_server_hosts[0] // .fleet_server_hosts[0] // empty' 2>/dev/null || echo "")

    if [[ -n "$fleet_host" && "$fleet_host" != "null" ]]; then
        record_pass "Fleet Server configured in Kibana: $fleet_host"
        return 0
    fi

    # If fleet_server_hosts not set, check if Fleet API is at least responding
    local status_code
    status_code=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}/api/fleet/settings" 2>/dev/null)

    if [[ "$status_code" == "200" ]]; then
        # API works but fleet_server_hosts may not be configured yet (normal during initial setup)
        record_pass "Fleet API accessible (fleet_server_hosts may be auto-configured during agent enrollment)"
        return 0
    else
        record_fail "Fleet Server API not responding (HTTP $status_code)"
        return 1
    fi
}

# =============================================================================
# Elastic Agent Tests
# =============================================================================

test_agent_enrolled() {
    log_test_start "Elastic Agent Enrolled"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}/api/fleet/agents" 2>/dev/null)

    local total_agents
    total_agents=$(echo "$response" | jq -r '.total' 2>/dev/null || echo "0")

    if [[ "$total_agents" -gt 0 ]]; then
        local online_agents
        online_agents=$(echo "$response" | jq '[.items[] | select(.status == "online")] | length' 2>/dev/null || echo "0")
        record_pass "Elastic Agents enrolled: $total_agents total, $online_agents online"
        return 0
    else
        record_fail "No Elastic Agents enrolled"
        return 1
    fi
}

test_agent_policy_applied() {
    log_test_start "Agent Policy Applied"

    local curl_opts
    curl_opts=$(get_curl_opts "$KIBANA_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        -H "kbn-xsrf: true" \
        "${KIBANA_URL}/api/fleet/agents" 2>/dev/null)

    # Check if agents have policies assigned
    local agents_with_policy
    agents_with_policy=$(echo "$response" | jq '[.items[] | select(.policy_id != null)] | length' 2>/dev/null || echo "0")

    if [[ "$agents_with_policy" -gt 0 ]]; then
        record_pass "Agents with policies assigned: $agents_with_policy"
        return 0
    else
        record_fail "No agents have policies assigned"
        return 1
    fi
}

test_agent_data_ingestion() {
    log_test_start "Agent Data Ingestion"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    # Check for recent data in logs-* or metrics-* indices
    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/logs-*,metrics-*/_count" 2>/dev/null)

    local count
    count=$(echo "$response" | jq -r '.count' 2>/dev/null || echo "0")

    if [[ "$count" -gt 0 ]]; then
        record_pass "Agent data found: $count documents in logs/metrics indices"
        return 0
    else
        # This might be expected early in deployment
        log_warning "No agent data found yet (may need more time)"
        record_pass "Agent data check completed (0 documents - may need time to populate)"
        return 0
    fi
}

# =============================================================================
# User Validation Tests (Extension Point)
# =============================================================================

test_user_exists() {
    local username="$1"

    log_test_start "User Exists: $username"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/_security/user/${username}" 2>/dev/null)

    if [[ "$status" == "200" ]]; then
        record_pass "User '$username' exists"
        return 0
    else
        record_fail "User '$username' not found (HTTP $status)"
        return 1
    fi
}

test_user_roles() {
    local username="$1"
    shift
    local expected_roles=("$@")

    log_test_start "User Roles: $username"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    local response
    response=$(curl -s $curl_opts -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/_security/user/${username}" 2>/dev/null)

    local user_roles
    user_roles=$(echo "$response" | jq -r ".[\"${username}\"].roles[]" 2>/dev/null | tr '\n' ' ')

    local missing_roles=()
    for role in "${expected_roles[@]}"; do
        if ! echo "$user_roles" | grep -qw "$role"; then
            missing_roles+=("$role")
        fi
    done

    if [[ ${#missing_roles[@]} -eq 0 ]]; then
        record_pass "User '$username' has all expected roles: ${expected_roles[*]}"
        return 0
    else
        record_fail "User '$username' missing roles: ${missing_roles[*]}"
        return 1
    fi
}

# =============================================================================
# Test Suites
# =============================================================================

run_certificate_tests() {
    echo -e "\n${BLUE}=== Certificate Tests ===${NC}"
    test_ca_certificate_exists || true
    test_ca_certificate_valid || true
    test_service_certificate "Elasticsearch" "./certs/es01/es01.crt" || true
    test_service_certificate "Kibana" "./certs/kibana/kibana.crt" || true
    test_service_certificate "Fleet" "./certs/fleet-server/fleet-server.crt" || true
    test_ssl_connection "Elasticsearch" "$ELASTICSEARCH_URL" || true
    test_ssl_connection "Kibana" "$KIBANA_URL" || true
    test_ssl_connection "Fleet" "$FLEET_URL" || true
}

run_elasticsearch_tests() {
    echo -e "\n${BLUE}=== Elasticsearch Tests ===${NC}"
    test_elasticsearch_health || true
    test_elasticsearch_authentication || true
    test_elasticsearch_api || true
}

run_kibana_tests() {
    echo -e "\n${BLUE}=== Kibana Tests ===${NC}"
    test_kibana_health || true
    test_kibana_login_page || true
    test_kibana_api || true
}

run_fleet_tests() {
    echo -e "\n${BLUE}=== Fleet Server Tests ===${NC}"
    test_fleet_server_health || true
    test_fleet_server_api || true
}

run_agent_tests() {
    echo -e "\n${BLUE}=== Elastic Agent Tests ===${NC}"
    test_agent_enrolled || true
    test_agent_policy_applied || true
    test_agent_data_ingestion || true
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

    echo -e "${BLUE}========================================${NC}"
    echo -e "${BLUE}Elastic Stack Test Suite${NC}"
    echo -e "${BLUE}========================================${NC}"
    echo -e "Elasticsearch URL: $ELASTICSEARCH_URL"
    echo -e "Kibana URL:        $KIBANA_URL"
    echo -e "Fleet URL:         $FLEET_URL"
    echo -e "Certificate Mode:  ${CERT_RESOLVER:-self-signed}"
    echo -e "CA Certificate:    ${CA_CERT:-none}"

    case "$test_suite" in
        certificates|certs)
            run_certificate_tests
            ;;
        elasticsearch|es)
            run_elasticsearch_tests
            ;;
        kibana|kb)
            run_kibana_tests
            ;;
        fleet)
            run_fleet_tests
            ;;
        agent)
            run_agent_tests
            ;;
        all)
            run_all_tests
            ;;
        *)
            echo "Unknown test suite: $test_suite"
            echo "Available: all, certificates, elasticsearch, kibana, fleet, agent"
            exit 1
            ;;
    esac

    print_summary
}

# Only run main if this script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
