#!/usr/bin/env bash
# =============================================================================
# Bootstrap Functional Tests
#
# Проверяет функциональность bootstrap-роли:
#   1. Nexus доступен и отвечает
#   2. Установка пароля администратора через admin.password
#   3. Аутентификация администратора (логин/пароль)
#   4. Анонимный доступ работает
# =============================================================================

set -euo pipefail

NEXUS_URL="${NEXUS_URL:-http://nginx:80}"
ADMIN_USER="${NEXUS_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${NEXUS_ADMIN_PASSWORD:-admin123}"
NEXUS_DATA="${NEXUS_DATA_DIR:-/nexus-data}"

PASSED=0
FAILED=0
TOTAL=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

log_info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
log_pass()  { echo -e "${GREEN}[PASS]${NC}  $*"; }
log_fail()  { echo -e "${RED}[FAIL]${NC}  $*"; }
log_section() { echo -e "\n${YELLOW}=== $* ===${NC}"; }

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASSED=$((PASSED + 1))
    log_pass "$test_name (expected=$expected, got=$actual)"
  else
    FAILED=$((FAILED + 1))
    log_fail "$test_name (expected=$expected, got=$actual)"
  fi
}

assert_not_empty() {
  local test_name="$1" value="$2"
  TOTAL=$((TOTAL + 1))
  if [ -n "$value" ]; then
    PASSED=$((PASSED + 1))
    log_pass "$test_name (value is not empty)"
  else
    FAILED=$((FAILED + 1))
    log_fail "$test_name (value is empty)"
  fi
}

# ---------------------------------------------------------------------------
# Phase 0: Wait for Nexus to be fully ready
# ---------------------------------------------------------------------------
log_section "Phase 0: Waiting for Nexus to be fully ready"

# Шаг 1: Ждём ответа от REST API через nginx
log_info "Step 1: Waiting for Nexus REST API at $NEXUS_URL ..."
attempt=0
max_attempts=90
while [ $attempt -lt $max_attempts ]; do
  http_code=$(curl -s -o /dev/null -w "%{http_code}" \
    "$NEXUS_URL/service/rest/v1/status" 2>/dev/null || echo "000")
  if [ "$http_code" = "200" ]; then
    log_info "Nexus REST API is responding (HTTP $http_code) after $((attempt * 5))s"
    break
  fi
  if [ $((attempt % 6)) -eq 0 ]; then
    log_info "Still waiting... (attempt $attempt/$max_attempts, last HTTP=$http_code)"
  fi
  attempt=$((attempt + 1))
  sleep 5
done
if [ $attempt -ge $max_attempts ]; then
  log_fail "Nexus REST API did not become ready after $((max_attempts * 5))s"
  exit 1
fi

# Шаг 2: Ждём появления файла admin.password (Nexus генерирует при первом старте)
log_info "Step 2: Waiting for admin.password file at $NEXUS_DATA/admin.password ..."
attempt=0
max_attempts=60
while [ $attempt -lt $max_attempts ]; do
  if [ -f "$NEXUS_DATA/admin.password" ]; then
    log_info "admin.password file found after $((attempt * 2))s"
    break
  fi
  attempt=$((attempt + 1))
  sleep 2
done
if [ $attempt -ge $max_attempts ]; then
  log_fail "admin.password file did not appear after $((max_attempts * 2))s"
  exit 1
fi

# Шаг 3: Дополнительная пауза — Nexus может ещё инициализировать внутренние сервисы
log_info "Step 3: Extra wait for Nexus internal services..."
sleep 5

# Шаг 4: Ждём что API аутентификации работает (с начальным паролем)
INITIAL_PASSWORD=$(cat "$NEXUS_DATA/admin.password")
log_info "Initial admin password read from file (length=${#INITIAL_PASSWORD})"

attempt=0
max_attempts=30
while [ $attempt -lt $max_attempts ]; do
  init_auth_code=$(curl -s -o /dev/null -w "%{http_code}" \
    -u "${ADMIN_USER}:${INITIAL_PASSWORD}" \
    "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null || echo "000")
  if [ "$init_auth_code" = "200" ]; then
    log_info "Initial password authentication works (HTTP $init_auth_code) after $((attempt * 3))s"
    break
  fi
  attempt=$((attempt + 1))
  sleep 3
done
if [ $attempt -ge $max_attempts ]; then
  log_fail "Cannot authenticate with initial password after $((max_attempts * 3))s (last HTTP=$init_auth_code)"
  exit 1
fi

log_info "Nexus is fully ready!"

# ---------------------------------------------------------------------------
# Phase 1: Bootstrap — change admin password
# ---------------------------------------------------------------------------
log_section "Phase 1: Bootstrap — admin password setup"

log_info "Changing admin password from initial to target..."
change_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${INITIAL_PASSWORD}" \
  -X PUT \
  -H "Content-Type: text/plain" \
  -d "${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/security/users/admin/change-password" 2>/dev/null || echo "000")
assert_eq "Change admin password" "204" "$change_code"

# Проверяем, что новый пароль работает
verify_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null || echo "000")
assert_eq "New admin password works" "200" "$verify_code"

# Проверяем, что старый пароль больше не работает
old_pw_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${INITIAL_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null || echo "000")
assert_eq "Old initial password rejected" "401" "$old_pw_code"

# ---------------------------------------------------------------------------
# Phase 2: Enable anonymous access
# ---------------------------------------------------------------------------
log_section "Phase 2: Enable anonymous access"

anon_enable_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  -X PUT \
  -H "Content-Type: application/json" \
  -d '{"enabled":true,"userId":"anonymous","realmName":"NexusAuthorizingRealm"}' \
  "$NEXUS_URL/service/rest/v1/security/anonymous" 2>/dev/null || echo "000")
