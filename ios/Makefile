# Sona for iPhone and Apple Watch. Run from ios/. See README.md.
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
SHELL := /bin/bash
# Test runs print only results and errors, and still fail when a test does (pipefail is set in each recipe:
# macOS's make 3.81 ignores .SHELLFLAGS).
RESULTS := grep -E '(✔|✘|error:|Test run|Suite .* (passed|failed)|TEST (SUCCEEDED|FAILED))'

PROJECT   := Sona.xcodeproj
DERIVED   := build/DerivedData
# Simulators of our own, so nothing else using the usual ones gets in the way. `make sims` makes and pairs them.
SIM       ?= Sona iPhone
WATCH_SIM ?= Sona Watch
APP       := $(DERIVED)/Build/Products/Debug-iphonesimulator/Sona.app
WATCH_APP := $(DERIVED)/Build/Products/Debug-watchsimulator/SonaWatch.app
BUNDLE_ID := com.dinilb.sona

.PHONY: generate build build-watch test test-watch run run-watch sims release icon clean

generate:
	xcodegen generate --quiet

build: generate
	xcodebuild -project $(PROJECT) -scheme Sona -configuration Debug \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) -quiet build

build-watch: generate
	xcodebuild -project $(PROJECT) -scheme SonaWatch -configuration Debug \
		-destination 'platform=watchOS Simulator,name=$(WATCH_SIM)' -derivedDataPath $(DERIVED) -quiet build

# No diagnostics collected after a run: xcodebuild's simctl diagnose took over 10 minutes per run (8 Nov 2026).
test: generate
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme Sona \
		-destination 'platform=iOS Simulator,name=$(SIM)' -derivedDataPath $(DERIVED) \
		-collect-test-diagnostics never test 2>&1 | $(RESULTS)

test-watch: generate
	set -o pipefail; xcodebuild -project $(PROJECT) -scheme SonaWatch \
		-destination 'platform=watchOS Simulator,name=$(WATCH_SIM)' -derivedDataPath $(DERIVED) \
		-collect-test-diagnostics never test 2>&1 | $(RESULTS)

# Install and launch on the simulator. ARGS="-debugRecordFile /path/clip.wav" etc. (see ios/README.md, "Launch arguments").
run: build
	xcrun simctl boot '$(SIM)' 2>/dev/null || true
	xcrun simctl install '$(SIM)' $(APP)
	xcrun simctl terminate '$(SIM)' $(BUNDLE_ID) 2>/dev/null || true
	xcrun simctl launch '$(SIM)' $(BUNDLE_ID) $(ARGS)

run-watch: build-watch
	xcrun simctl boot '$(WATCH_SIM)' 2>/dev/null || true
	xcrun simctl install '$(WATCH_SIM)' $(WATCH_APP)
	xcrun simctl launch '$(WATCH_SIM)' $(BUNDLE_ID).watchkitapp $(ARGS)

sims:
	scripts/sims.sh '$(SIM)' '$(WATCH_SIM)'

# One command to TestFlight: archive, sign, upload, wait for processing, hand it to the testers. See README.md.
# NOTES (what to test) reaches the script through the environment, so any quote or apostrophe in it is fine.
release: export NOTES := $(NOTES)
release:
	scripts/release.sh

icon:
	cd .. && swift ios/scripts/make-icon.swift

clean:
	rm -rf build $(PROJECT)
