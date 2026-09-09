#!/bin/sh

TMP_ROOT=${TMP_ROOT:-/tmp}
SAVES_TARGET=${SAVES_TARGET:-"$SDCARD_PATH/Saves"}
SHARED_TARGET=${SHARED_TARGET:-"$SDCARD_PATH/.userdata/shared"}
ACTIVE_FILE=${ACTIVE_FILE:-"$PROFILE_ROOT/active"}
CORE_PROFILE_FILE=${CORE_PROFILE_FILE:-"$PROFILE_ROOT/core-saves-profile"}
PRIMARY_FILE=${PRIMARY_FILE:-"$PROFILE_ROOT/primary"}
BACKUP_ROOT=${BACKUP_ROOT:-"$INSTALL_HOME/backup"}
SYNCTHING_CONFIG=${SYNCTHING_CONFIG:-"$USERDATA_PATH/Syncthing/config/config.xml"}
MOUNTINFO_PATH=${MOUNTINFO_PATH:-/proc/self/mountinfo}
AUTO_PATH=${AUTO_PATH:-"$USERDATA_PATH/auto.sh"}
PROFILE_MARKER="Profiles.pak-on-boot"
ACTION_RESULT=""

log_event() {
	[ -n "${LOG_FILE:-}" ] || return 0
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown-time)" "$*" >> "$LOG_FILE"
}

decode_mount_path_awk='function decode(path) {
	gsub(/\\040/, " ", path); gsub(/\\011/, sprintf("%c", 9), path)
	gsub(/\\012/, sprintf("%c", 10), path); gsub(/\\134/, sprintf("%c", 92), path)
	return path
}'

active_profile() {
	[ -f "$ACTIVE_FILE" ] && sed -n '1p' "$ACTIVE_FILE"
}

primary_profile() {
	if [ -f "$PRIMARY_FILE" ]; then
		sed -n '1p' "$PRIMARY_FILE"
	else
		# Profiles versions before the primary marker was introduced only knew
		# about the active profile. Treat that profile as primary on upgrade.
		active_profile
	fi
}

write_marker() {
	value=$1
	file=$2
	tmp="$file.new.$$"
	printf '%s\n' "$value" > "$tmp" && mv "$tmp" "$file"
}

profile_path() {
	printf '%s/%s' "$PROFILE_ROOT" "$1"
}

profiles_initialized() {
	name=$(active_profile)
	[ -n "$name" ] && [ -d "$PROFILE_ROOT/$name/Saves" ] && [ -d "$PROFILE_ROOT/$name/shared" ]
}

validate_profile_name() {
	name=$1
	PROFILE_ERROR=""
	case "$name" in
		"") PROFILE_ERROR="Profile name cannot be empty."; return 1 ;;
		.*) PROFILE_ERROR="Profile names cannot begin with a dot."; return 1 ;;
		*[!A-Za-z0-9_\ -]*) PROFILE_ERROR="Use letters, numbers, spaces, underscores, or hyphens."; return 1 ;;
	esac
	[ ${#name} -le 48 ] || {
		PROFILE_ERROR="Profile names must be 48 characters or fewer."
		return 1
	}
	[ ! -e "$PROFILE_ROOT/$name" ] || {
		PROFILE_ERROR="A profile named $name already exists."
		return 1
	}
	return 0
}

profile_simple_mode() {
	[ -f "$PROFILE_ROOT/$1/shared/enable-simple-mode" ]
}

set_profile_simple_mode() {
	name=$1
	enabled=$2
	path="$PROFILE_ROOT/$name/shared/enable-simple-mode"
	if [ "$enabled" = 1 ]; then
		: > "$path" || { ACTION_RESULT="Could not enable Simple Mode."; return 1; }
	else
		rm -f "$path" || { ACTION_RESULT="Could not disable Simple Mode."; return 1; }
	fi
	[ "$name" = "$(active_profile)" ] && refresh_hotkey
	sync
}

