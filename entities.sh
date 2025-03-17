#!/usr/bin/with-contenv bashio

# ==============================================================================
# Home Assistant Entity Management
# Description: Functions for creating and updating Home Assistant entities
# ==============================================================================

# Determine which authentication method to use
get_auth_header() {
  # First try to use Supervisor token if available
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    echo "Authorization: Bearer $SUPERVISOR_TOKEN"
  else
    # Fall back to the user-provided token
    echo "Authorization: Bearer $HA_TOKEN"
  fi
}

# Get the Base URL for API calls
get_api_base_url() {
  # When using Supervisor token, we can use the supervisor proxy
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    echo "http://supervisor/core/api"
  else
    # Otherwise use the configured URL
    echo "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api"
  fi
}

# Update Home Assistant entities for a specific inverter
update_ha_entities() {
  local inverter_serial=$1
  local success=0  # Using 0 for success as per bash convention

  # Log the start of entity updates
  log_message "INFO" "Updating Home Assistant entities for inverter: $inverter_serial"

  # Get the authentication header
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Using API base URL: $api_base_url"

  # Iterate through all sensor data points and create/update entities
  for key in "${!sensor_data[@]}"; do
    local value="${sensor_data[$key]}"
    local entity_id="sensor.sunsync_${inverter_serial}_${key}"
    local friendly_name="SunSync ${inverter_serial} ${key}"

    # Determine appropriate unit of measurement and device class
    local uom=""
    local device_class=""

    # Apply units based on the sensor type
    case "$key" in
      *_power)
        uom="W"
        device_class="power"
        ;;
      *_energy|*_charge|*_discharge)
        uom="kWh"
        device_class="energy"
        ;;
      *_voltage)
        uom="V"
        device_class="voltage"
        ;;
      *_current)
        uom="A"
        device_class="current"
        ;;
      *_frequency)
        uom="Hz"
        device_class="frequency"
        ;;
      *_temperature|*_temp)
        uom="°C"
        device_class="temperature"
        ;;
      *_soc)
        uom="%"
        device_class="battery"
        ;;
    esac

    # Create or update the entity
    if ! create_or_update_entity "$entity_id" "$friendly_name" "$value" "$uom" "$device_class"; then
      success=1  # Set to 1 to indicate failure
      log_message "ERROR" "Failed to update entity: $entity_id with value: $value"
    elif [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
      echo "$(date '+%d/%m/%Y %H:%M:%S') - Entity $entity_id already exists, updating..."
      echo "$(date '+%d/%m/%Y %H:%M:%S') - Updated entity: $entity_id with value: $value"
    fi
  done

  # Verify that at least some entities are registered
  verify_entities_created "$inverter_serial"

  return $success
}

# Function to create or update a single Home Assistant entity
create_or_update_entity() {
  local entity_id=$1
  local friendly_name=$2
  local state=$3
  local unit_of_measurement=$4
  local device_class=$5

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  # Build the Home Assistant API URL
  local ha_api_url="$api_base_url/states/$entity_id"

  # Build proper attributes JSON
  local attributes="{\"friendly_name\": \"$friendly_name\""

  # Only add unit_of_measurement if it's not empty
  if [ ! -z "$unit_of_measurement" ]; then
    attributes="$attributes, \"unit_of_measurement\": \"$unit_of_measurement\""
  fi

  # Only add device_class if it's not empty
  if [ ! -z "$device_class" ]; then
    attributes="$attributes, \"device_class\": \"$device_class\""
  fi

  # Close the attributes JSON
  attributes="$attributes}"

  # Create the payload
  local payload="{\"state\": \"$state\", \"attributes\": $attributes}"

  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    log_message "DEBUG" "Sending to $ha_api_url: $payload"
  fi

  # Make the API call to Home Assistant
  local response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$ha_api_url")

  local http_code=$(echo "$response" | tail -n1)
  local result=$(echo "$response" | head -n -1)

  # Log detailed diagnosis for errors
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_message "ERROR" "API call failed for entity $entity_id: HTTP $http_code"
    log_message "ERROR" "Response: $result"
    log_message "ERROR" "Attempted URL: $ha_api_url"
    return 1
  elif [[ "$result" == *"error"* ]]; then
    log_message "ERROR" "API returned error for entity $entity_id: $result"
    return 1
  fi

  return 0
}

