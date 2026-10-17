#!/bin/sh
# Profiles and RetroArch Core Saves together, with real bind mounts: setup,
# switching away from and back to the Core Saves owner, renaming the active
# profile, and uninstalling. Re-runs itself inside a private user+mount
# namespace (unshare -rm), so it needs no root and leaves the host alone.

set -u

if [ "${PROFILES_TEST_NS:-0}" != 1 ]; then
	command -v unshare >/dev/null 2>&1 || { echo "SKIP: unshare is not available"; exit 0; }
	PROFILES_TEST_NS=1 exec unshare -rm sh "$0" "$@"
fi

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MOUNT_MANAGER=${MOUNT_MANAGER:-"$DIR/../mount-manager"}
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/profiles-mounts.XXXXXX")
TEST_ROOT=$(CDPATH= cd -P -- "$TEST_ROOT" && pwd -P)

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
TMPDIR="$TEST_ROOT"
export SDCARD_PATH PLATFORM USERDATA_PATH SHARED_USERDATA_PATH LOGS_PATH
export PROFILE_ROOT INSTALL_HOME LOG_FILE TMP_ROOT MOUNTS_LOCK TMPDIR DIR

cleanup() {
	awk -v root="$TEST_ROOT" 'substr($5, 1, length(root) + 1) == root "/" { print length($5) " " $5 }' \
		/proc/self/mountinfo | sort -rn | cut -d' ' -f2- | while IFS= read -r path; do
		umount "$path" 2>/dev/null || true
	done
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
	echo "FAIL: $*" >&2
	for log in "$LOG_FILE" "$LOGS_PATH/mounts.txt"; do
		[ -f "$log" ] && { echo "--- $log" >&2; cat "$log" >&2; }
	done
	exit 1
}

assert_eq() {
	[ "$1" = "$2" ] || fail "expected [$2], got [$1]"
}

mount_count() {
	awk -v target="$1" '$5 == target { n++ } END { print n + 0 }' /proc/self/mountinfo
}

SAVES="$SDCARD_PATH/Saves"
SHARED="$SHARED_USERDATA_PATH"
mkdir -p "$SAVES/Cores/Gambatte" "$SHARED/RetroArch Core Saves" "$LOGS_PATH" "$TMP_ROOT"
echo original > "$SAVES/whose.txt"
echo pokemon > "$SAVES/Cores/Gambatte/Pokemon.srm"
: > "$LOG_FILE"

. "$DIR/bin/profiles.sh"
refresh_hotkey() { :; }

# Set up with Core Saves still off, as initial setup requires.
install_runtime || fail "$ACTION_RESULT"
initialize_from_current "Ben" 0 || fail "$ACTION_RESULT"
assert_eq "$(cat "$SAVES/whose.txt")" "original"
assert_eq "$(mount_count "$SAVES")" "1"

printf 'GB|Gambatte\n' > "$SHARED/RetroArch Core Saves/mounts.conf"
: > "$SHARED/RetroArch Core Saves/enabled"
create_empty_profile "Kiddos" 0 || fail "$ACTION_RESULT"

# Core Saves 0.6.x has no layer and mounts its own tag folders. mountctl does
# not own those mounts, but has to clear them to swap /Saves, and Profiles
# calls the old helper to put them back. The fixture is that release's helper.
LEGACY_HELPER="$DIR/bin/tests/fixtures/core-saves-0.6.1-boot-mount.sh"
if [ -f "$LEGACY_HELPER" ]; then
	cp "$LEGACY_HELPER" "$SHARED/RetroArch Core Saves/boot-mount.sh"
	chmod 0755 "$SHARED/RetroArch Core Saves/boot-mount.sh"
	"$SHARED/RetroArch Core Saves/boot-mount.sh" || fail "legacy Core Saves mount failed"
	assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
	activate_profile "Kiddos" || fail "legacy: switch to Kiddos: $ACTION_RESULT"
	assert_eq "$(mount_count "$SAVES/GB")" "0"
	activate_profile "Ben" || fail "legacy: switch back to Ben: $ACTION_RESULT"
	assert_eq "$(mount_count "$SAVES")" "1"
	assert_eq "$(mount_count "$SAVES/GB")" "1"
	assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
	activate_profile "Ben" || fail "legacy: reload Ben: $ACTION_RESULT"
	assert_eq "$(mount_count "$SAVES/GB")" "1"
	rm "$SHARED/RetroArch Core Saves/boot-mount.sh"
else
	echo "SKIP: legacy Core Saves helper not found at $LEGACY_HELPER"
fi

# Core Saves through its mountctl layer.
sh "$MOUNTS_HOME/mountctl.sh" install "$MOUNT_MANAGER/layers/20-core-saves.sh" || fail "core saves layer install failed"
apply_mounts || fail "$ACTION_RESULT"
assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
assert_eq "$(sed -n '1p' "$CORE_PROFILE_FILE")" "Ben"

# The reported bug: switching away from the owner with tag mounts live.
activate_profile "Kiddos" || fail "switch to Kiddos: $ACTION_RESULT"
assert_eq "$(active_profile)" "Kiddos"
assert_eq "$(mount_count "$SAVES")" "1"
assert_eq "$(mount_count "$SAVES/GB")" "0"
[ -e "$SAVES/whose.txt" ] && fail "Kiddos sees Ben's saves"

activate_profile "Ben" || fail "switch back to Ben: $ACTION_RESULT"
assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
assert_eq "$(mount_count "$SAVES")" "1"
assert_eq "$(mount_count "$SAVES/GB")" "1"

# Renaming the active Core Saves owner keeps both its mounts and ownership.
rename_profile "Ben" "Benjamin" || fail "rename: $ACTION_RESULT"
assert_eq "$(sed -n '1p' "$CORE_PROFILE_FILE")" "Benjamin"
assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
mc_matches "$PROFILE_ROOT/Benjamin/Saves" "$SAVES" || fail "/Saves does not show the renamed profile"

# Uninstalling restores Benjamin to the real folders, and Core Saves keeps
# working on them through its own layer.
uninstall_profiles || fail "uninstall: $ACTION_RESULT"
assert_eq "$(mount_count "$SAVES")" "0"
assert_eq "$(mount_count "$SHARED")" "0"
assert_eq "$(cat "$SAVES/whose.txt")" "original"
assert_eq "$(mount_count "$SAVES/GB")" "1"
assert_eq "$(cat "$SAVES/GB/Pokemon.srm")" "pokemon"
[ -f "$MOUNTS_HOME/layers.d/10-profiles.sh" ] && fail "profiles layer still installed"
[ -f "$MOUNTS_HOME/mountctl.sh" ] || fail "mountctl removed while Core Saves still uses it"

echo "PASS: Profiles + Core Saves with real mounts"
