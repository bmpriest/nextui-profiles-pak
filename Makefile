.PHONY: test release

PAK_NAME := Profiles
PAK_DIR := $(PAK_NAME).pak
ARCHIVE := dist/Profiles.pak.zip
PACKAGE := Profiles.pak

test:
	sh bin/tests/test-profiles.sh
	sh ../RetroArch\ Core\ Saves.pak/bin/tests/test-core-saves.sh

release:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	git archive --worktree-attributes --format=zip \
		--output="$(ARCHIVE)" HEAD

dev:
	mkdir -p dist
	rm -f "$(ARCHIVE)"
	zip -q -r "$(notdir $(ARCHIVE))" . \
		-x "/.git" \
		-x "/.git/*" \
		-x "/bin/tests" \
		-x "/bin/tests/*" \
		-x "/bin/SHA256SUMS" \
		-x "/dist/*" \
		-x "/Makefile" \
		-x "/.gitignore" \
		-x "/.gitattributes" 