# Function to check if Home Assistant is reachable
check_ha_connectivity() {
  log_message "INFO" "Testing connection to Home Assistant API"

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Using API URL: $api_base_url"

  # For supervisor, we need to test a different endpoint
  local test_endpoint
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    test_endpoint="$api_base_url/states"
  else
    test_endpoint="$api_base_url/"
  fi

  local curl_cmd="curl -s -o /dev/null -w \"%{http_code}\" \
    -H \"$auth_header\" \
    -H \"Content-Type: application/json\" \
    \"$test_endpoint\""

  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    log_message "DEBUG" "Command: $curl_cmd"
  fi

  local result=$(eval $curl_cmd)

  if [ "$result" = "200" ] || [ "$result" = "201" ]; then
    log_message "INFO" "Successfully connected to Home Assistant API"
    return 0
  else
    log_message "ERROR" "Failed to connect to Home Assistant API. HTTP Status: $result"
    log_message "ERROR" "Please verify your configuration and connectivity"

    # Try a different approach for supervisor
    if [ -n "$SUPERVISOR_TOKEN" ]; then
      log_message "INFO" "Trying alternative supervisor API endpoint..."
      local alt_result=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "$auth_header" \
        -H "Content-Type: application/json" \
        "http://supervisor/core/api/config")

      if [ "$alt_result" = "200" ] || [ "$alt_result" = "201" ]; then
        log_message "INFO" "Alternative supervisor endpoint works! Proceeding with this endpoint."
        return 0
      fi

      # Try direct connection to Home Assistant using host IP if configured
      if [ -n "$HA_IP" ] && [ -n "$HA_PORT" ]; then
        log_message "INFO" "Trying direct connection to Home Assistant..."
        local direct_result=$(curl -s -o /dev/null -w "%{http_code}" \
          -H "$auth_header" \
          -H "Content-Type: application/json" \
          "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/")

        if [ "$direct_result" = "200" ] || [ "$direct_result" = "201" ]; then
          log_message "INFO" "Direct connection to Home Assistant works! Will use direct URL."
          # Force using direct connection
          unset SUPERVISOR_TOKEN
          return 0
        fi
      fi
    fi

    return 1
  fi
}

# Verify at least some entities were successfully created
verify_entities_created() {
  local inverter_serial=$1
  local sample_entity="sensor.sunsync_${inverter_serial}_battery_soc"

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Verifying entity creation by checking for sample entity: $sample_entity"

  local response=$(curl -s -w "\n%{http_code}" -X GET \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    "$api_base_url/states/$sample_entity")

  local http_code=$(echo "$response" | tail -n1)
  local result=$(echo "$response" | head -n -1)

  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_message "ERROR" "Verification failed! Sample entity not found (HTTP $http_code)"
    log_message "ERROR" "Possible issues:"
    log_message "ERROR" "1. Your token may not have the correct permissions"
    log_message "ERROR" "2. Home Assistant may be rejecting the entity format"
    log_message "ERROR" "3. Network connectivity issues between add-on and Home Assistant"
    log_message "ERROR" "Trying a diagnostic API call to list all entities..."

    # Try to get all entities
    local all_entities=$(curl -s -X GET \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      "$api_base_url/states" | grep -c "entity_id" || echo "0")

    log_message "INFO" "Found approximately $all_entities entities total in Home Assistant"
    log_message "INFO" "If this number is 0, your token likely doesn't have correct permissions"

    # Search for any of our entities
    local our_entities=$(curl -s -X GET \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      "$api_base_url/states" | grep -c "sunsync" || echo "0")

    log_message "INFO" "Found approximately $our_entities SunSync entities"

    # Try to register the entity in the registry as a last resort
    register_entity_in_registry "$inverter_serial" "$sample_entity"

    return 1
  else
    log_message "INFO" "Entity verification successful. Sample entity exists."
    return 0
  fi
}

