#!/usr/bin/with-contenv bashio
set -e

# SunSynk Home Assistant Integration
# Author: Original by martinville, refactored on March 15, 2025
# Description: Connects to the SunSynk API and creates/updates Home Assistant entities with solar system data
#
# This script has been refactored to:
# - Improve error handling
# - Dynamically create Home Assistant entities
# - Follow better bash practices
# - Improve code structure and readability
# - Add better retry mechanisms for API calls

# Log header with timestamp
log_header() {
  local dt=$(date '+%d/%m/%Y %H:%M:%S')
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "-- SynSync - Log"
  echo "------------------------------------------------------------------------------"
  echo "Script execution date & time: $dt"
}

# Load configuration from Home Assistant add-on options
load_config() {
  CONFIG_PATH=config.json
  SUNSYNK_USER="$(bashio::config 'sunsynk_user')"
  SUNSYNK_PASS="$(bashio::config 'sunsynk_pass')"
  SUNSYNK_SERIAL="$(bashio::config 'sunsynk_serial')"
  HA_TOKEN="$(bashio::config 'HA_LongLiveToken')"
  HA_IP="$(bashio::config 'Home_Assistant_IP')"
  HA_PORT="$(bashio::config 'Home_Assistant_PORT')"
  REFRESH_RATE="$(bashio::config 'Refresh_rate')"
  ENABLE_HTTPS="$(bashio::config 'Enable_HTTPS')"
  ENABLE_VERBOSE_LOG="$(bashio::config 'Enable_Verbose_Log')"
  SETTINGS_HELPER_ENTITY="$(bashio::config 'Settings_Helper_Entity')"

  VarCurrentDate=$(date +%Y-%m-%d)

  if [ "$ENABLE_HTTPS" == "true" ]; then
    HTTP_CONNECT_TYPE="https"
  else
    HTTP_CONNECT_TYPE="http"
  fi

  echo "Verbose logging is set to: $ENABLE_VERBOSE_LOG"
  echo "HTTP Connect type: $HTTP_CONNECT_TYPE"
  echo "Refresh rate set to: $REFRESH_RATE seconds"
}

# Clean up old data files
cleanup_old_data() {
  echo "Cleaning up old data."
  rm -rf pvindata.json griddata.json loaddata.json batterydata.json outputdata.json dcactemp.json inverterinfo.json settings.json token.json
}

# Get authentication token
get_auth_token() {
  echo "Getting bearer token from solar service provider's API."

  local retry_count=0
  local max_retries=3

  while true; do
    # Fetch the token using curl with proper error handling
    if ! curl -s -f -S -k -X POST -H "Content-Type: application/json" \
         https://api.sunsynk.net/oauth/token \
         -d '{"areaCode": "sunsynk","client_id": "csp-web","grant_type": "password","password": "'"$SUNSYNK_PASS"'","source": "sunsynk","username": "'"$SUNSYNK_USER"'"}' \
         -o token.json; then

      echo "Error getting token (curl exit code $?). Retrying in 30 seconds..."
      sleep 30

      retry_count=$((retry_count + 1))
      if [ $retry_count -ge $max_retries ]; then
        echo "Maximum retries reached. Cannot obtain auth token."
        return 1
      fi
    else
      # Check verbose logging
      if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
        echo "Raw token data"
        echo ------------------------------------------------------------------------------
        echo "token.json"
        cat token.json
        echo ------------------------------------------------------------------------------
      fi

      # Parse token from response
      SERVER_API_BEARER_TOKEN=$(jq -r '.data.access_token' token.json)
      SERVER_API_BEARER_TOKEN_SUCCESS=$(jq -r '.success' token.json)

      if [ "$SERVER_API_BEARER_TOKEN_SUCCESS" == "true" ]; then
        echo "Valid token retrieved."
        echo "Bearer Token length: ${#SERVER_API_BEARER_TOKEN}"
        return 0
      else
        SERVER_API_BEARER_TOKEN_MSG=$(jq -r '.msg' token.json)
        echo "Invalid token received: $SERVER_API_BEARER_TOKEN_MSG. Retrying after a sleep..."
        sleep 30

        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          echo "Maximum retries reached. Cannot obtain auth token."
          return 1
        fi
      fi
    fi
  done
}

