#!/usr/bin/with-contenv bashio

# ==============================================================================
# Home Assistant Entity Management
# Description: Functions for creating and updating Home Assistant entities
# ==============================================================================

# Update Home Assistant entities for a specific inverter
update_ha_entities() {
  local inverter_serial=$1
  local success=0  # Using 0 for success as per bash convention

  # Log the start of entity updates
  log_message "INFO" "Updating Home Assistant entities for inverter: $inverter_serial"

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
      log_message "DEBUG" "Updated entity: $entity_id with value: $value"
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

  # Build the Home Assistant API URL
  local ha_api_url="$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id"

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
    -H "Authorization: Bearer $HA_TOKEN" \
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
  log_message "INFO" "Testing connection to Home Assistant at $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/"

  local curl_cmd="curl -s -I -o /dev/null -w \"%{http_code}\" \
    -H \"Authorization: Bearer $HA_TOKEN\" \
    -H \"Content-Type: application/json\" \
    \"$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/\""

  log_message "DEBUG" "Command: $curl_cmd"
  local result=$(eval $curl_cmd)

  if [ "$result" = "200" ] || [ "$result" = "201" ]; then
    log_message "INFO" "Successfully connected to Home Assistant API"
    # Check the long-lived token is valid by attempting to get states
    local auth_test=$(curl -s -X GET \
      -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states")

    if [[ "$auth_test" == *"unauthorized"* ]] || [[ "$auth_test" == *"error"* ]]; then
      log_message "ERROR" "Authentication failed. Your long-lived token may be invalid."
      log_message "ERROR" "Response: $auth_test"
      return 1
    fi

    return 0
  else
    log_message "ERROR" "Failed to connect to Home Assistant API. HTTP Status: $result"
    log_message "ERROR" "Please verify:"
    log_message "ERROR" "1. Home Assistant is running at $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT"
    log_message "ERROR" "2. Your Home_Assistant_IP setting ($HA_IP) is correct"
    log_message "ERROR" "3. Your Home_Assistant_PORT setting ($HA_PORT) is correct"
    log_message "ERROR" "4. Enable_HTTPS setting ($ENABLE_HTTPS) matches your Home Assistant configuration"
    log_message "ERROR" "5. Your HA_LongLiveToken is valid and has not expired"

    # Try a basic connection without auth to see if the server is reachable
    local basic_test=$(curl -s -I -o /dev/null -w "%{http_code}" "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/")
    log_message "ERROR" "Basic connection test result (no auth): HTTP $basic_test"

    return 1
  fi
}

# Verify at least some entities were successfully created
verify_entities_created() {
  local inverter_serial=$1
  local sample_entity="sensor.sunsync_${inverter_serial}_battery_soc"

  log_message "INFO" "Verifying entity creation by checking for sample entity: $sample_entity"

  local response=$(curl -s -w "\n%{http_code}" -X GET \
    -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$sample_entity")

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
      -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states" | grep -c "entity_id")

    log_message "INFO" "Found approximately $all_entities entities total in Home Assistant"
    log_message "INFO" "If this number is 0, your token likely doesn't have correct permissions"

    # Search for any of our entities
    local our_entities=$(curl -s -X GET \
      -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states" | grep -c "sunsync")

    log_message "INFO" "Found approximately $our_entities SunSync entities"

    return 1
  else
    log_message "INFO" "Entity verification successful. Sample entity exists."
    return 0
  fi
}

# Add a diagnostic function to debug Home Assistant configuration
diagnose_ha_setup() {
  log_message "INFO" "===== DIAGNOSTIC INFORMATION ====="
  log_message "INFO" "Home Assistant URL: $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT"
  log_message "INFO" "Token length: ${#HA_TOKEN}"
  log_message "INFO" "Token starting characters: ${HA_TOKEN:0:5}..."

  # Check if we can access Home Assistant at all
  log_message "INFO" "Testing basic connectivity..."
  local basic_conn=$(curl -s -I -o /dev/null -w "%{http_code}" "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/")
  log_message "INFO" "Basic connectivity: HTTP $basic_conn"

  # Validate token format
  if [[ ! "$HA_TOKEN" =~ ^[a-zA-Z0-9_\.\-]+$ ]]; then
    log_message "WARNING" "Token contains potentially invalid characters"
  fi

  # Attempt to get API status
  log_message "INFO" "Testing API access with token..."
  local response=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/")

  local http_code=$(echo "$response" | tail -n1)
  local result=$(echo "$response" | head -n -1)

  log_message "INFO" "API access result: HTTP $http_code"
  if [ "$http_code" != "200" ] && [ "$http_code" != "201" ]; then
    log_message "ERROR" "API access failed"
  else
    log_message "INFO" "API access successful"
  fi

  log_message "INFO" "===== END DIAGNOSTIC INFORMATION ====="
}