# Register an entity in the registry
register_entity_in_registry() {
  local inverter_serial=$1
  local entity_id=$2

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Attempting to register entity in registry: $entity_id"

  local payload="{\"entity_id\": \"$entity_id\", \"name\": \"SunSync $inverter_serial Battery SOC\", \"device_class\": \"battery\"}"

  local response=$(curl -s -w "\n%{http_code}" -X POST \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$api_base_url/config/entity_registry/register")

  local http_code=$(echo "$response" | tail -n1)
  local result=$(echo "$response" | head -n -1)

  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_message "WARNING" "Could not register entity in registry: $entity_id (HTTP $http_code)"
    log_message "WARNING" "Response: $result"
    return 1
  else
    log_message "INFO" "Successfully registered entity in registry: $entity_id"
    return 0
  fi
}

# Add a diagnostic function to debug Home Assistant configuration
diagnose_ha_setup() {
  log_message "INFO" "===== DIAGNOSTIC INFORMATION ====="

  # Check which authentication method is available
  if [ -n "$SUPERVISOR_TOKEN" ]; then
    log_message "INFO" "Using Supervisor token for authentication"
    log_message "INFO" "Token length: ${#SUPERVISOR_TOKEN}"
    log_message "INFO" "API URL: http://supervisor/core/api"
  else
    log_message "INFO" "Using long-lived token for authentication"
    log_message "INFO" "Home Assistant URL: $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT"
    log_message "INFO" "Token length: ${#HA_TOKEN}"
    log_message "INFO" "Token starting characters: ${HA_TOKEN:0:5}..."
  fi

  # Show addon info
  if command -v bashio >/dev/null 2>&1; then
    log_message "INFO" "Add-on version: $(bashio::addon.version)"
    log_message "INFO" "Add-on name: $(bashio::addon.name)"
  fi

  # Check if we can access Home Assistant at all
  log_message "INFO" "Testing basic connectivity..."
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  local basic_conn=$(curl -s -I -o /dev/null -w "%{http_code}" "$api_base_url/")
  log_message "INFO" "Basic connectivity: HTTP $basic_conn"

  # Validate token format if using long-lived token
  if [ -z "$SUPERVISOR_TOKEN" ] && [ -n "$HA_TOKEN" ]; then
    if [[ ! "$HA_TOKEN" =~ ^[a-zA-Z0-9_\.\-]+$ ]]; then
      log_message "WARNING" "Token contains potentially invalid characters"
    fi
  fi

  # Attempt to get API status
  log_message "INFO" "Testing API access..."
  local response=$(curl -s -w "\n%{http_code}" \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    "$api_base_url/")

  local http_code=$(echo "$response" | tail -n1)
  local result=$(echo "$response" | head -n -1)

  log_message "INFO" "API access result: HTTP $http_code"
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_message "ERROR" "API access failed"
  else
    log_message "INFO" "API access successful"

    # Check if we can see any entities
    local entities_count=$(curl -s -X GET \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      "$api_base_url/states" | grep -c "entity_id" || echo "0")

    log_message "INFO" "Found $entities_count entities in Home Assistant"

    # Look for our entities
    local our_entities=$(curl -s -X GET \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      "$api_base_url/states" | grep -c "sunsync" || echo "0")

    log_message "INFO" "Found $our_entities SunSync entities in Home Assistant"
  fi

  log_message "INFO" "===== END DIAGNOSTIC INFORMATION ====="
}
