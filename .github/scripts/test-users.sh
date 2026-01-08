#!/usr/bin/env bash
# User Validation Test Extensions
# Source this file to add user validation tests to your test suite
# Usage: source test-stack.sh && source test-users.sh && run_user_tests

# =============================================================================
# User Validation Tests
# =============================================================================

# Test that a specific user exists in Elasticsearch
# Usage: test_user_exists "username"
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

# Test that a user has specific roles
# Usage: test_user_has_roles "username" "role1" "role2" ...
test_user_has_roles() {
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

# Test that a user can authenticate
# Usage: test_user_can_authenticate "username" "password"
test_user_can_authenticate() {
    local username="$1"
    local password="$2"

    log_test_start "User Authentication: $username"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${username}:${password}" \
        "${ELASTICSEARCH_URL}/_security/_authenticate" 2>/dev/null)

    if [[ "$status" == "200" ]]; then
        record_pass "User '$username' can authenticate"
        return 0
    else
        record_fail "User '$username' cannot authenticate (HTTP $status)"
        return 1
    fi
}

# Test that a user has access to a specific index
# Usage: test_user_index_access "username" "password" "index_pattern" "expected_access" (read|write|none)
test_user_index_access() {
    local username="$1"
    local password="$2"
    local index_pattern="$3"
    local expected_access="$4"

    log_test_start "User Index Access: $username -> $index_pattern ($expected_access)"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    # Test read access
    local read_status
    read_status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${username}:${password}" \
        "${ELASTICSEARCH_URL}/${index_pattern}/_search?size=0" 2>/dev/null)

    # Test write access (via simulate)
    local write_status
    write_status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${username}:${password}" \
        -X POST \
        -H "Content-Type: application/json" \
        "${ELASTICSEARCH_URL}/${index_pattern}/_doc?dry_run=true" \
        -d '{"test": "data"}' 2>/dev/null)

    case "$expected_access" in
        read)
            if [[ "$read_status" == "200" && "$write_status" == "403" ]]; then
                record_pass "User '$username' has read-only access to '$index_pattern'"
                return 0
            else
                record_fail "User '$username' access incorrect: read=$read_status, write=$write_status (expected read=200, write=403)"
                return 1
            fi
            ;;
        write)
            if [[ "$read_status" == "200" && "$write_status" =~ ^(200|201)$ ]]; then
                record_pass "User '$username' has write access to '$index_pattern'"
                return 0
            else
                record_fail "User '$username' access incorrect: read=$read_status, write=$write_status (expected both 200)"
                return 1
            fi
            ;;
        none)
            if [[ "$read_status" == "403" && "$write_status" == "403" ]]; then
                record_pass "User '$username' has no access to '$index_pattern'"
                return 0
            else
                record_fail "User '$username' access incorrect: read=$read_status, write=$write_status (expected both 403)"
                return 1
            fi
            ;;
        *)
            record_fail "Unknown expected access level: $expected_access"
            return 1
            ;;
    esac
}

# Test that a role exists
# Usage: test_role_exists "role_name"
test_role_exists() {
    local role_name="$1"

    log_test_start "Role Exists: $role_name"

    local curl_opts
    curl_opts=$(get_curl_opts "$ELASTICSEARCH_URL")

    local status
    status=$(curl -s -o /dev/null -w "%{http_code}" $curl_opts \
        -u "${ELASTIC_USER}:${ELASTIC_PASSWORD}" \
        "${ELASTICSEARCH_URL}/_security/role/${role_name}" 2>/dev/null)

    if [[ "$status" == "200" ]]; then
        record_pass "Role '$role_name' exists"
        return 0
    else
        record_fail "Role '$role_name' not found (HTTP $status)"
        return 1
    fi
}

# Test built-in users exist and can authenticate
test_builtin_users() {
    log_test_start "Built-in Users"

    local builtin_users=("elastic" "kibana_system")
    local failed=0

    for user in "${builtin_users[@]}"; do
        if ! test_user_exists "$user"; then
            ((failed++))
        fi
    done

    if [[ $failed -eq 0 ]]; then
        record_pass "All built-in users exist"
        return 0
    else
        record_fail "$failed built-in users missing"
        return 1
    fi
}

# =============================================================================
# User Test Suite
# =============================================================================

run_user_tests() {
    echo -e "\n${BLUE}=== User Validation Tests ===${NC}"

    # Test built-in users
    test_builtin_users || true

    # Test elastic user authentication
    test_user_can_authenticate "elastic" "${ELASTIC_PASSWORD}" || true

    # Add custom user tests below
    # Example:
    # test_user_exists "my_custom_user" || true
    # test_user_has_roles "my_custom_user" "viewer" "monitoring_user" || true
    # test_user_can_authenticate "my_custom_user" "password123" || true
    # test_user_index_access "my_custom_user" "password123" "logs-*" "read" || true
}

# =============================================================================
# Example Usage in Workflow
# =============================================================================

# To add user tests to your workflow, add a step like:
#
# - name: Run user validation tests
#   run: |
#     export ELASTICSEARCH_URL="https://localhost:9200"
#     export ELASTIC_PASSWORD="TestPassword123!"
#     export CA_CERT="./ca.crt"
#
#     # Source the test libraries
#     source .github/scripts/test-stack.sh
#     source .github/scripts/test-users.sh
#
#     # Run user tests
#     run_user_tests
#
#     # Or run specific tests
#     test_user_exists "my_user"
#     test_user_has_roles "my_user" "admin" "superuser"
#
#     print_summary
