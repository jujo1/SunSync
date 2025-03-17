#!/bin/bash
# SunSync Integration - API Communication Functions

# Global API variables
SERVER_API_BEARER_TOKEN=""
SERVER_API_BEARER_TOKEN_SUCCESS=""
SERVER_API_BEARER_TOKEN_MSG=""

# Get authentication token from Sunsynk API
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

      log_message "ERROR" "Error getting token (curl exit code $?). Retrying in 30 seconds..."
      sleep 30

      retry_count=$((retry_count + 1))
      if [ $retry_count -ge $max_retries ]; then
        log_message "ERROR" "Maximum retries reached. Cannot obtain auth token."
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
        log_message "INFO" "Valid token retrieved."
        log_message "INFO" "Bearer Token length: ${#SERVER_API_BEARER_TOKEN}"
        return 0
      else
        SERVER_API_BEARER_TOKEN_MSG=$(jq -r '.msg' token.json)
        log_message "WARNING" "Invalid token received: $SERVER_API_BEARER_TOKEN_MSG. Retrying after a sleep..."
        sleep 30

        retry_count=$((retry_count + 1))
        if [ $retry_count -ge $max_retries ]; then
          log_message "ERROR" "Maximum retries reached. Cannot obtain auth token."
          return 1
        fi
      fi
    fi
  done
}

# Validate token
validate_token() {
  if [ -z "$SERVER_API_BEARER_TOKEN" ]; then
    log_message "ERROR" "****Token could not be retrieved due to the following possibilities****"
    log_message "ERROR" "Incorrect setup, please check the configuration tab."
    log_message "ERROR" "Either this HA instance cannot reach Sunsynk.net due to network problems or the Sunsynk server is down."
    log_message "ERROR" "The Sunsynk server admins are rejecting due to too frequent connection requests."
    log_message "ERROR" "This Script will not continue but will retry on next iteration. No values were updated."
    return 1
  fi

  log_message "INFO" "Sunsynk Server API Token: Hidden for security reasons"
  log_message "INFO" "Note: Setting the refresh rate of this addon to be lower than the update rate of the SunSynk server will not increase the actual update rate."
  return 0
}

# Generic function for performing API calls with retries
api_call() {
  local method=$1  # GET, POST, etc.
  local url=$2
  local output_file=$3
  local headers=("${@:4}")  # All remaining args are headers
  local retry_count=0
  local max_retries=3
  local data=""

  # Extract data if this is a POST request
  if [[ "$method" == "POST" && "${headers[*]}" == *"Content-Type: application/json"* ]]; then
    # Find the data in the headers
    for header in "${headers[@]}"; do
      if [[ "$header" == "-d "* ]]; then
        data="${header#-d }"
        break
      fi
    done
  fi

  while [ $retry_count -lt $max_retries ]; do
    # Build the curl command dynamically
    local curl_cmd="curl -s -f -S -k -X $method"

    # Add headers
    for header in "${headers[@]}"; do
      if [[ "$header" != "-d "* ]]; then  # Skip data, we'll add it separately
        curl_cmd="$curl_cmd -H \"$header\""
      fi
    done

    # Add data if it exists
    if [ ! -z "$data" ]; then
      curl_cmd="$curl_cmd -d '$data'"
    fi

    # Add the URL and output file
    curl_cmd="$curl_cmd \"$url\" -o \"$output_file\""

    # Execute the command
    if eval $curl_cmd; then
      return 0
    else
      log_message "WARNING" "API call failed: $method $url, attempt $(($retry_count + 1))/$max_retries"
      retry_count=$((retry_count + 1))

      if [ $retry_count -lt $max_retries ]; then
        log_message "INFO" "Retrying in 5 seconds..."
        sleep 5
      fi
    fi
  done

  log_message "ERROR" "API call failed after $max_retries attempts: $method $url"
  return 1
}

# Make an API call to the Sunsynk API
sunsynk_api_call() {
  local endpoint=$1
  local output_file=$2

  api_call "GET" "$endpoint" "$output_file" \
    "Content-Type: application/json" \
    "authorization: Bearer $SERVER_API_BEARER_TOKEN"
}

# Make an API call to the Home Assistant API
ha_api_call() {
  local endpoint=$1
  local method=${2:-"GET"}
  local data=${3:-""}
  local output_file=${4:-"/dev/null"}

  local url="$HTTP_CONNECT_TYPE://$HA_IP:$HA_PORT$endpoint"

  local headers=(
    "Authorization: Bearer $HA_TOKEN"
    "Content-Type: application/json"
  )

  if [ ! -z "$data" ]; then
    headers+=("-d $data")
  fi

  api_call "$method" "$url" "$output_file" "${headers[@]}"
}
