# make          build build/Sona.app (release) and build/sona-live-bench
# make install  build, then replace /Applications/Sona.app with it and restart it
# make test     unit tests
# make release  signed, notarized DMG (needs the Developer ID cert and an App Store Connect key)
# make clip     test audio (macOS say + ffmpeg)
# make clean    remove build/
.PHONY: app install release test clip clean
app:
	scripts/build.sh
install:
	scripts/install.sh
release:
	scripts/release.sh
test:
	swift test --scratch-path build/spm
clip:
	scripts/make-test-clip.sh
clean:
	rm -rf build
