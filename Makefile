APP      := ScreenUpscaler
BUNDLE   := dist/$(APP).app
CONFIG   ?= release

.PHONY: all build bundle run clean

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
	@codesign --force --deep --sign - $(BUNDLE) 2>/dev/null || \
		echo "note: ad-hoc signing unavailable; permissions may reset between builds"
	@echo "built $(BUNDLE)"

run: bundle
	open $(BUNDLE)

clean:
	rm -rf .build dist
