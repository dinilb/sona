# make          build build/Sona.app (release) and build/sona-live-bench
# make install  build, then replace /Applications/Sona.app with it and restart it
# make test     unit tests
# make release  signed, notarized DMG (needs the Developer ID cert and an App Store Connect key)
# make publish  put that DMG on GitHub Releases and in the Sparkle appcast, so installed copies update
# make clip     test audio (macOS say + ffmpeg)
# make clean    remove build/
.PHONY: app install release publish test clip clean
app:
	scripts/build.sh
install:
	scripts/install.sh
release:
	scripts/release.sh
publish:
	scripts/publish-mac.sh
test:
	swift test --scratch-path build/spm
clip:
	scripts/make-test-clip.sh
clean:
	rm -rf build
