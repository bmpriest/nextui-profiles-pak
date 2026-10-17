#!/bin/sh
# mountctl layer 10, Profiles.pak: the active profile's folders are mounted over
# the paths NextUI has hardcoded. Everything that mounts inside /Saves or
# .userdata/shared has to be numbered after this.

PROFILE_ROOT="$SDCARD_PATH/.profiles"

case "$1" in
	scope)
		printf 'at\t%s\n' "$SDCARD_PATH/Saves" "$SHARED_USERDATA_PATH"
		printf 'reads\t%s\n' "$PROFILE_ROOT"
		;;
	plan)
		[ -f "$PROFILE_ROOT/active" ] || exit 0
		name=$(sed -n '1p' "$PROFILE_ROOT/active")
		[ -n "$name" ] || exit 0
		[ -d "$PROFILE_ROOT/$name/Saves" ] && [ -d "$PROFILE_ROOT/$name/shared" ] || {
			echo "Active profile is incomplete: $PROFILE_ROOT/$name" >&2
			exit 1
		}
		printf '%s\t%s\n' "$PROFILE_ROOT/$name/Saves" "$SDCARD_PATH/Saves"
		printf '%s\t%s\n' "$PROFILE_ROOT/$name/shared" "$SHARED_USERDATA_PATH"
		;;
	*)
		echo "usage: $0 scope|plan" >&2
		exit 2
		;;
esac
