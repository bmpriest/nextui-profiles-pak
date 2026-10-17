#!/bin/sh

set -eu

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/profiles-test.XXXXXX")
# Mount lookups compare resolved paths, so the fake mount table must use them.
TEST_ROOT=$(CDPATH= cd -P -- "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

SDCARD_PATH="$TEST_ROOT/sd"
PLATFORM=tg5040
USERDATA_PATH="$SDCARD_PATH/.userdata/$PLATFORM"
SHARED_USERDATA_PATH="$SDCARD_PATH/.userdata/shared"
LOGS_PATH="$USERDATA_PATH/logs"
PROFILE_ROOT="$SDCARD_PATH/.profiles"
INSTALL_HOME="$USERDATA_PATH/Profiles"
LOG_FILE="$LOGS_PATH/profiles.txt"
TMP_ROOT="$TEST_ROOT/tmp"
MOUNTS_LOCK="$TEST_ROOT/mountctl.lock"
MOUNTINFO_PATH="$TEST_ROOT/mountinfo"
AUTO_PATH="$USERDATA_PATH/auto.sh"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

mkdir -p "$SDCARD_PATH/Saves" "$SHARED_USERDATA_PATH" "$LOGS_PATH" "$TMP_ROOT"
: > "$LOG_FILE"
: > "$MOUNTINFO_PATH"

export SDCARD_PATH PLATFORM USERDATA_PATH SHARED_USERDATA_PATH LOGS_PATH
export PROFILE_ROOT INSTALL_HOME LOG_FILE TMP_ROOT MOUNTINFO_PATH AUTO_PATH DIR MOUNTS_LOCK

. "$DIR/bin/profiles.sh"

pass_count=0

fail() {
	echo "FAIL: $*" >&2
	exit 1
}

pass() {
	pass_count=$((pass_count + 1))
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

assert_file() {
	[ -f "$1" ] || fail "missing file: $1"
}

assert_dir() {
	[ -d "$1" ] || fail "missing directory: $1"
}

assert_not_file() {
	[ ! -f "$1" ] || fail "unexpected file: $1"
}

assert_contains() {
	grep -Fq "$2" "$1" || fail "$1 does not contain: $2"
}

test_names() {
	validate_profile_name "Ben Smith" || fail "valid name rejected"
	validate_profile_name "Kid-2" || fail "valid hyphenated name rejected"
	validate_profile_name "../bad" && fail "unsafe name accepted"
	validate_profile_name ".hidden" && fail "hidden name accepted"
	pass
}

test_syncthing_paths() {
	mkdir -p "$(dirname "$SYNCTHING_CONFIG")"
	cat > "$SYNCTHING_CONFIG" <<EOF
<configuration>
  <folder id="saves" label="Saves" path="$SDCARD_PATH/Saves/Cores" type="sendreceive"></folder>
  <folder id="states" path="$SDCARD_PATH/.userdata/shared/GB-gambatte"></folder>
  <folder id="relative" path="Saves/OtherCore"></folder>
  <folder id="roms" path="$SDCARD_PATH/Roms"></folder>
</configuration>
EOF
	paths=$(syncthing_affected_paths)
	echo "$paths" | grep -Fq "$SDCARD_PATH/Saves/Cores" || fail "Saves path not detected"
	echo "$paths" | grep -Fq "$SDCARD_PATH/.userdata/shared/GB-gambatte" || fail "shared path not detected"
	echo "$paths" | grep -Fq "Saves/OtherCore" || fail "relative Saves path not detected"
	if echo "$paths" | grep -Fq "$SDCARD_PATH/Roms"; then
		fail "ROM path incorrectly detected"
	fi
	pass
}

test_mountinfo() {
	cat > "$MOUNTINFO_PATH" <<EOF
25 1 179:1 / $SDCARD_PATH rw - vfat /dev/mmcblk0p1 rw
36 25 179:1 /.profiles/Ben/Saves $SDCARD_PATH/Saves rw - vfat /dev/mmcblk0p1 rw
37 36 179:1 /.profiles/Ben/Saves/Cores/Gambatte $SDCARD_PATH/Saves/GB rw - vfat /dev/mmcblk0p1 rw
38 36 179:1 /.profiles/Ben/Saves/Cores/Gambatte $SDCARD_PATH/Saves/GBC rw - vfat /dev/mmcblk0p1 rw
EOF
	mc_is_mounted "$SDCARD_PATH/Saves" || fail "parent mount not detected"
	mc_matches "$PROFILE_ROOT/Ben/Saves" "$SDCARD_PATH/Saves" || fail "matching parent rejected"
	mc_matches "$PROFILE_ROOT/Kid/Saves" "$SDCARD_PATH/Saves" && fail "wrong source accepted"
	desc=$(mc_descendants "$SDCARD_PATH/Saves")
	echo "$desc" | grep -Fq "$SDCARD_PATH/Saves/GB" || fail "GB child missing"
	echo "$desc" | grep -Fq "$SDCARD_PATH/Saves/GBC" || fail "GBC child missing"
	core_saves_mounts_active && fail "child mounts alone reported as Core Saves"
	: > "$MOUNTINFO_PATH"
	pass
}


# h700 reaches the card through a symlink while the kernel lists the real path.
test_symlinked_sdcard() {
	real="$TEST_ROOT/real-sd"
	link="$TEST_ROOT/LINK-SD"
	mkdir -p "$real/Saves" "$real/.userdata/shared" "$real/.profiles/Ben/Saves"
	ln -s "$real" "$link"
	cat > "$MOUNTINFO_PATH" <<EOF
25 1 179:1 / $real rw - vfat /dev/mmcblk1p1 rw
36 25 179:1 /.profiles/Ben/Saves $real/Saves rw - vfat /dev/mmcblk1p1 rw
37 36 179:1 /.profiles/Ben/Saves/Cores/Gambatte $real/Saves/GB rw - vfat /dev/mmcblk1p1 rw
EOF
	assert_eq "$(mc_physical "$link/Saves")" "$real/Saves"
	assert_eq "$(mc_physical "$link/.profiles/Kid/Saves")" "$real/.profiles/Kid/Saves"
	assert_eq "$(mc_physical "/")" "/"
	mc_is_mounted "$link/Saves" || fail "mount behind symlink not detected"
	mc_is_mounted "$link/.userdata/shared" && fail "unmounted path reported mounted"
	mc_matches "$link/.profiles/Ben/Saves" "$link/Saves" || fail "matching mount behind symlink rejected"
	mc_matches "$link/.profiles/Kid/Saves" "$link/Saves" && fail "wrong source accepted behind symlink"
	assert_eq "$(mc_descendants "$link/Saves")" "$real/Saves/GB"
	(
		SAVES_TARGET="$link/Saves"
		SHARED_TARGET="$link/.userdata/shared"
		path_is_profile_alias "$real/Saves/Cores" || fail "resolved Saves path not treated as an alias"
		path_is_profile_alias "$link/.userdata/shared" || fail "symlinked shared path not treated as an alias"
		path_is_profile_alias "$real/Roms" && fail "ROM path treated as an alias"
		exit 0
	) || exit 1
	: > "$MOUNTINFO_PATH"
	pass
}

# install_runtime registers layer 10 with mountctl, installs the hotkey boot
# hook, and removes the auto.sh line that earlier versions mounted from.
test_install_runtime() {
	cat > "$AUTO_PATH" <<'EOF'
#!/bin/sh
syncthing-line
test -x "$USERDATA_PATH/Profiles/boot-mount.sh" && "$USERDATA_PATH/Profiles/boot-mount.sh" # Profiles.pak-on-boot
custom-line
EOF
	mkdir -p "$INSTALL_HOME"
	: > "$INSTALL_HOME/boot-mount.sh"
	install_runtime || fail "$ACTION_RESULT"
	assert_eq "$(grep -c "$PROFILE_MARKER" "$AUTO_PATH" || true)" "0"
	assert_contains "$AUTO_PATH" "syncthing-line"
	assert_contains "$AUTO_PATH" "custom-line"
	assert_not_file "$INSTALL_HOME/boot-mount.sh"
	assert_file "$MOUNTS_HOME/mountctl.sh"
	assert_file "$MOUNTS_HOME/layers.d/10-profiles.sh"
	assert_file "$USERDATA_PATH/.hooks/boot.d/00-mounts.sync.sh"
	assert_contains "$HOTKEY_HOOK" "refresh-hotkey.sh"
	assert_contains "$HOTKEY_HOOK" "PROFILES_DIR='$DIR'"
	pass
}


test_initial_copy() {
	: > "$MOUNTINFO_PATH"
	echo save-data > "$SDCARD_PATH/Saves/game.sav"
	echo state-data > "$SHARED_USERDATA_PATH/game.st0"

	# Initialization's filesystem work is real; only kernel mount operations are
	# replaced so this test can run without privileges.
	# mountctl itself is tested with real mounts in ../mount-manager. Here it
	# records which profile was active each time Profiles asked it to act, and
	# fails when $MOUNTCTL_FAIL names that command.
	mountctl() {
		echo "mountctl:$1:$(active_profile)" >> "$TEST_ROOT/order"
		[ "${MOUNTCTL_FAIL:-}" = "$1" ] && { echo "simulated $1 failure"; return 1; }
		return 0
	}
	refresh_hotkey() { :; }
	remove_auto_hook() { :; }
	remount_core_saves_if_compatible() { :; }
	profiles_before_mount_switch() { :; }
	sync() { :; }

	initialize_from_current "Ben" 0 || fail "$ACTION_RESULT"
	assert_file "$PROFILE_ROOT/Ben/Saves/game.sav"
	assert_file "$PROFILE_ROOT/Ben/shared/game.st0"
	assert_not_file "$PROFILE_ROOT/Ben/shared/enable-simple-mode"
	assert_eq "$(active_profile)" "Ben"
	assert_eq "$(primary_profile)" "Ben"
	backup=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d | head -n 1)
	assert_file "$backup/Saves/game.sav"
	assert_file "$backup/shared/game.st0"
	pass
}

test_clone_primary() {
	echo primary-only > "$PROFILE_ROOT/Ben/Saves/primary.sav"
	mkdir -p "$PROFILE_ROOT/Ben/shared/.minui"
	echo setting > "$PROFILE_ROOT/Ben/shared/.minui/config"
	: > "$PROFILE_ROOT/Ben/shared/enable-simple-mode"
	create_profile_from_primary "Copy" 0 || fail "$ACTION_RESULT"
	assert_file "$PROFILE_ROOT/Copy/Saves/primary.sav"
	assert_file "$PROFILE_ROOT/Copy/shared/.minui/config"
	assert_not_file "$PROFILE_ROOT/Copy/shared/enable-simple-mode"
	pass
}

test_switch_order() {
	create_empty_profile "Kid" 0 || fail "$ACTION_RESULT"
	: > "$TEST_ROOT/order"
	activate_profile "Kid" || fail "$ACTION_RESULT"
	assert_eq "$(cat "$TEST_ROOT/order")" "mountctl:apply:Kid"
	assert_eq "$(active_profile)" "Kid"
	pass
}

# A failed apply puts the previous profile back and remounts it.
test_failed_switch_restores() {
	: > "$TEST_ROOT/order"
	MOUNTCTL_FAIL=apply
	activate_profile "Ben" && fail "switch succeeded although mountctl failed"
	MOUNTCTL_FAIL=""
	assert_eq "$ACTION_RESULT" "simulated apply failure"
	assert_eq "$(active_profile)" "Kid"
	assert_eq "$(sed -n '1p' "$TEST_ROOT/order")" "mountctl:apply:Ben"
	assert_eq "$(sed -n '2p' "$TEST_ROOT/order")" "mountctl:apply:Kid"
	pass
}

test_reload_active() {
	: > "$TEST_ROOT/order"
	activate_profile "Kid" || fail "$ACTION_RESULT"
	assert_eq "$(active_profile)" "Kid"
	assert_contains "$LOG_FILE" "Reloading profile: Kid"
	assert_eq "$(cat "$TEST_ROOT/order")" "mountctl:apply:Kid"
	pass
}

test_profile_menu_json() {
	menu="$TEST_ROOT/profiles-menu.json"
	map="$TEST_ROOT/profiles-menu.map"
	build_profile_menu "$menu" "$map"
	assert_contains "$menu" '"name":"[ACTIVE] Kid","features":{"confirm_text":"RELOAD"}'
	assert_contains "$menu" '"name":"Ben","features":{"confirm_text":"CHANGE"}'
	assert_contains "$menu" '"confirm_text":"ADD"'
	assert_contains "$menu" '"confirm_text":"UNINSTALL"'
	jq -e '.items | length == 5' "$menu" >/dev/null || fail "profile menu is not valid JSON"
	pass
}

test_menu_invocation_formats() {
	profiles_ui=$(sed -n '/^profiles_menu()/,/^main()/p' "$DIR/launch.sh")
	printf '%s\n' "$profiles_ui" | grep -Fq -- '--format json --file "$menu" --item-key items' ||
		fail "Profiles menu is not invoked in JSON format"
	edit_ui=$(sed -n '/^edit_profile_ui()/,/^profiles_menu()/p' "$DIR/launch.sh")
	printf '%s\n' "$edit_ui" | grep -Fq -- '--format text --file "$menu"' ||
		fail "Edit menu is not invoked in text format"
	pass
}

test_core_owner() {
	mkdir -p "$SHARED_TARGET/RetroArch Core Saves"
	: > "$SHARED_TARGET/RetroArch Core Saves/enabled"
	rm -f "$CORE_PROFILE_FILE"
	validate_core_saves_owner || fail "first owner was rejected"
	assert_eq "$(cat "$CORE_PROFILE_FILE")" "Kid"
	printf '%s\n' "Ben" > "$ACTIVE_FILE"
	validate_core_saves_owner && fail "second Core Saves owner accepted"
	pass
}

test_rename_primary() {
	rename_profile "Ben" "Main" || fail "$ACTION_RESULT"
	assert_eq "$(primary_profile)" "Main"
	pass
}

# Renaming the active profile unmounts it first and remounts it under its new
# name only after every marker names the new folder.
test_rename_active() {
	printf '%s\n' "Kid" > "$ACTIVE_FILE"
	printf '%s\n' "Kid" > "$CORE_PROFILE_FILE"
	: > "$TEST_ROOT/order"
	rename_profile "Kid" "Kiddos" || fail "$ACTION_RESULT"
	assert_eq "$(cat "$TEST_ROOT/order")" "$(printf 'mountctl:down:Kid\nmountctl:apply:Kiddos')"
	assert_eq "$(active_profile)" "Kiddos"
	assert_eq "$(sed -n '1p' "$CORE_PROFILE_FILE")" "Kiddos"
	assert_dir "$PROFILE_ROOT/Kiddos/Saves"

	# If the remount fails, the old name and markers come back.
	MOUNTCTL_FAIL=apply
	rename_profile "Kiddos" "Kid" && fail "rename succeeded although mountctl failed"
	MOUNTCTL_FAIL=""
	assert_eq "$(active_profile)" "Kiddos"
	assert_eq "$(sed -n '1p' "$CORE_PROFILE_FILE")" "Kiddos"
	assert_dir "$PROFILE_ROOT/Kiddos/Saves"
	[ ! -e "$PROFILE_ROOT/Kid" ] || fail "half-renamed profile left behind"

	rename_profile "Kiddos" "Kid" || fail "$ACTION_RESULT"
	pass
}

test_delete_profile() {
	delete_profile "Main" && fail "primary profile was deleted"
	printf '%s\n' "Kid" > "$ACTIVE_FILE"
	delete_profile "Kid" && fail "active profile was deleted"
	printf '%s\n' "Main" > "$ACTIVE_FILE"
	delete_profile "Copy" || fail "$ACTION_RESULT"
	[ ! -d "$PROFILE_ROOT/Copy" ] || fail "deleted profile directory remains"
	pass
}

test_uninstall() {
	echo legacy-save > "$SAVES_TARGET/legacy.sav"
	echo primary-restore > "$PROFILE_ROOT/Main/Saves/restored.sav"
	printf '%s\n' '#!/bin/sh' 'old-line # Profiles.pak-on-boot' > "$AUTO_PATH"
	: > "$INSTALL_HOME/boot-mount.sh"
	unset -f remove_auto_hook
	. "$DIR/bin/profiles.sh"
	mountctl() {
		echo "mountctl:$1:$(active_profile)" >> "$TEST_ROOT/order"
		return 0
	}
	refresh_hotkey() { :; }
	: > "$TEST_ROOT/order"
	: > "$INSTALL_HOME/hotkey-monitor.sh"
	: > "$INSTALL_HOME/refresh-hotkey.sh"
	uninstall_profiles || fail "$ACTION_RESULT"
	assert_file "$SAVES_TARGET/restored.sav"
	assert_not_file "$SAVES_TARGET/legacy.sav"
	assert_not_file "$INSTALL_HOME/boot-mount.sh"
	assert_eq "$(grep -c "$PROFILE_MARKER" "$AUTO_PATH" || true)" "0"
	assert_eq "$(sed -n '1p' "$TEST_ROOT/order")" "mountctl:remove:Main"
	assert_eq "$(sed -n '2p' "$TEST_ROOT/order")" "mountctl:apply:Main"
	uninstall_backup=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'uninstall-*' | head -n 1)
	assert_file "$uninstall_backup/Saves/legacy.sav"
	pass
}

test_names
test_syncthing_paths
test_mountinfo
test_symlinked_sdcard
test_install_runtime
test_initial_copy
test_clone_primary
test_switch_order
test_failed_switch_restores
test_reload_active
test_profile_menu_json
test_menu_invocation_formats
test_core_owner
test_rename_primary
test_rename_active
test_delete_profile
test_uninstall

echo "PASS: $pass_count Profiles tests"
