XCB = xcodebuild -project DOSCrate.xcodeproj -scheme DOSCrate -destination 'platform=macOS,arch=arm64'

.PHONY: vendor generate test build release

vendor:
	@echo "vendor: not yet implemented (Task 2)"

generate:
	xcodegen generate

test: vendor
	swift test --package-path Packages/DOSCrateKit
	mkdir -p build
	set -o pipefail; $(XCB) test 2>&1 | tee build/test.log
	@if grep -E "warning:" build/test.log; then echo "FAIL: warnings found"; exit 1; fi

build: vendor
	$(XCB) -configuration Debug build

release: vendor
	$(XCB) -configuration Release build
