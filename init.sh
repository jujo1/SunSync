#!/bin/bash

# ==============================================================================
# SunSync Home Assistant Integration
# Initialization Script
# Description: Prepares Home Assistant by initializing entities properly
# ==============================================================================

# Initialize the SunSync environment
initialize_sunsync() {
  log_message "INFO" "Starting SunSync initialization process"

  # Check if we can connect to Home Assistant
  if ! check_ha_connectivity; then
    log_message "ERROR" "Cannot connect to Home Assistant during initialization. Will retry later."
    return 1
  fi

  # For each inverter, check existing entities and create placeholders if needed
  IFS=';'
  for inverter_serial in $SUNSYNK_SERIAL; do
    log_message "INFO" "Initializing entities for inverter: $inverter_serial"

    # Check for existing entities and only create what's missing
    check_and_create_entities "$inverter_serial"

    # Create or check for the settings helper entity
    create_settings_helper "$inverter_serial"
  done
  unset IFS

  log_message "INFO" "SunSync initialization completed"
  return 0
}

# Check for existing entities and create only what's missing
check_and_create_entities() {
  local inverter_serial=$1
  local entity_prefix="sensor.${ENTITY_PREFIX}_${inverter_serial}_"

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Checking for existing entities with prefix: $entity_prefix"

  # Get a list of all entities
  local all_entities=$(curl -s -X GET \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    "$api_base_url/states" | jq -r '.[].entity_id' | grep -c "^$entity_prefix" || echo "0")

  log_message "INFO" "Found $all_entities existing entities for $inverter_serial"

  # If we found more than 10 entities, assume they're already properly set up
  if [ "$all_entities" -gt 10 ]; then
    log_message "INFO" "Found a substantial number of existing entities, skipping entity creation."
    return 0
  else
    log_message "INFO" "Minimal or no existing entities found, creating placeholders."
    create_placeholder_entities "$inverter_serial"
    return 0
  fi
}

# Create initial placeholder entities for critical values
create_placeholder_entities() {
  local inverter_serial=$1
  local success=true

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Creating placeholder entities for inverter $inverter_serial"

  # Define a list of important entities to create as placeholders
  local key_entities=(
    "battery_soc"
    "battery_power"
    "grid_power"
    "load_power"
    "pv1_power"
    "pv2_power"
    "inverter_power"
    "day_battery_charge"
    "day_battery_discharge"
    "day_grid_import"
    "day_grid_export"
    "day_pv_energy"
    "day_load_energy"
    "battery_temperature"
    "overall_state"
  )

  # Create each placeholder entity if it doesn't exist
  for key in "${key_entities[@]}"; do
    local entity_id
    local friendly_name

    if [ "$INCLUDE_SERIAL_IN_NAME" = "true" ]; then
      entity_id="sensor.${ENTITY_PREFIX}_${inverter_serial}_${key}"
      friendly_name="${ENTITY_PREFIX^} ${inverter_serial} ${key}"
    else
      entity_id="sensor.${ENTITY_PREFIX}_${key}"
      friendly_name="${ENTITY_PREFIX^} ${key}"
    fi

    local uom=""
    local device_class=""

    # Set appropriate unit and device class
    case "$key" in
      *_power)
        uom="W"
        device_class="power"
        ;;
      *_energy|*_charge|*_discharge)
        uom="kWh"
        device_class="energy"
        ;;
      *_soc)
        uom="%"
        device_class="battery"
        ;;
      *_temperature)
        uom="°C"
        device_class="temperature"
        ;;
    esac

    # Check if entity already exists
    local entity_check=$(curl -s -X GET \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      "$api_base_url/states/$entity_id")

    if [[ "$entity_check" == *"not found"* ]] || [[ -z "$entity_check" ]]; then
      # Entity doesn't exist, create it
      log_message "INFO" "Creating placeholder for missing entity: $entity_id"
      if ! create_entity "$entity_id" "$friendly_name" "unknown" "$uom" "$device_class"; then
        success=false
        log_message "WARNING" "Failed to create placeholder entity: $entity_id"
      fi
    else
      log_message "INFO" "Entity already exists, preserving: $entity_id"
    fi
  done

  if [ "$success" = true ]; then
    log_message "INFO" "Successfully created placeholder entities for $inverter_serial"
    return 0
  else
    log_message "WARNING" "Some placeholder entities could not be created"
    return 1
  fi
}

