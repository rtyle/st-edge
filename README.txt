# git

	git clone git@github.com:rtyle/st-edge.git

# SmartThings hubs use lua 5.3

	# $HOME/lua/5.3.6

	# configure Visual Studio code workspace for lua 5.3

		Extensions: Search: Lua Debug (actboy168): Install

		File: Preferences: Settings: Workspace: @ext:actboy168.lua-debug

			Lua> Debug> Settings: Lua Version: 5.3

	# workspace.code-workspace

		"settings": {
			"lua.debug.settings.luaVersion": "5.3"
		}

# fedora dependencies

	sudo dnf install openssl-devel

# lua

	# unfortunately, lua, as a git submodule ...
	#	https://github.com/lua/lua.git is incomplete
	# ... is incomplete.
	# instead, download and build from latest 5.3 package at lua.org
	curl https://www.lua.org/ftp/lua-5.3.6.tar.gz | tar xzf -
	(cd lua-5.3.6; make linux)
	(cd lua-5.3.6; make install INSTALL_TOP=$(realpath ..)/tools)

# submodules

	mkdir modules

	# luarocks

		git submodule add https://github.com/luarocks/luarocks.git modules/luarocks
		(cd modules/luarocks; git checkout v3.8.0)

		(cd modules/luarocks; ./configure --help)
		(cd modules/luarocks; ./configure --with-lua=$(realpath ../../tools) --prefix=$(realpath ../../tools))
		(cd modules/luarocks; make install)

		tools/bin/luarocks init

	# forked lua-lockbox to resolve SmartThings hub incompatibilities

		git submodule add -b smartthings-edge https://github.com/rtyle/lua-lockbox.git modules/lockbox

	# forked suncalc for lua port

		git submodule add -b suncalc.lua https://github.com/rtyle/suncalc-lua.git modules/suncalc

	# forked xml2lua for tree-reduce-relax branch (pending pull request)

		git submodule add -b tree-reduce-relax https://github.com/rtyle/xml2lua.git modules/xml2lua

# lua_modules

	# https://luarocks.org/modules/azdle/st

		./luarocks install cosock
		./luarocks install dkjson
		./luarocks install logface
		./luarocks install luasec
		./luarocks install luasocket

	# modules that we will have to package

		./luarocks install date

	# code linter

		./luarocks install luacheck

# configure Visual Studio code workspace for lua_modules

	LUALOG=DEBUG code workspace.code-workspace

	# File: Preferences: Settings: Workspace: @ext:actboy168.lua-debug

		Lua > Debug > Settings: CPath
				"${workspaceFolder}/lua_modules/lib/lua/5.3/?.lua",
		Lua > Debug > Settings: Path
			"${workspaceFolder}/lua_modules/share/lua/5.3/?.lua",

	# workspace.code-workspace

		"settings": {
			"lua.debug.settings.path": [
				"${workspaceFolder}/src/?.lua",
				"${workspaceFolder}/src/?/init.lua",
				"${workspaceFolder}/lua_modules/share/lua/5.3/?.lua",
				"${workspaceFolder}/lua_modules/share/lua/5.3/?/init.lua",
			],
			"lua.debug.settings.cpath": [
				"${workspaceFolder}/lua_modules/lib/lua/5.3/?.lua",
			],
			"lua.debug.settings.luaVersion": "5.3"
		}

# smartthings edge API source (look for updates)

	curl -L https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases/download/apiv2_45_1/lua_libs-api_v2_45X.tar.gz	| (d=api/2_45_1	; mkdir -p $d; cd $d; tar xzf -)
	curl -L https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases/download/apiv3_46/lua_libs-api_v3_46X.tar.gz	| (d=api/3_46	; mkdir -p $d; cd $d; tar xzf -)
	curl -L https://github.com/SmartThingsCommunity/SmartThingsEdgeDrivers/releases/download/apiv6_49/lua_libs-api_v6_49X.tar.gz	| (d=api/6_49	; mkdir -p $d; cd $d; tar xzf -)

# smartthings-cli

	# download an unzip latest smartthings-cli (v0.0.0-pre.36) release

		curl -L https://github.com/SmartThingsCommunity/smartthings-cli/releases/download/%40smartthings%2Fcli%401.0.1/smartthings-linux-x64.tar.gz | tar tzf -

	# as of 2021-12-27, tokens created through
	#	https://account.smartthings.com/tokens
	# do not provide sufficient access to smartthings hubs.
	# instead, on first use, the CLI will implicitly use OAuth
	to gain necessary access and cache the credentials in
	#	~/.config/@smartthings/cli/credentials.json

	# smartthings edge:drivers:package will not build if symbolic links are under src/
	# copy lua modules that we depend on

		cp -r modules/lockbox/lockbox src/

	# one time setup

		./smartthings edge:drivers:package	# build, package, upload
		./smartthings edge:channels:create	# create a channel
		./smartthings edge:channels:assign	# assign driver to channel
		./smartthings edge:channels:drivers	# list the drivers assigned to channel
		./smartthings edge:channels:enroll	# enroll hub in channel
		./smartthings edge:channels:enrollments	# list hub's channel enrollments
		./smartthings edge:drivers:install	# install driver on hub
		./smartthings edge:drivers:logcat	# monitor driver log
		./smartthings edge:drivers:package      # build, package, upload

	# update driver by NAME

		. ./private.sh				# uuids for HUB, ADDRESS, CHANNEL, ... (see/edit file)

		NAME=legrand-rflc			# for example
		make driver/$NAME/driver		# rebuild, package, upload
		DRIVER=$(head -1 driver/$NAME/driver)	# uuid for DRIVER

		# before assigning the updated driver to the download channel that the hub subscribes to,
		# if the updated driver will not support its existing devices on the hub, remove them all first

		./smartthings edge:channels:assign --channel=$CHANNEL $DRIVER	# reassign channel to use uploaded version

		# the driver on the hub will eventually (when, exactly?) be updated; otherwise
		# reboot the hub or install the updated driver by command

		./smartthings edge:drivers:install --hub=$HUB --channel=$CHANNEL $DRIVER

	# monitor $DRIVER log on hub by its $ADDRESS

		./smartthings edge:drivers:logcat --hub-address=$ADDRESS $DRIVER
