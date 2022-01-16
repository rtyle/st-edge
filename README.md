# st-edge-legrand-rflc

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

## Deployment

### Deployment from Public Channel

TODO.

### Deployment from Private Channel Built from Source

These instructions are written for a Linux platform. Similar steps may be taken for MacOS or Windows.

Get the source from this repository.

	git clone http://github.com/rtyle/st-edge-legrand-rflc.git

All commands documented here are executed from this directory.

	cd st-edge-legrand-rflc

Update all submodules of this repository.

	git submodule update --init --recursive

Install the latest (v0.0.0-pre.34, at the time of this writing) smartthings-cli.

	curl -L https://github.com/SmartThingsCommunity/smartthings-cli/releases/download/v0.0.0-pre.34/smartthings-linux.zip | gunzip - | install /dev/stdin smartthings

Copy source dependencies into our package (they cannot be gathered through symbolic links).

	cp -r modules/lockbox/lockbox src/

Create a SmartThings Edge Driver package from this source.

	./smartthings edge:drivers:package

If needed, create a new distribution channel for this package.

	./smartthings edge:channels:create

Assign this package to a distribution channel.

	./smartthings edge:channels:assign

Enroll your SmartThings hub in this distribution channel.

	./smartthings edge:channels:enroll

Install this package on your SmartThings hub.

	./smartthings edge:drivers:install

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
and a device with Switch (and possibly SwitchLevel) capabilities for each light/dimmer.
Control the lights from SmartThings in the expected way, including refreshing their status with a swipe on their page.
Refreshing the status of all lights associated with an LC7001 controller can be done by swiping on its page.

## Development

### Command line lua

SmartThings uses an old version of lua (5.3) that is likely not to be supported by your Linux distribution.
Build from the source.

	curl https://www.lua.org/ftp/lua-5.3.6.tar.gz | tar xzf -
	(cd lua-5.3.6; make linux)
	(cd lua-5.3.6; make install INSTALL_TOP=$(realpath ..)/tools)

### Luarocks

Build luarocks from our submodule.

	(cd modules/luarocks; ./configure --help)
	(cd modules/luarocks; ./configure --with-lua=$(realpath ../../tools) --prefix=$(realpath ../../tools))
	(cd modules/luarocks; make install)

	tools/bin/luarocks init

#### lua_modules

Install SmartThings supported modules (https://luarocks.org/modules/azdle/st).

	./luarocks install cosock
	./luarocks install dkjson
	./luarocks install logface
	./luarocks install luasec
	./luarocks install luasocket

Install luacheck tool.

	./luarocks install luacheck

Example luacheck usage.

	./lua_modules/bin/luacheck src/init.lua

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
