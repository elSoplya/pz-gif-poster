# Steam connection check for the GIF Poster approach (Windows). Uploads nothing.
#
# Double-click "Steam Check.bat". It connects to the running Steam app the way
# Project Zomboid does, looks one workshop mod up, disconnects, then watches for
# 20 seconds whether Steam stayed signed in. Everything it prints is also saved
# to steamcheck_report.txt next to this file. No account names or ids are
# written to the report.
#
#     "Steam Check.bat" [workshop id]      default: 3728582856
#
# While it is connected, Steam shows you as playing Project Zomboid.
# STEAM_API_LIB overrides which steam_api64.dll is loaded.

# Keep this file ASCII-only: Windows PowerShell 5.1 reads it as ANSI.

$ErrorActionPreference = 'Stop'

$AppId = 108600 # Project Zomboid
$ItemId = if ($args.Count -gt 0) { [uint64]$args[0] } else { [uint64]3728582856 }
$OnWindows = $env:OS -eq 'Windows_NT'
$Report = Join-Path $PSScriptRoot 'steamcheck_report.txt'
$Marshal = [System.Runtime.InteropServices.Marshal]
# Callback id and size of SteamUGCQueryCompleted_t, and field offsets in SteamUGCDetails_t.
# Steamworks packs structs to 8 bytes on Windows and to 4 elsewhere, which moves the owner field.
$QueryCompletedId = 3401
$QueryCompletedSize = 280
$OwnerOffset = if ($OnWindows) { 8160 } else { 8156 }

function Say([string]$Text) {
    Write-Host $Text
    Add-Content -LiteralPath $Report -Value $Text -Encoding UTF8
}

function Hide-Ids([string]$Text) {
    return (($Text -replace '\[U:1:\d+\]', '[U:1:<id>]') -replace '7656\d{13}', '<steamid>')
}

