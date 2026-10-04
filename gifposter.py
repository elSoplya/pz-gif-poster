#!/usr/bin/env python3
"""Set a GIF as the Steam Workshop poster of a Project Zomboid mod, through the
running Steam app. For macOS and Linux; the Windows version is windows/gifposter.ps1.

    gifposter.py                 interactive: pick a mod and a GIF
    gifposter.py <mod> [gif]     upload the GIF as the mod's poster
    gifposter.py -n <mod> [gif]  check the GIF and look the mod up on Steam, upload nothing

On macOS, "GIF Poster.command" next to this file starts the interactive mode on
double-click.

<mod> is a workshop ID, a workshop URL, a folder holding workshop.txt with an
id= line, or the name of such a folder under ~/Zomboid/Workshop.
[gif] defaults to preview.gif in that folder.

Steam has to be running and signed in; there is no separate login. The upload
goes through the Steam library that ships with the game (libsteam_api), the way
the in-game uploader does, so Steam shows you as playing Project Zomboid for the
few seconds it takes.

The in-game uploader puts preview.png back on every mod update, so re-run this
after each update. Uploaded mods are remembered in ~/.gifposter/mods.tsv and
listed in the interactive mode.

STEAM_API_LIB overrides which libsteam_api file is loaded.
"""

import argparse
import atexit
import contextlib
import ctypes
import os
import re
import shutil
import struct
import subprocess
import sys
import time
from ctypes import POINTER, byref, c_bool, c_char, c_char_p, c_int, c_uint32, c_uint64, c_void_p, sizeof
from pathlib import Path

APP_ID = 108600  # Project Zomboid
MAX_BYTES = 1024 * 1024
WORKSHOP_DIR = Path.home() / "Zomboid" / "Workshop"
MODS_FILE = Path.home() / ".gifposter" / "mods.tsv"  # one line per mod: id<TAB>title<TAB>gif
MAC = sys.platform == "darwin"

K_ERESULT_OK = 1
ERESULTS = {
    2: "Steam reported a generic failure",
    3: "Steam has no connection",
    9: "the workshop item was not found",
    15: "access denied - this Steam account is not the owner or a contributor of the mod",
    16: "Steam timed out",
    21: "Steam is not logged on",
    24: "this Steam account is not allowed to change the mod",
    25: "Steam refused the file as too large",
}
UPDATE_STATUS = {1: "Preparing", 2: "Preparing", 3: "Uploading", 4: "Uploading the GIF", 5: "Committing"}
# Callback ids of the two asynchronous results read below.
K_UGC_QUERY_COMPLETED = 3401
K_SUBMIT_ITEM_UPDATE_RESULT = 3404


class Error(Exception):
    pass


# Steamworks structs are packed to 4 bytes on macOS and Linux.
class UGCQueryCompleted(ctypes.Structure):
    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [
        ("handle", c_uint64),
        ("result", c_int),
        ("num_results", c_uint32),
        ("total_results", c_uint32),
        ("cached", c_bool),
        ("next_cursor", c_char * 256),
    ]


# Only the leading fields of SteamUGCDetails_t; it is read out of a larger buffer.
class UGCDetails(ctypes.Structure):
    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [
        ("published_file_id", c_uint64),
        ("result", c_int),
        ("file_type", c_int),
        ("creator_app_id", c_uint32),
        ("consumer_app_id", c_uint32),
        ("title", c_char * 129),
        ("description", c_char * 8000),
        ("owner", c_uint64),
    ]


class SubmitItemUpdateResult(ctypes.Structure):
    _pack_ = 4
    _layout_ = "ms"
    _fields_ = [
        ("result", c_int),
        ("needs_legal_agreement", c_bool),
        ("published_file_id", c_uint64),
    ]


@contextlib.contextmanager
def quiet():
    """The Steam library logs straight to the process's stdout and stderr."""
    sys.stdout.flush()
    sys.stderr.flush()
    saved = os.dup(1), os.dup(2)
    null = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(null, 1)
        os.dup2(null, 2)
        yield
    finally:
        os.dup2(saved[0], 1)
        os.dup2(saved[1], 2)
        for fd in (null, *saved):
            os.close(fd)


