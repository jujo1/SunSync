#!/bin/bash

# ==============================================================================
# Sunsync Home Assistant Integration
# Configuration Management
# ==============================================================================

# Global variables for configuration
SUNSYNK_USER=""
SUNSYNK_PASS=""
SUNSYNK_SERIAL=""
HA_IP=""
HA_PORT=8123
HA_TOKEN=""
REFRESH_RATE=300
HTTP_CONNECT_TYPE="http"
ENABLE_HTTPS=false
ENABLE_VERBOSE_LOG=false
VarCurrentDate=$(date '+%Y-%m-%d')

# Load configuration from Home Assistant add-on
load_config() {
  log_message "INFO" "Loading configuration"

  # Get configuration from Home Assistant
  SUNSYNK_USER=$(bashio::config 'sunsynk_user')
  SUNSYNK_PASS=$(bashio::config 'sunsynk_pass')
  SUNSYNK_SERIAL=$(bashio::config 'sunsynk_serial')
  HA_IP=$(bashio::config 'Home_Assistant_IP')
  HA_PORT=$(bashio::config 'Home_Assistant_PORT')
  HA_TOKEN=$(bashio::config 'HA_LongLiveToken')
  REFRESH_RATE=$(bashio::config 'Refresh_rate')
  ENABLE_HTTPS=$(bashio::config 'Enable_HTTPS')
  ENABLE_VERBOSE_LOG=$(bashio::config 'Enable_Verbose_Log')

  # Set proper HTTP connect type based on HTTPS setting
  if [ "$ENABLE_HTTPS" == "true" ]; then
    HTTP_CONNECT_TYPE="https"
    log_message "INFO" "HTTPS Enabled"
  else
    HTTP_CONNECT_TYPE="http"
    log_message "INFO" "HTTP Enabled"
  fi

  # Validate configuration
  if [ -z "$SUNSYNK_USER" ] || [ -z "$SUNSYNK_PASS" ] || [ -z "$SUNSYNK_SERIAL" ] || [ -z "$HA_IP" ] || [ -z "$HA_TOKEN" ]; then
    log_message "ERROR" "Missing required configuration. Please check your add-on configuration."
    return 1
  fi

  if [ "$ENABLE_VERBOSE_LOG" == "true" ]; then
    log_message "INFO" "Verbose logging enabled"
    log_message "INFO" "Configuration loaded:"
    log_message "INFO" "- Username: $SUNSYNK_USER"
    log_message "INFO" "- Serial(s): $SUNSYNK_SERIAL"
    log_message "INFO" "- Home Assistant: $HA_IP:$HA_PORT"
    log_message "INFO" "- Refresh rate: $REFRESH_RATE seconds"
  else
    log_message "INFO" "Configuration loaded successfully"
  fi

  return 0
}
