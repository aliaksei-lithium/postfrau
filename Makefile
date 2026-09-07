# Postfrau — build automation.
#
# `make gen` regenerates Postfrau.xcodeproj from project.yml (the project is git-ignored).
# `make core-test` is the fast inner loop; `make test` is the gate before every commit.

SHELL      := /bin/bash
PROJECT    := Postfrau.xcodeproj
SCHEME     := Postfrau
CORE       := Packages/PostfrauCore
DERIVED    := $(HOME)/Library/Developer/Xcode/DerivedData
XCODEGEN   := /opt/homebrew/bin/xcodegen
DEST       := platform=macOS
# xcodebuild is extremely noisy; keep only diagnostics and the verdict.
FILTER     := (grep -E "^(/|\.).*:[0-9]+:[0-9]+: (error|warning): |^(error|warning): |^\*\* [A-Z]+ (SUCCEEDED|FAILED)|^Testing failed" || true)

.PHONY: all gen build test core-test app-test run clean release screenshot

all: build

gen:
	@$(XCODEGEN) generate --quiet
	@echo "Generated $(PROJECT)"

$(PROJECT):
	@$(MAKE) --no-print-directory gen

build: $(PROJECT)
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DEST)' build 2>&1 | $(FILTER)

core-test:
	@cd $(CORE) && swift test 2>&1 | grep -vE "^◇" || (cd $(CORE) && swift test)

app-test: $(PROJECT)
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DEST)' test 2>&1 | $(FILTER)

test: core-test app-test

run: build
	@open "$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
		-destination '$(DEST)' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$$2} / FULL_PRODUCT_NAME /{n=$$2} END{print d"/"n}')"

screenshot:
	@Scripts/screenshot.sh

clean:
	@rm -rf .build $(CORE)/.build
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) clean >/dev/null 2>&1 || true
	@echo "Cleaned"

release:
	@Scripts/release.sh
