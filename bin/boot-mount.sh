#!/bin/sh

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"

PROFILE_ROOT=${PROFILE_ROOT:-"$SDCARD_PATH/.profiles"}
INSTALL_HOME=${INSTALL_HOME:-"$USERDATA_PATH/Profiles"}
ACTIVE_FILE="$PROFILE_ROOT/active"
SAVES_TARGET="$SDCARD_PATH/Saves"
SHARED_TARGET="$SDCARD_PATH/.userdata/shared"
LOGS_PATH=${LOGS_PATH:-"$USERDATA_PATH/logs"}
LOG_FILE="$LOGS_PATH/profiles-mounts.txt"
MOUNTINFO_PATH=${MOUNTINFO_PATH:-/proc/self/mountinfo}
TMP_ROOT=${TMP_ROOT:-/tmp}
DIR=${PROFILES_DIR:-"$SDCARD_PATH/Tools/$PLATFORM/Profiles.pak"}

mkdir -p "$LOGS_PATH"
: > "$LOG_FILE"
export SDCARD_PATH PLATFORM USERDATA_PATH PROFILE_ROOT INSTALL_HOME ACTIVE_FILE
export SAVES_TARGET SHARED_TARGET LOGS_PATH LOG_FILE MOUNTINFO_PATH TMP_ROOT DIR

. "$DIR/bin/profiles.sh" 2>> "$LOG_FILE" || exit 1

# Every line here is timestamped and the log is truncated on each run, so the
# file doubles as proof the hook fired at boot. Success used to be logged as
# nothing at all, which is indistinguishable from the hook never running.
mount_and_log() {
	source=$1
	target=$2
	if mountpoint_is_mounted "$target" && mount_matches "$source" "$target"; then
		log_event "already mounted: $target -> $source"
		return 0
	fi
	bind_profile_path "$source" "$target" || {
		log_event "FAILED to mount: $target -> $source"
		return 1
	}
	log_event "mounted: $target -> $source"
}

name=$(active_profile)
[ -n "$name" ] || {
	log_event "No active profile recorded in $ACTIVE_FILE; nothing to mount"
	exit 0
}
[ -d "$PROFILE_ROOT/$name/Saves" ] && [ -d "$PROFILE_ROOT/$name/shared" ] || {
	log_event "Active profile is incomplete: $name"
	exit 1
}

log_event "Boot mount for profile: $name"
mount_and_log "$PROFILE_ROOT/$name/Saves" "$SAVES_TARGET" || exit 1
mount_and_log "$PROFILE_ROOT/$name/shared" "$SHARED_TARGET" || exit 1
validate_core_saves_owner || log_event "$ACTION_RESULT"
refresh_hotkey
log_event "Boot mount complete for profile: $name"