create_empty_profile() {
	name=$1
	simple=${2:-0}
	validate_profile_name "$name" || { ACTION_RESULT=$PROFILE_ERROR; return 1; }
	path="$PROFILE_ROOT/$name"
	mkdir -p "$path/Saves" "$path/shared/.minui" || {
		ACTION_RESULT="Could not create $path."
		return 1
	}
	[ "$simple" = 1 ] && : > "$path/shared/enable-simple-mode"
	sync
	log_event "Created empty profile: $name (simple_mode=$simple)"
}

create_profile_from_primary() {
	name=$1
	simple=${2:-0}
	primary=$(primary_profile)
	[ -n "$primary" ] && [ -d "$PROFILE_ROOT/$primary/Saves" ] &&
		[ -d "$PROFILE_ROOT/$primary/shared" ] || {
		ACTION_RESULT="The primary profile could not be found."
		return 1
	}
	validate_profile_name "$name" || { ACTION_RESULT=$PROFILE_ERROR; return 1; }
	stamp=$(timestamp)
	staging="$PROFILE_ROOT/.staging-$stamp-$$"
	mkdir -p "$staging/Saves" "$staging/shared" || {
		ACTION_RESULT="Could not create profile staging folders."
		return 1
	}
	copy_tree "$PROFILE_ROOT/$primary/Saves" "$staging/Saves" &&
		copy_tree "$PROFILE_ROOT/$primary/shared" "$staging/shared" || {
		rm -rf -- "$staging"
		ACTION_RESULT="Could not copy the primary profile."
		return 1
	}
	if [ "$simple" = 1 ]; then
		: > "$staging/shared/enable-simple-mode"
	else
		rm -f "$staging/shared/enable-simple-mode"
	fi
	mv "$staging" "$PROFILE_ROOT/$name" || {
		rm -rf -- "$staging"
		ACTION_RESULT="Could not commit the new profile."
		return 1
	}
	sync
	log_event "Created profile from primary: $name (primary=$primary simple_mode=$simple)"
}

copy_tree() {
	source=$1
	destination=$2
	mkdir -p "$destination" || return 1
	[ -d "$source" ] || return 0
	cp -a "$source/." "$destination/"
}

timestamp() {
	date +%Y%m%d-%H%M%S 2>/dev/null || echo now
}

initial_copy_has_space() {
	used_saves=$(du -sk "$SAVES_TARGET" 2>/dev/null | awk '{ print $1 }')
	used_shared=$(du -sk "$SHARED_TARGET" 2>/dev/null | awk '{ print $1 }')
	available=$(df -Pk "$SDCARD_PATH" 2>/dev/null | awk 'NR > 1 { value=$4 } END { print value }')
	case "$used_saves" in ""|*[!0-9]*) return 0 ;; esac
	case "$used_shared" in ""|*[!0-9]*) return 0 ;; esac
	case "$available" in ""|*[!0-9]*) return 0 ;; esac
	required=$((2 * (used_saves + used_shared) + 1024))
	[ "$available" -ge "$required" ] || {
		ACTION_RESULT="Not enough free space for both the safety backup and the new profile. Need approximately ${required} KB; ${available} KB is available."
		return 1
	}
}