assert_eq "Enable anonymous access API call" "200" "$anon_enable_code"

# ---------------------------------------------------------------------------
# Phase 3: Tests
# ---------------------------------------------------------------------------

# --- Test 3.1: Nexus status endpoint ---
log_section "Test 3.1: Nexus is UP and responding"

status_code=$(curl -s -o /dev/null -w "%{http_code}" "$NEXUS_URL/service/rest/v1/status" 2>/dev/null || echo "000")
assert_eq "GET /service/rest/v1/status returns 200" "200" "$status_code"

status_body=$(curl -s "$NEXUS_URL/service/rest/v1/status" 2>/dev/null || echo "")
assert_not_empty "Status response body is not empty" "$status_body"

# --- Test 3.2: Nexus status/check (writable) ---
log_section "Test 3.2: Nexus is writable (status/check)"

check_code=$(curl -s -o /dev/null -w "%{http_code}" "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null || echo "000")
assert_eq "GET /service/rest/v1/status/check returns 200" "200" "$check_code"

# --- Test 3.3: Anonymous access ---
log_section "Test 3.3: Anonymous access"

# Анонимный запрос к API (без аутентификации)
anon_status=$(curl -s -o /dev/null -w "%{http_code}" "$NEXUS_URL/service/rest/v1/status" 2>/dev/null || echo "000")
assert_eq "Anonymous GET /status returns 200" "200" "$anon_status"

# Проверяем настройки анонимного доступа через API (нужен admin)
anon_settings=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/security/anonymous" 2>/dev/null || echo "{}")
anon_enabled=$(echo "$anon_settings" | jq -r '.enabled' 2>/dev/null || echo "")
assert_eq "Anonymous access is enabled" "true" "$anon_enabled"

anon_user=$(echo "$anon_settings" | jq -r '.userId' 2>/dev/null || echo "")
assert_eq "Anonymous userId is 'anonymous'" "anonymous" "$anon_user"

# Анонимный доступ к списку репозиториев
anon_repos_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "$NEXUS_URL/service/rest/v1/repositories" 2>/dev/null || echo "000")
assert_eq "Anonymous GET /repositories returns 200" "200" "$anon_repos_code"

# Анонимный поиск компонентов (search endpoint)
anon_search_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "$NEXUS_URL/service/rest/v1/search" 2>/dev/null || echo "000")
assert_eq "Anonymous GET /search returns 200" "200" "$anon_search_code"

# --- Test 3.4: Admin authentication ---
log_section "Test 3.4: Admin authentication"

# Успешная аутентификация
auth_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/status/check" 2>/dev/null || echo "000")
assert_eq "Admin auth GET /status/check returns 200" "200" "$auth_code"

# Проверка, что admin может получить список пользователей (привилегированный endpoint)
users_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/security/users" 2>/dev/null || echo "000")
assert_eq "Admin GET /security/users returns 200" "200" "$users_code"

users_body=$(curl -s -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/security/users" 2>/dev/null || echo "[]")
admin_in_list=$(echo "$users_body" | jq -r '.[].userId' 2>/dev/null | grep -c "^admin$" || echo "0")
assert_eq "Admin user exists in user list" "1" "$admin_in_list"

# Проверка привилегий — чтение ролей
roles_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "${ADMIN_USER}:${ADMIN_PASSWORD}" \
  "$NEXUS_URL/service/rest/v1/security/roles" 2>/dev/null || echo "000")
assert_eq "Admin GET /security/roles returns 200" "200" "$roles_code"

# --- Test 3.5: Wrong credentials rejected ---
log_section "Test 3.5: Invalid credentials are rejected"

bad_auth_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "admin:wrong_password_12345" \
  "$NEXUS_URL/service/rest/v1/security/users" 2>/dev/null || echo "000")
assert_eq "Wrong password returns 401" "401" "$bad_auth_code"

bad_user_code=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "nonexistent:password" \
  "$NEXUS_URL/service/rest/v1/security/users" 2>/dev/null || echo "000")
assert_eq "Non-existent user returns 401" "401" "$bad_user_code"

# --- Test 3.6: Anonymous cannot access admin endpoints ---
log_section "Test 3.6: Anonymous cannot access admin-only endpoints"

anon_users_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "$NEXUS_URL/service/rest/v1/security/users" 2>/dev/null || echo "000")
assert_eq "Anonymous GET /security/users returns 403" "403" "$anon_users_code"

anon_roles_code=$(curl -s -o /dev/null -w "%{http_code}" \
  "$NEXUS_URL/service/rest/v1/security/roles" 2>/dev/null || echo "000")
assert_eq "Anonymous GET /security/roles returns 403" "403" "$anon_roles_code"

# --- Test 3.7: Nginx proxying works correctly ---
log_section "Test 3.7: Nginx reverse proxy"

# Проверяем что Nexus UI доступен через nginx
ui_code=$(curl -s -o /dev/null -w "%{http_code}" "$NEXUS_URL/" 2>/dev/null || echo "000")
assert_eq "Nexus UI via nginx returns 200" "200" "$ui_code"

# Проверяем что REST API доступен через nginx
api_code=$(curl -s -o /dev/null -w "%{http_code}" "$NEXUS_URL/service/rest/v1/status" 2>/dev/null || echo "000")
assert_eq "REST API via nginx returns 200" "200" "$api_code"

# =============================================================================
# Results
# =============================================================================
log_section "RESULTS"
echo -e "Total:  ${TOTAL}"
echo -e "Passed: ${GREEN}${PASSED}${NC}"
echo -e "Failed: ${RED}${FAILED}${NC}"
echo ""

if [ "$FAILED" -gt 0 ]; then
  log_fail "Some tests failed!"
  exit 1
else
  log_pass "All tests passed!"
  exit 0
fi