# Validate token
validate_token() {
  if [ -z "$SERVER_API_BEARER_TOKEN" ]; then
    echo "****Token could not be retrieved due to the following possibilities****"
    echo "Incorrect setup, please check the configuration tab."
    echo "Either this HA instance cannot reach Sunsynk.net due to network problems or the Sunsynk server is down."
    echo "The Sunsynk server admins are rejecting due to too frequent connection requests."
    echo ""
    echo "This Script will not continue but will retry on next iteration. No values were updated."
    return 1
  fi

  echo "Sunsynk Server API Token: Hidden for security reasons"
  echo "Note: Setting the refresh rate of this addon to be lower than the update rate of the SunSynk server will not increase the actual update rate."
  return 0
}

# Fetch data for a specific inverter
fetch_inverter_data() {
  local inverter_serial=$1
  local curl_error=0

  echo ""
  echo "Fetching data for serial: $inverter_serial"
  echo "Please wait while curl is fetching input, grid, load, battery & output data..."

  # Helper function to fetch data with retries
  fetch_endpoint() {
    local endpoint=$1
    local output_file=$2
    local retry_count=0
    local max_retries=3

    while [ $retry_count -lt $max_retries ]; do
      if curl -s -f -S -k -X GET \
         -H "Content-Type: application/json" \
         -H "authorization: Bearer $SERVER_API_BEARER_TOKEN" \
         "$endpoint" -o "$output_file"; then
        return 0
      else
        echo "Error: Request failed for $output_file, attempt $(($retry_count + 1))/$max_retries"
        retry_count=$((retry_count + 1))

        if [ $retry_count -lt $max_retries ]; then
          echo "Retrying in 5 seconds..."
          sleep 5
        fi
      fi
    done

    return 1
  }

  # Fetch all endpoints with retries
  # PV input data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/$inverter_serial/realtime/input" "pvindata.json"; then
    curl_error=1
  fi

  # Grid data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/grid/$inverter_serial/realtime?sn=$inverter_serial" "griddata.json"; then
    curl_error=1
  fi

  # Load data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/load/$inverter_serial/realtime?sn=$inverter_serial" "loaddata.json"; then
    curl_error=1
  fi

  # Battery data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/battery/$inverter_serial/realtime?sn=$inverter_serial&lan=en" "batterydata.json"; then
    curl_error=1
  fi

  # Output data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/$inverter_serial/realtime/output" "outputdata.json"; then
    curl_error=1
  fi

  # Temperature data
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/$inverter_serial/output/day?lan=en&date=$VarCurrentDate&column=dc_temp,igbt_temp" "dcactemp.json"; then
    curl_error=1
  fi

  # Inverter info
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/inverter/$inverter_serial" "inverterinfo.json"; then
    curl_error=1
  fi

  # Settings
  if ! fetch_endpoint "https://api.sunsynk.net/api/v1/common/setting/$inverter_serial/read" "settings.json"; then
    curl_error=1
  fi

  if [ $curl_error -eq 1 ]; then
    echo "Some data endpoints failed to fetch. Data may be incomplete."
  fi

  return $curl_error
}

# Create Home Assistant device for the inverter if it doesn't exist
create_device_if_needed() {
  local inverter_serial=$1
  local device_id="sunsynk_${inverter_serial}"

  # Check if device exists
  local response=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $HA_TOKEN" \
    "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/config/device_registry?device_id=$device_id")

  if [ "$response" != "200" ]; then
    echo "Creating device for inverter: $inverter_serial"

    # Get inverter info
    local inverter_model=$(jq -r '.data.model // "Unknown"' inverterinfo.json)
    local inverter_brand=$(jq -r '.data.brand // "Sunsynk"' inverterinfo.json)
    local inverter_firmware=$(jq -r '.data.firmwareVersion // "Unknown"' inverterinfo.json)
    local plant_name=$(jq -r '.data.plant.name // "Solar System"' inverterinfo.json)

    # Register the device in Home Assistant
    curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{
        \"identifiers\": [\"sunsynk_$inverter_serial\"],
        \"name\": \"Sunsynk Inverter ($inverter_serial)\",
        \"manufacturer\": \"$inverter_brand\",
        \"model\": \"$inverter_model\",
        \"sw_version\": \"$inverter_firmware\",
        \"via_device_id\": null,
        \"area_id\": null,
        \"name_by_user\": \"$plant_name Inverter\"
      }" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/config/device_registry" > /dev/null
  fi
}