initialize_from_current() {
	name=$1
	simple=${2:-0}
	validate_profile_name "$name" || { ACTION_RESULT=$PROFILE_ERROR; return 1; }
	initial_copy_has_space || return 1
	mkdir -p "$PROFILE_ROOT" "$BACKUP_ROOT" || {
		ACTION_RESULT="Could not create profile storage."
		return 1
	}

	stamp=$(timestamp)
	backup="$BACKUP_ROOT/$stamp"
	[ ! -e "$backup" ] || backup="$BACKUP_ROOT/$stamp-$$"
	staging="$PROFILE_ROOT/.staging-$stamp-$$"
	mkdir -p "$backup/Saves" "$backup/shared" "$staging/Saves" "$staging/shared" || {
		ACTION_RESULT="Could not create backup or staging folders."
		return 1
	}

	copy_tree "$SAVES_TARGET" "$backup/Saves" &&
		copy_tree "$SHARED_TARGET" "$backup/shared" || {
		ACTION_RESULT="Backup failed at $backup. Original data was not removed."
		return 1
	}
	copy_tree "$SAVES_TARGET" "$staging/Saves" &&
		copy_tree "$SHARED_TARGET" "$staging/shared" || {
		rm -rf -- "$staging"
		ACTION_RESULT="Profile copy failed. Backup is at $backup."
		return 1
	}
	[ "$simple" = 1 ] && : > "$staging/shared/enable-simple-mode"
	mv "$staging" "$PROFILE_ROOT/$name" || {
		ACTION_RESULT="Could not commit the new profile. Backup is at $backup."
		return 1
	}

	activate_profile "$name" || return 1
	write_marker "$name" "$PRIMARY_FILE" || {
		ACTION_RESULT="Profile initialized, but its primary marker could not be written."
		return 1
	}
	ACTION_RESULT="Backup: $backup"
	log_event "Initialized Profiles (primary=$name backup=$backup)"
}

mountpoint_is_mounted() {
	target=$1
	awk -v target="$target" "$decode_mount_path_awk
		decode(\$5) == target { found=1 }
		END { exit !found }" "$MOUNTINFO_PATH" 2>/dev/null
}

mounted_descendants() {
	target=$1
	awk -v target="$target" "$decode_mount_path_awk
		{ path=decode(\$5) }
		path != target && substr(path, 1, length(target) + 1) == target \"/\" { print path }" \
		"$MOUNTINFO_PATH" 2>/dev/null
}

