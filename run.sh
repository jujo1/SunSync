#!/usr/bin/with-contenv bashio
set -e

# SunSynk Home Assistant Integration
# Author: Original by martinville, refactored and modularized
# Description: Connects to the SunSynk API and creates/updates Home Assistant entities with solar system data

# Current directory
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Source all modules
source "$SCRIPT_DIR/utils.sh"
source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/api.sh"
source "$SCRIPT_DIR/data.sh"
source "$SCRIPT_DIR/entities.sh"

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