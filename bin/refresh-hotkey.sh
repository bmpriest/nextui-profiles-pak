#!/bin/sh

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"

PROFILE_ROOT=${PROFILE_ROOT:-"$SDCARD_PATH/.profiles"}
INSTALL_HOME=${INSTALL_HOME:-"$USERDATA_PATH/Profiles"}
PID_FILE="$INSTALL_HOME/hotkey.pid"
DIR=${PROFILES_DIR:-"$SDCARD_PATH/Tools/$PLATFORM/Profiles.pak"}

if [ -f "$PID_FILE" ]; then
	pid=$(cat "$PID_FILE" 2>/dev/null)
	case "$pid" in
		*[!0-9]*|"") ;;
		*)
			if [ -r "/proc/$pid/cmdline" ] && tr '\000' ' ' < "/proc/$pid/cmdline" | grep -q 'hotkey-monitor.sh'; then
				kill "$pid" 2>/dev/null || true
			fi
			;;
	esac
	rm -f "$PID_FILE"
fi

name=$([ -f "$PROFILE_ROOT/active" ] && sed -n '1p' "$PROFILE_ROOT/active")
[ -n "$name" ] && [ -f "$PROFILE_ROOT/$name/shared/enable-simple-mode" ] || exit 0
[ -x "$DIR/bin/$PLATFORM/minui-btntest" ] || exit 0

PROFILES_DIR="$DIR" "$INSTALL_HOME/hotkey-monitor.sh" &
echo $! > "$PID_FILE"