def library_candidates():
    override = os.environ.get("STEAM_API_LIB")
    if override:
        return [Path(override)]
    home = Path.home()
    if MAC:
        roots = [home / "Library/Application Support/Steam"]
    else:
        roots = [home / p for p in (".steam/steam", ".local/share/Steam",
                                    ".var/app/com.valvesoftware.Steam/.local/share/Steam")]
    libraries = []
    for root in roots:
        libraries.append(root)
        folders = root / "steamapps" / "libraryfolders.vdf"
        if folders.is_file():
            libraries += [Path(p) for p in re.findall(r'"path"\s+"([^"]+)"', folders.read_text(errors="replace"))]
    name = "libsteam_api.dylib" if MAC else "libsteam_api.so"
    found = []
    for library in dict.fromkeys(libraries):
        game = library / "steamapps" / "common" / "ProjectZomboid"
        if game.is_dir():
            found += sorted(game.rglob(name))
    return found


def load_library():
    for path in library_candidates():
        try:
            return ctypes.CDLL(str(path))
        except OSError:
            continue  # e.g. the 32-bit copy
    raise Error("could not load the game's Steam library (libsteam_api) - "
                "is Project Zomboid installed through Steam on this computer?")


class Steam:
    """One connection to the running Steam app, as Project Zomboid."""

    def __init__(self):
        os.environ["SteamAppId"] = os.environ["SteamGameId"] = str(APP_ID)
        with quiet():
            self.lib = load_library()
            if not hasattr(self.lib, "SteamAPI_InitFlat"):
                raise Error("the game's Steam library is too old for this tool")
            if not self._fn("SteamAPI_IsSteamRunning", c_bool)():
                raise Error("Steam is not running - start Steam, sign in, and try again")
            message = ctypes.create_string_buffer(1024)
            if self._fn("SteamAPI_InitFlat", c_int, c_char_p)(message) != 0:
                raise Error("could not connect to Steam: " + message.value.decode(errors="replace"))
        atexit.register(self._shutdown)
        self.ugc = self._interface("SteamUGC")
        self.utils = self._interface("SteamUtils")
        self.steam_id = self._fn("SteamAPI_ISteamUser_GetSteamID", c_uint64, c_void_p)(self._interface("SteamUser"))
        name = self._fn("SteamAPI_ISteamFriends_GetPersonaName", c_char_p, c_void_p)(self._interface("SteamFriends"))
        self.persona = (name or b"").decode(errors="replace")

    def _shutdown(self):
        with quiet():
            self.lib.SteamAPI_Shutdown()

    def _fn(self, name, restype, *argtypes):
        fn = getattr(self.lib, name)
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    def _interface(self, base):
        # Accessors carry the interface version of the SDK the game was built with, e.g. SteamAPI_SteamUGC_v021.
        for version in range(40, 0, -1):
            name = "SteamAPI_%s_v%03d" % (base, version)
            if hasattr(self.lib, name):
                return self._fn(name, c_void_p)()
        raise Error("the game's Steam library has no %s interface this tool knows" % base)

    def _wait(self, call, result, callback_id, timeout, tick=None):
        completed = self._fn("SteamAPI_ISteamUtils_IsAPICallCompleted", c_bool, c_void_p, c_uint64, POINTER(c_bool))
        failed = c_bool(False)
        deadline = time.monotonic() + timeout
        while not completed(self.utils, call, byref(failed)):
            if time.monotonic() > deadline:
                raise Error("Steam did not answer in time")
            self.lib.SteamAPI_RunCallbacks()
            if tick:
                tick()
            time.sleep(0.1)
        fetch = self._fn("SteamAPI_ISteamUtils_GetAPICallResult", c_bool,
                         c_void_p, c_uint64, c_void_p, c_int, c_int, POINTER(c_bool))
        if not fetch(self.utils, call, byref(result), sizeof(result), callback_id, byref(failed)) or failed.value:
            raise Error("Steam could not complete the request")
        return result

    def lookup(self, item_id):
        """Title of a Project Zomboid workshop item, and whether this account owns it."""
        ids = c_uint64(item_id)
        query = self._fn("SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest", c_uint64,
                         c_void_p, POINTER(c_uint64), c_uint32)(self.ugc, byref(ids), 1)
        try:
            call = self._fn("SteamAPI_ISteamUGC_SendQueryUGCRequest", c_uint64, c_void_p, c_uint64)(self.ugc, query)
            done = self._wait(call, UGCQueryCompleted(), K_UGC_QUERY_COMPLETED, timeout=30)
            buffer = ctypes.create_string_buffer(32768)
            got = self._fn("SteamAPI_ISteamUGC_GetQueryUGCResult", c_bool,
                           c_void_p, c_uint64, c_uint32, c_void_p)(self.ugc, query, 0, buffer)
            details = UGCDetails.from_buffer(buffer)
            if done.result != K_ERESULT_OK or not got or details.result != K_ERESULT_OK:
                raise Error("workshop item %d was not found, or this Steam account cannot see it" % item_id)
            if details.consumer_app_id != APP_ID:
                raise Error("workshop item %d is not a Project Zomboid mod" % item_id)
            return details.title.decode(errors="replace"), details.owner == self.steam_id
        finally:
            self._fn("SteamAPI_ISteamUGC_ReleaseQueryUGCRequest", c_bool, c_void_p, c_uint64)(self.ugc, query)

    def set_preview(self, item_id, image):
        handle = self._fn("SteamAPI_ISteamUGC_StartItemUpdate", c_uint64,
                          c_void_p, c_uint32, c_uint64)(self.ugc, APP_ID, item_id)
        if not self._fn("SteamAPI_ISteamUGC_SetItemPreview", c_bool,
                        c_void_p, c_uint64, c_char_p)(self.ugc, handle, os.fsencode(image)):
            raise Error("Steam did not accept %s as a preview image" % image)
        call = self._fn("SteamAPI_ISteamUGC_SubmitItemUpdate", c_uint64,
                        c_void_p, c_uint64, c_char_p)(self.ugc, handle, None)

        progress = self._fn("SteamAPI_ISteamUGC_GetItemUpdateProgress", c_int,
                            c_void_p, c_uint64, POINTER(c_uint64), POINTER(c_uint64))
        shown = []

        def tick():
            status = UPDATE_STATUS.get(progress(self.ugc, handle, byref(c_uint64()), byref(c_uint64())))
            if status and status not in shown:
                shown.append(status)
                print(status + "...")

        result = self._wait(call, SubmitItemUpdateResult(), K_SUBMIT_ITEM_UPDATE_RESULT, timeout=300, tick=tick)
        if result.result != K_ERESULT_OK:
            raise Error("upload failed: " + ERESULTS.get(result.result, "Steam error %d" % result.result))
        if result.needs_legal_agreement:
            print("note: Steam wants you to accept the Workshop legal agreement: "
                  "https://steamcommunity.com/sharedfiles/workshoplegalagreement")


