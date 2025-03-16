#!/bin/bash
# SunSynk Integration - Entity Management Functions

# Create Home Assistant device for the inverter if it doesn't exist
create_device_if_needed() {
  local inverter_serial=$1
  local device_id="sunsynk_${inverter_serial}"

  log_message "INFO" "Ensuring device exists for inverter: $inverter_serial"

  # Get inverter info
  local inverter_model=$(jq -r '.data.model // "Unknown"' inverterinfo.json)
  local inverter_brand=$(jq -r '.data.brand // "Sunsynk"' inverterinfo.json)
  local inverter_firmware=$(jq -r '.data.firmwareVersion // "Unknown"' inverterinfo.json)
  local plant_name=$(jq -r '.data.plant.name // "Solar System"' inverterinfo.json)

  # Always try to create/update the device to ensure it exists
  local device_data="{
    \"config_entry_id\": null,
    \"connections\": [],
    \"identifiers\": [
      [
        \"solarsynk\",
        \"$inverter_serial\"
      ]
    ],
    \"manufacturer\": \"$inverter_brand\",
    \"model\": \"$inverter_model\",
    \"name\": \"SunSynk Inverter ($inverter_serial)\",
    \"sw_version\": \"$inverter_firmware\",
    \"via_device_id\": null,
    \"area_id\": null,
    \"name_by_user\": null,
    \"entry_type\": \"service\"
  }"

  # Register the device in Home Assistant
  local result=$(curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$device_data" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/config/device_registry")

  log_message "INFO" "Device registration result: $result"

  # Also create a device via MQTT as a fallback method
  local mqtt_data="{
    \"service\": \"mqtt.publish\",
    \"data\": {
      \"topic\": \"homeassistant/sensor/solarsynk_${inverter_serial}/config\",
      \"payload\": \"{\\\"device\\\":{\\\"identifiers\\\":[\\\"sunsynk_${inverter_serial}\\\"],\\\"manufacturer\\\":\\\"${inverter_brand}\\\",\\\"model\\\":\\\"${inverter_model}\\\",\\\"name\\\":\\\"SunSynk Inverter (${inverter_serial})\\\",\\\"sw_version\\\":\\\"${inverter_firmware}\\\"}}\",
      \"retain\": true
    }
  }"

  curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$mqtt_data" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/services/mqtt/publish" > /dev/null
}

