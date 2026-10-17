#!/bin/sh

TMP_ROOT=${TMP_ROOT:-/tmp}
SAVES_TARGET=${SAVES_TARGET:-"$SDCARD_PATH/Saves"}
SHARED_TARGET=${SHARED_TARGET:-"$SDCARD_PATH/.userdata/shared"}
ACTIVE_FILE=${ACTIVE_FILE:-"$PROFILE_ROOT/active"}
CORE_PROFILE_FILE=${CORE_PROFILE_FILE:-"$PROFILE_ROOT/core-saves-profile"}
PRIMARY_FILE=${PRIMARY_FILE:-"$PROFILE_ROOT/primary"}
BACKUP_ROOT=${BACKUP_ROOT:-"$INSTALL_HOME/backup"}
SYNCTHING_CONFIG=${SYNCTHING_CONFIG:-"$USERDATA_PATH/Syncthing/config/config.xml"}
HOTKEY_HOOK=${HOTKEY_HOOK:-"$USERDATA_PATH/.hooks/boot.d/profiles-hotkey.sh"}
# Before mountctl, Profiles mounted from a marked line in auto.sh. Only kept
# so that line can be removed.
AUTO_PATH=${AUTO_PATH:-"$USERDATA_PATH/auto.sh"}
PROFILE_MARKER="Profiles.pak-on-boot"
ACTION_RESULT=""

log_event() {
	[ -n "${LOG_FILE:-}" ] || return 0
	printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo unknown-time)" "$*" >> "$LOG_FILE"
}

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

# Profiles never mounts anything itself. mountctl (bin/mounts, shared with
# RetroArch Core Saves.pak) owns the mount table; Profiles is its layer 10 (see
# bin/mounts/10-profiles.sh), which mounts whatever .profiles/active names. A
# switch is therefore: change the marker, ask mountctl to apply.
#
# The read-only helpers (mc_physical, mc_descendants, ...) come from the
# bundled copy so these checks resolve paths exactly as mountctl does.
MOUNTCTL_LIB=1
. "$DIR/bin/mounts/mountctl.sh"
unset MOUNTCTL_LIB

mountctl() {
	MOUNTCTL_LIB=0 sh "$(mc_newest "$DIR/bin/mounts/mountctl.sh")" "$@"
}

# Installing goes through this pak's copy, so a newer bundled mountctl
# replaces an older installed one.
mountctl_bundled() {
	MOUNTCTL_LIB=0 sh "$DIR/bin/mounts/mountctl.sh" "$@"
}

# mountctl prints its first error; the details are in logs/mounts.txt.
mountctl_or_fail() {
	result=$(mountctl "$@" 2>> "$LOG_FILE")
	rc=$?
	[ "$rc" -eq 0 ] && return 0
	ACTION_RESULT=${result:-"Could not update the mounts; see logs/mounts.txt."}
	log_event "mountctl $1 failed: $ACTION_RESULT"
	return 1
}

apply_mounts() {
	mountctl_or_fail apply
}

write_active() {
	write_marker "$1" "$ACTIVE_FILE"
}

# Core Saves versions that predate mountctl mount their own tag folders. Their
# helper is only needed while Core Saves has no mountctl layer installed.
remount_core_saves_if_compatible() {
	name=$1
	[ ! -f "$MOUNTS_HOME/layers.d/20-core-saves.sh" ] || return 0
	[ -f "$CORE_PROFILE_FILE" ] || return 0
	[ "$(sed -n '1p' "$CORE_PROFILE_FILE")" = "$name" ] || return 0
	helper="$SHARED_TARGET/RetroArch Core Saves/boot-mount.sh"
	[ -x "$helper" ] && "$helper" >> "$LOG_FILE" 2>&1 || true
}

