# Hangar. The Swift build needs only Command Line Tools; Xcode is required for one
# step, actool, which compiles the asset catalog.
.PHONY: help all build test testbed icon wordmark verify-assets bundle dmg install run uninstall clean

help:
	@echo "  make test            offline test suite, no network needed"
	@echo "  make testbed         drive every host source against a fake home"
	@echo "  make bundle          assemble dist/Hangar.app and sign it"
	@echo "  make icon            re-render the app icon previews from the layer SVGs"
	@echo "  make wordmark        re-render the wordmark @2x fallbacks and its manifest"
	@echo "  make verify-assets   prove every brand asset resolves in the bundle"
	@echo "  make install         build and copy to ~/Applications"
	@echo "  make run             install and launch"
	@echo "  make dmg             build dist/Hangar-<version>.dmg (notarizes when configured)"
	@echo "  make uninstall       remove the installed app"
	@echo "  make clean           remove build products"

all: bundle

build:
	@swift build --package-path app -c release

test:
	@scripts/test.sh

# Every source, the merge and the writer against a fabricated home directory,
# then proves your own ~/.ssh/config and ~/.hangar were not touched.
testbed:
	@swift build --package-path app
	@scripts/testbed.sh

bundle:
	@scripts/bundle.sh

# Flattens the layered icon sources into the preview PNGs the bundle falls back to.
icon:
	@scripts/render-icon.sh

wordmark:
	@scripts/render-wordmark.sh

# Proves every supplied brand asset name resolves inside the real bundle.
verify-assets: bundle
	@dist/Hangar.app/Contents/MacOS/Hangar --verify-assets

dmg:
	@scripts/package-dmg.sh

install: bundle
	@mkdir -p $(HOME)/Applications
	@rm -rf $(HOME)/Applications/Hangar.app
	@cp -R dist/Hangar.app $(HOME)/Applications/
	@echo "installed to $(HOME)/Applications/Hangar.app"

run: install
	@pkill -x Hangar 2>/dev/null || true
	@open $(HOME)/Applications/Hangar.app
	@echo "launched; look for the hangar glyph in your menubar"

uninstall:
	@pkill -x Hangar 2>/dev/null || true
	@rm -rf $(HOME)/Applications/Hangar.app

clean:
	@rm -rf dist app/.build build
