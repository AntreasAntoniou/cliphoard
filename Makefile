.PHONY: build run app install clean

# Compile a debug binary.
build:
	swift build

# Build the release .app bundle into ./build.
app:
	@bash Scripts/build-app.sh release

# Build and launch the app.
run: app
	@open build/Cliphoard.app

# Copy the app into /Applications.
install: app
	@rm -rf /Applications/Cliphoard.app
	@cp -R build/Cliphoard.app /Applications/Cliphoard.app
	@echo "✓ Installed to /Applications/Cliphoard.app"

clean:
	swift package clean
	rm -rf build .build
