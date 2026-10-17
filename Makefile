.PHONY: test release sync-mounts

PAK_NAME := Profiles
PAK_DIR := $(PAK_NAME).pak
ARCHIVE := dist/Profiles.pak.zip
PACKAGE := Profiles.pak

# mountctl's source of truth is ../mount-manager; this pak ships a copy.
MOUNT_MANAGER := ../mount-manager

test:
	sh bin/tests/test-profiles.sh
	sh bin/tests/test-profiles-mounts.sh
	sh $(MOUNT_MANAGER)/tests/test-mountctl.sh
	sh ../RetroArch\ Core\ Saves.pak/bin/tests/test-core-saves.sh
	sh ../RetroArch\ Core\ Saves.pak/bin/tests/test-core-saves-mounts.sh

sync-mounts:
	mkdir -p bin/mounts
	cp $(MOUNT_MANAGER)/mountctl.sh $(MOUNT_MANAGER)/layers/10-profiles.sh bin/mounts/
	chmod 0755 bin/mounts/*.sh

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