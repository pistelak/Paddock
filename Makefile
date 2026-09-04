SCHEME   := Paddock
DERIVED  := $(CURDIR)/DerivedData
XCB      := xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet
BUMP     ?= patch

.PHONY: gen build test run release clean

gen:
	xcodegen generate

build: gen
	$(XCB) build

test: gen
	$(XCB) test

run: build
	open "$(DERIVED)/Build/Products/Debug/$(SCHEME).app"

# A local dry run of what .github/workflows/release.yml builds: the next
# version after the last v* tag (BUMP=minor or major to change it), as a
# signed universal zip in build/. Nothing is tagged or published.
release:
	@eval "$$(scripts/next-version.sh $(BUMP))" && scripts/build-release.sh "$$version"

clean:
	rm -rf "$(DERIVED)" Paddock.xcodeproj build
