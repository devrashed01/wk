# wk — menu-bar app + CLI for repos, branches, worktrees and Claude Code sessions.
#   make test      run Go + Swift tests
#   make install   build for this Mac, install ~/Applications/Wk.app and ~/go/bin/wk
#   make run       install and (re)start the app
#   make release   universal, signed build + zips in dist/ (notarized when NOTARY_PROFILE is set)

APP_NAME   := Wk
VERSION    ?= $(shell git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo 0.1.0)
BUILD_DIR  := app/build
APP_BUNDLE := $(BUILD_DIR)/$(APP_NAME).app
DIST       := dist
INSTALL_TO := $(HOME)/Applications
CLI_LINK   := $(HOME)/go/bin/wk

# Signing: a Developer ID certificate if present (required for others to open it without warnings),
# else your Apple Development certificate, else ad-hoc. Override with SIGN_IDENTITY="...".
SIGN_IDENTITY ?= $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Developer ID Application[^"]*"' | head -1 | tr -d '"')
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := $(shell security find-identity -v -p codesigning 2>/dev/null | grep -o '"Apple Development[^"]*"' | head -1 | tr -d '"')
endif
ifeq ($(strip $(SIGN_IDENTITY)),)
SIGN_IDENTITY := -
endif
# Hardened runtime + secure timestamp (needed for notarization) only with a Developer ID.
SIGN_FLAGS := $(if $(findstring Developer ID,$(SIGN_IDENTITY)),--options runtime --timestamp,)
# Name of a `xcrun notarytool store-credentials` profile; empty skips notarization.
NOTARY_PROFILE ?=

.PHONY: all core app test install run uninstall clean release core-universal app-universal bundle sign

all: app

core:
	cd core && go build -trimpath -ldflags "-s -w" -o bin/wk ./cmd/wk

app: core
	cd app && swift build -c release
	$(MAKE) bundle APP_BINARY=app/.build/release/$(APP_NAME) CORE_BINARY=core/bin/wk
	$(MAKE) sign

core-universal:
	cd core && GOOS=darwin GOARCH=arm64 go build -trimpath -ldflags "-s -w" -o bin/wk-arm64 ./cmd/wk
	cd core && GOOS=darwin GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o bin/wk-amd64 ./cmd/wk
	lipo -create -output core/bin/wk-universal core/bin/wk-arm64 core/bin/wk-amd64

app-universal: core-universal
	cd app && swift build -c release --arch arm64 --arch x86_64
	$(MAKE) bundle APP_BINARY=$$(cd app && swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$(APP_NAME) CORE_BINARY=core/bin/wk-universal
	$(MAKE) sign

bundle:
	rm -rf $(APP_BUNDLE)
	mkdir -p $(APP_BUNDLE)/Contents/MacOS $(APP_BUNDLE)/Contents/Resources
	cp $(APP_BINARY) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	cp $(CORE_BINARY) $(APP_BUNDLE)/Contents/Resources/wk
	cp app/Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	cp app/Resources/AppIcon.icns $(APP_BUNDLE)/Contents/Resources/AppIcon.icns
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(VERSION)" $(APP_BUNDLE)/Contents/Info.plist

# Sign inside-out: the bundled CLI first, then the app.
sign:
	@echo "Signing with: $(SIGN_IDENTITY)"
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)/Contents/Resources/wk
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(APP_BUNDLE)
	codesign --verify --strict --verbose=1 $(APP_BUNDLE)

test:
	cd core && go vet ./... && go test ./...
	cd app && swift test

install: app
	mkdir -p $(INSTALL_TO) $(dir $(CLI_LINK))
	rm -rf $(INSTALL_TO)/$(APP_NAME).app
	cp -R $(APP_BUNDLE) $(INSTALL_TO)/
	ln -sf $(INSTALL_TO)/$(APP_NAME).app/Contents/Resources/wk $(CLI_LINK)
	@echo "Installed $(INSTALL_TO)/$(APP_NAME).app and $(CLI_LINK)"

run: install
	-pkill -x $(APP_NAME)
	open $(INSTALL_TO)/$(APP_NAME).app

release: test app-universal
	rm -rf $(DIST) && mkdir -p $(DIST)
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip
ifneq ($(strip $(NOTARY_PROFILE)),)
	xcrun notarytool submit $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(APP_BUNDLE)
	rm $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip
	ditto -c -k --keepParent $(APP_BUNDLE) $(DIST)/$(APP_NAME)-$(VERSION)-macos.zip
endif
	rm -rf $(DIST)/dmg && mkdir -p $(DIST)/dmg
	cp -R $(APP_BUNDLE) $(DIST)/dmg/
	ln -s /Applications $(DIST)/dmg/Applications
	hdiutil create -volname "$(APP_NAME)" -srcfolder $(DIST)/dmg -ov -format UDZO $(DIST)/$(APP_NAME)-$(VERSION).dmg
	rm -rf $(DIST)/dmg
	codesign --force $(if $(findstring Developer ID,$(SIGN_IDENTITY)),--timestamp,) --sign "$(SIGN_IDENTITY)" $(DIST)/$(APP_NAME)-$(VERSION).dmg
ifneq ($(strip $(NOTARY_PROFILE)),)
	xcrun notarytool submit $(DIST)/$(APP_NAME)-$(VERSION).dmg --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple $(DIST)/$(APP_NAME)-$(VERSION).dmg
endif
	cp core/bin/wk-universal $(DIST)/wk
	codesign --force $(SIGN_FLAGS) --sign "$(SIGN_IDENTITY)" $(DIST)/wk
	tar -czf $(DIST)/wk-$(VERSION)-darwin-universal.tar.gz -C $(DIST) wk
	rm $(DIST)/wk
	cd $(DIST) && shasum -a 256 *.dmg *.zip *.tar.gz > SHA256SUMS.txt
	@echo "Release artifacts in $(DIST)/ (signed with: $(SIGN_IDENTITY))"

uninstall:
	-pkill -x $(APP_NAME)
	rm -rf $(INSTALL_TO)/$(APP_NAME).app $(CLI_LINK)

clean:
	rm -rf core/bin $(BUILD_DIR) app/.build $(DIST)
