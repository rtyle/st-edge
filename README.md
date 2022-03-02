# st-edge

[SmartThings Edge Drivers](https://community.smartthings.com/t/preview-smartthings-managed-edge-device-drivers)

* [bug](https://github.com/rtyle/st-edge/blob/master/driver/bug/README.md)
* [legrand-rflc](https://github.com/rtyle/st-edge/blob/master/driver/legrand-rflc/README.md)
* [sundial](https://github.com/rtyle/st-edge/blob/master/driver/sundial/README.md)

## Deployment

### Deployment from Public Channel

TODO.

### Deployment from Private Channel Built from Source

These instructions are written for a Linux platform. Similar steps may be taken for MacOS or Windows.

Get the source from this repository.

	git clone https://github.com/rtyle/st-edge.git

All commands documented here are executed from this directory.

	cd st-edge

Update all submodules of this repository.

	git submodule update --init --recursive

Install the latest (v0.0.0-pre.36, at the time of this writing) smartthings-cli.

	curl -L https://github.com/SmartThingsCommunity/smartthings-cli/releases/download/v0.0.0-pre.36/smartthings-linux.zip | gunzip - | install /dev/stdin smartthings

If needed, create a new distribution CHANNEL for these packages.

	./smartthings edge:channels:create

Assign these DRIVER packages to a distribution channel.

	./smartthings edge:channels:assign

Enroll your SmartThings HUB in this distribution channel.

	./smartthings edge:channels:enroll

Install this package on your SmartThings hub.

	# create private.mk as makefile suggests and
	make install

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

### Visual Studio Code

Debug as much of the code in the development environment as possible.
Visual Studio Code workspaces are provided.
Set the LUALOG environment variable to see log messages through the DEBUG level.

	LUALOG=DEBUG code workspace.code-workspace
	Extensions: Search: Lua Debug (actboy168): Install
