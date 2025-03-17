#!/usr/bin/with-contenv bashio
# SolarSynk Home Assistant Integration
# Author: Original by martinville, refactored and modularized
# Description: Connects to the SunSynk API and creates/updates Home Assistant entities with solar system data
#
# This script coordinates the modules:
# - utils.sh: Common utility functions
# - config.sh: Configuration management
# - api.sh: API communication
# - data.sh: Data parsing and processing
# - entities.sh: Home Assistant entity creation and management

# Disable exit on error to prevent script from terminating on recoverable errors
set +e

# Current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source all modules
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/api.sh"
source "$SCRIPT_DIR/data.sh"
source "$SCRIPT_DIR/entities.sh"

# Log header with timestamp
log_header() {
  local dt=$(date '+%d/%m/%Y %H:%M:%S')
  echo ""
  echo "------------------------------------------------------------------------------"
  echo "-- SolarSynk - Log"
  echo "------------------------------------------------------------------------------"
  echo "Script execution date & time: $dt"
  echo "Version: 2.1.23 (Modular Refactor)"
}

# Clean up old data files
cleanup_old_data() {
  log_message "INFO" "Cleaning up old data files"
  rm -f pvindata.json griddata.json loaddata.json batterydata.json outputdata.json dcactemp.json inverterinfo.json settings.json token.json tmpcurllog.json
}

# Main program function that executes the full workflow
main() {
  log_header

  # Load configuration from Home Assistant
  if ! load_config; then
    log_message "ERROR" "Failed to load configuration. Exiting."
    exit 1
  fi

  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    log_message "INFO" "Starting SolarSynk integration with verbose logging enabled"
  else
    log_message "INFO" "Starting SolarSynk integration"
  fi

  log_message "INFO" "Using HTTP connect type: $HTTP_CONNECT_TYPE"
  log_message "INFO" "Refresh rate set to: $REFRESH_RATE seconds"

  # Main loop
  while true; do
    cleanup_old_data

    if get_auth_token && validate_token; then
      IFS=';'
      for inverter_serial in $SUNSYNK_SERIAL; do
        log_message "INFO" "Processing inverter with serial: $inverter_serial"

        if fetch_inverter_data "$inverter_serial"; then
          # Parse the data
          if parse_inverter_data "$inverter_serial"; then
            # Check if we have data to process
            if [ ${#sensor_data[@]} -eq 0 ]; then
              log_message "WARNING" "No valid data retrieved for inverter $inverter_serial"
            else
              log_message "INFO" "Successfully parsed data for inverter $inverter_serial with ${#sensor_data[@]} data points"

              # Create or update the entities in Home Assistant
              if update_ha_entities "$inverter_serial"; then
                log_message "INFO" "Successfully updated Home Assistant entities for inverter $inverter_serial"
              else
                log_message "ERROR" "Failed to update some Home Assistant entities for inverter $inverter_serial"
              fi
            fi
          else
            log_message "ERROR" "Failed to parse data for inverter $inverter_serial"
          fi
        else
          log_message "ERROR" "Failed to fetch complete data for inverter $inverter_serial. Will retry on next iteration."
        fi
      done
      unset IFS

      log_message "INFO" "Processing cycle completed successfully"
    else
      log_message "ERROR" "Authentication failed. Will retry on next iteration."
    fi

    log_message "INFO" "All done! Waiting $REFRESH_RATE seconds before next update."
    sleep "$REFRESH_RATE"
  done
}

# Start the main program
main
