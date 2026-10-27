XCB = xcodebuild -project DOSCrate.xcodeproj -scheme DOSCrate -destination 'platform=macOS,arch=arm64'

.PHONY: vendor generate test build release

vendor:
	scripts/fetch-staging.sh

generate:
	xcodegen generate

test: vendor
	mkdir -p build
	set -o pipefail; swift test --package-path Packages/DOSCrateKit 2>&1 | tee build/swift-test.log
	set -o pipefail; $(XCB) test 2>&1 | tee build/test.log
	@if grep -E "warning:" build/swift-test.log build/test.log; then echo "FAIL: warnings found"; exit 1; fi

build: vendor
	$(XCB) -configuration Debug build

release: vendor
	$(XCB) -configuration Release build
