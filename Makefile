APP_NAME := Palette
BUNDLE_ID := dev.myleshen.palette
BUILD_DIR := build
APP := $(BUILD_DIR)/$(APP_NAME).app
INSTALL_DIR ?= /Applications
BIN_PATH := $(shell swift build -c release --show-bin-path)
BINARY := $(BIN_PATH)/$(APP_NAME)

.PHONY: all build app install run test clean debug

all: app

build:
	swift build -c release

app: build
	rm -rf "$(APP)"
	mkdir -p "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@# Keep the dev build out of Spotlight so it does not shadow the installed app.
	touch "$(BUILD_DIR)/.metadata_never_index"
	cp "$(BINARY)" "$(APP)/Contents/MacOS/$(APP_NAME)"
	cp Resources/Info.plist "$(APP)/Contents/Info.plist"
	cp Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"
	cp -R Resources/Themes "$(APP)/Contents/Resources/Themes"
	cp -R Resources/Providers "$(APP)/Contents/Resources/Providers"
	cp -R Resources/Examples "$(APP)/Contents/Resources/Examples"
	codesign --force --deep --sign - --requirements '=designated => identifier "dev.myleshen.palette"' "$(APP)"
	@echo "Built $(APP)"

install: app
	mkdir -p "$(INSTALL_DIR)"
	rm -rf "$(INSTALL_DIR)/$(APP_NAME).app"
	cp -R "$(APP)" "$(INSTALL_DIR)/$(APP_NAME).app"
	@echo "Installed to $(INSTALL_DIR)/$(APP_NAME).app"

run: app
	open "$(APP)"

debug:
	swift build
	swift run PaletteApp

test:
	swift test

clean:
	swift package clean
	rm -rf "$(BUILD_DIR)"
