# SunSync API Home Assistant Integration

**Forked and Enhanced by:** [Julian Jones](github.com/jujo1)
**Original Author:** [Martin Ville](github.com/martinville)

## Overview

SunSync is a Home Assistant integration designed to connect to the SunSynk ((github.com/martinville
) API, fetching solar system data to dynamically create and update sensor entities
within Home Assistant.

## Why This Fork?

This fork by jujo1 enhances the original integration with:

- Improved error handling and robust retry mechanisms for API calls
- Dynamic creation of Home Assistant entities
- Enhanced code structure and readability
- Adoption of improved bash scripting practices

## How SunSync Works

SunSync obtains solar system data from the SunSynk cloud API, originally uploaded by your inverter via the SunSynk dongle. It has no direct physical interface
with your inverter hardware.

**Please note:** This integration only populates sensor data and does not include display cards.

This integration specifically targets **SunSynk Region 2** and supports setups with multiple inverters.

## Documentation

For detailed instructions, see [DOCS.md](github.com/jujo1/SunSync/blob/main/DOCS.md).