# Parse data from JSON files
parse_inverter_data() {
  local inverter_serial=$1

  # Show inverter information
  local inverterinfo_brand=$(jq -r '.data.brand' inverterinfo.json)
  local inverterinfo_status=$(jq -r '.data.status' inverterinfo.json)
  local inverterinfo_runstatus=$(jq -r '.data.runStatus' inverterinfo.json)
  local inverterinfo_ratepower=$(jq -r '.data.ratePower' inverterinfo.json)
  local inverterinfo_plantid=$(jq -r '.data.plant.id' inverterinfo.json)
  local inverterinfo_plantname=$(jq -r '.data.plant.name' inverterinfo.json)
  local inverterinfo_serial=$(jq -r '.data.sn' inverterinfo.json)

  echo ------------------------------------------------------------------------------
  echo "Inverter Information"
  echo "Brand: $inverterinfo_brand"
  echo "Status: $inverterinfo_runstatus"
  echo "Max Watts: $inverterinfo_ratepower"
  echo "Plant ID: $inverterinfo_plantid"
  echo "Plant Name: $inverterinfo_plantname"
  echo "Inverter S/N: $inverterinfo_serial"
  echo ------------------------------------------------------------------------------

  echo "Data fetched for serial $inverter_serial. Enable verbose logging to see more information."

  # Parse all the different data points
  # Create an associative array to store all sensor data
  declare -A sensor_data

  # Battery data
  sensor_data["battery_capacity"]=$(jq -r '.data.capacity' batterydata.json)
  sensor_data["battery_chargevolt"]=$(jq -r '.data.chargeVolt' batterydata.json)
  sensor_data["battery_current"]=$(jq -r '.data.current' batterydata.json)
  sensor_data["battery_dischargevolt"]=$(jq -r '.data.dischargeVolt' batterydata.json)
  sensor_data["battery_power"]=$(jq -r '.data.power' batterydata.json)
  sensor_data["battery_soc"]=$(jq -r '.data.soc' batterydata.json)
  sensor_data["battery_temperature"]=$(jq -r '.data.temp' batterydata.json)
  sensor_data["battery_type"]=$(jq -r '.data.type' batterydata.json)
  sensor_data["battery_voltage"]=$(jq -r '.data.voltage' batterydata.json)

  # Battery 1
  sensor_data["battery1_voltage"]=$(jq -r '.data.batteryVolt1' batterydata.json)
  sensor_data["battery1_current"]=$(jq -r '.data.batteryCurrent1' batterydata.json)
  sensor_data["battery1_power"]=$(jq -r '.data.batteryPower1' batterydata.json)
  sensor_data["battery1_soc"]=$(jq -r '.data.batterySoc1' batterydata.json)
  sensor_data["battery1_temperature"]=$(jq -r '.data.batteryTemp1' batterydata.json)
  sensor_data["battery1_status"]=$(jq -r '.data.status' batterydata.json)

  # Battery 2
  sensor_data["battery2_voltage"]=$(jq -r '.data.batteryVolt2' batterydata.json)
  sensor_data["battery2_current"]=$(jq -r '.data.batteryCurrent2' batterydata.json)
  sensor_data["battery2_chargevolt"]=$(jq -r '.data.chargeVolt2' batterydata.json)
  sensor_data["battery_dischargevolt2"]=$(jq -r '.data.dischargeVolt2' batterydata.json)
  sensor_data["battery2_power"]=$(jq -r '.data.batteryPower2' batterydata.json)
  sensor_data["battery2_soc"]=$(jq -r '.data.batterySoc2' batterydata.json)
  sensor_data["battery2_temperature"]=$(jq -r '.data.batteryTemp2' batterydata.json)
  sensor_data["battery2_status"]=$(jq -r '.data.batteryStatus2' batterydata.json)

  # Daily energy figures
  sensor_data["day_battery_charge"]=$(jq -r '.data.etodayChg' batterydata.json)
  sensor_data["day_battery_discharge"]=$(jq -r '.data.etodayDischg' batterydata.json)
  sensor_data["day_grid_export"]=$(jq -r '.data.etodayTo' griddata.json)
  sensor_data["day_grid_import"]=$(jq -r '.data.etodayFrom' griddata.json)
  sensor_data["day_load_energy"]=$(jq -r '.data.dailyUsed' loaddata.json)
  sensor_data["day_pv_energy"]=$(jq -r '.data.etoday' pvindata.json)

  # Grid data
  sensor_data["grid_connected_status"]=$(jq -r '.data.status' griddata.json)
  sensor_data["grid_frequency"]=$(jq -r '.data.fac' griddata.json)
  sensor_data["grid_power"]=$(jq -r '.data.vip[0].power' griddata.json)
  sensor_data["grid_voltage"]=$(jq -r '.data.vip[0].volt' griddata.json)
  sensor_data["grid_current"]=$(jq -r '.data.vip[0].current' griddata.json)
  sensor_data["grid_power1"]=$(jq -r '.data.vip[1].power' griddata.json)
  sensor_data["grid_voltage1"]=$(jq -r '.data.vip[1].volt' griddata.json)
  sensor_data["grid_current1"]=$(jq -r '.data.vip[1].current' griddata.json)
  sensor_data["grid_power2"]=$(jq -r '.data.vip[2].power' griddata.json)
  sensor_data["grid_voltage2"]=$(jq -r '.data.vip[2].volt' griddata.json)
  sensor_data["grid_current2"]=$(jq -r '.data.vip[2].current' griddata.json)

  # Inverter data
  sensor_data["inverter_frequency"]=$(jq -r '.data.fac' outputdata.json)
  sensor_data["inverter_current"]=$(jq -r '.data.vip[0].current' outputdata.json)
  sensor_data["inverter_power"]=$(jq -r '.data.vip[0].power' outputdata.json)
  sensor_data["inverter_voltage"]=$(jq -r '.data.vip[0].volt' outputdata.json)
  sensor_data["inverter_current1"]=$(jq -r '.data.vip[1].current' outputdata.json)
  sensor_data["inverter_power1"]=$(jq -r '.data.vip[1].power' outputdata.json)
  sensor_data["inverter_voltage1"]=$(jq -r '.data.vip[1].volt' outputdata.json)
  sensor_data["inverter_current2"]=$(jq -r '.data.vip[2].current' outputdata.json)
  sensor_data["inverter_power2"]=$(jq -r '.data.vip[2].power' outputdata.json)
  sensor_data["inverter_voltage2"]=$(jq -r '.data.vip[2].volt' outputdata.json)

  # Load data
  sensor_data["load_frequency"]=$(jq -r '.data.loadFac' loaddata.json)
  sensor_data["load_voltage"]=$(jq -r '.data.vip[0].volt' loaddata.json)
  sensor_data["load_voltage1"]=$(jq -r '.data.vip[1].volt' loaddata.json)
  sensor_data["load_voltage2"]=$(jq -r '.data.vip[2].volt' loaddata.json)
  sensor_data["load_current"]=$(jq -r '.data.vip[0].current' loaddata.json)
  sensor_data["load_current1"]=$(jq -r '.data.vip[1].current' loaddata.json)
  sensor_data["load_current2"]=$(jq -r '.data.vip[2].current' loaddata.json)
  sensor_data["load_power"]=$(jq -r '.data.vip[0].power' loaddata.json)
  sensor_data["load_power1"]=$(jq -r '.data.vip[1].power' loaddata.json)
  sensor_data["load_power2"]=$(jq -r '.data.vip[2].power' loaddata.json)
  sensor_data["load_upsPowerL1"]=$(jq -r '.data.upsPowerL1' loaddata.json)
  sensor_data["load_upsPowerL2"]=$(jq -r '.data.upsPowerL2' loaddata.json)
  sensor_data["load_upsPowerL3"]=$(jq -r '.data.upsPowerL3' loaddata.json)
  sensor_data["load_upsPowerTotal"]=$(jq -r '.data.upsPowerTotal' loaddata.json)
  sensor_data["load_totalpower"]=$(jq -r '.data.totalPower' loaddata.json)

  # Solar data
  sensor_data["pv1_current"]=$(jq -r '.data.pvIV[0].ipv' pvindata.json)
  sensor_data["pv1_power"]=$(jq -r '.data.pvIV[0].ppv' pvindata.json)
  sensor_data["pv1_voltage"]=$(jq -r '.data.pvIV[0].vpv' pvindata.json)
  sensor_data["pv2_current"]=$(jq -r '.data.pvIV[1].ipv' pvindata.json)
  sensor_data["pv2_power"]=$(jq -r '.data.pvIV[1].ppv' pvindata.json)
  sensor_data["pv2_voltage"]=$(jq -r '.data.pvIV[1].vpv' pvindata.json)
  sensor_data["pv3_current"]=$(jq -r '.data.pvIV[2].ipv' pvindata.json)
  sensor_data["pv3_power"]=$(jq -r '.data.pvIV[2].ppv' pvindata.json)
  sensor_data["pv3_voltage"]=$(jq -r '.data.pvIV[2].vpv' pvindata.json)
  sensor_data["pv4_current"]=$(jq -r '.data.pvIV[3].ipv' pvindata.json)
  sensor_data["pv4_power"]=$(jq -r '.data.pvIV[3].ppv' pvindata.json)
  sensor_data["pv4_voltage"]=$(jq -r '.data.pvIV[3].vpv' pvindata.json)
  sensor_data["overall_state"]=$(jq -r '.data.runStatus' inverterinfo.json)

  # Settings/Program data
  sensor_data["prog1_time"]=$(jq -r '.data.sellTime1' settings.json)
  sensor_data["prog2_time"]=$(jq -r '.data.sellTime2' settings.json)
  sensor_data["prog3_time"]=$(jq -r '.data.sellTime3' settings.json)
  sensor_data["prog4_time"]=$(jq -r '.data.sellTime4' settings.json)
  sensor_data["prog5_time"]=$(jq -r '.data.sellTime5' settings.json)
  sensor_data["prog6_time"]=$(jq -r '.data.sellTime6' settings.json)
  sensor_data["prog1_charge"]=$(jq -r '.data.time1on' settings.json)
  sensor_data["prog2_charge"]=$(jq -r '.data.time2on' settings.json)
  sensor_data["prog3_charge"]=$(jq -r '.data.time3on' settings.json)
  sensor_data["prog4_charge"]=$(jq -r '.data.time4on' settings.json)
  sensor_data["prog5_charge"]=$(jq -r '.data.time5on' settings.json)
  sensor_data["prog6_charge"]=$(jq -r '.data.time6on' settings.json)
  sensor_data["prog1_capacity"]=$(jq -r '.data.cap1' settings.json)
  sensor_data["prog2_capacity"]=$(jq -r '.data.cap2' settings.json)
  sensor_data["prog3_capacity"]=$(jq -r '.data.cap3' settings.json)
  sensor_data["prog4_capacity"]=$(jq -r '.data.cap4' settings.json)
  sensor_data["prog5_capacity"]=$(jq -r '.data.cap5' settings.json)
  sensor_data["prog6_capacity"]=$(jq -r '.data.cap6' settings.json)
  sensor_data["battery_shutdown_cap"]=$(jq -r '.data.batteryShutdownCap' settings.json)
  sensor_data["use_timer"]=$(jq -r '.data.peakAndVallery' settings.json)
  sensor_data["priority_load"]=$(jq -r '.data.energyMode' settings.json)

  # Temperature data
  # Temperature data
  sensor_data["dc_temp"]=$(jq -r '.data.infos[0].records[-1].value' dcactemp.json)
  sensor_data["ac_temp"]=$(jq -r '.data.infos[1].records[-1].value' dcactemp.json)

  # Dump all data if verbose logging is enabled
  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    echo "Raw data per file"
    echo ------------------------------------------------------------------------------
    echo "pvindata.json"
    cat pvindata.json
    echo ------------------------------------------------------------------------------
    echo "griddata.json"
    cat griddata.json
    echo ------------------------------------------------------------------------------
    echo "loaddata.json"
    cat loaddata.json
    echo ------------------------------------------------------------------------------
    echo "batterydata.json"
    cat batterydata.json
    echo ------------------------------------------------------------------------------
    echo "outputdata.json"
    cat outputdata.json
    echo ------------------------------------------------------------------------------
    echo "dcactemp.json"
    cat dcactemp.json
    echo ------------------------------------------------------------------------------
    echo "inverterinfo.json"
    cat inverterinfo.json
    echo ------------------------------------------------------------------------------
    echo "settings.json"
    cat settings.json
    echo ------------------------------------------------------------------------------
    echo "Values to send. If ALL values are NULL then something went wrong:"

    # Print all sensor data
    for key in "${!sensor_data[@]}"; do
      echo "$key: ${sensor_data[$key]}"
    done
    echo ------------------------------------------------------------------------------
  fi

  return 0
}

