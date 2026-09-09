#!/bin/sh

DIR=${PROFILES_DIR:-$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)}
PAK_NAME=$(basename "$DIR")
PAK_NAME=${PAK_NAME%.pak}

: "${SDCARD_PATH:=/mnt/SDCARD}"
: "${PLATFORM:=tg5040}"
: "${SYSTEM_PATH:=$SDCARD_PATH/.system/$PLATFORM}"
: "${USERDATA_PATH:=$SDCARD_PATH/.userdata/$PLATFORM}"
: "${SHARED_USERDATA_PATH:=$SDCARD_PATH/.userdata/shared}"
: "${LOGS_PATH:=$USERDATA_PATH/logs}"

PROFILE_ROOT=${PROFILE_ROOT:-"$SDCARD_PATH/.profiles"}
INSTALL_HOME=${INSTALL_HOME:-"$USERDATA_PATH/Profiles"}
LOG_FILE=${LOG_FILE:-"$LOGS_PATH/profiles.txt"}

mkdir -p "$LOGS_PATH" "$INSTALL_HOME"
touch "$LOG_FILE"
exec >> "$LOG_FILE" 2>&1

export DIR PAK_NAME SDCARD_PATH PLATFORM SYSTEM_PATH USERDATA_PATH
export SHARED_USERDATA_PATH LOGS_PATH PROFILE_ROOT INSTALL_HOME LOG_FILE
export PATH="$DIR/bin/$PLATFORM:$DIR/bin:$PATH"

. "$DIR/bin/profiles.sh" || exit 1
log_event "Profiles opened (platform=$PLATFORM)"

cleanup() {
	rm -f "$TMP_ROOT"/profiles-*.$$ 2>/dev/null || true
	killall minui-presenter >/dev/null 2>&1 || true
}

message_text() {
	# minui-presenter expects literal line breaks; it does not interpret \n.
	printf '%b' "$1"
}

present() {
	minui-presenter --disable-auto-sleep --message "$(message_text "$1")" \
		--confirm-show --confirm-text "OK"
}

confirm_continue() {
	minui-presenter --disable-auto-sleep --message "$(message_text "$1")" \
		--confirm-show --confirm-text "CONTINUE" \
		--cancel-show --cancel-text "QUIT"
}

blocking_notice() {
	minui-presenter --disable-auto-sleep --message "$(message_text "$1")" \
		--cancel-show --cancel-text "QUIT"
	return 1
}

ask_simple_mode() {
	minui-presenter --disable-auto-sleep \
		--message "$(message_text "Enable Simple Mode for this profile?\n\nMENU + L2 + R2 opens Profiles while the NextUI menu is visible.")" \
		--confirm-show --confirm-text "ENABLE" \
		--cancel-show --cancel-text "SKIP"
}

ask_initial_name() {
	if minui-presenter --disable-auto-sleep \
		--message "Would you like to name the initial profile?" \
		--confirm-show --confirm-text "SET NAME" \
		--cancel-show --cancel-text "NO"; then
		while :; do
			ask_profile_name ""
			rc=$?
			[ "$rc" -eq 0 ] && return 0
			case "$rc" in 2|3) return 1 ;; esac
		done
	fi
	PROFILE_NAME=Default
	validate_profile_name "$PROFILE_NAME" || {
		present "$PROFILE_ERROR"
		return 1
	}
}

ask_copy_primary() {
	primary=$(primary_profile)
	minui-presenter --disable-auto-sleep \
		--message "$(message_text "Copy saves and settings from the primary profile ($primary)?\n\nChoose EMPTY to start with fresh save and MinUI settings folders.")" \
		--confirm-show --confirm-text "COPY" \
		--cancel-show --cancel-text "EMPTY"
}

ask_profile_name() {
	initial=${1:-}
	output="$TMP_ROOT/profiles-name.$$"
	rm -f "$output"
	if [ -n "$initial" ]; then
		minui-keyboard --disable-auto-sleep --show-hardware-group \
			--title "Profile name" --initial-value "$initial" \
			--write-location "$output"
	else
		minui-keyboard --disable-auto-sleep --show-hardware-group \
			--title "Profile name" --write-location "$output"
	fi
	rc=$?
	[ "$rc" -eq 0 ] || return "$rc"
	PROFILE_NAME=$(cat "$output" 2>/dev/null)
	[ -n "$initial" ] && [ "$PROFILE_NAME" = "$initial" ] && return 0
	validate_profile_name "$PROFILE_NAME" || {
		present "$PROFILE_ERROR"
		return 1
	}
	return 0
}

