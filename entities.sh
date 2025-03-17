#!/usr/bin/with-contenv bashio

# ==============================================================================
# Home Assistant Entity Management
# Description: Functions for creating and updating Home Assistant entities
# ==============================================================================

# Update Home Assistant entities for a specific inverter
update_ha_entities() {
  local inverter_serial=$1
  local success=true

  # Log the start of entity updates
  log_message "INFO" "Updating Home Assistant entities for inverter: $inverter_serial"

  # Iterate through all sensor data points and create/update entities
  for key in "${!sensor_data[@]}"; do
    local value="${sensor_data[$key]}"
    local entity_id="sensor.sunsync_${inverter_serial}_${key}"
    local friendly_name="SunSync ${inverter_serial} ${key}"

    # Create or update the entity
    if ! create_or_update_entity "$entity_id" "$friendly_name" "$value"; then
      success=false
      log_message "ERROR" "Failed to update entity: $entity_id with value: $value"
    elif [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
      log_message "DEBUG" "Updated entity: $entity_id with value: $value"
    fi
  done

  return $success
}

# Function to create or update a single Home Assistant entity
create_or_update_entity() {
  local entity_id=$1
  local friendly_name=$2
  local state=$3

  # Use Home Assistant API to create/update the entity
  local result=$(curl -s -X POST \
    -H "Authorization: Bearer $SUPERVISOR_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"state\": \"$state\", \"attributes\": {\"friendly_name\": \"$friendly_name\", \"unit_of_measurement\": \"\", \"device_class\": \"\"}}" \
    "http://supervisor/core/api/states/$entity_id")

  # Check if the API call was successful
  if [ -z "$result" ] || [[ "$result" == *"error"* ]]; then
    return 1
  else
    return 0
  fi
}

# Additional entity-related functions can be added here