mount_matches() {
	source=$1
	target=$2
	awk -v source="$source" -v target="$target" "$decode_mount_path_awk
		function clean(path) { gsub(/\\/+/, \"/\", path); if (length(path)>1) sub(/\\/\$/, \"\", path); return path }
		{
			root=decode(\$4); point=clean(decode(\$5))
			if (point == clean(target)) { found=1; target_device=\$3; target_root=clean(root) }
			if (point == \"/\" || source == point || substr(source,1,length(point)+1) == point \"/\") {
				if (length(point)>best) { best=length(point); source_device=\$3; source_root=root; source_mount=point }
			}
		}
		END {
			if (!found || !best || target_device != source_device) exit 1
			suffix=(source_mount == \"/\") ? source : substr(source,length(source_mount)+1)
			expected=clean(source_root \"/\" suffix)
			exit target_root != expected
		}" "$MOUNTINFO_PATH" 2>/dev/null
}

unmount_descendants() {
	target=$1
	list="$TMP_ROOT/profiles-mounts.$$"
	mounted_descendants "$target" | awk '{ print length($0) "|" $0 }' | sort -rn > "$list"
	while IFS='|' read -r length path; do
		[ -n "$path" ] || continue
		unmount_with_retry "$path" || {
			ACTION_RESULT="Could not unmount child path: $path"
			rm -f "$list"
			return 1
		}
	done < "$list"
	rm -f "$list"
}

log_mount_users() {
	target=$1
	echo "Processes referring to $target:" >> "$LOG_FILE"
	for proc in /proc/[0-9]*; do
		[ -d "$proc" ] || continue
		pid=${proc##*/}
		comm=$(cat "$proc/comm" 2>/dev/null || echo unknown)
		cwd=$(readlink "$proc/cwd" 2>/dev/null || true)
		case "$cwd" in
			"$target"|"$target"/*) echo "pid=$pid comm=$comm cwd=$cwd" >> "$LOG_FILE" ;;
		esac
		for fd in "$proc"/fd/*; do
			[ -e "$fd" ] || [ -L "$fd" ] || continue
			path=$(readlink "$fd" 2>/dev/null || true)
			path=${path% (deleted)}
			case "$path" in
				"$target"|"$target"/*)
					echo "pid=$pid comm=$comm fd=${fd##*/} path=$path" >> "$LOG_FILE"
					;;
			esac
		done
	done
}

unmount_with_retry() {
	target=$1
	attempt=1
	while [ "$attempt" -le 3 ]; do
		if umount "$target" >> "$LOG_FILE" 2>&1; then
			return 0
		fi
		sync
		sleep 1
		attempt=$((attempt + 1))
	done
	log_mount_users "$target"
	return 1
}

unmount_target() {
	target=$1
	unmount_descendants "$target" || return 1
	if mountpoint_is_mounted "$target"; then
		unmount_with_retry "$target" || {
			ACTION_RESULT="Could not unmount $target."
			return 1
		}
	fi
}

bind_profile_path() {
	source=$1
	target=$2
	mkdir -p "$source" "$target" || return 1
	if mountpoint_is_mounted "$target"; then
		mount_matches "$source" "$target"
		return $?
	fi
	mount -o bind "$source" "$target" >> "$LOG_FILE" 2>&1
}

write_active() {
	name=$1
	write_marker "$name" "$ACTIVE_FILE"
}

remount_core_saves_if_compatible() {
	name=$1
	[ -f "$CORE_PROFILE_FILE" ] || return 0
	[ "$(sed -n '1p' "$CORE_PROFILE_FILE")" = "$name" ] || return 0
	helper="$SHARED_TARGET/RetroArch Core Saves/boot-mount.sh"
	[ -x "$helper" ] && "$helper" >> "$LOG_FILE" 2>&1 || true
}

restore_profile_mounts() {
	name=$1
	[ -n "$name" ] || return 0
	bind_profile_path "$PROFILE_ROOT/$name/Saves" "$SAVES_TARGET" || return 1
	bind_profile_path "$PROFILE_ROOT/$name/shared" "$SHARED_TARGET" || return 1
	remount_core_saves_if_compatible "$name"
}

batmon_pid() {
	for pid in $(pidof batmon.elf 2>/dev/null); do
		state=$(awk '/^State:/ { print $2 }' "/proc/$pid/status" 2>/dev/null)
		[ "$state" != Z ] && { printf '%s\n' "$pid"; return 0; }
	done
	return 1
}

batmon_is_running() {
	batmon_pid >/dev/null 2>&1
}

# batmon.elf is linked against the firmware's libraries and exits immediately
# when it cannot find them. The library path differs per platform and the pak
# can be reached from a context that never exported it, so copy the environment
# out of the running process instead of rebuilding it here.
capture_batmon_env() {
	BATMON_LD_LIBRARY_PATH=""
	pid=$(batmon_pid) || return 0
	BATMON_LD_LIBRARY_PATH=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null |
		sed -n 's/^LD_LIBRARY_PATH=//p' | sed -n '1p')
}

stop_profile_services() {
	BATMON_WAS_RUNNING=0
	batmon_is_running || return 0
	capture_batmon_env
	BATMON_WAS_RUNNING=1
	log_event "Stopping batmon for shared-data remount"
	killall -TERM batmon.elf 2>/dev/null || true
	attempt=1
	while batmon_is_running && [ "$attempt" -le 3 ]; do
		sleep 1
		attempt=$((attempt + 1))
	done
	if batmon_is_running; then
		killall -9 batmon.elf 2>/dev/null || true
		sleep 1
	fi
	# This has to stay an if. As a trailing "batmon_is_running && { ... }" the
	# successful case returned the failed test's status, so every caller's
	# "stop_profile_services || return 1" aborted the switch with an empty
	# ACTION_RESULT and the UI presented no message at all.
	if batmon_is_running; then
		ACTION_RESULT="Could not stop battery monitoring before switching profiles."
		return 1
	fi
	return 0
}

start_profile_services() {
	[ "${BATMON_WAS_RUNNING:-0}" = 1 ] || return 0
	BATMON_WAS_RUNNING=0
	command -v batmon.elf >/dev/null 2>&1 || {
		log_event "Warning: batmon was stopped but its executable is unavailable"
		return 1
	}
	if [ -n "${BATMON_LD_LIBRARY_PATH:-}" ]; then
		LD_LIBRARY_PATH="$BATMON_LD_LIBRARY_PATH" batmon.elf \
			>> "$LOGS_PATH/batmon.txt" 2>&1 &
	else
		batmon.elf >> "$LOGS_PATH/batmon.txt" 2>&1 &
	fi
	# Confirm it survived rather than logging a restart that did not happen.
	sleep 1
	if batmon_is_running; then
		log_event "Restarted batmon after shared-data remount"
		return 0
	fi
	log_event "Warning: batmon did not stay running after the remount; see batmon.txt"
	return 1
}

activate_profile() {
	name=$1
	old=$(active_profile)
	if [ "$name" = "$old" ]; then action=Reloading; else action=Activating; fi
	log_event "$action profile: $name"
	new="$PROFILE_ROOT/$name"
	[ -d "$new/Saves" ] && [ -d "$new/shared" ] || {
		ACTION_RESULT="Profile data is incomplete: $new"
		return 1
	}
	if command -v profiles_before_mount_switch >/dev/null 2>&1; then
		profiles_before_mount_switch
	fi
	stop_profile_services || return 1
	sync
	unmount_target "$SHARED_TARGET" || { start_profile_services || true; return 1; }
	unmount_target "$SAVES_TARGET" || {
		restore_profile_mounts "$old" || true
		start_profile_services || true
		return 1
	}
	if ! bind_profile_path "$new/Saves" "$SAVES_TARGET"; then
		ACTION_RESULT="Could not mount $new/Saves."
		restore_profile_mounts "$old" || true
		start_profile_services || true
		return 1
	fi
	if ! bind_profile_path "$new/shared" "$SHARED_TARGET"; then
		ACTION_RESULT="Could not mount $new/shared."
		umount "$SAVES_TARGET" 2>/dev/null || true
		restore_profile_mounts "$old" || true
		start_profile_services || true
		return 1
	fi
	write_active "$name" || {
		ACTION_RESULT="Mounted $name but could not record it as active."
		start_profile_services || true
		return 1
	}
	remount_core_saves_if_compatible "$name"
	start_profile_services || true
	refresh_hotkey
	sync
	log_event "Profile active: $name"
}

rename_profile() {
	old=$1
	new=$2
	validate_profile_name "$new" || { ACTION_RESULT=$PROFILE_ERROR; return 1; }
	was_active=0
	[ "$old" = "$(active_profile)" ] && was_active=1
	primary_owner=$(primary_profile)
	core_owner=""
	[ -f "$CORE_PROFILE_FILE" ] && core_owner=$(sed -n '1p' "$CORE_PROFILE_FILE")
	if [ "$was_active" = 1 ]; then
		if command -v profiles_before_mount_switch >/dev/null 2>&1; then
			profiles_before_mount_switch
		fi
		stop_profile_services || return 1
		unmount_target "$SHARED_TARGET" || { start_profile_services || true; return 1; }
		unmount_target "$SAVES_TARGET" || {
			restore_profile_mounts "$old" || true
			start_profile_services || true
			return 1
		}
	fi
	mv "$PROFILE_ROOT/$old" "$PROFILE_ROOT/$new" || {
		ACTION_RESULT="Could not rename $old."
		[ "$was_active" = 1 ] && bind_profile_path "$PROFILE_ROOT/$old/Saves" "$SAVES_TARGET"
		[ "$was_active" = 1 ] && bind_profile_path "$PROFILE_ROOT/$old/shared" "$SHARED_TARGET"
		[ "$was_active" = 1 ] && start_profile_services || true
		return 1
	}
	if [ "$was_active" = 1 ]; then
		if ! bind_profile_path "$PROFILE_ROOT/$new/Saves" "$SAVES_TARGET" ||
			! bind_profile_path "$PROFILE_ROOT/$new/shared" "$SHARED_TARGET"; then
			unmount_target "$SHARED_TARGET" 2>/dev/null || true
			unmount_target "$SAVES_TARGET" 2>/dev/null || true
			mv "$PROFILE_ROOT/$new" "$PROFILE_ROOT/$old" 2>/dev/null || true
			restore_profile_mounts "$old" || true
			start_profile_services || true
			ACTION_RESULT="Could not restore mounts after renaming; the original name was restored."
			return 1
		fi
		write_active "$new" || {
			ACTION_RESULT="Renamed profile, but could not update the active-profile marker."
			start_profile_services || true
			return 1
		}
	fi
	if [ "$core_owner" = "$old" ]; then
		printf '%s\n' "$new" > "$CORE_PROFILE_FILE" || {
			ACTION_RESULT="Renamed profile, but could not update its Core Saves ownership."
			[ "$was_active" = 1 ] && start_profile_services || true
			return 1
		}
	fi
	if [ "$primary_owner" = "$old" ]; then
		write_marker "$new" "$PRIMARY_FILE" || {
			ACTION_RESULT="Renamed profile, but could not update its primary-profile marker."
			[ "$was_active" = 1 ] && start_profile_services || true
			return 1
		}
	fi
	if [ "$was_active" = 1 ]; then
		remount_core_saves_if_compatible "$new"
		start_profile_services || true
		refresh_hotkey
	fi
	sync
	log_event "Renamed profile: $old -> $new"
}

delete_profile() {
	name=$1
	[ "$name" != "$(primary_profile)" ] || {
		ACTION_RESULT="The primary profile cannot be deleted."
		return 1
	}
	[ "$name" != "$(active_profile)" ] || {
		ACTION_RESULT="Switch to another profile before deleting $name."
		return 1
	}
	[ -d "$PROFILE_ROOT/$name/Saves" ] && [ -d "$PROFILE_ROOT/$name/shared" ] || {
		ACTION_RESULT="Profile data is incomplete: $name"
		return 1
	}
	rm -rf -- "$PROFILE_ROOT/$name" || {
		ACTION_RESULT="Could not delete $name."
		return 1
	}
	sync
	log_event "Deleted profile: $name"
}

build_profile_menu() {
	menu=$1
	map=$2
	current=$(active_profile)
	: > "$map"
	{
		printf '{"items":['
		first=1
		find "$PROFILE_ROOT" -mindepth 1 -maxdepth 1 -type d ! -name '.*' 2>/dev/null | LC_ALL=C sort | while IFS= read -r path; do
			name=$(basename "$path")
			[ -d "$path/Saves" ] && [ -d "$path/shared" ] || continue
			if [ "$name" = "$current" ]; then
				shown="[ACTIVE] $name"
				confirm=RELOAD
			else
				shown=$name
				confirm=CHANGE
			fi
			escaped=$(printf '%s' "$shown" | sed 's/\\/\\\\/g; s/"/\\"/g')
			[ "$first" = 1 ] || printf ','
			first=0
			printf '{"name":"%s","features":{"confirm_text":"%s"}}' "$escaped" "$confirm"
			printf '%s|%s\n' "$shown" "$name" >> "$map"
		done
		printf ',{"name":"+ Add New Profile","features":{"confirm_text":"ADD"}}'
		printf ',{"name":"Uninstall Profiles","features":{"confirm_text":"UNINSTALL"}}]}'
	} > "$menu"
	printf '%s|%s\n' "+ Add New Profile" "+" >> "$map"
	printf '%s|%s\n' "Uninstall Profiles" "!" >> "$map"
}

syncthing_installed() {
	[ -f "$SYNCTHING_CONFIG" ] || [ -d "$SDCARD_PATH/Tools/$PLATFORM/Syncthing.pak" ]
}

syncthing_running() {
	pgrep syncthing >/dev/null 2>&1
}

syncthing_folder_paths() {
	[ -f "$SYNCTHING_CONFIG" ] || return 0
	sed -n 's/.*<folder[^>]*[[:space:]]path="\([^"]*\)".*/\1/p' "$SYNCTHING_CONFIG" |
		sed 's/&amp;/\&/g; s/&quot;/"/g; s/&#39;/'"'"'/g; s|/*$||'
}

path_is_profile_alias() {
	path=${1%/}
	case "$path" in
		"$SAVES_TARGET"|"$SAVES_TARGET"/*|"$SHARED_TARGET"|"$SHARED_TARGET"/*) return 0 ;;
		/Saves|/Saves/*|Saves|Saves/*|./Saves|./Saves/*) return 0 ;;
		/.userdata/shared|/.userdata/shared/*|.userdata/shared|.userdata/shared/*|./.userdata/shared|./.userdata/shared/*) return 0 ;;
	esac
	return 1
}

syncthing_affected_paths() {
	syncthing_folder_paths | while IFS= read -r path; do
		if path_is_profile_alias "$path"; then
			printf '%s\n' "$path"
		fi
	done
	return 0
}

core_saves_mounts_active() {
	[ -n "$(mounted_descendants "$SAVES_TARGET")" ] || return 1
	core_saves_enabled
}

core_saves_enabled() {
	[ -f "$SHARED_TARGET/RetroArch Core Saves/enabled" ] ||
		[ -f "$USERDATA_PATH/.hooks/boot.d/core-saves.sync.sh" ]
}

validate_core_saves_owner() {
	current=$(active_profile)
	current_enabled=0
	[ -f "$SHARED_TARGET/RetroArch Core Saves/enabled" ] && current_enabled=1
	[ "$current_enabled" = 1 ] || return 0
	if [ ! -f "$CORE_PROFILE_FILE" ]; then
		printf '%s\n' "$current" > "$CORE_PROFILE_FILE"
		return 0
	fi
	owner=$(sed -n '1p' "$CORE_PROFILE_FILE")
	[ "$owner" = "$current" ] || {
		ACTION_RESULT="RetroArch Core Saves is enabled for $current, but Profiles already assigned Core Saves compatibility to $owner. Disable it in $current before continuing."
		return 1
	}
}

install_auto_hook() {
	mkdir -p "$(dirname "$AUTO_PATH")" || return 1
	tmp="$AUTO_PATH.new.$$"
	line='test -x "$USERDATA_PATH/Profiles/boot-mount.sh" && "$USERDATA_PATH/Profiles/boot-mount.sh" # Profiles.pak-on-boot'
	{
		echo '#!/bin/sh'
		echo "$line"
		if [ -f "$AUTO_PATH" ]; then
			awk -v marker="$PROFILE_MARKER" 'NR == 1 && /^#!/ { next } index($0, marker) == 0 { print }' "$AUTO_PATH"
		fi
	} > "$tmp" && mv "$tmp" "$AUTO_PATH" && chmod 0755 "$AUTO_PATH"
}

remove_auto_hook() {
	[ -f "$AUTO_PATH" ] || return 0
	tmp="$AUTO_PATH.new.$$"
	awk -v marker="$PROFILE_MARKER" 'index($0, marker) == 0 { print }' "$AUTO_PATH" > "$tmp" &&
		mv "$tmp" "$AUTO_PATH" && chmod 0755 "$AUTO_PATH"
}

uninstall_profiles() {
	primary=$(primary_profile)
	[ -n "$primary" ] && [ -d "$PROFILE_ROOT/$primary/Saves" ] &&
		[ -d "$PROFILE_ROOT/$primary/shared" ] || {
		ACTION_RESULT="The primary profile is incomplete; uninstall was cancelled."
		return 1
	}
	stamp=$(timestamp)
	backup="$BACKUP_ROOT/uninstall-$stamp"
	[ ! -e "$backup" ] || backup="$BACKUP_ROOT/uninstall-$stamp-$$"
	mkdir -p "$backup" || {
		ACTION_RESULT="Could not create the uninstall safety backup."
		return 1
	}

	if command -v profiles_before_mount_switch >/dev/null 2>&1; then
		profiles_before_mount_switch
	fi
	stop_profile_services || return 1
	sync
	unmount_target "$SHARED_TARGET" || { start_profile_services || true; return 1; }
	unmount_target "$SAVES_TARGET" || {
		restore_profile_mounts "$(active_profile)" || true
		start_profile_services || true
		return 1
	}

	mv "$SAVES_TARGET" "$backup/Saves" &&
		mv "$SHARED_TARGET" "$backup/shared" &&
		mkdir -p "$SAVES_TARGET" "$SHARED_TARGET" || {
		[ -e "$SAVES_TARGET" ] || mv "$backup/Saves" "$SAVES_TARGET" 2>/dev/null || true
		[ -e "$SHARED_TARGET" ] || mv "$backup/shared" "$SHARED_TARGET" 2>/dev/null || true
		restore_profile_mounts "$(active_profile)" || true
		start_profile_services || true
		ACTION_RESULT="Could not prepare the original save paths."
		return 1
	}
	if ! copy_tree "$PROFILE_ROOT/$primary/Saves" "$SAVES_TARGET" ||
		! copy_tree "$PROFILE_ROOT/$primary/shared" "$SHARED_TARGET"; then
		rm -rf -- "$SAVES_TARGET" "$SHARED_TARGET"
		mv "$backup/Saves" "$SAVES_TARGET" 2>/dev/null || true
		mv "$backup/shared" "$SHARED_TARGET" 2>/dev/null || true
		restore_profile_mounts "$(active_profile)" || true
		start_profile_services || true
		ACTION_RESULT="Restore failed. The previous folders were put back."
		return 1
	fi

	remove_auto_hook || {
		start_profile_services || true
		ACTION_RESULT="Data was restored, but the boot hook could not be removed."
		return 1
	}
	killall hotkey-monitor.sh 2>/dev/null || true
	rm -f "$INSTALL_HOME/boot-mount.sh" "$INSTALL_HOME/hotkey-monitor.sh" \
		"$INSTALL_HOME/refresh-hotkey.sh"
	start_profile_services || true
	sync
	ACTION_RESULT="Primary profile restored to the original paths. Safety backup: $backup"
	log_event "Uninstalled Profiles (primary=$primary backup=$backup)"
}

install_runtime() {
	mkdir -p "$INSTALL_HOME" "$BACKUP_ROOT" || {
		ACTION_RESULT="Could not create $INSTALL_HOME."
		return 1
	}
	for file in boot-mount.sh hotkey-monitor.sh refresh-hotkey.sh; do
		cp "$DIR/bin/$file" "$INSTALL_HOME/$file" || {
			ACTION_RESULT="Could not install $file."
			return 1
		}
		chmod 0755 "$INSTALL_HOME/$file"
	done
	install_auto_hook || {
		ACTION_RESULT="Could not install the boot mount in $AUTO_PATH."
		return 1
	}
	sync
	log_event "Installed runtime and boot hook"
}

refresh_hotkey() {
	[ -x "$INSTALL_HOME/refresh-hotkey.sh" ] || return 0
	PROFILES_DIR="$DIR" "$INSTALL_HOME/refresh-hotkey.sh" >> "$LOG_FILE" 2>&1 || true
}
