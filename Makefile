APP_NAME := Palette
BUNDLE_ID := dev.myleshen.palette
DEBUG_BUNDLE_ID := dev.myleshen.palette.debug
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
DEBUG_APP := $(BUILD_DIR)/$(APP_NAME) Debug.app
INSTALL_DIR ?= /Applications
BIN_PATH := $(shell swift build -c release --show-bin-path)
BINARY := $(BIN_PATH)/$(APP_NAME)
DEBUG_BIN_PATH := $(shell swift build --show-bin-path)
DEBUG_BINARY := $(DEBUG_BIN_PATH)/$(APP_NAME)
# The short commit is stamped into Info.plist so About can name the build.
# Missing git (a source tarball, CI without history) just skips the key.
COMMIT := $(shell git rev-parse --short HEAD 2>/dev/null)

.PHONY: all build app install run test clean debug debug-app layout-check e2e

all: app

build:
	swift build -c release

# assemble_bundle <bundle> <binary>
define assemble_bundle
	rm -rf "$(1)"
	mkdir -p "$(1)/Contents/MacOS" "$(1)/Contents/Resources"
	@# Keep the dev build out of Spotlight so it does not shadow the installed app.
	touch "$(BUILD_DIR)/.metadata_never_index"
	cp "$(2)" "$(1)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(1)/Contents/Info.plist"
	if [ -n "$(COMMIT)" ]; then plutil -insert PaletteCommit -string "$(COMMIT)" "$(1)/Contents/Info.plist"; fi
	cp Resources/AppIcon.icns "$(1)/Contents/Resources/AppIcon.icns"
	cp -R Resources/Themes "$(1)/Contents/Resources/Themes"
	cp -R Resources/Providers "$(1)/Contents/Resources/Providers"
	cp -R Resources/Examples "$(1)/Contents/Resources/Examples"
endef

app: build
	$(call assemble_bundle,$(APP),$(BINARY))
	codesign --force --deep --sign - --requirements '=designated => identifier "$(BUNDLE_ID)"' "$(APP)"
	@echo "Built $(APP)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

run: app
	open "$(APP)"

# Debug runs launch through LaunchServices so tccd attributes permission prompts
# to the debug bundle id, not the terminal or agent that spawned the process.
debug-app:
	swift build
	$(call assemble_bundle,$(DEBUG_APP),$(DEBUG_BINARY))
	plutil -replace CFBundleIdentifier -string "$(DEBUG_BUNDLE_ID)" "$(DEBUG_APP)/Contents/Info.plist"
	plutil -replace CFBundleName -string "Palette Debug" "$(DEBUG_APP)/Contents/Info.plist"
	plutil -replace CFBundleDisplayName -string "Palette Debug" "$(DEBUG_APP)/Contents/Info.plist"
	codesign --force --deep --sign - --requirements '=designated => identifier "$(DEBUG_BUNDLE_ID)"' "$(DEBUG_APP)"
	@echo "Built $(DEBUG_APP)"
	open "$(DEBUG_APP)"

debug: debug-app

layout-check:
	Scripts/layout-check.sh

e2e:
	Scripts/e2e.sh

test:
	swift test

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
