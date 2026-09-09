# Profiles.pak

Profiles keeps each user's NextUI saves, save states, resume metadata, recents,
and shared settings in a canonical profile directory:

```text
/mnt/SDCARD/.profiles/<name>/Saves
/mnt/SDCARD/.profiles/<name>/shared
```

At boot it bind-mounts the active profile onto NextUI's fixed paths:

```text
<profile>/Saves  -> /mnt/SDCARD/Saves
<profile>/shared -> /mnt/SDCARD/.userdata/shared
```

The original data is copied, not deleted. Initial setup also makes a dated
backup under `.userdata/<platform>/Profiles/backup` before creating any mounts.
The initial profile may be named during setup; choosing No names it `Default`.
Simple Mode is only offered for profiles created afterward.

New profiles can either copy the primary profile's saves and shared settings or
start with empty Saves and MinUI settings folders. The primary profile remains
the initial profile even when it is renamed or another profile is active.
Inactive non-primary profiles can be deleted from their Edit screen. The active
and primary profiles are protected from deletion.

Selecting the active profile reloads it, reapplying its save mounts, Core Saves
compatibility, and Simple Mode hotkey state. Profile operations are appended to
`.userdata/<platform>/logs/profiles.txt` with timestamps.

## Uninstall

Choose `Uninstall Profiles` from the profile list to restore the primary
profile to `/Saves` and `/.userdata/shared` and remove the boot integration.
Other canonical profiles are retained under `.profiles`, and the replaced
legacy folders are kept in a dated uninstall safety backup.

## Syncthing

Do not sync `/mnt/SDCARD/Saves` or `/mnt/SDCARD/.userdata/shared` after Profiles
is installed. Those paths are moving aliases. Sync one or more canonical
folders under `/mnt/SDCARD/.profiles` instead. Profiles blocks initial setup if
Syncthing's `config.xml` still contains one of the moving paths or a descendant.

That includes `/mnt/SDCARD/Saves/Cores`, if you are using RetroArch Core Saves.pak. 
With Profiles installed, use:

```text
/mnt/SDCARD/.profiles/<name>/Saves/Cores
```

## RetroArch Core Saves

Disable RetroArch Core Saves before initial setup. Afterward it may be enabled
for one profile. Profiles remembers that owner and will not allow a second
profile to claim Core Saves compatibility. Its child save mounts are removed
before switching the `/Saves` parent and restored only for the compatible
profile.

Core Saves keeps operating on `/Saves`, which is the correct behaviour: `/Saves`
is a bind mount of the active profile's folder, so its `Cores` tree already
lives at `.profiles/<name>/Saves/Cores`. It reads `.profiles/active` to name the
active profile and the canonical path in its own UI, and to keep its save
backups inside the owning profile.

Sync the owning profile's `Saves/Cores` folder, not the whole `Saves` folder.
The tag bind mounts live at `/Saves/<tag>`, so `.profiles/<name>/Saves/<tag>` is
an empty directory on disk; files synced into it from a peer that is not running
Core Saves would land underneath the mount and be unreadable.

## Simple Mode

Simple Mode creates `enable-simple-mode` in that profile's `shared` directory.
On supported devices a background `minui-btntest` watcher opens Profiles when
MENU + L2 + R2 is held while the NextUI menu is visible. It deliberately does
nothing while a game is running.

## Supported platforms

- tg5040
- my285

The UI uses `minui-list`, `minui-presenter`, and `minui-keyboard`. The Simple
Mode chord uses `minui-btntest`; their bundled licenses and checksums are in
`bin/`.
