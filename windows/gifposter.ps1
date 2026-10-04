# Set a GIF as the Steam Workshop poster of a Project Zomboid mod, through the
# running Steam app. For Windows; the macOS and Linux version is gifposter.py.
#
#     "GIF Poster.bat"                     double-click: pick a mod and a GIF
#     "GIF Poster.bat" <mod> [gif]         upload the GIF as the mod's poster
#     "GIF Poster.bat" -n <mod> [gif]      check the GIF and look the mod up on Steam, upload nothing
#
# <mod> is a workshop ID, a workshop URL, a folder holding workshop.txt with an
# id= line, or the name of such a folder under %USERPROFILE%\Zomboid\Workshop.
# [gif] defaults to preview.gif in that folder.
#
# Steam has to be running and signed in; there is no separate login. The upload
# goes through the Steam library that ships with the game (steam_api64.dll), the
# way the in-game uploader does, so Steam shows you as playing Project Zomboid
# for the few seconds it takes.
#
# The in-game uploader puts preview.png back on every mod update, so re-run this
# after each update. Uploaded mods are remembered in %USERPROFILE%\.gifposter\mods.tsv
# and listed when you double-click.
#
# STEAM_API_LIB overrides which steam_api64.dll is loaded.

# Keep this file ASCII-only: Windows PowerShell 5.1 reads it as ANSI.

$ErrorActionPreference = 'Stop'

$AppId = 108600 # Project Zomboid
$MaxBytes = 1MB
$OnWindows = $env:OS -eq 'Windows_NT'
$WorkshopDir = Join-Path (Join-Path $HOME 'Zomboid') 'Workshop'
$ModsFile = Join-Path (Join-Path $HOME '.gifposter') 'mods.tsv' # one line per mod: id<TAB>title<TAB>gif
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
$Marshal = [System.Runtime.InteropServices.Marshal]
$Argv = @($args)

# Callback ids and sizes of the two asynchronous results read below, and field offsets in
# SteamUGCDetails_t. Steamworks packs structs to 8 bytes on Windows and to 4 elsewhere,
# which moves the owner field.
$QueryCompletedId = 3401
$QueryCompletedSize = 280
$SubmitResultId = 3404
$SubmitResultSize = 16
$OwnerOffset = if ($OnWindows) { 8160 } else { 8156 }
$EResults = @{
    2  = 'Steam reported a generic failure'
    3  = 'Steam has no connection'
    9  = 'the workshop item was not found'
    15 = 'access denied - this Steam account is not the owner or a contributor of the mod'
    16 = 'Steam timed out'
    21 = 'Steam is not logged on'
    24 = 'this Steam account is not allowed to change the mod'
    25 = 'Steam refused the file as too large'
}
$UpdateStatus = @{ 1 = 'Preparing'; 2 = 'Preparing'; 3 = 'Uploading'; 4 = 'Uploading the GIF'; 5 = 'Committing' }

function Show-Usage {
    foreach ($line in Get-Content -LiteralPath $PSCommandPath) {
        if ($line -notmatch '^#') { break }
        Write-Host ($line -replace '^# ?', '')
    }
}

