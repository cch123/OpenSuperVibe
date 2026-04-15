.PHONY: build bundle run clean

APP_NAME = SuperVibe

build:
	swift build -c release

bundle: build
	@BIN_PATH=$$(swift build -c release --show-bin-path) && \
	mkdir -p $(APP_NAME).app/Contents/MacOS && \
	mkdir -p $(APP_NAME).app/Contents/Resources && \
	cp "$$BIN_PATH/$(APP_NAME)" $(APP_NAME).app/Contents/MacOS/ && \
	cp Info.plist $(APP_NAME).app/Contents/ && \
	if [ -d "$$BIN_PATH/SuperVibe_SuperVibe.bundle" ]; then \
		cp -R "$$BIN_PATH/SuperVibe_SuperVibe.bundle" $(APP_NAME).app/Contents/Resources/; \
	fi && \
	echo "APPL????" > $(APP_NAME).app/Contents/PkgInfo && \
	codesign --force --sign - $(APP_NAME).app && \
	echo "Built & signed $(APP_NAME).app"

run: build
	@BIN_PATH=$$(swift build -c release --show-bin-path) && \
	"$$BIN_PATH/$(APP_NAME)"

debug:
	swift build
	@BIN_PATH=$$(swift build --show-bin-path) && \
	"$$BIN_PATH/$(APP_NAME)"

clean:
	swift package clean
	rm -rf $(APP_NAME).app