function Get-SteamPath {
    if (-not $OnWindows) { return $null }
    $key = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -ErrorAction SilentlyContinue
    if ($key -and $key.SteamPath) { return ($key.SteamPath -replace '/', '\') }
    return $null
}

# Running: steam.exe exists. SignedIn: the registry's ActiveUser is not 0.
function Get-SteamState {
    $key = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam\ActiveProcess' -ErrorAction SilentlyContinue
    return @{
        Running  = [bool](Get-Process -Name steam -ErrorAction SilentlyContinue)
        SignedIn = [bool]($key -and $key.ActiveUser -ne 0)
    }
}

function Find-SteamApiLibrary([string]$SteamPath) {
    if ($env:STEAM_API_LIB) { return $env:STEAM_API_LIB }
    if (-not $SteamPath) { return $null }
    $folders = @($SteamPath)
    $vdf = Join-Path $SteamPath 'steamapps\libraryfolders.vdf'
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

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    [return: MarshalAs(UnmanagedType.I1)]
    public static extern bool SteamAPI_ISteamUser_BLoggedOn(IntPtr self);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern ulong SteamAPI_ISteamUser_GetSteamID(IntPtr self);

    [DllImport(Lib, CallingConvention = CallingConvention.Cdecl)]
    public static extern uint SteamAPI_ISteamUtils_GetAppID(IntPtr self);

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
}
'@
    $source = $source.Replace('LIBRARY', $Library)
    $source = $source.Replace('UGC_ACCESSOR', $Accessors.UGC)
    $source = $source.Replace('UTILS_ACCESSOR', $Accessors.Utils)
    $source = $source.Replace('USER_ACCESSOR', $Accessors.User)
    Add-Type -TypeDefinition $source
}

# Title and owner of a workshop item, read through the connected Steam app.
function Get-WorkshopItem($Ugc, $Utils, [uint64]$Id) {
    $query = [SteamNative]::SteamAPI_ISteamUGC_CreateQueryUGCDetailsRequest($Ugc, [uint64[]]@($Id), 1)
    $completed = $Marshal::AllocHGlobal($QueryCompletedSize)
    $details = $Marshal::AllocHGlobal(32768)
    try {
        $call = [SteamNative]::SteamAPI_ISteamUGC_SendQueryUGCRequest($Ugc, $query)
        $failed = $false
        $deadline = (Get-Date).AddSeconds(30)
        while (-not [SteamNative]::SteamAPI_ISteamUtils_IsAPICallCompleted($Utils, $call, [ref]$failed)) {
            if ((Get-Date) -gt $deadline) { throw 'Steam did not answer the lookup within 30 seconds' }
            [SteamNative]::SteamAPI_RunCallbacks()
            Start-Sleep -Milliseconds 100
        }
        $got = [SteamNative]::SteamAPI_ISteamUtils_GetAPICallResult(
            $Utils, $call, $completed, $QueryCompletedSize, $QueryCompletedId, [ref]$failed)
        if (-not $got -or $failed) { throw 'Steam could not complete the lookup' }
        $queryResult = $Marshal::ReadInt32($completed, 8)
        $hasDetails = [SteamNative]::SteamAPI_ISteamUGC_GetQueryUGCResult($Ugc, $query, 0, $details)
        $titleBytes = New-Object byte[] 129
        $Marshal::Copy([IntPtr]::Add($details, 24), $titleBytes, 0, 129)
        $end = [Array]::IndexOf($titleBytes, [byte]0)
        if ($end -lt 0) { $end = 129 }
        return @{
            QueryResult = $queryResult
            HasDetails  = $hasDetails
            ItemResult  = $Marshal::ReadInt32($details, 8)
            ConsumerApp = $Marshal::ReadInt32($details, 20)
            Title       = [System.Text.Encoding]::UTF8.GetString($titleBytes, 0, $end)
            Owner       = [uint64]$Marshal::ReadInt64($details, $OwnerOffset)
        }
    } finally {
        [void][SteamNative]::SteamAPI_ISteamUGC_ReleaseQueryUGCRequest($Ugc, $query)
        $Marshal::FreeHGlobal($completed)
        $Marshal::FreeHGlobal($details)
    }
}

# Lines appended to a log file after $Offset. Steam keeps the file open, hence the shared read.
function Get-NewLogLines([string]$Path, [long]$Offset) {
    $stream = New-Object System.IO.FileStream($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        if ($stream.Length -ge $Offset) { [void]$stream.Seek($Offset, [System.IO.SeekOrigin]::Begin) }
        $text = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
    } finally {
        $stream.Dispose()
    }
    return @($text -split "`r?`n" | Where-Object { $_ })
}

function Invoke-Check {
    Say 'GIF Poster - Steam connection check (uploads nothing)'
    Say ("Time: {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Say ("PowerShell {0}, 64-bit process: {1}" -f $PSVersionTable.PSVersion, [Environment]::Is64BitProcess)
    if (-not [Environment]::Is64BitProcess) { throw 'this needs 64-bit PowerShell' }

    $steamPath = Get-SteamPath
    Say "Steam folder: $steamPath"
    if ($OnWindows) {
        $before = Get-SteamState
        Say ("Before: Steam running: {0}, signed in: {1}" -f $before.Running, $before.SignedIn)
    }

    $library = Find-SteamApiLibrary $steamPath
    if (-not $library -or -not (Test-Path -LiteralPath $library)) {
        throw 'steam_api64.dll was not found - is Project Zomboid installed through Steam on this PC?'
    }
    $file = Get-Item -LiteralPath $library
    Say "Steam library: $($file.FullName)"
    Say ("  size {0} bytes, modified {1}, file version {2}" -f $file.Length, $file.LastWriteTime.ToString('yyyy-MM-dd'), $file.VersionInfo.FileVersion)

    # Exported names are plain ASCII inside the file.
    $text = [System.Text.Encoding]::GetEncoding(28591).GetString([System.IO.File]::ReadAllBytes($library))
    $accessors = @{}
    foreach ($name in 'UGC', 'Utils', 'User') {
        $accessors[$name] = [regex]::Match($text, "SteamAPI_Steam${name}_v\d{3}").Value
    }
    $hasInitFlat = $text.Contains('SteamAPI_InitFlat')
    Say ("  exports: InitFlat {0}; accessors: {1}, {2}, {3}" -f $hasInitFlat, $accessors.UGC, $accessors.Utils, $accessors.User)
    Say ("  interface strings: {0}" -f (([regex]::Matches($text, 'STEAMUGC_INTERFACE_VERSION\d+|SteamUtils\d{3}|SteamUser\d{3}|SteamClient\d{3}') |
        ForEach-Object { $_.Value } | Sort-Object -Unique) -join ', '))
    if (-not $hasInitFlat -or ($accessors.Values -contains '')) {
        throw 'this copy of the game ships an older Steam library than the check supports'
    }

    $logFile = if ($steamPath) { Join-Path $steamPath 'logs\connection_log.txt' } else { $null }
    $logOffset = if ($logFile -and (Test-Path -LiteralPath $logFile)) { (Get-Item -LiteralPath $logFile).Length } else { 0 }

    $env:SteamAppId = "$AppId"
    $env:SteamGameId = "$AppId"
    Say 'Step 1 - load the library'
    Add-SteamNative $library $accessors
    $steamRunning = [SteamNative]::SteamAPI_IsSteamRunning()
    Say "  library says Steam is running: $steamRunning"
    if (-not $steamRunning) { throw 'Steam is not running - start Steam, sign in, and run this again' }

    Say 'Step 2 - connect as Project Zomboid'
    $message = New-Object byte[] 1024
    $init = [SteamNative]::SteamAPI_InitFlat($message)
    if ($init -ne 0) {
        $end = [Math]::Max(0, [Array]::IndexOf($message, [byte]0))
        throw ("could not connect (code {0}): {1}" -f $init, [System.Text.Encoding]::ASCII.GetString($message, 0, $end))
    }
    try {
        $ugc = [SteamNative]::SteamUGC()
        $utils = [SteamNative]::SteamUtils()
        $user = [SteamNative]::SteamUser()
        $me = [SteamNative]::SteamAPI_ISteamUser_GetSteamID($user)
        Say ("  connected; logged on: {0}; app id seen by Steam: {1}; got a Steam id: {2}" -f
            [SteamNative]::SteamAPI_ISteamUser_BLoggedOn($user), [SteamNative]::SteamAPI_ISteamUtils_GetAppID($utils), ($me -ne 0))

        Say "Step 3 - look up workshop item $ItemId"
        $item = Get-WorkshopItem $ugc $utils $ItemId
        Say ("  query result {0}, details returned {1}, item result {2} (1 means OK)" -f $item.QueryResult, $item.HasDetails, $item.ItemResult)
        Say ("  title: {0}" -f $item.Title)
        Say ("  is a Project Zomboid item: {0}; owned by this account: {1}" -f ($item.ConsumerApp -eq $AppId), ($item.Owner -eq $me))
    } finally {
        Say 'Step 4 - disconnect'
        [SteamNative]::SteamAPI_Shutdown()
    }

    if (-not $OnWindows) { return }
    Say 'Step 5 - waiting 20 seconds, then checking whether Steam stayed signed in'
    Start-Sleep -Seconds 20
    $after = Get-SteamState
    Say ("  After: Steam running: {0}, signed in: {1}" -f $after.Running, $after.SignedIn)
    $kicked = @()
    if ($logFile -and (Test-Path -LiteralPath $logFile)) {
        $kicked = @(Get-NewLogLines $logFile $logOffset |
            Where-Object { $_ -match 'LoggedOff|Logged In Elsewhere|Log session ended' })
        Say ("  Steam connection log: {0} new line(s) about being logged off" -f $kicked.Count)
        foreach ($line in $kicked) { Say ('    ' + (Hide-Ids $line)) }
    } else {
        Say '  Steam connection log: not found'
    }
    if ($after.Running -and $after.SignedIn -and $kicked.Count -eq 0) {
        Say 'RESULT: Steam on this PC stayed signed in.'
    } else {
        Say 'RESULT: Steam on this PC was signed out or closed during the check.'
    }
}

if (Test-Path -LiteralPath $Report) { Remove-Item -LiteralPath $Report }
try {
    Invoke-Check
    $code = 0
} catch {
    Say "STOPPED: $($_.Exception.Message)"
    $code = 1
}
Write-Host ''
Write-Host "Report saved to $Report"
exit $code
