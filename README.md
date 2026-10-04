# PZ GIF Poster

Set an animated GIF as the Steam Workshop poster of a Project Zomboid mod, without SteamCMD and without logging in again.

Project Zomboid's in-game uploader only accepts `preview.png`. The usual workaround is SteamCMD, which needs its own login and signs the Steam app out on the same computer. This tool instead talks to the Steam app that is already running, through the Steam library that ships with the game, the same way the in-game uploader does. It never asks for or sees your password.

## Requirements

- Steam running and signed in, with Project Zomboid installed through Steam.
- You are the owner or a contributor of the mod.
- A GIF under 1 MB. 256x256 is recommended; other sizes only get a warning.
- Windows: nothing else. macOS and Linux: Python 3.

## Windows

1. Download the `windows` folder.
2. Double-click `GIF Poster.bat`.
3. Type `n`, paste the mod's workshop link or ID, then drag the GIF into the window (or press Enter to pick it in a file dialog).

It shows the mod's title, uploads, and prints the workshop link. Mods you have uploaded are remembered and listed by title, so after a mod update you only type the mod's number.

From a command prompt:

```
"GIF Poster.bat" <mod> [gif]        upload
"GIF Poster.bat" -n <mod> [gif]     check the GIF and look the mod up, upload nothing
```

`<mod>` is a workshop ID, a workshop URL, a folder containing `workshop.txt` with an `id=` line, or the name of such a folder under `%USERPROFILE%\Zomboid\Workshop`. `[gif]` defaults to `preview.gif` in that folder.

`Steam Check.bat` is a diagnostic: it connects, looks one mod up, disconnects, and reports whether Steam stayed signed in. It uploads nothing and writes `steamcheck_report.txt`.

## macOS and Linux

```
python3 gifposter.py                 interactive
python3 gifposter.py <mod> [gif]     upload
python3 gifposter.py -n <mod> [gif]  check only
```

On macOS, `GIF Poster.command` starts the interactive mode on double-click.

## Things to know

- **Re-run after every mod update.** The in-game uploader puts `preview.png` back each time.
- **Steam shows you as playing Project Zomboid** for the few seconds an upload takes.
- **Close games on your other computers first.** Steam lets one computer per account be in a game at a time. During development Steam signed out once on a Mac when the tool connected while the same account was online on a second computer; the cause was not confirmed.
- Remembered mods are stored in `.gifposter/mods.tsv` in your home folder.

## Status

| Platform | State |
| --- | --- |
| Windows | Tested with a real upload. |
| macOS | Connecting and looking a mod up worked; a real upload has not been tried. |
| Linux | Never run. |

## How it works

The scripts load `steam_api64.dll` (Windows), `libsteam_api.dylib` (macOS) or `libsteam_api.so` (Linux) from the Project Zomboid install, connect to the running Steam app as app 108600, and call `StartItemUpdate`, `SetItemPreview` and `SubmitItemUpdate` from the Steamworks UGC interface. Only the preview image is changed.

The SteamCMD method this replaces is described in the guide [How to change the mod poster image to a GIF](https://steamcommunity.com/sharedfiles/filedetails/?id=3324078713).
