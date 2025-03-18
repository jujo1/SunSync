# ==============================================================================
# Sunsync Home Assistant Integration
# API Communication Functions
# ==============================================================================

import os
import time
import subprocess
import json

# Global API variables
SERVER_API_BEARER_TOKEN = ""
SERVER_API_BEARER_TOKEN_SUCCESS = ""
SERVER_API_BEARER_TOKEN_MSG = ""

# Default retry configuration - used across all API functions
DEFAULT_MAX_RETRIES = 3
DEFAULT_RETRY_DELAY = 30


# Get authentication token from Sunsynk API
def get_auth_token():
    log_message(
        "INFO",
        "Getting bearer token from solar service provider's API."
    )

    retry_count = 0
    output_file = "token.json"

    while retry_count < DEFAULT_MAX_RETRIES:
        # Fetch the token using our standardized api_call function
        if api_call(
            "POST",
            "https://api.sunsynk.net/oauth/token",
            output_file,
            "Content-Type: application/json",
            f"-d {{\"areaCode\": \"sunsynk\",\"client_id\": \"csp-web\",\"grant_type\": \"password\",\"password\": \"{os.getenv('SUNSYNK_PASS')}\","
            f"\"source\": \"sunsynk\",\"username\": \"{os.getenv('SUNSYNK_USER')}\"}}"
        ):
            # Check if file exists before attempting to parse
            if not os.path.exists(
                output_file
            ):
                log_message(
                    "ERROR",
                    "Token response file not found"
                )
                retry_count += 1
                time.sleep(
                    DEFAULT_RETRY_DELAY
                )
                continue

            # Check verbose logging
            if os.getenv(
                "ENABLE_VERBOSE_LOG"
            ) == "true":
                print(
                    "Raw token data"
                )
                print(
                    "------------------------------------------------------------------------------"
                )
                print(
                    "token.json"
                )
                with open(
                    output_file,
                    'r'
                ) as f:
                    print(
                        f.read()
                    )
                print(
                    "------------------------------------------------------------------------------"
                )

            # Parse token from response with error checking
            try:
                with open(
                    output_file,
                    'r'
                ) as f:
                    response_data = json.load(
                        f
                    )
            except Exception as e:
                log_message(
                    "ERROR",
                    "Failed to parse token data"
                )
                retry_count += 1
                time.sleep(
                    DEFAULT_RETRY_DELAY
                )
                continue

            SERVER_API_BEARER_TOKEN = response_data.get(
                "data",
                {}
            ).get(
                "access_token",
                ""
            )
            SERVER_API_BEARER_TOKEN_SUCCESS = response_data.get(
                "success",
                "false"
            )

            if SERVER_API_BEARER_TOKEN_SUCCESS == "true" and SERVER_API_BEARER_TOKEN:
                log_message(
                    "INFO",
                    "Valid token retrieved."
                )
                log_message(
                    "INFO",
                    f"Bearer Token length: {len(SERVER_API_BEARER_TOKEN)}"
                )
                return 0
            else:
                SERVER_API_BEARER_TOKEN_MSG = response_data.get(
                    "msg",
                    "Unknown error"
                )
                log_message(
                    "WARNING",
                    f"Invalid token received: {SERVER_API_BEARER_TOKEN_MSG}. Retrying after a sleep..."
                )
                time.sleep(
                    DEFAULT_RETRY_DELAY
                )
                retry_count += 1
        else:
            log_message(
                "ERROR",
                f"Error getting token. Retrying in {DEFAULT_RETRY_DELAY} seconds..."
            )
            time.sleep(
                DEFAULT_RETRY_DELAY
            )
            retry_count += 1

    if retry_count >= DEFAULT_MAX_RETRIES:
        log_message(
            "ERROR",
            "Maximum retries reached. Cannot obtain auth token."
        )
        return 1

    return 0


