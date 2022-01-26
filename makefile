include private.mk

# private.mk content should look something like ...
#
#	ADDRESS	:= $(shell host smartthings.home | head -1 | tr [:space:] \\n | tail -1)
#	HUB	:= xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#	CHANNEL	:= xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
#
# where
#
#	ADDRESS	is the IP address of the targeted SmartThings hub
#	HUB	is the UUID of the targeted SmartThings hub
#	CHANNEL	is the UUID of the targeted SmartThings distribution channel

# we do not use ...
#	./smartthings edge:drivers:package --build
# because it does not follow the symbolic links in our packages.
# instead, we build our PACKAGES in a way that does, upload them,
# and cache driverId, name, version and packageKey for each in DRIVERS
# which targets depend and rules use for their driverId.

PACKAGES := $(addsuffix /package.zip, $(wildcard driver/*))
DRIVERS  := $(addsuffix /driver     , $(wildcard driver/*))

all: $(DRIVERS)

clean:
	rm -f $(PACKAGES) $(DRIVERS)

driver/legrand-rflc/package.zip: $(shell find driver/legrand-rflc/package -follow -type f)
	(cd $(basename $@); zip ../$(@F) $$(find . -follow) > /dev/null)

driver/legrand-rflc/driver: driver/legrand-rflc/package.zip
	./smartthings edge:drivers:package --upload $< > /dev/null
	./smartthings edge:drivers -y --indent=1 | egrep '^ (driverId|name|version|packageKey):' | paste - - - - | grep "packageKey: $$(basename $(@D))" | tr \\t \\n | sed 's/^\s*\w*:\s*//' > $@

# install all DRIVERS through $(CHANNEL) on $(HUB)
install: $(DRIVERS)
	for driver in $^; do\
		./smartthings edge:drivers:install --channel=$(CHANNEL) --hub=$(HUB) $$(head -1 $$driver);\
	done

# uninstall all DRIVERS on $(HUB)
uninstall: $(DRIVERS)
	for driver in $^; do\
		./smartthings edge:drivers:uninstall --hub=$(HUB) $$(head -1 $$driver);\
	done

logcat-legrand-rflc: driver/legrand-rflc/driver
	./smartthings edge:drivers:logcat --hub-address=$(ADDRESS) $$(head -1 $<)
