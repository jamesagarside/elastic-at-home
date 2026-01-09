#!/usr/bin/env bash
# User Validation Test Extensions
# Source this AFTER test-stack.sh to add user validation tests
# Usage: source test-stack.sh && source test-users.sh && run_user_tests

# =============================================================================
# User Role Tests
# =============================================================================

# Test that a user has specific roles
# Usage: test_user_roles "username" "role1" "role2" ...
test_user_roles() {
    local username="$1"
    shift
    local expected_roles=("$@")

    log_test_start "User Roles: $username"

    local response=$(api_get "${ELASTICSEARCH_URL}/_security/user/${username}")
    local user_roles=$(echo "$response" | jq -r ".\"${username}\".roles[]" 2>/dev/null | tr '\n' ' ')

    local missing_roles=()
    for role in "${expected_roles[@]}"; do
        if ! echo "$user_roles" | grep -qw "$role"; then
            missing_roles+=("$role")
        fi
    done

    if [[ ${#missing_roles[@]} -eq 0 ]]; then
        record_pass "User '$username' has all expected roles: ${expected_roles[*]}"
        return 0
    fi

    record_fail "User '$username' missing roles: ${missing_roles[*]}"
    return 1
}

# Test that a user has access to a specific index
# Usage: test_user_index_access "username" "password" "index_pattern" "expected_access" (read|write|none)
test_user_index_access() {
    local username="$1"
    local password="$2"
    local index_pattern="$3"
    local expected_access="$4"

    log_test_start "Index Access: $username -> $index_pattern ($expected_access)"

    # Test read access
    local read_status=$(api_status "${ELASTICSEARCH_URL}/${index_pattern}/_search?size=0" "${username}:${password}")

    # Test write access (via simulate)
    local opts=$(_curl_opts)
    local write_status=$(curl $opts -o /dev/null -w "%{http_code}" \
        -u "${username}:${password}" \
        -X POST -H "Content-Type: application/json" \
        "${ELASTICSEARCH_URL}/${index_pattern}/_doc?dry_run=true" \
        -d '{"test": "data"}' 2>/dev/null) || write_status="000"

    case "$expected_access" in
        read)
            if [[ "$read_status" == "200" && "$write_status" == "403" ]]; then
                record_pass "User '$username' has read-only access"
                return 0
            fi
            record_fail "Access incorrect: read=$read_status, write=$write_status (expected 200/403)"
            return 1
            ;;
        write)
            if [[ "$read_status" == "200" && "$write_status" =~ ^(200|201)$ ]]; then
                record_pass "User '$username' has write access"
                return 0
            fi
            record_fail "Access incorrect: read=$read_status, write=$write_status (expected 200/200)"
            return 1
            ;;
        none)
            if [[ "$read_status" == "403" && "$write_status" == "403" ]]; then
                record_pass "User '$username' has no access"
                return 0
            fi
            record_fail "Access incorrect: read=$read_status, write=$write_status (expected 403/403)"
            return 1
            ;;
        *)
            record_fail "Unknown access level: $expected_access"
            return 1
            ;;
    esac
}

# Test that a role exists
# Usage: test_role_exists "role_name"
test_role_exists() {
    local role_name="$1"
    log_test_start "Role Exists: $role_name"

    local status=$(api_status "${ELASTICSEARCH_URL}/_security/role/${role_name}" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")

    if [[ "$status" == "200" ]]; then
        record_pass "Role '$role_name' exists"
        return 0
    fi

    LAST_STATUS="$status"
    record_fail "Role '$role_name' not found"
    return 1
}

# Test built-in users exist
test_builtin_users() {
    log_test_start "Built-in Users"

    local users=("elastic" "kibana_system")
    local failed=0

    for user in "${users[@]}"; do
        local status=$(api_status "${ELASTICSEARCH_URL}/_security/user/${user}" "${ELASTIC_USER}:${ELASTIC_PASSWORD}")
        if [[ "$status" != "200" ]]; then
            log_error "User '$user' not found"
            ((failed++))
        fi
    done

    if [[ $failed -eq 0 ]]; then
        record_pass "All built-in users exist"
        return 0
    fi

    record_fail "$failed built-in users missing"
    return 1
}

# =============================================================================
# User Test Suite
# =============================================================================

run_user_tests() {
    echo -e "\n${BLUE}═══ User Validation Tests ═══${NC}"

    test_builtin_users || true
    test_user_auth "elastic" "${ELASTIC_PASSWORD}" || true

    # Add custom user tests below:
    # test_user_exists "my_user" || true
    # test_user_roles "my_user" "viewer" "monitoring_user" || true
    # test_user_auth "my_user" "password123" || true
    # test_user_index_access "my_user" "password123" "logs-*" "read" || true
}