# Validate token
def validate_token():
    if not SERVER_API_BEARER_TOKEN:
        log_message(
            "ERROR",
            "****Token could not be retrieved due to the following possibilities****"
        )
        log_message(
            "ERROR",
            "Incorrect setup, please check the configuration tab."
        )
        log_message(
            "ERROR",
            "Either this HA instance cannot reach Sunsynk.net due to network problems or the Sunsynk server is down."
        )
        log_message(
            "ERROR",
            "The Sunsynk server admins are rejecting due to too frequent connection requests."
        )
        log_message(
            "ERROR",
            "This Script will not continue but will retry on next iteration. No values were updated."
        )
        return 1

    log_message(
        "INFO",
        "Sunsynk Server API Token: Hidden for security reasons"
    )
    log_message(
        "INFO",
        "Note: Setting the refresh rate of this addon to be lower than the update rate of the SunSynk server will not increase the actual update rate."
    )
    return 0


# Generic function for performing API calls with retries
def api_call(
    method,
    url,
    output_file,
    *headers
):
    retry_count = 0
    data = ""

    # Extract data if this is a POST request
    if method == "POST" and any(
        "Content-Type: application/json" in header for header in headers
    ):
        for header in headers:
            if header.startswith(
                "-d "
            ):
                data = header[3:]
                break

    while retry_count < DEFAULT_MAX_RETRIES:
        # Construct the CURL command
        curl_cmd = ["curl", "-s", "-f", "-S", "-k", "-X", method]

        # Add headers
        for header in headers:
            if not header.startswith(
                "-d "
            ):  # Skip data, add separately
                curl_cmd += ["-H", header]

        # Add data if it exists
        if data:
            curl_cmd += ["-d", data]

        # Add the URL and output file
        curl_cmd += [url, "-o", output_file]

        # Execute the command
        if subprocess.call(
            curl_cmd
        ) == 0:
            # Check if the output file is not empty
            if output_file != "/dev/null" and os.stat(
                output_file
            ).st_size == 0:
                log_message(
                    "WARNING",
                    f"API call returned empty response: {method} {url}"
                )
                retry_count += 1

                if retry_count < DEFAULT_MAX_RETRIES:
                    log_message(
                        "INFO",
                        "Retrying in 5 seconds..."
                    )
                    time.sleep(
                        5
                    )
                    continue
            return 0
        else:
            log_message(
                "WARNING",
                f"API call failed: {method} {url}, attempt {retry_count + 1}/{DEFAULT_MAX_RETRIES}"
            )
            retry_count += 1

            if retry_count < DEFAULT_MAX_RETRIES:
                log_message(
                    "INFO",
                    "Retrying in 5 seconds..."
                )
                time.sleep(
                    5
                )

    log_message(
        "ERROR",
        f"API call failed after {DEFAULT_MAX_RETRIES} attempts: {method} {url}"
    )
    return 1


# Make an API call to the Sunsynk API
def sunsynk_api_call(
    endpoint,
    output_file
):
    # Validate parameters
    if not endpoint or not output_file:
        log_message(
            "ERROR",
            "Missing required parameters for sunsynk_api_call"
        )
        return 1

    if not SERVER_API_BEARER_TOKEN:
        log_message(
            "ERROR",
            "No valid bearer token available for API call"
        )
        return 1

    return api_call(
        "GET",
        endpoint,
        output_file,
        "Content-Type: application/json",
        f"authorization: Bearer {SERVER_API_BEARER_TOKEN}"
    )


# Make an API call to the Home Assistant API
def ha_api_call(
    endpoint,
    method="GET",
    data="",
    output_file="/dev/null"
):
    # Validate parameters
    if not endpoint:
        log_message(
            "ERROR",
            "Missing required parameters for ha_api_call"
        )
        return 1

    if not os.getenv(
        "HA_TOKEN"
    ):
        log_message(
            "ERROR",
            "No valid HA token available for API call"
        )
        return 1

    url = f"{os.getenv('HTTP_CONNECT_TYPE')}://{os.getenv('HA_IP')}:{os.getenv('HA_PORT')}{endpoint}"

    headers = [
        f"Authorization: Bearer {os.getenv('HA_TOKEN')}",
        "Content-Type: application/json"
    ]

    if data:
        headers.append(
            f"-d {data}"
        )

    return api_call(
        method,
        url,
        output_file,
        *headers
    )