initial_preflight() {
	if syncthing_installed; then
		confirm_continue "Syncthing has been detected on this device. Please disable syncing and remove its Saves and shared-data folders.\n\nProfiles needs to copy and redirect your saves and save states. Continuing before removing those folders may result in data loss." || return 1
	fi

	if syncthing_running; then
		confirm_continue "Syncthing is currently running. Please stop it and remove its Saves and shared-data folders before setup." || return 1
	fi

	paths=$(syncthing_affected_paths)
	if [ -n "$paths" ]; then
		blocking_notice "Syncthing is still configured to sync these moving paths:\n\n$paths\n\nRemove these folders from Syncthing before continuing."
		return 1
	fi

	if core_saves_enabled; then
		blocking_notice "RetroArch Core Saves.pak has active save mounts. Disable RetroArch Core Saves before continuing."
		return 1
	fi
	return 0
}

runtime_preflight() {
	warnings=""
	paths=""
	if syncthing_running; then
		paths=$(syncthing_affected_paths)
		if [ -n "$paths" ]; then
			warnings="Syncthing is running and syncing:\n$paths"
		fi
	fi

	if core_saves_mounts_active; then
		core_paths=$(mounted_descendants "$SAVES_TARGET")
		[ -n "$warnings" ] && warnings="$warnings\n\n"
		warnings="${warnings}RetroArch Core Saves has active mounts:\n$core_paths"
	fi

	[ -z "$warnings" ] || confirm_continue "Warning!\n\n$warnings\n\nThese aliases change when profiles switch. Continuing may cause corrupt, deleted, or lost save data."
}

initialize_profiles() {
	initial_preflight || return 1
	ask_initial_name || return 1

	present_progress "Backing up saves and shared data..."
	initialize_from_current "$PROFILE_NAME" 0
	rc=$?
	stop_progress
	if [ "$rc" -ne 0 ]; then
		present "Setup failed. The original folders were not removed.\n\n$ACTION_RESULT"
		return "$rc"
	fi

	present "Success!\n\nYour active data now lives at:\n$PROFILE_ROOT/$PROFILE_NAME\n\nFor Syncthing, sync profile folders under this path—not /Saves or /.userdata/shared."
}

present_progress() {
	minui-presenter --disable-auto-sleep --message "$(message_text "$1")" --timeout -1 &
	PROGRESS_PID=$!
}

stop_progress() {
	if [ -n "${PROGRESS_PID:-}" ]; then
		kill "$PROGRESS_PID" 2>/dev/null || true
		attempt=1
		while kill -0 "$PROGRESS_PID" 2>/dev/null && [ "$attempt" -le 2 ]; do
			sleep 1
			attempt=$((attempt + 1))
		done
		kill -9 "$PROGRESS_PID" 2>/dev/null || true
	fi
	wait "${PROGRESS_PID:-}" 2>/dev/null || true
	PROGRESS_PID=""
}

# UI helpers load settings from SHARED_USERDATA_PATH. Keeping the progress
# presenter alive across the unmount can therefore make the profile mount busy.
profiles_before_mount_switch() {
	stop_progress
}

create_profile_ui() {
	while :; do
		ask_profile_name ""
		rc=$?
		[ "$rc" -eq 0 ] && break
		case "$rc" in 2|3) return 0 ;; esac
	done
	simple=0
	ask_simple_mode && simple=1
	copy_primary=0
	ask_copy_primary && copy_primary=1
	if [ "$copy_primary" = 1 ]; then
		create_profile_from_primary "$PROFILE_NAME" "$simple"
	else
		create_empty_profile "$PROFILE_NAME" "$simple"
	fi || {
		present "$ACTION_RESULT"
		return 1
	}
	present "Profile created:\n$PROFILE_ROOT/$PROFILE_NAME"
}

