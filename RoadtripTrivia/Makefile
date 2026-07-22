## Roadtrip Trivia — developer shortcuts.
##
## `make test` runs the pure-logic XCTest suite (AnswerGrader,
## FarewellScript, PostScoreWatchdogPolicy, ...) defined in Package.swift.
##
## Honors a pre-set $DEVELOPER_DIR (e.g. when invoked from an Xcode
## build phase, Xcode exports its own DEVELOPER_DIR pointing at the
## running Xcode). Otherwise falls back to Xcode-beta because the
## system Command Line Tools `swift` is currently out of sync with the
## macOS SDK on this machine.

DEVELOPER_DIR ?= /Users/tedmorgan/Downloads/Xcode-beta.app/Contents/Developer
SWIFT         := $(DEVELOPER_DIR)/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift
CACHE_DIR     := $(CURDIR)/.swiftpm-cache
BUILD_DIR     := $(CURDIR)/.build

.PHONY: test test-clean audit

test:
	@DEVELOPER_DIR="$(DEVELOPER_DIR)" \
		"$(SWIFT)" test \
		--cache-path "$(CACHE_DIR)/cache" \
		--build-path "$(BUILD_DIR)"

test-clean:
	rm -rf "$(BUILD_DIR)" "$(CACHE_DIR)"

## Audit the most recent drive-test logs (defaults to ~/Downloads).
## Usage: make audit            — scan ~/Downloads for standard log names
##        make audit LOGS="a b" — scan specific files
audit:
	python3 scripts/analyze_game_logs.py $(LOGS)
