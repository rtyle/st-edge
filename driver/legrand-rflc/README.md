# st-edge/driver/legrand-rflc

[SmartThings Edge Driver](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)
for a
[Legrand RFLC](https://www.legrand.us/solutions/smart-lighting/radio-frequency-lighting-controls)
system via a
[LC7001 Whole House Lighting Controller](https://www.legrand.us/wiring-devices/electrical-accessories/miscellaneous/adorne-hub/p/lc7001).


This SmartThings Edge Driver runs on your SmartThings hub and communicates locally/directly with its LC7001 LAN neighbor(s).
This does not use Legrand Cloud services and the SmartThings Cloud is only required for external access.

Unlike the
[Legrand Lighting Control App](https://play.google.com/store/apps/details?id=us.legrand.lighting),
this driver can interface with multiple LC7001 controllers on the same LAN.

## Usage

Install your Legrand/On-Q LC7001 Whole House Lighting Controller on the same LAN as your SmartThings hub.
Use the Legrand Lighting Control App on your smart phone to configure your Legrand RFLC system.

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
Give the system time to discover all of your LC7001 controllers and the lights that they control.
Repeat as necessary to discover everything.

If the lights controlled by a controller are not discovered or subsequently go offline,
it may be that the cached authentication information for the controller is not correct.
This is likely the first time it is discovered.
Use the SmartThings App to change the Lighting Control System Password on the Settings for the Whole House Lighting Controller.
The password here and in the Legrand Lighting Control App must match.

Expect a bridge device to be created in SmartThings for each LC7001 controller
and a device with Switch (and possibly SwitchLevel) capabilities for each light switch (and dimmer).
Control the lights from SmartThings in the expected way, including refreshing their status with a swipe on their page.
Refreshing the status of all lights associated with an LC7001 controller can be done by swiping on its page.

Removing the device for an LC7001 controller will remove all of its associated devices.

## Development

### Command Line Interpreter Testing

A command line interpreter (cli) can be run from the command line.

	./cli

The first line output will suggest the command needed to interface with it. For example,

	socat - TCP:127.0.0.1:38019

See *cli.lua* source code for the simple command set.

### Visual Studio Code

You should be able to debug much of the code through the command line interpreter interface supported by *cli.lua*.
Set the LUALOG environment variable to see log messages through the DEBUG level.

	LUALOG=DEBUG code workspace.code-workspace
	Extensions: Search: Lua Debug (actboy168): Install
