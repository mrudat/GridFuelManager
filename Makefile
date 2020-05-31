# commands
LUAC := luac
LUACHECK := luacheck
ZIP := zip -r

# directories
FACTORIO_MODS := ~/.Factorio/mods

# override the above with local values in the optional local.mk
-include local.mk

PACKAGE_NAME := $(shell cat info.json|jq -r .name)
VERSION_STRING := $(shell cat info.json|jq -r .version)

OUTPUT_NAME := $(PACKAGE_NAME)_$(VERSION_STRING)
OUTPUT_DIR := build/$(OUTPUT_NAME)

PKG_COPY := $(shell find . -iname '*.cfg' -type f -not -path "./build/*")
PKG_COPY += $(shell find . -iname '*.png' -type f -not -path "./build/*")

SED_FILES := $(shell find . -iname '*.json' -type f -not -path "./build/*")
SED_FILES += $(shell find . -iname '*.lua' -type f -not -path "./build/*")
SED_FILES += $(shell find . -iname '*.md' -type f -not -path "./build/*")
SED_FILES += $(shell find . -iname 'changelog.txt' -type f -not -path "./build/*")

OUT_FILES := $(SED_FILES:%=$(OUTPUT_DIR)/%)

SED_EXPRS := -e 's/{{MOD_NAME}}/$(PACKAGE_NAME)/g'

SED_EXPRS += -e 's/{{VERSION}}/$(VERSION_STRING)/g'

all: clean verify package install_mod

release: clean verify package install_mod tag

package-copy:
	mkdir -p $(OUTPUT_DIR)
	for a in $(PKG_COPY) ; do \
		cp --parents $$a $(OUTPUT_DIR) ; \
	done

$(OUTPUT_DIR)/%.lua: %.lua
	@mkdir -p $(@D)
	@sed $(SED_EXPRS) $< > $@
	$(LUAC) -p $@

$(OUTPUT_DIR)/%: %
	mkdir -p $(@D)
	sed $(SED_EXPRS) $< > $@

package: package-copy $(OUT_FILES)
	cd build && $(ZIP) $(OUTPUT_NAME).zip $(OUTPUT_NAME)

clean:
	rm -rf build/

verify:
	$(LUACHECK) .

install_mod:
	if [ -d $(FACTORIO_MODS) ]; then \
		rm -rf $(FACTORIO_MODS)/$(OUTPUT_NAME) ; \
		cp -R build/$(OUTPUT_NAME) $(FACTORIO_MODS) ; \
	fi;

tag:
	git tag -f $(VERSION_STRING)