# Create a single entity
create_entity() {
  local entity_id=$1
  local friendly_name=$2
  local state=$3
  local unit_of_measurement=$4
  local device_class=$5

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    log_message "DEBUG" "Creating entity: $entity_id with state: $state"
  fi

  # Build attributes JSON
  local attributes="{\"friendly_name\": \"$friendly_name\""

  # Add unit of measurement if provided
  if [ ! -z "$unit_of_measurement" ]; then
    attributes="$attributes, \"unit_of_measurement\": \"$unit_of_measurement\""
  fi

  # Add device class if provided
  if [ ! -z "$device_class" ]; then
    attributes="$attributes, \"device_class\": \"$device_class\""
  fi

  # Close attributes JSON
  attributes="$attributes}"

  # Build payload
  local payload="{\"state\": \"$state\", \"attributes\": $attributes}"

  # Make API call
  local result=$(curl -s -X POST \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "$api_base_url/states/$entity_id")

  if [[ "$result" == *"error"* ]]; then
    log_message "WARNING" "Failed to create entity $entity_id: $result"
    return 1
  fi

  # Attempt to register the entity in the registry
  register_entity_in_registry "$inverter_serial" "$entity_id" "$friendly_name" "$device_class"

  return 0
}

# Create settings helper entity for inverter configuration
create_settings_helper() {
  local inverter_serial=$1
  local entity_id="input_text.${ENTITY_PREFIX}_${inverter_serial}_inverter_settings"
  local friendly_name="${ENTITY_PREFIX^} ${inverter_serial} Settings"

  # Get the authentication header and API base URL
  local auth_header=$(get_auth_header)
  local api_base_url=$(get_api_base_url)

  log_message "INFO" "Checking for settings helper entity: $entity_id"

  # Check if entity already exists
  local entity_check=$(curl -s -X GET \
    -H "$auth_header" \
    -H "Content-Type: application/json" \
    "$api_base_url/states/$entity_id")

  if [[ "$entity_check" == *"not found"* ]] || [[ -z "$entity_check" ]]; then
    log_message "INFO" "Creating settings helper entity: $entity_id"

    # Create the input_text helper via Home Assistant API
    local payload="{
      \"name\": \"${friendly_name}\",
      \"icon\": \"mdi:solar-power-variant\",
      \"max\": 1024,
      \"min\": 0,
      \"mode\": \"text\",
      \"initial\": \"\"
    }"

    local result=$(curl -s -X POST \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$api_base_url/services/input_text/reload")

    # Helper creation, then set its initial state
    curl -s -X POST \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      -d "{\"entity_id\": \"$entity_id\"}" \
      "$api_base_url/services/input_text/create"

    # Set the initial empty value
    curl -s -X POST \
      -H "$auth_header" \
      -H "Content-Type: application/json" \
      -d "{\"entity_id\": \"$entity_id\", \"value\": \"\"}" \
      "$api_base_url/services/input_text/set_value"

    log_message "INFO" "Settings helper entity created: $entity_id"
  else
    log_message "INFO" "Settings helper entity already exists: $entity_id"
  fi

  return 0
}

# Register entities with Home Assistant (to make them appear in UI)
register_entities_with_ha() {
  local inverter_serial=$1

  log_message "INFO" "Registering entities with Home Assistant for inverter $inverter_serial"

  # This would typically involve adding entities to Home Assistant's registry
  # However, this is typically managed automatically by Home Assistant
  # We're including this function for potential future use

  return 0
}