def resolve_mod(mod):
    """Workshop id of <mod>, and its folder when <mod> is one."""
    if not mod:
        raise Error("no mod given")
    if mod.isdigit():
        return int(mod), None
    folder = next((p for p in (Path(mod).expanduser(), WORKSHOP_DIR / mod) if p.is_dir()), None)
    if folder is None:
        match = re.search(r"[?&]id=(\d+)", mod)
        if not match:
            raise Error("'%s' is not a workshop ID, a workshop URL or a mod folder" % mod)
        return int(match.group(1)), None
    workshop_txt = folder / "workshop.txt"
    if not workshop_txt.is_file():
        raise Error("no workshop.txt in %s" % folder)
    match = re.search(r"^id=\s*(\d+)", workshop_txt.read_text(errors="replace"), re.MULTILINE)
    if not match:
        raise Error("%s has no workshop id - give the workshop ID or URL instead" % workshop_txt)
    return int(match.group(1)), folder


def check_gif(gif):
    if not gif.is_file():
        raise Error("GIF not found: %s" % gif)
    with gif.open("rb") as f:
        head = f.read(10)
    if len(head) < 10 or head[:3] != b"GIF":
        raise Error("not a GIF file: %s" % gif)
    size = gif.stat().st_size
    if size >= MAX_BYTES:
        raise Error("%s is %d KB - a workshop poster must be under 1 MB" % (gif, size // 1024))
    width, height = struct.unpack("<HH", head[6:10])  # logical screen size
    if (width, height) != (256, 256):
        print("warning: GIF is %dx%d; workshop posters are meant to be 256x256" % (width, height), file=sys.stderr)
    print("GIF: %s (%d KB, %dx%d)" % (gif, size // 1024, width, height))
    return gif.resolve()


def read_mods():
    if not MODS_FILE.is_file():
        return []
    return [line.split("\t", 2) for line in MODS_FILE.read_text().splitlines() if line.count("\t") == 2]


def remember(item_id, title, gif):
    row = [str(item_id), title.replace("\t", " "), str(gif)]
    mods = read_mods()
    for i, mod in enumerate(mods):
        if mod[0] == row[0]:
            mods[i] = row
            break
    else:
        mods.append(row)
    MODS_FILE.parent.mkdir(exist_ok=True)
    MODS_FILE.write_text("".join("\t".join(mod) + "\n" for mod in mods))


def run(mod, gif, check_only):
    item_id, folder = resolve_mod(mod)
    if gif is None:
        if folder is None:
            raise Error("give the GIF path when <mod> is an ID or URL")
        gif = folder / "preview.gif"
    gif = check_gif(Path(gif).expanduser())

    steam = Steam()
    title, mine = steam.lookup(item_id)
    url = "https://steamcommunity.com/sharedfiles/filedetails/?id=%d" % item_id
    print("Steam account: %s" % steam.persona)
    print("Mod: %s%s" % (title, "" if mine else "  (owned by another account - works only if you are a contributor)"))
    if check_only:
        print("Check only - nothing uploaded. Would set the poster of %s" % url)
        return
    steam.set_preview(item_id, gif)
    remember(item_id, title, gif)
    print("Poster updated: %s" % url)


def clean_path(text):
    """Undo what a terminal does to a dragged-in path: trailing space, quotes, backslash escapes."""
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "'\"":
        return text[1:-1]
    return re.sub(r"\\(.)", r"\1", text)


def pick_gif():
    if MAC:
        command = ["osascript", "-e", "activate", "-e",
                   'POSIX path of (choose file of type {"com.compuserve.gif"} with prompt "Choose the GIF poster")']
    elif shutil.which("zenity"):
        command = ["zenity", "--file-selection", "--title=Choose the GIF poster", "--file-filter=GIF | *.gif"]
    else:
        print("no file dialog available here - type or drag the path instead", file=sys.stderr)
        return None
    picked = subprocess.run(command, capture_output=True, text=True)
    return picked.stdout.strip() or None


def interactive():
    print("GIF Poster - set a GIF as the workshop poster of a Project Zomboid mod")
    print("Steam must be running and signed in.")
    home = str(Path.home())
    while True:
        mods = read_mods()
        print()
        for number, (item_id, title, gif) in enumerate(mods, 1):
            shown = "~" + gif[len(home):] if gif.startswith(home + os.sep) else gif
            print("  %d) %s  %s" % (number, title, shown))
        print("  n) new mod    q) quit")
        try:
            choice = input("> ").strip().lower()
            if choice == "q":
                return
            if choice == "n":
                mod = clean_path(input("Workshop link or ID of the mod: "))
                gif = clean_path(input("GIF file - drag it into this window, or press Enter to choose it: ")) or pick_gif()
                if not gif:
                    continue
            elif choice.isdigit() and 1 <= int(choice) <= len(mods):
                mod, _, gif = mods[int(choice) - 1]
            else:
                continue
        except EOFError:
            return
        # A fresh process per upload: Steam shows the game as running only while one is in progress.
        subprocess.run([sys.executable, os.path.abspath(__file__), mod, gif])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("-n", dest="check_only", action="store_true", help="check only, upload nothing")
    parser.add_argument("mod", nargs="?")
    parser.add_argument("gif", nargs="?")
    args = parser.parse_args()
    try:
        if args.mod is None:
            if args.check_only:
                parser.error("-n needs a <mod>")
            if not sys.stdin.isatty():
                parser.print_help()
                return 0
            interactive()
        else:
            run(args.mod, args.gif, args.check_only)
    except Error as error:
        sys.stdout.flush()
        print("error: %s" % error, file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
