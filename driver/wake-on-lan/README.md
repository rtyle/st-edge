# st-edge/driver/sundial

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
for
[Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN)
capabilities.

This runs on your SmartThings hub without any external dependencies.

## Usage

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
This will create a single
**Wake-on-LAN** bridge device
from which many
**Wake-on-LAN** momentary switch devices
may be created.

Use the settings of the
**Wake-on-LAN** bridge device
to specify the MAC address (12 hexadecimal numerals) of a target device.
This will create create a new
**Wake-on-LAN** momentary switch device
that, when pushed, will wake the target device.

If necessary, use the settings of a
**Wake-on-LAN** momentary switch device
to set the SecureOn password (12 hexadecimal numerals) required by the target device.

Removing the
**Wake-on-LAN** bridge device
will remove all associated
**Wake-on-LAN** momentary switch devices.
