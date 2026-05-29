CC ?= clang
BUILD_DIR ?= .build/debug
BINARY ?= $(BUILD_DIR)/foreground-tracker
SOURCES := Sources/ForegroundTracker/main.m
APP_NAME ?= Gotowork
APP_DIR ?= dist/$(APP_NAME).app
APP_BINARY := $(APP_DIR)/Contents/MacOS/ForegroundTracker
APP_SOURCES := App/ForegroundTrackerApp.m
PREVIEW_DIR ?= /tmp/foreground-tracker-previews
PREVIEW_DATE ?= 2026-05-28
PREVIEW_NOW ?= 16:20

.PHONY: build app previews clean

build: $(BINARY)

$(BINARY): $(SOURCES)
	mkdir -p $(BUILD_DIR)
	$(CC) -fobjc-arc -fblocks $(SOURCES) -o $(BINARY) -framework Foundation -framework AppKit -framework ApplicationServices

app: $(APP_BINARY)

$(APP_BINARY): $(APP_SOURCES) App/Info.plist
	mkdir -p "$(APP_DIR)/Contents/MacOS"
	cp App/Info.plist "$(APP_DIR)/Contents/Info.plist"
	$(CC) -fobjc-arc -fblocks $(APP_SOURCES) -o "$(APP_BINARY)" -framework Foundation -framework AppKit -framework ApplicationServices -framework EventKit
	codesign --force --deep --sign - "$(APP_DIR)" >/dev/null 2>&1 || true

previews: app
	mkdir -p "$(PREVIEW_DIR)"
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/01-light.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/02-dark.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --dark --preview-size 1160x760
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/03-narrow-light.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 900x680
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/04-narrow-dark.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --dark --preview-size 900x680
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/05-pending.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760 --show-pending
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/06-hover.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760 --hover-first-calendar
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/07-manual-creation.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760 --manual-draft 18:30-18:45 --manual-creation
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/08-confirmed.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760 --select-first-calendar --confirm-first-calendar
	"$(APP_BINARY)" --render-dashboard-preview "$(PREVIEW_DIR)/09-confirmed-flash.png" --date "$(PREVIEW_DATE)" --now "$(PREVIEW_NOW)" --preview-size 1160x760 --select-first-calendar --confirm-first-calendar --flash-first-calendar
	@echo "Wrote dashboard previews to $(PREVIEW_DIR)"

clean:
	rm -rf .build dist