function Find-SteamApiLibrary {
    if ($env:STEAM_API_LIB) { return $env:STEAM_API_LIB }
    $key = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if (-not $key -or -not $key.SteamPath) { return $null }
    $steamPath = $key.SteamPath -replace '/', '\'
    $folders = @($steamPath)
    $vdf = Join-Path $steamPath 'steamapps\libraryfolders.vdf'
    if (Test-Path -LiteralPath $vdf) {
        foreach ($match in [regex]::Matches((Get-Content -LiteralPath $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $folders += $match.Groups[1].Value -replace '\\\\', '\'
        }
    }
    foreach ($folder in $folders) {
        $game = Join-Path $folder 'steamapps\common\ProjectZomboid'
        if (-not (Test-Path -LiteralPath $game)) { continue }
        $dll = Get-ChildItem -LiteralPath $game -Recurse -Filter 'steam_api64.dll' -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($dll) { return $dll.FullName }
    }
    return $null
}

# The declarations are generated because the library path and the versioned accessor names
# (e.g. SteamAPI_SteamUGC_v021) depend on the copy of the game that is installed.
function Add-SteamNative([string]$Library, [hashtable]$Accessors) {
    $source = @'
using System;
using System.Runtime.InteropServices;

public static class SteamNative
{
    const string Lib = @"LIBRARY";

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_IsSteamRunning();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int SteamAPI_InitFlat(byte[] errorMessage);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void SteamAPI_Shutdown();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern void SteamAPI_RunCallbacks();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl, EntryPoint = "UGC_ACCESSOR")]
    public static extern IntPtr SteamUGC();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl, EntryPoint = "UTILS_ACCESSOR")]
    public static extern IntPtr SteamUtils();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl, EntryPoint = "USER_ACCESSOR")]
    public static extern IntPtr SteamUser();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl, EntryPoint = "FRIENDS_ACCESSOR")]
    public static extern IntPtr SteamFriends();

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr SteamAPI_ISteamFriends_GetPersonaName(IntPtr self);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUtils_IsAPICallCompleted(
        IntPtr self, ulong call, [MarshalAs(UnmanagedType.I1)] out bool failed);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUtils_GetAPICallResult(
        IntPtr self, ulong call, IntPtr result, int resultSize, int expectedCallback,
        [MarshalAs(UnmanagedType.I1)] out bool failed);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest(IntPtr self, ulong[] ids, uint count);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUGC_SendQueryUGCRequest(IntPtr self, ulong query);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_GetQueryUGCResult(IntPtr self, ulong query, uint index, IntPtr details);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_ReleaseQueryUGCRequest(IntPtr self, ulong query);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUGC_StartItemUpdate(IntPtr self, uint appId, ulong itemId);

    // previewFile is UTF-8 and NUL-terminated.
    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUGC_SetItemPreview(IntPtr self, ulong update, byte[] previewFile);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUGC_SubmitItemUpdate(IntPtr self, ulong update, IntPtr changeNote);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern int SteamAPI_ISteamUGC_GetItemUpdateProgress(
        IntPtr self, ulong update, out ulong bytesProcessed, out ulong bytesTotal);
}
'@
    $source = $source.Replace('LIBRARY', $Library)
    foreach ($name in $Accessors.Keys) {
        $source = $source.Replace($name.ToUpper() + '_ACCESSOR', $Accessors[$name])
    }
    Add-Type -TypeDefinition $source
}

# One connection to the running Steam app, as Project Zomboid. Returns @{ Ugc; Utils; Me; Persona }.
function Connect-Steam {
    if (-not [Environment]::Is64BitProcess) { throw 'this needs 64-bit PowerShell' }
    $library = Find-SteamApiLibrary
    if (-not $library -or -not (Test-Path -LiteralPath $library)) {
        throw 'steam_api64.dll was not found - is Project Zomboid installed through Steam on this PC?'
    }
    # Exported names are plain ASCII inside the file.
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($library))
    $accessors = @{}
    foreach ($name in 'UGC', 'Utils', 'User', 'Friends') {
        $accessors[$name] = [regex]::Match($text, "SteamAPI_Steam${name}_v\d{3}").Value
    }
    if (-not $text.Contains('SteamAPI_InitFlat') -or ($accessors.Values -contains '')) {
        throw "the game's Steam library is too old for this tool"
    }

    $env:SteamAppId = "$AppId"
    $env:SteamGameId = "$AppId"
    Add-SteamNative $library $accessors
    if (-not [SteamNative]::SteamAPI_IsSteamRunning()) {
        throw 'Steam is not running - start Steam, sign in, and try again'
    }
    $message = New-Object byte[] 1024
    $code = [SteamNative]::SteamAPI_InitFlat($message)
    if ($code -ne 0) {
        $end = [Math]::Max(0, [Array]::IndexOf($message, [byte]0))
        throw ('could not connect to Steam: ' + [System.Text.Encoding]::ASCII.GetString($message, 0, $end))
    }

    $name = [SteamNative]::SteamAPI_ISteamFriends_GetPersonaName([SteamNative]::SteamFriends())
    $nameBytes = New-Object System.Collections.Generic.List[byte]
    if ($name -ne [IntPtr]::Zero) {
        for ($i = 0; $i -lt 256; $i++) {
            $b = $Marshal::ReadByte($name, $i)
            if ($b -eq 0) { break }
            $nameBytes.Add($b)
        }
    }
    return @{
        Ugc     = [SteamNative]::SteamUGC()
        Utils   = [SteamNative]::SteamUtils()
        Me      = [SteamNative]::SteamAPI_ISteamUser_GetSteamID([SteamNative]::SteamUser())
        Persona = [System.Text.Encoding]::UTF8.GetString($nameBytes.ToArray())
    }
}

