APP := .build/xcode/Build/Products/Debug/Merlix.app

.PHONY: ghostty project build run release install clean

ghostty:
	./scripts/build-ghostty.sh

project: ghostty
	xcodegen generate --quiet

build: project
	xcodebuild -project Merlix.xcodeproj -scheme Merlix -configuration Debug \
		-derivedDataPath .build/xcode -quiet build

run: build
	open $(APP)

release: project
	xcodebuild -project Merlix.xcodeproj -scheme Merlix -configuration Release \
		-derivedDataPath .build/xcode-release -quiet build
	rm -rf .build/release && mkdir -p .build/release
	ditto .build/xcode-release/Build/Products/Release/Merlix.app .build/release/Merlix.app
	@echo .build/release/Merlix.app

# Replaces /Applications/Merlix.app; quit Merlix first.
install: release
	rm -rf /Applications/Merlix.app
	ditto .build/release/Merlix.app /Applications/Merlix.app
	@echo /Applications/Merlix.app

clean:
	rm -rf .build/xcode .build/xcode-release .build/release Merlix.xcodeproj