# Create or update HA entities
update_ha_entities() {
  local inverter_serial=$1
  local entity_log_output=""

  if [ "$ENABLE_VERBOSE_LOG" != "true" ]; then
    entity_log_output="-o tmpcurllog.json"
  fi

  echo "Attempting to update entities for inverter: $inverter_serial"
  echo "Sending to $HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT"
  echo ------------------------------------------------------------------------------

  # Define a function to create/update an entity
  create_entity() {
    local sensor_id=$1
    local sensor_value=$2
    local friendly_name=$3
    local device_class=$4
    local state_class=$5
    local unit=$6

    # Skip if value is null or empty
    if [ "$sensor_value" == "null" ] || [ -z "$sensor_value" ]; then
      return 0
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

    attributes="$attributes}"

    # Entity ID
    local entity_id="sensor.SynSync_${inverter_serial}_${sensor_id}"

    # Check if entity exists by getting its current state
    local entity_exists=0
    local response

    response=$(curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $HA_TOKEN" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id")

    if [ "$response" == "200" ]; then
      entity_exists=1
    fi

    # Create or update the entity
    local result=$(curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
      -H "Content-Type: application/json" \
      -d "{\"attributes\": $attributes, \"state\": \"$sensor_value\"}" \
      "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/states/$entity_id" $entity_log_output)

    # If this is a new entity, log it and add to Home Assistant registry for persistence
    if [ $entity_exists -eq 0 ]; then
      echo "Created new entity: $entity_id"

      # Determine the appropriate domain for the sensor based on device_class
      local domain="sensor"

      # Create entity registry entry to make it persistent in Home Assistant
      # This ensures the entity will survive restarts and be properly integrated
      curl -s -k -X POST -H "Authorization: Bearer $HA_TOKEN" \
        -H "Content-Type: application/json" \
        -d "{
          \"device_id\": \"sunsynk_${inverter_serial}\",
          \"entity_id\": \"$entity_id\",
          \"name\": \"$friendly_name\",
          \"platform\": \"sensor\",
          \"disabled_by\": null
        }" \
        "$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT/api/config/entity_registry/register" > /dev/null

      # Create device if it doesn't exist
      create_device_if_needed "$inverter_serial"
    fi
  }

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

  # Process all sensor values and create/update entities
  for sensor_id in "${!sensor_data[@]}"; do
    # Only process if we have a configuration for this sensor
    if [ -n "${sensor_configs[$sensor_id]}" ]; then
      # Parse the config
      IFS='|' read -r friendly_name device_class state_class unit <<< "${sensor_configs[$sensor_id]}"

      # Create or update the entity
      create_entity "$sensor_id" "${sensor_data[$sensor_id]}" "$friendly_name" "$device_class" "$state_class" "$unit"
    fi
  done

  return 0
}

# Main program function that executes the full workflow
main() {
  log_header
  load_config

  while true; do
    cleanup_old_data

    if get_auth_token && validate_token; then
      IFS=";"
      for inverter_serial in $SUNSYNK_SERIAL; do
        if fetch_inverter_data "$inverter_serial"; then
          parse_inverter_data "$inverter_serial"
          update_ha_entities "$inverter_serial"
        else
          echo "Failed to fetch complete data for inverter $inverter_serial. Will retry on next iteration."
        fi
      done
    else
      echo "Authentication failed. Will retry on next iteration."
    fi

    echo "All Done! Waiting $REFRESH_RATE seconds before next update."
    sleep "$REFRESH_RATE"
  done
}

# Start the main program
main