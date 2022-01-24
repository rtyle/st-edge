PACKAGES := $(addsuffix /package.zip, $(wildcard driver/*))

all: $(PACKAGES)

$(PACKAGES):
	(cd $(basename $@); zip ../$(@F) $$(find . -follow) > /dev/null)

clean:
	rm -f $(PACKAGES)

upload: $(PACKAGES)
	./smartthings edge:drivers:package --upload $<