# Create or update an entity
create_entity() {
  local sensor_id=$1
  local sensor_value=$2
  local friendly_name=$3
  local device_class=$4
  local state_class=$5
  local unit=$6
  local inverter_serial=$7

  # Skip if value is null or empty
  if [ "$sensor_value" == "null" ] || [ -z "$sensor_value" ]; then
    return 0
  fi

  # Entity ID
  local entity_id="sensor.solarsynk_${inverter_serial}_${sensor_id}"

  # Check if entity exists
  local entity_exists=0
  local response

  response=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $HA_TOKEN" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id")

  # Force entity creation regardless of whether it exists in states API
  if [ "$response" != "200" ]; then
    log_message "INFO" "Entity $entity_id does not exist. Creating it now..."
    entity_exists=0
  else
    log_message "INFO" "Entity $entity_id already exists. Updating it..."
    entity_exists=1
  fi

  # Prepare additional attributes
  local attributes="{\"friendly_name\": \"$friendly_name\""

  if [ ! -z "$device_class" ]; then
    attributes="$attributes, \"device_class\": \"$device_class\""
  fi

  if [ ! -z "$state_class" ]; then
    attributes="$attributes, \"state_class\": \"$state_class\""
  fi

  if [ ! -z "$unit" ]; then
    attributes="$attributes, \"unit_of_measurement\": \"$unit\""
  fi

  # Add device connection if it doesn't exist
  if [ $entity_exists -eq 0 ]; then
    attributes="$attributes, \"device\": {\"identifiers\": [\"sunsynk_${inverter_serial}\"], \"name\": \"SunSynk Inverter (${inverter_serial})\"}"
  fi

  attributes="$attributes}"

  # Create or update the entity state
  curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{\"attributes\": $attributes, \"state\": \"$sensor_value\"}" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id" > /dev/null

  # If this is a new entity, register it permanently
  if [ $entity_exists -eq 0 ]; then
    # Register the entity in Home Assistant registry for persistence
    log_message "INFO" "Registering entity $entity_id in Home Assistant registry..."

    local registry_data="{
      \"device_id\": \"sunsynk_${inverter_serial}\",
      \"entity_id\": \"$entity_id\",
      \"name\": \"$friendly_name\",
      \"disabled_by\": null
    }"

    if [ ! -z "$device_class" ]; then
      registry_data=$(echo $registry_data | sed 's/}$/,"original_device_class":"'$device_class'"}/')
    fi

    if [ ! -z "$unit" ]; then
      registry_data=$(echo $registry_data | sed 's/}$/,"unit_of_measurement":"'$unit'"}/')
    fi

    # Add platform information
    registry_data=$(echo $registry_data | sed 's/}$/,"platform":"solarsynk"}/')

    # Actually register the entity
    local register_response=$(curl -s -k -X POST \
      -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$registry_data" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/config/entity_registry/register")

    log_message "INFO" "Entity registration response: $register_response"

    # Also create a sensor via REST API as a fallback
    curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"platform\": \"rest\",
        \"name\": \"$friendly_name\",
        \"resource\": \"$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id\",
        \"value_template\": \"{{ value_json.state }}\",
        \"device_class\": \"$device_class\",
        \"state_class\": \"$state_class\",
        \"unit_of_measurement\": \"$unit\"
      }" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/services/homeassistant/reload_config_entry" > /dev/null

    # Create MQTT discovery entity as another fallback
    local mqtt_data="{
      \"service\": \"mqtt.publish\",
      \"data\": {
        \"topic\": \"homeassistant/sensor/solarsynk_${inverter_serial}/${sensor_id}/config\",
        \"payload\": \"{\\\"device_class\\\":\\\"$device_class\\\",\\\"state_class\\\":\\\"$state_class\\\",\\\"unit_of_measurement\\\":\\\"$unit\\\",\\\"name\\\":\\\"$friendly_name\\\",\\\"state_topic\\\":\\\"solarsynk/${inverter_serial}/${sensor_id}\\\",\\\"unique_id\\\":\\\"solarsynk_${inverter_serial}_${sensor_id}\\\",\\\"device\\\":{\\\"identifiers\\\":[\\\"sunsynk_${inverter_serial}\\\"],\\\"name\\\":\\\"SunSynk Inverter (${inverter_serial})\\\"}}\",
        \"retain\": true
      }
    }"

    curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$mqtt_data" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/services/mqtt/publish" > /dev/null

    # Publish the actual value
    local mqtt_value="{
      \"service\": \"mqtt.publish\",
      \"data\": {
        \"topic\": \"solarsynk/${inverter_serial}/${sensor_id}\",
        \"payload\": \"$sensor_value\",
        \"retain\": true
      }
    }"

    curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "$mqtt_value" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/services/mqtt/publish" > /dev/null
  }
}

