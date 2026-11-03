APP      := ScreenUpscaler
BUNDLE   := dist/$(APP).app
CONFIG   ?= release
CERT_NAME := ScreenUpscaler Dev

# TCC identifies an app by its code signature. Ad-hoc signatures ("-") are
# identified by a hash of the binary, which changes on every rebuild - so the
# Screen Recording grant is lost each time you recompile. A self-signed
# certificate gives a stable identity that survives rebuilds.
# Sign by SHA-1 hash rather than name: the name contains a space, and the
# cert is listed in both the login and System keychains.
SIGN_ID := $(shell security find-identity -v -p codesigning 2>/dev/null | \
             grep '"$(CERT_NAME)"' | head -1 | awk '{print $$2}' || true)
ifeq ($(strip $(SIGN_ID)),)
SIGN_ID := -
endif

.PHONY: all build bundle run clean cert

all: bundle

build:
	swift build -c $(CONFIG)

# ScreenCaptureKit's permission prompt is keyed to a bundle identifier, so the
# binary has to live inside a real .app - a bare SwiftPM executable is never
# granted Screen Recording.
bundle: build
	@rm -rf $(BUNDLE)
	@mkdir -p $(BUNDLE)/Contents/MacOS $(BUNDLE)/Contents/Resources
	@cp Resources/Info.plist $(BUNDLE)/Contents/Info.plist
	@cp .build/$(CONFIG)/$(APP) $(BUNDLE)/Contents/MacOS/$(APP)
	@cp -R Models/*.mlpackage Models/REAL-ESRGAN-LICENSE $(BUNDLE)/Contents/Resources/
	@codesign --force --deep --sign $(SIGN_ID) $(BUNDLE) 2>/dev/null && \
		echo "signed with: $(if $(filter -,$(SIGN_ID)),ad-hoc,$(CERT_NAME) ($(SIGN_ID)))" || \
		echo "warning: signing failed"
	@if [ "$(SIGN_ID)" = "-" ]; then \
		echo "note: ad-hoc signed - macOS will drop Screen Recording permission"; \
		echo "      on every rebuild. Run 'make cert' once to fix this."; \
	fi
	@echo "built $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist

# One-time setup: create a self-signed code-signing certificate so Screen
# Recording permission survives rebuilds. Prompts for your login password.
cert:
	@scripts/make-signing-cert.sh "$(CERT_NAME)"

# Forget the Screen Recording grant for this bundle id, so the next launch
# prompts cleanly instead of silently matching a stale entry.
reset-permission:
	tccutil reset ScreenCapture io.jeffersonst.screenupscaler
