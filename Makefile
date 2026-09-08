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

.PHONY: all gen build test core-test app-test ui-test live-test run clean release screenshot bundle-cli install skill

all: build

gen:
	@$(XCODEGEN) generate --quiet
	@echo "Generated $(PROJECT)"

$(PROJECT):
	@$(MAKE) --no-print-directory gen

build: $(PROJECT)
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DEST)' build 2>&1 | $(FILTER)
	@$(MAKE) --no-print-directory bundle-cli CONFIG=Debug

# Builds the `postfrau` binary and puts it inside the app bundle, where Settings ▸ Advanced can
# symlink it from. Done here rather than as an Xcode build phase: `swift build` inside Xcode's
# script sandbox needs that sandbox turned off, and it would rebuild the package on every app
# build. See docs/decisions.md D36.
#
# It goes in Contents/Helpers, never Contents/MacOS: macOS filesystems are case-insensitive, so
# a file called `postfrau` beside the app's own `Postfrau` executable overwrites it.
CONFIG ?= Debug
SWIFT_CONFIG = $(shell [ "$(CONFIG)" = "Release" ] && echo release || echo debug)

bundle-cli:
	@cd $(CORE) && swift build -c $(SWIFT_CONFIG) --product postfrau >/dev/null
	@APP=$$(xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination '$(DEST)' -showBuildSettings 2>/dev/null \
		| awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $$2}' | head -1)/$(SCHEME).app; \
	mkdir -p "$$APP/Contents/Helpers"; \
	cp "$$(cd $(CORE) && swift build -c $(SWIFT_CONFIG) --show-bin-path)/postfrau" \
		"$$APP/Contents/Helpers/postfrau"; \
	echo "Bundled postfrau into $$APP/Contents/Helpers"

# Puts `postfrau` on the PATH for development. The app offers the same thing in
# Settings ▸ Advanced; this is the version for a checkout.
install: build
	@mkdir -p $(HOME)/.local/bin
	@cd $(CORE) && swift build -c release --product postfrau >/dev/null
	@ln -sf "$$(cd $(CORE) && swift build -c release --show-bin-path)/postfrau" \
		$(HOME)/.local/bin/postfrau
	@echo "Linked $(HOME)/.local/bin/postfrau — make sure that is on your PATH."

# Regenerates the repository copy of the skill from the one compiled into the binary, so the two
# can never disagree.
skill:
	@cd $(CORE) && swift build -c debug --product postfrau >/dev/null
	@"$$(cd $(CORE) && swift build -c debug --show-bin-path)/postfrau" skill install --to skills/postfrau


core-test:
	@cd $(CORE) && swift test 2>&1 | grep -vE "^◇" || (cd $(CORE) && swift test)

# Unit tests for the app target. These need no window, so they always run.
app-test: $(PROJECT)
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DEST)' test \
		-only-testing:PostfrauTests 2>&1 | $(FILTER)

# XCUITests drive the real UI, so they need a display where Postfrau's window can come to the
# front. They fail with "unable to find hit point" when something else owns the screen — a
# full-screen app on its own Space, a locked screen, screen sharing. Kept out of `make test` for
# that reason; run them yourself when the desktop is free. See docs/decisions.md D22.
ui-test: $(PROJECT)
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-configuration Debug -destination '$(DEST)' test \
		-only-testing:PostfrauUITests 2>&1 | $(FILTER)

# Tests that talk to the real network (example.com, httpbin.org). Kept out of `make test` so the
# commit gate never depends on someone else's uptime. `TEST_RUNNER_` is how xcodebuild passes an
# environment variable through to the test host; the shell's own environment does not reach it.
live-test: $(PROJECT)
	@cd $(CORE) && POSTFRAU_LIVE_TESTS=1 swift test --filter Live 2>&1 | grep -vE "^◇" || true
	@set -o pipefail; TEST_RUNNER_POSTFRAU_LIVE_TESTS=1 xcodebuild -project $(PROJECT) \
		-scheme $(SCHEME) -configuration Debug -destination '$(DEST)' test \
		-only-testing:PostfrauTests 2>&1 | $(FILTER)

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
