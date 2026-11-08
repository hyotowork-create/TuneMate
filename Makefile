SDK := /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
PLUGIN := /Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing

.PHONY: build test run core xcodeproj ios mac
build:
	swift build --sdk $(SDK)
test:
	swift test --sdk $(SDK) -Xswiftc -plugin-path -Xswiftc $(PLUGIN)
run:
	swift run --sdk $(SDK) TuneMateApp
core:
	swift build --target TuneMateCore
xcodeproj:
	xcodegen generate
ios:
	xcodegen generate && xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_iOS -destination 'platform=iOS Simulator,name=iPhone 17' -derivedDataPath .build/dd-ios build
mac:
	xcodegen generate && xcodebuild -project TuneMate.xcodeproj -scheme TuneMate_macOS -destination 'platform=macOS' -derivedDataPath .build/dd-mac build

# ---- 설치 (Xcode 있는 Mac) ----
.PHONY: bootstrap install-mac install-ios release-mac
bootstrap:
	scripts/bootstrap.sh
install-mac:
	scripts/install-mac.sh
release-mac:
	NO_INSTALL=1 scripts/install-mac.sh
install-ios:
	scripts/install-ios.sh
