# bestOCR release pipeline — sign + notarize (che-mcps family pattern).
#
# macOS TCC requires Developer ID signing + Apple notarization for distributed
# binaries; ad-hoc builds are dev-only. Credentials live in the keychain
# (`che-mcps-notary` profile) — never in this file or the environment.
#
#   make release-signed        # build + sign + notarize + sha256 sidecars
#
# Apple's notarize round-trip takes ~2–10 minutes.

BINARIES := bestocr bestocr-mcp
BUILD_DIR := .build/release
DEVELOPER_ID ?= F2523DCF6D02BE99B67C7D27F633119292DA4934
NOTARY_PROFILE ?= che-mcps-notary

.PHONY: build-release sign notarize release-signed

build-release:
	swift build -c release

sign: build-release
	@for b in $(BINARIES); do \
	  codesign --force --options runtime --timestamp \
	    --sign $(DEVELOPER_ID) $(BUILD_DIR)/$$b && \
	  echo "signed: $$b"; \
	done

notarize: sign
	rm -f notarize-bundle.zip
	cd $(BUILD_DIR) && zip -q $(CURDIR)/notarize-bundle.zip $(BINARIES)
	xcrun notarytool submit notarize-bundle.zip \
	  --keychain-profile $(NOTARY_PROFILE) --wait
	rm -f notarize-bundle.zip

release-signed: notarize
	@for b in $(BINARIES); do \
	  shasum -a 256 $(BUILD_DIR)/$$b | awk '{print $$1}' > $(BUILD_DIR)/$$b.sha256 && \
	  echo "sha256: $$b"; \
	done
	@echo "release artifacts in $(BUILD_DIR): $(BINARIES) + .sha256 sidecars"