# Waits for an asynchronous Steam call and returns its result struct as bytes.
function Wait-SteamCall($Steam, [uint64]$Call, [int]$Size, [int]$CallbackId, [int]$TimeoutSeconds, [scriptblock]$Tick) {
    $failed = $false
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while (-not [SteamNative]::SteamAPI_ISteamUtils_IsAPICallCompleted($Steam.Utils, $Call, [ref]$failed)) {
        if ((Get-Date) -gt $deadline) { throw 'Steam did not answer in time' }
        [SteamNative]::SteamAPI_RunCallbacks()
        if ($Tick) { & $Tick | Out-Null }
        Start-Sleep -Milliseconds 100
    }
    $buffer = $Marshal::AllocHGlobal($Size)
    try {
        $got = [SteamNative]::SteamAPI_ISteamUtils_GetAPICallResult($Steam.Utils, $Call, $buffer, $Size, $CallbackId, [ref]$failed)
        if (-not $got -or $failed) { throw 'Steam could not complete the request' }
        $bytes = New-Object byte[] $Size
        $Marshal::Copy($buffer, $bytes, 0, $Size)
        return , $bytes
    } finally {
        $Marshal::FreeHGlobal($buffer)
    }
}

# Title of a Project Zomboid workshop item, and whether this account owns it.
function Get-WorkshopItem($Steam, [uint64]$Id) {
    $query = [SteamNative]::SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest($Steam.Ugc, [uint64[]]@($Id), 1)
    $details = $Marshal::AllocHGlobal(32768)
    try {
        $call = [SteamNative]::SteamAPI_ISteamUGC_SendQueryUGCRequest($Steam.Ugc, $query)
        $completed = Wait-SteamCall $Steam $call $QueryCompletedSize $QueryCompletedId 30 $null
        $got = [SteamNative]::SteamAPI_ISteamUGC_GetQueryUGCResult($Steam.Ugc, $query, 0, $details)
        if ([BitConverter]::ToInt32($completed, 8) -ne 1 -or -not $got -or $Marshal::ReadInt32($details, 8) -ne 1) {
            throw "workshop item $Id was not found, or this Steam account cannot see it"
        }
        if ($Marshal::ReadInt32($details, 20) -ne $AppId) { throw "workshop item $Id is not a Project Zomboid mod" }
        $titleBytes = New-Object byte[] 129
        $Marshal::Copy([IntPtr]::Add($details, 24), $titleBytes, 0, 129)
        $end = [Array]::IndexOf($titleBytes, [byte]0)
        if ($end -lt 0) { $end = 129 }
        return @{
            Title = [System.Text.Encoding]::UTF8.GetString($titleBytes, 0, $end)
            Mine  = ([uint64]$Marshal::ReadInt64($details, $OwnerOffset) -eq $Steam.Me)
        }
    } finally {
        [void][SteamNative]::SteamAPI_ISteamUGC_ReleaseQueryUGCRequest($Steam.Ugc, $query)
        $Marshal::FreeHGlobal($details)
    }
}

function Set-WorkshopPreview($Steam, [uint64]$Id, [string]$Image) {
    $update = [SteamNative]::SteamAPI_ISteamUGC_StartItemUpdate($Steam.Ugc, $AppId, $Id)
    $path = [System.Text.Encoding]::UTF8.GetBytes($Image + "`0")
    if (-not [SteamNative]::SteamAPI_ISteamUGC_SetItemPreview($Steam.Ugc, $update, $path)) {
        throw "Steam did not accept $Image as a preview image"
    }
    $call = [SteamNative]::SteamAPI_ISteamUGC_SubmitItemUpdate($Steam.Ugc, $update, [IntPtr]::Zero)

    $shown = New-Object System.Collections.Generic.List[string]
    $tick = {
        $processed = [uint64]0
        $total = [uint64]0
        $status = $UpdateStatus[[SteamNative]::SteamAPI_ISteamUGC_GetItemUpdateProgress($Steam.Ugc, $update, [ref]$processed, [ref]$total)]
        if ($status -and -not $shown.Contains($status)) {
            $shown.Add($status)
            Write-Host "$status..."
        }
    }
    $result = Wait-SteamCall $Steam $call $SubmitResultSize $SubmitResultId 300 $tick
    $code = [BitConverter]::ToInt32($result, 0)
    if ($code -ne 1) {
        $reason = $EResults[$code]
        if (-not $reason) { $reason = "Steam error $code" }
        throw "upload failed: $reason"
    }
    if ($result[4] -ne 0) {
        Write-Host 'note: Steam wants you to accept the Workshop legal agreement: https://steamcommunity.com/sharedfiles/workshoplegalagreement'
    }
}