# Send settings to Sunsynk inverter via API
def send_inverter_settings(
    inverter_sn,
    settings_data
):
    retry_count = 0

    # Validate parameters
    if not inverter_sn or not settings_data:
        log_message(
            "ERROR",
            "Missing required parameters for send_inverter_settings"
        )
        return 1

    # Validate JSON format of settings_data
    try:
        json.loads(
            settings_data
        )
    except json.JSONDecodeError:
        log_message(
            "ERROR",
            "Invalid JSON format in settings data"
        )
        return 1

    endpoint = f"https://api.sunsynk.net/api/v1/common/setting/{inverter_sn}/set"
    output_file = "inverter_settings_response.json"

    log_message(
        "INFO",
        f"Sending settings to inverter {inverter_sn}"
    )

    if os.getenv(
        "ENABLE_VERBOSE_LOG"
    ) == "true":
        print(
            "Sending settings data:"
        )
        print(
            settings_data
        )

    # Try with retry logic
    while retry_count < DEFAULT_MAX_RETRIES:
        # Make POST request to update inverter settings
        status = api_call(
            "POST",
            endpoint,
            output_file,
            "Content-Type: application/json",
            f"authorization: Bearer {SERVER_API_BEARER_TOKEN}",
            f"-d {settings_data}"
        )

        if status == 0:
            # Check if response file exists
            if not os.path.exists(
                output_file
            ):
                log_message(
                    "ERROR",
                    "Settings response file not found"
                )
                retry_count += 1
                if retry_count < DEFAULT_MAX_RETRIES:
                    log_message(
                        "INFO",
                        f"Retrying in {DEFAULT_RETRY_DELAY} seconds..."
                    )
                    time.sleep(
                        DEFAULT_RETRY_DELAY
                    )
                    continue
                return 1

            # Verbose logging of response
            if os.getenv(
                "ENABLE_VERBOSE_LOG"
            ) == "true":
                print(
                    "Settings response:"
                )
                print(
                    "------------------------------------------------------------------------------"
                )
                with open(
                    output_file,
                    'r'
                ) as f:
                    print(
                        f.read()
                    )
                print(
                    "------------------------------------------------------------------------------"
                )

            # Parse and check success
            try:
                with open(
                    output_file,
                    'r'
                ) as f:
                    response_data = json.load(
                        f
                    )
            except Exception as e:
                log_message(
                    "ERROR",
                    "Failed to parse settings response"
                )
                retry_count += 1
                if retry_count < DEFAULT_MAX_RETRIES:
                    log_message(
                        "INFO",
                        f"Retrying in {DEFAULT_RETRY_DELAY} seconds..."
                    )
                    time.sleep(
                        DEFAULT_RETRY_DELAY
                    )
                    continue
                return 1

            success = response_data.get(
                "success",
                "false"
            )
            if success == "true":
                log_message(
                    "INFO",
                    "Successfully updated inverter settings"
                )
                return 0
            else:
                error_msg = response_data.get(
                    "msg",
                    "Unknown error"
                )
                log_message(
                    "ERROR",
                    f"Failed to update inverter settings: {error_msg}"
                )
                retry_count += 1
                if retry_count < DEFAULT_MAX_RETRIES:
                    log_message(
                        "INFO",
                        f"Retrying in {DEFAULT_RETRY_DELAY} seconds..."
                    )
                    time.sleep(
                        DEFAULT_RETRY_DELAY
                    )
                    continue
            return 1
        else:
            log_message(
                "ERROR",
                f"Failed to send settings to inverter {inverter_sn}"
            )
            retry_count += 1
            if retry_count < DEFAULT_MAX_RETRIES:
                log_message(
                    "INFO",
                    f"Retrying in {DEFAULT_RETRY_DELAY} seconds..."
                )
                time.sleep(
                    DEFAULT_RETRY_DELAY
                )
            else:
                return 1

    log_message(
        "ERROR",
        f"Failed to update inverter settings after {DEFAULT_MAX_RETRIES} attempts"
    )
    return 1

# Example usage:
# send_inverter_settings("INV123456789", '{"workMode":1,"gridChargeEnable":true,"batteryType":1,"batteryCapacity":200}')