#!/bin/sh

set -eu

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/profiles-test.XXXXXX")
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
MOUNTINFO_PATH="$TEST_ROOT/mountinfo"
AUTO_PATH="$USERDATA_PATH/auto.sh"
DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)

mkdir -p "$SDCARD_PATH/Saves" "$SHARED_USERDATA_PATH" "$LOGS_PATH" "$TMP_ROOT"
: > "$LOG_FILE"
: > "$MOUNTINFO_PATH"

export SDCARD_PATH PLATFORM USERDATA_PATH SHARED_USERDATA_PATH LOGS_PATH
export PROFILE_ROOT INSTALL_HOME LOG_FILE TMP_ROOT MOUNTINFO_PATH AUTO_PATH DIR

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
	mountpoint_is_mounted "$SDCARD_PATH/Saves" || fail "parent mount not detected"
	mount_matches "$PROFILE_ROOT/Ben/Saves" "$SDCARD_PATH/Saves" || fail "matching parent rejected"
	mount_matches "$PROFILE_ROOT/Kid/Saves" "$SDCARD_PATH/Saves" && fail "wrong source accepted"
	desc=$(mounted_descendants "$SDCARD_PATH/Saves")
	echo "$desc" | grep -Fq "$SDCARD_PATH/Saves/GB" || fail "GB child missing"
	echo "$desc" | grep -Fq "$SDCARD_PATH/Saves/GBC" || fail "GBC child missing"
	pass
}

test_auto_hook() {
	cat > "$AUTO_PATH" <<'EOF'
#!/bin/sh
syncthing-line
old-profiles-line # Profiles.pak-on-boot
custom-line
EOF
	install_auto_hook || fail "auto hook install failed"
	assert_eq "$(sed -n '1p' "$AUTO_PATH")" "#!/bin/sh"
	assert_eq "$(sed -n '2p' "$AUTO_PATH" | grep -c 'Profiles.pak-on-boot')" "1"
	assert_contains "$AUTO_PATH" "syncthing-line"
	assert_contains "$AUTO_PATH" "custom-line"
	assert_eq "$(grep -c 'Profiles.pak-on-boot' "$AUTO_PATH")" "1"
	pass
}

# The switch-order tests stub the service helpers out, so exercise the real ones
# here. Each case runs in a subshell that re-sources profiles.sh, both to get
# fresh definitions and to keep these stubs from leaking into later tests.
test_profile_services() {
	# batmon stops on the first signal: the success path must return 0 and leave
	# ACTION_RESULT untouched. Returning 1 here aborted every profile switch with
	# an empty message.
	(
		. "$DIR/bin/profiles.sh"
		calls="$TEST_ROOT/batmon-calls"
		: > "$calls"
		pidof() { [ -f "$TEST_ROOT/batmon-dead" ] && return 1; echo 4242; }
		killall() { echo "killall $*" >> "$calls"; : > "$TEST_ROOT/batmon-dead"; }
		awk() { echo S; }
		capture_batmon_env() { BATMON_LD_LIBRARY_PATH=/system/lib; }
		sleep() { :; }
		rm -f "$TEST_ROOT/batmon-dead"
		ACTION_RESULT=""
		stop_profile_services
		rc=$?
		[ "$rc" -eq 0 ] || fail "stop_profile_services returned $rc after stopping batmon"
		[ -z "$ACTION_RESULT" ] || fail "stop_profile_services set ACTION_RESULT on success: $ACTION_RESULT"
		[ "${BATMON_WAS_RUNNING:-0}" = 1 ] || fail "stop_profile_services did not record that batmon was running"
		grep -Fq "killall -TERM batmon.elf" "$calls" || fail "batmon was not asked to stop"
	) || exit 1

	# batmon survives every signal: that is the only case that may fail, and it
	# must carry a message the UI can present.
	(
		. "$DIR/bin/profiles.sh"
		pidof() { echo 4242; }
		killall() { :; }
		awk() { echo S; }
		capture_batmon_env() { :; }
		sleep() { :; }
		ACTION_RESULT=""
		stop_profile_services && fail "stop_profile_services succeeded while batmon was still running"
		[ -n "$ACTION_RESULT" ] || fail "unstoppable batmon produced no ACTION_RESULT"
	) || exit 1

	# "batmon.elf" is not a valid shell function name, so the restart cases use a
	# real stub on PATH. That exercises the "command -v batmon.elf" guard too.
	stub_bin="$TEST_ROOT/stub-bin"
	mkdir -p "$stub_bin"
	launched="$TEST_ROOT/batmon-launched"
	cat > "$stub_bin/batmon.elf" <<'STUB'
#!/bin/sh
echo "LD_LIBRARY_PATH=${LD_LIBRARY_PATH-unset}" > "$BATMON_STUB_MARKER"
STUB
	chmod 0755 "$stub_bin/batmon.elf"

	# The restart must pass batmon its library path and verify it stayed up.
	(
		. "$DIR/bin/profiles.sh"
		PATH="$stub_bin:$PATH"
		BATMON_STUB_MARKER="$launched"
		export BATMON_STUB_MARKER
		rm -f "$launched"
		# start_profile_services backgrounds batmon and then sleeps before
		# checking, so the real sleep has to run for the stub to land.
		batmon_is_running() { [ -f "$launched" ]; }
		BATMON_WAS_RUNNING=1
		BATMON_LD_LIBRARY_PATH=/system/lib:/usr/trimui/lib
		start_profile_services || fail "start_profile_services reported failure after a good restart"
		assert_eq "$(cat "$launched")" "LD_LIBRARY_PATH=/system/lib:/usr/trimui/lib"
		assert_contains "$LOG_FILE" "Restarted batmon after shared-data remount"
	) || exit 1

	# With no captured environment it must not invent one.
	(
		. "$DIR/bin/profiles.sh"
		PATH="$stub_bin:$PATH"
		BATMON_STUB_MARKER="$launched"
		export BATMON_STUB_MARKER
		rm -f "$launched"
		unset LD_LIBRARY_PATH
		batmon_is_running() { [ -f "$launched" ]; }
		BATMON_WAS_RUNNING=1
		BATMON_LD_LIBRARY_PATH=""
		start_profile_services || fail "start_profile_services failed with no captured environment"
		assert_eq "$(cat "$launched")" "LD_LIBRARY_PATH=unset"
	) || exit 1

	# A batmon that dies on startup must be reported, not logged as restarted.
	(
		. "$DIR/bin/profiles.sh"
		PATH="$stub_bin:$PATH"
		BATMON_STUB_MARKER="$TEST_ROOT/batmon-ignored"
		export BATMON_STUB_MARKER
		batmon_is_running() { return 1; }
		sleep() { :; }
		BATMON_WAS_RUNNING=1
		BATMON_LD_LIBRARY_PATH=""
		start_profile_services && fail "start_profile_services succeeded when batmon did not stay up"
		assert_contains "$LOG_FILE" "batmon did not stay running"
	) || exit 1

	# A missing executable must be reported rather than silently skipped. PATH is
	# emptied only across the call itself; the assertions still need real tools.
	(
		. "$DIR/bin/profiles.sh"
		empty_bin="$TEST_ROOT/empty-bin"
		mkdir -p "$empty_bin"
		real_path="$PATH"
		BATMON_WAS_RUNNING=1
		PATH="$empty_bin"
		start_profile_services
		rc=$?
		PATH="$real_path"
		[ "$rc" -eq 0 ] && fail "start_profile_services succeeded with no batmon.elf"
		assert_contains "$LOG_FILE" "its executable is unavailable"
	) || exit 1
	pass
}

