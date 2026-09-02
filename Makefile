SCHEME   := Paddock
DERIVED  := $(CURDIR)/DerivedData
XCB      := xcodebuild -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) -quiet

.PHONY: gen build test run clean

gen:
	xcodegen generate

build: gen
	$(XCB) build

test: gen
	$(XCB) test

run: build
	open "$(DERIVED)/Build/Products/Debug/$(SCHEME).app"

clean:
	rm -rf "$(DERIVED)" Paddock.xcodeproj