# Get or define sensor configurations
get_sensor_configs() {
  # Define sensor configurations
  # Format: sensor_id|friendly_name|device_class|state_class|unit
  declare -A sensor_configs

  # Battery sensors
  sensor_configs["battery_capacity"]="Battery Capacity||measurement|Ah"
  sensor_configs["battery_chargevolt"]="Battery Charge Voltage|voltage|measurement|V"
  sensor_configs["battery_current"]="Battery Current|current|measurement|A"
  sensor_configs["battery_dischargevolt"]="Battery Discharge Voltage|voltage|measurement|V"
  sensor_configs["battery_power"]="Battery Power|power|measurement|W"
  sensor_configs["battery_soc"]="Battery SOC|battery|measurement|%"
  sensor_configs["battery_temperature"]="Battery Temp|temperature|measurement|°C"
  sensor_configs["battery_type"]="Battery Type|||"
  sensor_configs["battery_voltage"]="Battery Voltage|voltage|measurement|V"

  # Battery 1 sensors
  sensor_configs["battery1_voltage"]="Battery 1 Voltage|voltage|measurement|V"
  sensor_configs["battery1_current"]="Battery 1 Current|current|measurement|A"
  sensor_configs["battery1_power"]="Battery 1 Power|power|measurement|W"
  sensor_configs["battery1_soc"]="Battery 1 SOC|battery|measurement|%"
  sensor_configs["battery1_temperature"]="Battery 1 Temp|temperature|measurement|°C"
  sensor_configs["battery1_status"]="Battery 1 Status|||"

  # Battery 2 sensors
  sensor_configs["battery2_voltage"]="Battery 2 Voltage|voltage|measurement|V"
  sensor_configs["battery2_current"]="Battery 2 Current|current|measurement|A"
  sensor_configs["battery2_chargevolt"]="Battery 2 Charge Voltage|voltage|measurement|V"
  sensor_configs["battery_dischargevolt2"]="Battery 2 Discharge Voltage|voltage|measurement|V"
  sensor_configs["battery2_power"]="Battery 2 Power|power|measurement|W"
  sensor_configs["battery2_soc"]="Battery 2 SOC|battery|measurement|%"
  sensor_configs["battery2_temperature"]="Battery 2 Temp|temperature|measurement|°C"
  sensor_configs["battery2_status"]="Battery 2 Status|||"

  # Daily energy sensors
  sensor_configs["day_battery_charge"]="Daily Battery Charge|energy|total_increasing|kWh"
  sensor_configs["day_battery_discharge"]="Daily Battery Discharge|energy|total_increasing|kWh"
  sensor_configs["day_grid_export"]="Daily Grid Export|energy|total_increasing|kWh"
  sensor_configs["day_grid_import"]="Daily Grid Import|energy|total_increasing|kWh"
  sensor_configs["day_load_energy"]="Daily Load Energy|energy|total_increasing|kWh"
  sensor_configs["day_pv_energy"]="Daily PV Energy|energy|total_increasing|kWh"

  # Grid sensors
  sensor_configs["grid_connected_status"]="Grid Connection Status|||"
  sensor_configs["grid_frequency"]="Grid Freq|frequency|measurement|Hz"
  sensor_configs["grid_power"]="Grid Power|power|measurement|W"
  sensor_configs["grid_voltage"]="Grid Voltage|voltage|measurement|V"
  sensor_configs["grid_current"]="Grid Current|current|measurement|A"
  sensor_configs["grid_power1"]="Grid Power L1|power|measurement|W"
  sensor_configs["grid_voltage1"]="Grid Voltage L1|voltage|measurement|V"
  sensor_configs["grid_current1"]="Grid Current L1|current|measurement|A"
  sensor_configs["grid_power2"]="Grid Power L2|power|measurement|W"
  sensor_configs["grid_voltage2"]="Grid Voltage L2|voltage|measurement|V"
  sensor_configs["grid_current2"]="Grid Current L2|current|measurement|A"

  # Inverter sensors
  sensor_configs["inverter_frequency"]="Inverter Freq|frequency|measurement|Hz"
  sensor_configs["inverter_current"]="Inverter Current|current|measurement|A"
  sensor_configs["inverter_power"]="Inverter Power|power|measurement|W"
  sensor_configs["inverter_voltage"]="Inverter Voltage|voltage|measurement|V"
  sensor_configs["inverter_current1"]="Inverter Current L1|current|measurement|A"
  sensor_configs["inverter_power1"]="Inverter Power L1|power|measurement|W"
  sensor_configs["inverter_voltage1"]="Inverter Voltage L1|voltage|measurement|V"
  sensor_configs["inverter_current2"]="Inverter Current L2|current|measurement|A"
  sensor_configs["inverter_power2"]="Inverter Power L2|power|measurement|W"
  sensor_configs["inverter_voltage2"]="Inverter Voltage L2|voltage|measurement|V"

  # Load sensors
  sensor_configs["load_frequency"]="Load Freq|frequency|measurement|Hz"
  sensor_configs["load_voltage"]="Load Voltage|voltage|measurement|V"
  sensor_configs["load_voltage1"]="Load Voltage L1|voltage|measurement|V"
  sensor_configs["load_voltage2"]="Load Voltage L2|voltage|measurement|V"
  sensor_configs["load_current"]="Load Current|current|measurement|A"
  sensor_configs["load_current1"]="Load Current L1|current|measurement|A"
  sensor_configs["load_current2"]="Load Current L2|current|measurement|A"
  sensor_configs["load_power"]="Load Power|power|measurement|W"
  sensor_configs["load_power1"]="Load Power L1|power|measurement|W"
  sensor_configs["load_power2"]="Load Power L2|power|measurement|W"
  sensor_configs["load_upsPowerL1"]="Load UPS Power L1|power|measurement|W"
  sensor_configs["load_upsPowerL2"]="Load UPS Power L2|power|measurement|W"
  sensor_configs["load_upsPowerL3"]="Load UPS Power L3|power|measurement|W"
  sensor_configs["load_upsPowerTotal"]="Load UPS Power Total|power|measurement|W"
  sensor_configs["load_totalpower"]="Load Total Power|power|measurement|W"

  # Solar sensors
  sensor_configs["pv1_current"]="PV1 Current|current|measurement|A"
  sensor_configs["pv1_power"]="PV1 Power|power|measurement|W"
  sensor_configs["pv1_voltage"]="PV1 Voltage|voltage|measurement|V"
  sensor_configs["pv2_current"]="PV2 Current|current|measurement|A"
  sensor_configs["pv2_power"]="PV2 Power|power|measurement|W"
  sensor_configs["pv2_voltage"]="PV2 Voltage|voltage|measurement|V"
  sensor_configs["pv3_current"]="PV3 Current|current|measurement|A"
  sensor_configs["pv3_power"]="PV3 Power|power|measurement|W"
  sensor_configs["pv3_voltage"]="PV3 Voltage|voltage|measurement|V"
  sensor_configs["pv4_current"]="PV4 Current|current|measurement|A"
  sensor_configs["pv4_power"]="PV4 Power|power|measurement|W"
  sensor_configs["pv4_voltage"]="PV4 Voltage|voltage|measurement|V"

  # Settings sensors
  sensor_configs["prog1_time"]="Prog1 Time|timestamp||"
  sensor_configs["prog2_time"]="Prog2 Time|timestamp||"
  sensor_configs["prog3_time"]="Prog3 Time|timestamp||"
  sensor_configs["prog4_time"]="Prog4 Time|timestamp||"
  sensor_configs["prog5_time"]="Prog5 Time|timestamp||"
  sensor_configs["prog6_time"]="Prog6 Time|timestamp||"
  sensor_configs["prog1_charge"]="Prog1 Charge|||"
  sensor_configs["prog2_charge"]="Prog2 Charge|||"
  sensor_configs["prog3_charge"]="Prog3 Charge|||"
  sensor_configs["prog4_charge"]="Prog4 Charge|||"
  sensor_configs["prog5_charge"]="Prog5 Charge|||"
  sensor_configs["prog6_charge"]="Prog6 Charge|||"
  sensor_configs["prog1_capacity"]="Prog1 Capacity|||"
  sensor_configs["prog2_capacity"]="Prog2 Capacity|||"
  sensor_configs["prog3_capacity"]="Prog3 Capacity|||"
  sensor_configs["prog4_capacity"]="Prog4 Capacity|||"
  sensor_configs["prog5_capacity"]="Prog5 Capacity|||"
  sensor_configs["prog6_capacity"]="Prog6 Capacity|||"

  # Misc sensors
  sensor_configs["battery_shutdown_cap"]="Battery Shutdown Cap|battery|measurement|%"
  sensor_configs["use_timer"]="Use Timer|||"
  sensor_configs["priority_load"]="Priority Load|||"
  sensor_configs["overall_state"]="Inverter Overall State|||"
  sensor_configs["dc_temp"]="Inverter DC Temp|temperature|measurement|°C"
  sensor_configs["ac_temp"]="Inverter AC Temp|temperature|measurement|°C"

  echo "${sensor_configs[@]}"
}