before_mount_switch() {
	if command -v profiles_before_mount_switch >/dev/null 2>&1; then
		profiles_before_mount_switch
	fi
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
	before_mount_switch
	sync
	write_active "$name" || {
		ACTION_RESULT="Could not record $name as the active profile."
		return 1
	}
	if ! apply_mounts; then
		failure=$ACTION_RESULT
		if [ -z "$old" ]; then
			rm -f "$ACTIVE_FILE"
			apply_mounts || true
		elif [ "$old" != "$name" ]; then
			if write_active "$old" && apply_mounts; then
				log_event "Restored $old after the failed switch"
			else
				log_event "Could not restore $old after the failed switch"
			fi
		fi
		ACTION_RESULT=$failure
		return 1
	fi
	remount_core_saves_if_compatible "$name"
	refresh_hotkey
	sync
	log_event "Profile active: $name"
}

# Points every marker that named $1 at $2. Used both ways by rename_profile.
move_profile_markers() {
	from=$1
	to=$2
	[ "$was_active" = 1 ] && { write_active "$to" || return 1; }
	[ "$core_owner" = "$from" ] && { write_marker "$to" "$CORE_PROFILE_FILE" || return 1; }
	[ "$primary_owner" = "$from" ] && { write_marker "$to" "$PRIMARY_FILE" || return 1; }
	return 0
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
		before_mount_switch
		# A mounted folder cannot be renamed.
		mountctl_or_fail down || {
			failure=$ACTION_RESULT
			apply_mounts || true
			ACTION_RESULT=$failure
			return 1
		}
	fi
	mv "$PROFILE_ROOT/$old" "$PROFILE_ROOT/$new" || {
		ACTION_RESULT="Could not rename $old."
		[ "$was_active" = 1 ] && { apply_mounts || true; }
		return 1
	}
	# The markers have to name the new folder before anything is remounted:
	# both mount layers read them.
	if ! move_profile_markers "$old" "$new"; then
		mv "$PROFILE_ROOT/$new" "$PROFILE_ROOT/$old" 2>/dev/null || true
		move_profile_markers "$old" "$old" || true
		[ "$was_active" = 1 ] && { apply_mounts || true; }
		ACTION_RESULT="Could not update the profile markers; $old kept its name."
		return 1
	fi
	if [ "$was_active" = 1 ]; then
		if ! apply_mounts; then
			failure=$ACTION_RESULT
			mountctl down >> "$LOG_FILE" 2>&1 || true
			mv "$PROFILE_ROOT/$new" "$PROFILE_ROOT/$old" 2>/dev/null || true
			move_profile_markers "$old" "$old" || true
			apply_mounts || true
			ACTION_RESULT="Could not remount after renaming, so $old kept its name. $failure"
			return 1
		fi
		remount_core_saves_if_compatible "$new"
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
	saves_real=$(mc_physical "$SAVES_TARGET")
	shared_real=$(mc_physical "$SHARED_TARGET")
	case "$path" in
		"$SAVES_TARGET"|"$SAVES_TARGET"/*|"$SHARED_TARGET"|"$SHARED_TARGET"/*) return 0 ;;
		"$saves_real"|"$saves_real"/*|"$shared_real"|"$shared_real"/*) return 0 ;;
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
	[ -n "$(mc_descendants "$SAVES_TARGET")" ] || return 1
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

remove_auto_hook() {
	[ -f "$AUTO_PATH" ] || return 0
	grep -Fq "$PROFILE_MARKER" "$AUTO_PATH" || return 0
	tmp="$AUTO_PATH.new.$$"
	awk -v marker="$PROFILE_MARKER" 'index($0, marker) == 0 { print }' "$AUTO_PATH" > "$tmp" &&
		mv "$tmp" "$AUTO_PATH" && chmod 0755 "$AUTO_PATH"
}

# Restarts the Simple Mode watcher at boot. Not .sync.sh, so it runs after the
# mount hook (00-mounts.sync.sh) without holding up NextUI.
install_hotkey_hook() {
	mkdir -p "${HOTKEY_HOOK%/*}" || return 1
	tmp="$HOTKEY_HOOK.new.$$"
	{
		echo '#!/bin/sh'
		echo '# Installed by Profiles.pak: starts the Simple Mode hotkey watcher.'
		printf 'PROFILES_DIR=%s\n' "$(mc_quote "$DIR")"
		echo 'export PROFILES_DIR'
		printf 'exec sh %s\n' "$(mc_quote "$INSTALL_HOME/refresh-hotkey.sh")"
	} > "$tmp" && chmod 0755 "$tmp" && mv "$tmp" "$HOTKEY_HOOK"
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

	before_mount_switch
	sync
	# Takes the profile mounts, and anything mounted inside them, down. Other
	# layers are reapplied onto the restored folders at the end.
	mountctl_or_fail remove 10-profiles || {
		failure=$ACTION_RESULT
		apply_mounts || true
		ACTION_RESULT=$failure
		return 1
	}

	mv "$SAVES_TARGET" "$backup/Saves" &&
		mv "$SHARED_TARGET" "$backup/shared" &&
		mkdir -p "$SAVES_TARGET" "$SHARED_TARGET" || {
		[ -e "$SAVES_TARGET" ] || mv "$backup/Saves" "$SAVES_TARGET" 2>/dev/null || true
		[ -e "$SHARED_TARGET" ] || mv "$backup/shared" "$SHARED_TARGET" 2>/dev/null || true
		reinstall_profiles_layer
		ACTION_RESULT="Could not prepare the original save paths."
		return 1
	}
	if ! copy_tree "$PROFILE_ROOT/$primary/Saves" "$SAVES_TARGET" ||
		! copy_tree "$PROFILE_ROOT/$primary/shared" "$SHARED_TARGET"; then
		rm -rf -- "$SAVES_TARGET" "$SHARED_TARGET"
		mv "$backup/Saves" "$SAVES_TARGET" 2>/dev/null || true
		mv "$backup/shared" "$SHARED_TARGET" 2>/dev/null || true
		reinstall_profiles_layer
		ACTION_RESULT="Restore failed. The previous folders were put back."
		return 1
	fi

	remove_auto_hook || {
		ACTION_RESULT="Data was restored, but the old boot line could not be removed from $AUTO_PATH."
		return 1
	}
	rm -f "$HOTKEY_HOOK"
	killall hotkey-monitor.sh 2>/dev/null || true
	rm -f "$INSTALL_HOME/boot-mount.sh" "$INSTALL_HOME/hotkey-monitor.sh" \
		"$INSTALL_HOME/refresh-hotkey.sh" "$INSTALL_HOME/hotkey.pid"
	# Core Saves, if it has a layer, now mounts onto the restored /Saves.
	apply_mounts || log_event "Warning: remaining mount layers did not apply: $ACTION_RESULT"
	sync
	ACTION_RESULT="Primary profile restored to the original paths. Safety backup: $backup"
	log_event "Uninstalled Profiles (primary=$primary backup=$backup)"
}

reinstall_profiles_layer() {
	mountctl_bundled install "$DIR/bin/mounts/10-profiles.sh" >> "$LOG_FILE" 2>&1 || true
	apply_mounts || true
}

install_runtime() {
	mkdir -p "$INSTALL_HOME" "$BACKUP_ROOT" || {
		ACTION_RESULT="Could not create $INSTALL_HOME."
		return 1
	}
	for file in hotkey-monitor.sh refresh-hotkey.sh; do
		cp "$DIR/bin/$file" "$INSTALL_HOME/$file" || {
			ACTION_RESULT="Could not install $file."
			return 1
		}
		chmod 0755 "$INSTALL_HOME/$file"
	done
	result=$(mountctl_bundled install "$DIR/bin/mounts/10-profiles.sh" 2>> "$LOG_FILE") || {
		ACTION_RESULT=${result:-"Could not install the mount manager."}
		return 1
	}
	install_hotkey_hook || {
		ACTION_RESULT="Could not install the hotkey boot hook."
		return 1
	}
	# Upgrade from the auto.sh boot mount.
	remove_auto_hook || log_event "Warning: could not remove the old boot line from $AUTO_PATH"
	rm -f "$INSTALL_HOME/boot-mount.sh"
	sync
	log_event "Installed runtime and boot hooks"
}

refresh_hotkey() {
	[ -x "$INSTALL_HOME/refresh-hotkey.sh" ] || return 0
	PROFILES_DIR="$DIR" "$INSTALL_HOME/refresh-hotkey.sh" >> "$LOG_FILE" 2>&1 || true
}
