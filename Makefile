.PHONY: format lint test check

DEVELOPER_DIR ?= /Applications/Xcode-26.4.1.app/Contents/Developer
export DEVELOPER_DIR

format:
	find DGXPulse DGXPulseTests -name '*.swift' -print0 | xargs -0 swift format --in-place --configuration .swift-format

lint:
	find DGXPulse DGXPulseTests -name '*.swift' -print0 | xargs -0 swift format lint --strict --configuration .swift-format
	swiftlint lint --strict --config .swiftlint.yml

test:
	xcodebuild test \
		-project DGXPulse.xcodeproj \
		-scheme DGXPulse \
		-destination 'platform=macOS' \
		-only-testing:DGXPulseTests \
		CODE_SIGNING_ALLOWED=NO

check: lint test