edit_profile_ui() {
	name=$1
	while :; do
		menu="$TMP_ROOT/profiles-edit.$$"
		output="$TMP_ROOT/profiles-edit-output.$$"
		if profile_simple_mode "$name"; then mode=On; else mode=Off; fi
		{
			echo "Rename profile"
			echo "Simple Mode: $mode"
			if [ "$name" != "$(primary_profile)" ] && [ "$name" != "$(active_profile)" ]; then
				echo "Delete profile"
			fi
		} > "$menu"
		rm -f "$output"
		minui-list --disable-auto-sleep --format text --file "$menu" \
			--title "$name" --confirm-text "CHANGE" --cancel-text "BACK" \
			--write-location "$output"
		rc=$?
		case "$rc" in
			0)
				selection=$(cat "$output" 2>/dev/null)
				case "$selection" in
					"Rename profile")
						ask_profile_name "$name" || continue
						[ "$PROFILE_NAME" = "$name" ] && continue
						if rename_profile "$name" "$PROFILE_NAME"; then
							name=$PROFILE_NAME
						else
							present "$ACTION_RESULT"
						fi
						;;
					"Simple Mode:"*)
						if profile_simple_mode "$name"; then simple=0; else simple=1; fi
						set_profile_simple_mode "$name" "$simple" || present "$ACTION_RESULT"
						;;
					"Delete profile")
						if minui-presenter --disable-auto-sleep \
							--message "$(message_text "Delete $name?\n\nIts saves and settings will be permanently removed.")" \
							--confirm-show --confirm-text "DELETE" \
							--cancel-show --cancel-text "CANCEL"; then
							if delete_profile "$name"; then
								present "Profile deleted: $name"
								return 0
							else
								present "$ACTION_RESULT"
							fi
						fi
						;;
				esac
				;;
			2|3) return 0 ;;
			*) return "$rc" ;;
		esac
	done
}

profiles_menu() {
	PROFILES_UNINSTALLED=0
	while :; do
		menu="$TMP_ROOT/profiles-menu.$$"
		map="$TMP_ROOT/profiles-map.$$"
		output="$TMP_ROOT/profiles-menu-output.$$"
		build_profile_menu "$menu" "$map"
		rm -f "$output"
		minui-list --disable-auto-sleep --format json --file "$menu" --item-key items \
			--title "Profiles" --confirm-text "SELECT" --cancel-text "EXIT" \
			--action-button "X" --action-text "EDIT" --write-location "$output"
		rc=$?
		selection=$(cat "$output" 2>/dev/null)
		name=$(awk -F '|' -v shown="$selection" '$1 == shown { print substr($0, index($0, "|") + 1); exit }' "$map")
		case "$rc" in
			0)
				if [ "$name" = "+" ]; then
					create_profile_ui
				elif [ "$name" = "!" ]; then
					if minui-presenter --disable-auto-sleep \
						--message "$(message_text "Uninstall Profiles?\n\nThe primary profile will be restored to /Saves and /.userdata/shared. Other profiles will remain in $PROFILE_ROOT.")" \
						--confirm-show --confirm-text "UNINSTALL" \
						--cancel-show --cancel-text "CANCEL"; then
						present_progress "Restoring the primary profile..."
						uninstall_profiles
						uninstall_rc=$?
						stop_progress
						present "$ACTION_RESULT"
						[ "$uninstall_rc" -eq 0 ] && { PROFILES_UNINSTALLED=1; break; }
					fi
				elif [ -n "$name" ]; then
					current=$(active_profile)
					if [ "$name" = "$current" ]; then
						present_progress "Reloading $name..."
						activate_profile "$name"
						reload_rc=$?
						stop_progress
						if [ "$reload_rc" -eq 0 ]; then
							present "Reloaded profile: $name"
						else
							present "$ACTION_RESULT"
						fi
					else
						present_progress "Switching to $name..."
						activate_profile "$name"
						switch_rc=$?
						stop_progress
						if [ "$switch_rc" -eq 0 ]; then
							present "Active profile: $name\n\nCanonical data:\n$PROFILE_ROOT/$name"
						else
							present "$ACTION_RESULT"
						fi
					fi
				fi
				;;
			4) [ -n "$name" ] && [ "$name" != "+" ] && [ "$name" != "!" ] && edit_profile_ui "$name" ;;
			2|3) break ;;
			*) break ;;
		esac
	done
}

main() {
	trap cleanup EXIT INT TERM HUP QUIT
	case "$PLATFORM" in my285|tg5040) ;; *) echo "Unsupported platform: $PLATFORM"; return 1 ;; esac
	for executable in minui-list minui-presenter minui-keyboard; do
		chmod +x "$DIR/bin/$PLATFORM/$executable" 2>/dev/null || true
	done
	for executable in minui-list minui-presenter minui-keyboard; do
		command -v "$executable" >/dev/null 2>&1 || {
			echo "Missing UI executable: $executable"
			return 1
		}
	done

	install_runtime || {
		present "$ACTION_RESULT"
		return 1
	}

	if ! profiles_initialized; then
		initialize_profiles || return $?
	fi

	validate_core_saves_owner || {
		blocking_notice "$ACTION_RESULT"
		return 1
	}
	runtime_preflight || return 0
	profiles_menu
}

if [ "${PROFILES_SOURCE_ONLY:-0}" != 1 ]; then
	main "$@"
fi
