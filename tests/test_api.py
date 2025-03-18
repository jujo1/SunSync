import json
import logging
import os
import sys
import yaml
import requests
import time
from typing import (
    Any,
    Dict,
    List,
    Optional
)

logging.basicConfig(
    level=os.getenv(
        'LOG_LEVEL',
        'INFO'
    )
)

CONFIG_FILE: str = os.path.normpath(
    './config_local.yaml'
)
API_URL: str = 'https://api.sunsynk.net/api/v1'
ENDPOINTS: List[Dict[str, Any]] = [
    {
        'endpoint': 'inverters',
        'methods':  ['GET']
    },
    {
        'endpoint': 'battery',
        'methods':  ['GET']
    },
    {
        'endpoint': 'plants',
        'methods':  ['GET']
    },
    {
        'endpoint': 'user',
        'methods':  ['GET']
    },
    {
        'endpoint': 'plant/info',
        'methods':  ['GET']
    },
    {
        'endpoint': 'weather/now',
        'methods':  ['GET']
    },
    {
        'endpoint': 'alerts',
        'methods':  ['GET', 'POST']
    }
]


def load_config(
    config_path: str = '../config.sh'
) -> Dict[str, str]:
    config: Dict[str, str] = {}
    if not os.path.exists(
        config_path
    ):
        logging.error(
            f'Configuration file "{config_path}" does not exist.'
        )
        return config

    try:
        with open(
            config_path,
            'r'
        ) as file:
            for line in file:
                if line.startswith(
                    '#'
                ) or '=' not in line:
                    continue
                key, value = line.strip().split(
                    '=',
                    1
                )
                config[key.strip()] = value.strip().strip(
                    '"'
                )
    except Exception as e:
        logging.error(
            f'Error reading configuration file: {e}'
        )

    return config


def get_bearer_token() -> Optional[str]:
    """Get bearer token from Sunsynk API directly using Python requests.
    Uses credentials from config_local.yaml."""

    # Load credentials from config_local.yaml
    try:
        with open(
            CONFIG_FILE,
            'r'
        ) as file:
            config = yaml.safe_load(
                file
            )
    except FileNotFoundError:
        logging.error(
            f"{CONFIG_FILE} file not found"
        )
        return None
    except yaml.YAMLError as e:
        logging.error(
            f"Error parsing {CONFIG_FILE}: {e}"
        )
        return None

    # Extract credentials
    username = config.get(
        'options',
        {}
    ).get(
        'sunsynk_user'
    )
    password = config.get(
        'options',
        {}
    ).get(
        'sunsynk_pass'
    )

    if not username or not password:
        logging.error(
            f"Missing credentials in {CONFIG_FILE}"
        )
        return None

    # Prepare request
    url = "https://api.sunsynk.net/oauth/token"
    headers = {
        "Content-Type": "application/json"
    }
    payload = {
        "areaCode":   "sunsynk",
        "client_id":  "csp-web",
        "grant_type": "password",
        "password":   password,
        "source":     "sunsynk",
        "username":   username
    }

    # Make request with retry logic
    max_retries = 3
    retry_count = 0

    while retry_count < max_retries:
        try:
            response = requests.post(
                url,
                json=payload,
                headers=headers
            )
            response.raise_for_status()

            data = response.json()
            if data.get(
                'success'
            ) == True and 'data' in data:
                token = data['data'].get(
                    'access_token'
                )
                if token:
                    logging.info(
                        f"Valid token retrieved. Token length: {len(token)}"
                    )
                    return token

            error_msg = data.get(
                'msg',
                'Unknown error'
            )
            logging.warning(
                f"Invalid token received: {error_msg}. Retrying..."
            )

        except requests.RequestException as e:
            logging.error(
                f"Error getting token: {str(e)}"
            )

        retry_count += 1
        if retry_count < max_retries:
            time.sleep(
                30
            )  # 30 second delay between retries

    logging.error(
        "Maximum retries reached. Cannot obtain auth token."
    )
    return None


def explore_sunsynk_api(
    bearer_token: str,
    timeout: int = 10
) -> Dict[str, Dict[str, Any]]:
    headers: Dict[str, str] = {
        'Authorization': f'Bearer {bearer_token}',
        'Accept':        'application/json'
    }

    api_docs: Dict[str, Dict[str, Any]] = {}

    for endpoint in ENDPOINTS:
        ep_name: str = endpoint['endpoint']
        methods: List[str] = endpoint['methods']
        api_docs[ep_name] = {}

        for method in methods:
            url: str = f'{API_URL}/{ep_name}'
            response: Optional[requests.Response] = None
            try:
                logging.info(
                    f'Sending {method} request to {url}'
                )
                response = requests.request(
                    method=method,
                    url=url,
                    headers=headers,
                    timeout=timeout
                )

                content_type: str = response.headers.get(
                    'Content-Type',
                    ''
                )

                if content_type.startswith(
                    'application/json'
                ):
                    resp_content: Any = response.json()
                else:
                    resp_content: str = response.text

                api_docs[ep_name][method] = {
                    'status':      'valid' if response.ok else 'invalid',
                    'status_code': response.status_code,
                    'response':    resp_content
                }

                logging.info(
                    f'Received response with status code {response.status_code}'
                )

            except requests.exceptions.RequestException as e:
                logging.error(
                    f'Request to {url} failed: {e}'
                )
                api_docs[ep_name][method] = {
                    'status':   'error',
                    'response': str(e)
                }
            except (json.JSONDecodeError, ValueError, TypeError) as e:
                logging.error(
                    f'Parsing error for response from {url}: {e}'
                )
                api_docs[ep_name][method] = {
                    'status':   'invalid',
                    'response': response.text if response and response.text else str(e)
                }

    return api_docs


def save_api_documentation(
    api_docs: Dict[str, Any],
    file_path: str = 'api_documentation.json'
) -> None:
    try:
        with open(
            file_path,
            'w'
        ) as outfile:
            json.dump(
                api_docs,
                outfile,
                indent=2
            )
        logging.info(
            f'API documentation successfully saved to {file_path}.'
        )
    except Exception as e:
        logging.error(
            f'Failed to save API documentation: {e}'
        )


def main() -> None:
    config: Dict[str, str] = load_config()
    if not config:
        logging.error(
            'Failed to load configuration; exiting.'
        )
        sys.exit(1)

    bearer_token: Optional[str] = get_bearer_token()
    if not bearer_token:
        logging.error(
            'Unable to obtain bearer token; exiting.'
        )
        sys.exit(1)

    api_documentation: Dict[str, Dict[str, Any]] = explore_sunsynk_api(
        bearer_token
    )
    save_api_documentation(
        api_documentation
    )


if __name__ == '__main__':
    main()