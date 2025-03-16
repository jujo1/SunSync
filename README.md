![](https://github.com/jujo1/SunSync_test/blob/main/logo.png)

## What this is:

SunSynk API Home Assistant Integration

Original Author: martinville
Forked by Author: jujo1

Description: Connects to the SunSynk API and creates/updates Home Assistant entities with solar system data

## Reason for the fork:

This is a fork of the original Sunsynk API integration for Home Assistant. The original project was created by Martin Ville and is available
at https://github.com/martinville/solarsynkv2

- Improve error handling
- Dynamically create Home Assistant entities
- Follow better bash practices
- Improve code structure and readability
- Add better retry mechanisms for API calls

## How it works

SunSync will fetch solar system data via the internet which was initially posted to the cloud via your sunsynk dongle. It does not have any physical
interfaces that are connected directly to your inverter.
Please also note that this add-on only populates sensor values with data. It does not come with any cards to display information.

This add-on was developed for Sunsynk Region 2 customers only. Supports multiple inverters.

See for more information: https://github.com/jujo1/SunSync/blob/main/DOCS.md

![](https://github.com/jujo1/SunSync/blob/main/SunSync_started.png)
