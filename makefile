include private.mk

PACKAGES := $(addsuffix /package.zip, $(wildcard driver/*))

all: $(PACKAGES)

# we do not use ...
#	./smartthings edge:drivers:package --build
# because it does not follow symbolic links.
# instead, we build a zip file in a way that does
# and upload the result separately.
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