test_initial_copy() {
	: > "$MOUNTINFO_PATH"
	echo save-data > "$SDCARD_PATH/Saves/game.sav"
	echo state-data > "$SHARED_USERDATA_PATH/game.st0"

	# Initialization's filesystem work is real; only kernel mount operations are
	# replaced so this test can run without privileges.
	unmount_target() { echo "down:$1" >> "$TEST_ROOT/order"; }
	bind_profile_path() { echo "up:$1:$2" >> "$TEST_ROOT/order"; }
	refresh_hotkey() { :; }
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
	expected="$TEST_ROOT/expected"
	cat > "$expected" <<EOF
down:$SHARED_TARGET
down:$SAVES_TARGET
up:$PROFILE_ROOT/Kid/Saves:$SAVES_TARGET
up:$PROFILE_ROOT/Kid/shared:$SHARED_TARGET
EOF
	cmp -s "$expected" "$TEST_ROOT/order" || {
		echo "actual order:" >&2
		cat "$TEST_ROOT/order" >&2
		fail "switch order was not child/parent-safe"
	}
	assert_eq "$(active_profile)" "Kid"
	pass
}

test_reload_active() {
	stop_profile_services() { echo "service:stop" >> "$TEST_ROOT/order"; }
	start_profile_services() { echo "service:start" >> "$TEST_ROOT/order"; }
	: > "$TEST_ROOT/order"
	activate_profile "Kid" || fail "$ACTION_RESULT"
	assert_eq "$(active_profile)" "Kid"
	assert_contains "$LOG_FILE" "Reloading profile: Kid"
	assert_eq "$(sed -n '1p' "$TEST_ROOT/order")" "service:stop"
	assert_eq "$(tail -n 1 "$TEST_ROOT/order")" "service:start"
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
	install_auto_hook || fail "could not install hook for uninstall test"
	: > "$INSTALL_HOME/boot-mount.sh"
	: > "$INSTALL_HOME/hotkey-monitor.sh"
	: > "$INSTALL_HOME/refresh-hotkey.sh"
	uninstall_profiles || fail "$ACTION_RESULT"
	assert_file "$SAVES_TARGET/restored.sav"
	assert_not_file "$SAVES_TARGET/legacy.sav"
	assert_not_file "$INSTALL_HOME/boot-mount.sh"
	assert_eq "$(grep -c "$PROFILE_MARKER" "$AUTO_PATH" || true)" "0"
	uninstall_backup=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'uninstall-*' | head -n 1)
	assert_file "$uninstall_backup/Saves/legacy.sav"
	pass
}

test_names
test_syncthing_paths
test_mountinfo
test_auto_hook
test_profile_services
test_initial_copy
test_clone_primary
test_switch_order
test_reload_active
test_profile_menu_json
test_menu_invocation_formats
test_core_owner
test_rename_primary
test_delete_profile
test_uninstall

echo "PASS: $pass_count Profiles tests"
