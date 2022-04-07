# st-edge/driver/wake-on-lan

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

For better integration with the SmartThings App and Google Assistant, all
**Wake-on-LAN** momentary switch devices
also have an on/off switch capability.
When the on/off switch is turned on it behaves exactly as if the momentary switch was pushed
(it is automatically reset (turned off) after a moment).

As the **Wake-on-LAN** protocol only supports waking (turning on) a target device, turning off a
**Wake-on-LAN** (momentary) on/off switch
does nothing.

### Samsung TVs

2019 Samsung QLED Q90R TVs cannot be turned on through their native SmartThings integration.
This is may be true for other Samsung TVs.

While the native TV thing in the SmartThings App is presented with an on/off switch, turning on the TV here will not work unless it was very recently turned off.
When Google Assistant is asked to turn on the TV (through its SmartThings integration) it may complain: “It looks like the TV isn’t available right now”.

A solution is to deploy an instance of a
**Wake-on-LAN** (momentary) on/off switch device
that targets the TV.

In Google Home, one can import the
**Wake-on-LAN** (momentary) on/off switch device
and the native TV thing from SmartThings.
One should give them names so that "Turn on NAME" and "Turn off NAME" voice commands get resolved to both.
For example, naming them both "TV" seems to work.
Turning on the TV may still result in the “It looks like the TV isn’t available right now” response from the SmartThings native TV thing but the SmartThings
**Wake-on-LAN** (momentary) on/off switch device
will still work (the TV will be turned on).
