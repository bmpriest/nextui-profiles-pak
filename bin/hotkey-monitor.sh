#!/bin/sh

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"

DIR=${PROFILES_DIR:-"$SDCARD_PATH/Tools/$PLATFORM/Profiles.pak"}
export PATH="$DIR/bin/$PLATFORM:$PATH"

chmod +x "$DIR/bin/$PLATFORM/minui-btntest" 2>/dev/null || exit 1

wait_pid=""
cleanup() {
	[ -n "$wait_pid" ] && kill "$wait_pid" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

wait_for_buttons() {
	minui-btntest wait "$@" &
	wait_pid=$!
	wait "$wait_pid"
	rc=$?
	wait_pid=""
	return "$rc"
}

while :; do
	wait_for_buttons is_pressed all "btn_menu,btn_l2,btn_r2" || exit 1
	# The launcher can only run the pak after NextUI has exited. Do not tear down
	# an emulator if the chord is pressed during a game.
	if pgrep nextui.elf >/dev/null 2>&1 && [ ! -f /tmp/next ]; then
		printf "'%s/launch.sh'\n" "$DIR" > /tmp/next
		sync
		# SIGTERM makes NextUI render its system-shutdown screen. The command in
		# /tmp/next is already durable, so exit it without invoking that handler.
		killall -9 nextui.elf >/dev/null 2>&1 || true
	fi
	wait_for_buttons is_released all "btn_menu,btn_l2,btn_r2" || sleep 1
done