# Returns @{ Id; Dir }, Dir being set when <mod> is a folder.
function Resolve-Mod([string]$Mod) {
    if (-not $Mod) { throw 'no mod given' }
    if ($Mod -match '^\d+$') { return @{ Id = [uint64]$Mod; Dir = '' } }
    if ($Mod -match '[?&]id=(\d+)') { return @{ Id = [uint64]$Matches[1]; Dir = '' } }
    if (Test-Path -LiteralPath $Mod -PathType Container) {
        $dir = $Mod
    } elseif (Test-Path -LiteralPath (Join-Path $WorkshopDir $Mod) -PathType Container) {
        $dir = Join-Path $WorkshopDir $Mod
    } else {
        throw "'$Mod' is not a workshop ID, a workshop URL or a mod folder"
    }
    $txt = Join-Path $dir 'workshop.txt'
    if (-not (Test-Path -LiteralPath $txt)) { throw "no workshop.txt in $dir" }
    $match = Select-String -LiteralPath $txt -Pattern '^id=\s*(\d+)' | Select-Object -First 1
    if (-not $match) { throw "$txt has no workshop id - give the workshop ID or URL instead" }
    return @{ Id = [uint64]$match.Matches[0].Groups[1].Value; Dir = $dir }
}

# Returns the full path of a GIF that passed the checks.
function Test-Gif([string]$Gif) {
    if (-not (Test-Path -LiteralPath $Gif -PathType Leaf)) { throw "GIF not found: $Gif" }
    $item = Get-Item -LiteralPath $Gif
    $head = New-Object byte[] 10
    $stream = [System.IO.File]::OpenRead($item.FullName)
    try { $read = $stream.Read($head, 0, 10) } finally { $stream.Dispose() }
    if ($read -lt 10 -or [System.Text.Encoding]::ASCII.GetString($head, 0, 3) -ne 'GIF') {
        throw "not a GIF file: $Gif"
    }
    $kb = [math]::Floor($item.Length / 1KB)
    if ($item.Length -ge $MaxBytes) { throw "$Gif is $kb KB - a workshop poster must be under 1 MB" }
    # Logical screen size: two little-endian uint16 at byte 6.
    $w = $head[6] + 256 * $head[7]
    $h = $head[8] + 256 * $head[9]
    if ($w -ne 256 -or $h -ne 256) {
        Write-Host "warning: GIF is ${w}x${h}; workshop posters are meant to be 256x256" -ForegroundColor Yellow
    }
    Write-Host "GIF: $($item.FullName) ($kb KB, ${w}x${h})"
    return $item.FullName
}

function Get-Mods {
    if (-not (Test-Path -LiteralPath $ModsFile)) { return }
    foreach ($line in [System.IO.File]::ReadAllLines($ModsFile, $Utf8NoBom)) {
        $parts = $line -split "`t", 3
        if ($parts.Count -eq 3) { [pscustomobject]@{ Id = $parts[0]; Title = $parts[1]; Gif = $parts[2] } }
    }
}

function Save-Mod([uint64]$Id, [string]$Title, [string]$Gif) {
    $mods = @(Get-Mods)
    $entry = [pscustomobject]@{ Id = "$Id"; Title = $Title.Replace("`t", ' '); Gif = $Gif }
    $known = $false
    for ($i = 0; $i -lt $mods.Count; $i++) {
        if ($mods[$i].Id -eq $entry.Id) {
            $mods[$i] = $entry
            $known = $true
        }
    }
    if (-not $known) { $mods += $entry }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ModsFile) | Out-Null
    $lines = [string[]]@($mods | ForEach-Object { "$($_.Id)`t$($_.Title)`t$($_.Gif)" })
    [System.IO.File]::WriteAllLines($ModsFile, $lines, $Utf8NoBom)
}

