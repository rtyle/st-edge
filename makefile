include private.mk

PACKAGES := $(addsuffix /package.zip, $(wildcard driver/*))

all: $(PACKAGES)

$(PACKAGES):
	(cd $(basename $@); zip ../$(@F) $$(find . -follow) > /dev/null)

clean:
	rm -f $(PACKAGES)

upload: $(PACKAGES)
	./smartthings edge:drivers:package --upload $<

install:
	./smartthings edge:drivers:install --channel=$(CHANNEL) --hub=$(HUB) $(DRIVER)

uninstall:
	./smartthings edge:drivers:uninstall --hub=$(HUB) $(DRIVER) 

logcat:
	./smartthings edge:drivers:logcat --hub-address=$(ADDRESS) $(DRIVER)
