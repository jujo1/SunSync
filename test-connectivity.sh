#!/bin/bash

# ==============================================================================
# SunSync Home Assistant Integration
# API Connectivity Test Script
# Description: Helper script to test connectivity to Home Assistant API
# ==============================================================================

log_message() {
  local level=$1
  local message=$2
  local dt=$(date '+%d/%m/%Y %H:%M:%S')
  echo "[$level] $dt - $message"
}

# Test function to try different API endpoints
test_api_endpoint() {
  local url=$1
  local auth=$2
  local description=$3

  log_message "INFO" "Testing $description: $url"

  local result=$(curl -s -o /dev/null -w "%{http_code}" \
    -H "Authorization: Bearer $auth" \
    -H "Content-Type: application/json" \
    "$url")

  if [ "$result" = "200" ] || [ "$result" = "201" ]; then
    log_message "SUCCESS" "$description works (HTTP $result)"
    return 0
  else
    log_message "FAILED" "$description failed (HTTP $result)"
    return 1
  fi
}

# Main test function
run_tests() {
  echo "==== SunSync Connectivity Test ===="
  echo "Testing connectivity to Home Assistant API..."
  echo ""

  # Check if SUPERVISOR_TOKEN is available
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    log_message "INFO" "Supervisor token available, length: ${#SUPERVISOR_TOKEN}"

    # Test supervisor API endpoints
    test_api_endpoint "http://supervisor/core/api" "$SUPERVISOR_TOKEN" "Supervisor Core API"
    test_api_endpoint "http://supervisor/core/api/states" "$SUPERVISOR_TOKEN" "Supervisor States API"
    test_api_endpoint "http://supervisor/core/api/config" "$SUPERVISOR_TOKEN" "Supervisor Config API"
    test_api_endpoint "http://supervisor/core" "$SUPERVISOR_TOKEN" "Supervisor Core"
  else
    log_message "INFO" "No Supervisor token available"
  fi

  # If HA_TOKEN and HA_IP are available, test direct connection
  if [ -n "$HA_TOKEN" ] && [ -n "$HA_IP" ] && [ -n "$HA_PORT" ]; then
    log_message "INFO" "Testing direct connection to Home Assistant"

    # Test with and without HTTPS
    test_api_endpoint "http://$HA_IP:$HA_PORT/api" "$HA_TOKEN" "Direct HTTP connection"
    test_api_endpoint "https://$HA_IP:$HA_PORT/api" "$HA_TOKEN" "Direct HTTPS connection"
  fi

  echo ""
  echo "==== Test Completed ===="
}

# Run the tests
run_tests
