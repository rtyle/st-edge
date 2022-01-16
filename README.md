# st-edge-legrand-rflc

## Deploy

Get source

	git clone http://github.com/rtyle/st-edge-legrand-rflc.git
	cd st-edge-legrand-rflc
	git submodule update --init --recursive

Install the latest (v0.0.0-pre.34, at the time of this writing) smartthings-cli

	curl -L https://github.com/SmartThingsCommunity/smartthings-cli/releases/download/v0.0.0-pre.34/smartthings-linux.zip | gunzip - | install /dev/stdin smartthings

Copy source dependencies into our package (they cannot be gathered through symbolic links)

	cp -r modules/lockbox/lockbox src/

Create package

	./smartthings edge:drivers:package

If needed, create a new distribution channel for this package

	./smartthings edge:channels:create

Assign this package to a distribution channel

	./smartthings edge:channels:assign

Enroll your hub in this distribution channel

	./smartthings edge:channels:enroll

Install this package on your hub

	./smartthings edge:drivers:install

## Usage

Install your Legrand/On-Q LC7001 Whole House Lighting Controller on the same LAN as your SmartThings Hub.
Use the Legrand Lighting Control App on your smart phone to configure your Legrand RFLC system.

From the Devices tab in the SmartThings App, click **+**, **Add device** and **Scan for nearby devices**.
Give the system time to discover all of your LC7001 hubs and the lights that they control.
Repeat as necessary to discover everything.

If the lights controlled by a hub are not discovered or subsequently go offline, it may be that the cached authentication information for the hub is not correct.
This is likely the first time it is discovered.
Use the SmartThings App to change the Lighting Control System Password in the Settings for the Whole House Lighting Controller.
The password here and in the Legrand Lighting Control App must match.

Expect a bridge device to be created in SmartThings for each LC7001 hub and a device with Switch (and possibly SwitchLevel) capabilities for each light/dimmer.
Control the lights from SmartThings in the expected way, including refreshing their status with a swipe on their page.
Refreshing the status of all devices associated with an LC7001 hub can be done by swiping on its page.
    