# Create or update Home Assistant entities
update_ha_entities() {
  local inverter_serial=$1
  local entity_log_output=""

  if [ "$ENABLE_VERBOSE_LOG" != "true" ]; then
    entity_log_output="-o tmpcurllog.json"
  fi

  log_message "INFO" "Attempting to update entities for inverter: $inverter_serial"
  log_message "INFO" "Sending to $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT"
  echo ------------------------------------------------------------------------------

  # First, ensure the device exists
  create_device_if_needed "$inverter_serial"

  # Get the sensor configurations
  declare -A sensor_configs
  eval "sensor_configs=($(get_sensor_configs))"

  # Process all sensor values and create/update entities
  for sensor_id in "${!sensor_data[@]}"; do
    # Only process if we have a configuration for this sensor
    if [ -n "${sensor_configs[$sensor_id]}" ]; then
      # Parse the config
      IFS='|' read -r friendly_name device_class state_class unit <<< "${sensor_configs[$sensor_id]}"

      # Create or update the entity
      create_entity "$sensor_id" "${sensor_data[$sensor_id]}" "$friendly_name" "$device_class" "$state_class" "$unit" "$inverter_serial"
    fi
  done

  # Force reload of entities to ensure they appear in Home Assistant
  log_message "INFO" "Reloading Home Assistant entities..."
  curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
    -H "Content-Type: application/json" \
    -d "{}" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/services/homeassistant/reload_core_config" > /dev/null

  return 0
}