function Invoke-Run([string]$Mod, [string]$Gif, [bool]$CheckOnly) {
    $resolved = Resolve-Mod $Mod
    if (-not $Gif) {
        if (-not $resolved.Dir) { throw 'give the GIF path when <mod> is an ID or URL' }
        $Gif = Join-Path $resolved.Dir 'preview.gif'
    }
    $Gif = Test-Gif $Gif
    $url = "https://steamcommunity.com/sharedfiles/filedetails/?id=$($resolved.Id)"

    $steam = Connect-Steam
    try {
        $item = Get-WorkshopItem $steam $resolved.Id
        Write-Host "Steam account: $($steam.Persona)"
        $note = ''
        if (-not $item.Mine) { $note = '  (owned by another account - works only if you are a contributor)' }
        Write-Host "Mod: $($item.Title)$note"
        if ($CheckOnly) {
            Write-Host "Check only - nothing uploaded. Would set the poster of $url"
            return
        }
        Set-WorkshopPreview $steam $resolved.Id $Gif
        Save-Mod $resolved.Id $item.Title $Gif
        Write-Host "Poster updated: $url"
    } finally {
        [SteamNative]::SteamAPI_Shutdown()
    }
}

# Undo what the console does to a dragged-in path: surrounding spaces and quotes.
function Format-PathInput([string]$Text) {
    $p = $Text.Trim()
    if ($p.Length -ge 2 -and ($p[0] -eq '"' -or $p[0] -eq "'") -and $p[$p.Length - 1] -eq $p[0]) {
        $p = $p.Substring(1, $p.Length - 2)
    }
    return $p
}

function Select-Gif {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = 'Choose the GIF poster'
    $dialog.Filter = 'GIF images (*.gif)|*.gif'
    # A topmost owner keeps the dialog from opening behind the console window.
    $owner = New-Object System.Windows.Forms.Form -Property @{ TopMost = $true }
    if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) { return $dialog.FileName }
    return ''
}

function Show-Error($ErrorRecord) {
    Write-Host "error: $($ErrorRecord.Exception.Message)" -ForegroundColor Red
}

function Start-Interactive {
    Write-Host 'GIF Poster - set a GIF as the workshop poster of a Project Zomboid mod'
    Write-Host 'Steam must be running and signed in.'
    $powershell = if ($OnWindows) { (Get-Process -Id $PID).Path } else { 'pwsh' }
    while ($true) {
        $mods = @(Get-Mods)
        Write-Host ''
        for ($i = 0; $i -lt $mods.Count; $i++) {
            Write-Host ("  {0}) {1}  {2}" -f ($i + 1), $mods[$i].Title, $mods[$i].Gif)
        }
        Write-Host '  n) new mod    q) quit'
        Write-Host '> ' -NoNewline
        $choice = Read-Host
        if ($null -eq $choice) { break }
        $choice = $choice.Trim()
        if ($choice -match '^[qQ]$') { break }
        if ($choice -match '^[nN]$') {
            $mod = Format-PathInput (Read-Host 'Workshop link or ID of the mod')
            $gif = Format-PathInput (Read-Host 'GIF file - drag it into this window, or press Enter to choose it')
            if (-not $gif) { $gif = Select-Gif }
            if (-not $gif) { continue }
        } elseif ($choice -match '^\d+$' -and [int]$choice -ge 1 -and [int]$choice -le $mods.Count) {
            $mod = $mods[[int]$choice - 1].Id
            $gif = $mods[[int]$choice - 1].Gif
        } else {
            continue
        }
        # A fresh process per upload: Steam shows the game as running only while one is in progress.
        & $powershell -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath $mod $gif
    }
}

try {
    if ($Argv.Count -eq 0) {
        Start-Interactive
    } elseif ($Argv[0] -eq '-h' -or $Argv[0] -eq '--help' -or $Argv[0] -eq '/?') {
        Show-Usage
    } else {
        $checkOnly = $Argv[0] -eq '-n'
        $rest = @($Argv | Select-Object -Skip ([int]$checkOnly))
        if ($rest.Count -lt 1 -or $rest.Count -gt 2) {
            Show-Usage
            exit 2
        }
        Invoke-Run ([string]$rest[0]) ([string]$rest[1]) $checkOnly
    }
} catch {
    Show-Error $_
    exit 1
}
