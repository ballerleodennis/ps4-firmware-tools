@echo off
setlocal enabledelayedexpansion
title IMG/SLB Extractor
color 0B

set "SELF=%~f0"
set "BATDIR=%~dp0"
set "PSF=%TEMP%\imgslb_%RANDOM%%RANDOM%.ps1"

if "%~1"=="" goto :ask
set "PSARGS=%*"
goto :run

:ask
echo ============================================================
echo  IMG / SLB Extractor
echo ============================================================
echo  Datei oder Ordner hierher ziehen, oder Pfad eintippen.
echo  Beenden mit leerer Eingabe.
echo.
set /p "TARGET=Pfad: "
if "!TARGET!"=="" exit /b 1
set "PSARGS="!TARGET!""

:run
echo.
powershell -NoProfile -ExecutionPolicy Bypass -Command "$l=Get-Content -LiteralPath $env:SELF; $i=[array]::IndexOf($l,'::PS1_START'); if($i -lt 0){Write-Host 'Marker ::PS1_START fehlt.' -ForegroundColor Red; exit 1}; Set-Content -LiteralPath $env:PSF -Value $l[($i+1)..($l.Count-1)] -Encoding UTF8"
if errorlevel 1 goto :cleanup

powershell -NoProfile -ExecutionPolicy Bypass -File "%PSF%" %PSARGS%
set "RC=%ERRORLEVEL%"

:cleanup
del "%PSF%" >nul 2>&1
echo.
if "%~1"=="" pause
exit /b %RC%

::PS1_START
#requires -version 5.1
<#
  IMG / SLB Extractor
  Extrahiert Disk-Images (MBR/GPT/ISO/VHD/VHDX/FAT/NTFS/ext) und
  AutoCAD-Slide-Libraries (.slb) sowie .sld.

  Beispiele:
    extractor.bat "C:\daten\spiel.img"
    extractor.bat "C:\daten\slides.slb" -OutDir "C:\out"
    extractor.bat "C:\daten" -Recurse -Carve
    extractor.bat "C:\daten\roh.img" -List

  Optionen:
    -OutDir <dir>       Zielordner (Standard: _extracted neben der Quelle)
    -List               Nur Format bestimmen, nichts schreiben
    -Recurse            Ordner rekursiv durchsuchen
    -Carve              Signatur-Carving bei unbekannten Rohdaten
    -KeepPartitions     Partition-Rohabbilder behalten
    -Force              Vorhandene Zielordner wiederverwenden
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0, Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$InputPath,
    [string]$OutDir,
    [switch]$List,
    [switch]$Recurse,
    [switch]$Carve,
    [switch]$KeepPartitions,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$script:SevenZip = $null
$script:LogFile  = $null
$script:Count    = 0
$script:Fail     = 0
$script:Seen     = 0

# ------------------------------------------------------------------ Helfer

function Find-SevenZip {
    $cands = @()
    if ($env:SEVENZIP) { $cands += $env:SEVENZIP }
    if ($env:BATDIR)   { $cands += (Join-Path $env:BATDIR '7z.exe'); $cands += (Join-Path $env:BATDIR '7za.exe') }
    $cands += "$env:ProgramFiles\7-Zip\7z.exe"
    $cands += "${env:ProgramFiles(x86)}\7-Zip\7z.exe"
    $cands += "$env:LOCALAPPDATA\Programs\7-Zip\7z.exe"
    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return (Resolve-Path -LiteralPath $c).Path }
    }
    $cmd = Get-Command 7z.exe, 7za.exe, 7zz.exe -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Write-Log {
    param([string]$Msg, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Msg
    switch ($Level) {
        'OK'   { Write-Host $line -ForegroundColor Green }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        'ERR'  { Write-Host $line -ForegroundColor Red }
        'HEAD' { Write-Host $line -ForegroundColor Cyan }
        default { Write-Host $line }
    }
    if ($script:LogFile) { Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8 }
}

function Get-SafeName {
    param([string]$Name)
    $n = $Name.Trim()
    if (-not $n) { return 'unnamed' }
    foreach ($c in ([IO.Path]::GetInvalidFileNameChars())) { $n = $n.Replace($c, '_') }
    $n = $n -replace '\s+', '_'
    $n = $n -replace '_+', '_'
    if ($n.Length -gt 90) { $n = $n.Substring(0, 90) }
    return $n.Trim('_', '.')
}

function New-OutDir {
    param([string]$Base, [string]$Name)
    $d = Join-Path $Base $Name
    $i = 1
    while ((Test-Path -LiteralPath $d) -and -not $Force) {
        $d = Join-Path $Base ('{0}_{1}' -f $Name, $i)
        $i++
    }
    New-Item -ItemType Directory -Path $d -Force | Out-Null
    return $d
}

function Read-Bytes {
    param([string]$Path, [long]$Offset, [int]$Count)
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        if ($Offset -gt 0) { [void]$fs.Seek($Offset, 'Begin') }
        $buf = New-Object byte[] $Count
        $read = $fs.Read($buf, 0, $Count)
        if ($read -le 0) { return @() }
        if ($read -lt $Count) { return $buf[0..($read - 1)] }
        return ,$buf
    } finally { $fs.Dispose() }
}

function Test-Magic {
    param([string]$Path, [long]$Offset, [byte[]]$Magic)
    try { $b = Read-Bytes -Path $Path -Offset $Offset -Count $Magic.Length } catch { return $false }
    if ($b.Length -lt $Magic.Length) { return $false }
    for ($i = 0; $i -lt $Magic.Length; $i++) { if ($b[$i] -ne $Magic[$i]) { return $false } }
    return $true
}

function Get-FileKind {
    param([string]$Path)
    if (Test-Magic $Path 0 ([byte[]](0x1F, 0x8B)))                       { return 'gzip' }
    if (Test-Magic $Path 0 ([byte[]](0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00))) { return 'xz' }
    if (Test-Magic $Path 0 ([byte[]](0x42, 0x5A, 0x68)))                 { return 'bzip2' }
    if (Test-Magic $Path 0 ([byte[]](0x50, 0x4B, 0x03, 0x04)))           { return 'zip' }
    if (Test-Magic $Path 0 ([byte[]](0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C))) { return '7z' }
    if (Test-Magic $Path 0 ([byte[]](0x52, 0x61, 0x72, 0x21)))           { return 'rar' }
    if (Test-Magic $Path 0x8001 ([Text.Encoding]::ASCII.GetBytes('CD001'))) { return 'iso' }
    if (Test-Magic $Path 0 ([Text.Encoding]::ASCII.GetBytes('vhdxfile')))  { return 'vhdx' }
    $len = (Get-Item -LiteralPath $Path).Length
    if ($len -ge 512 -and (Test-Magic $Path ($len - 512) ([Text.Encoding]::ASCII.GetBytes('conectix')))) { return 'vhd' }
    if (Test-Magic $Path 512 ([Text.Encoding]::ASCII.GetBytes('EFI PART'))) { return 'gpt' }
    if (Test-Magic $Path 0x438 ([byte[]](0x53, 0xEF)))                   { return 'ext' }
    if (Test-Magic $Path 0x1FE ([byte[]](0x55, 0xAA))) {
        if (Test-Magic $Path 3 ([Text.Encoding]::ASCII.GetBytes('NTFS')))    { return 'ntfs' }
        if (Test-Magic $Path 0x36 ([Text.Encoding]::ASCII.GetBytes('exFAT'))) { return 'fat' }
        if (Test-Magic $Path 0x36 ([Text.Encoding]::ASCII.GetBytes('FAT')))   { return 'fat' }
        if (Test-Magic $Path 0x52 ([Text.Encoding]::ASCII.GetBytes('FAT32'))) { return 'fat' }
        return 'mbr'
    }
    return 'raw'
}

function Copy-Range {
    param([string]$Path, [long]$Offset, [long]$Length, [string]$Dest)
    $src = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $out = [IO.File]::Create($Dest)
        try {
            [void]$src.Seek($Offset, 'Begin')
            $buf = New-Object byte[] (1MB)
            $rest = $Length
            while ($rest -gt 0) {
                $want = [int][Math]::Min($buf.Length, $rest)
                $r = $src.Read($buf, 0, $want)
                if ($r -le 0) { break }
                $out.Write($buf, 0, $r)
                $rest -= $r
            }
        } finally { $out.Dispose() }
    } finally { $src.Dispose() }
}

function Invoke-SevenZip {
    param([string]$Archive, [string]$Dest)
    if (-not $script:SevenZip) {
        Write-Log '  7-Zip nicht gefunden - Dateisystem wird uebersprungen.' 'WARN'
        return $false
    }
    $errFile = Join-Path $env:TEMP ('7zerr_' + [Guid]::NewGuid().ToString('N') + '.txt')
    $args = @('x', '-y', '-bd', '-bso0', '-bsp0', "-o$Dest", '--', $Archive)
    $p = Start-Process -FilePath $script:SevenZip -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardError $errFile
    if ($p.ExitCode -eq 0) { Remove-Item $errFile -Force -ErrorAction SilentlyContinue; return $true }
    $err = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
    Remove-Item $errFile -Force -ErrorAction SilentlyContinue
    Write-Log ('  7-Zip ExitCode {0}: {1}' -f $p.ExitCode, ($err -replace '\s+', ' ').Trim()) 'WARN'
    return $false
}

function Mount-And-Copy {
    param([string]$Path, [string]$Dest)
    $img = $null
    try {
        $img = Mount-DiskImage -ImagePath $Path -PassThru -ErrorAction Stop
        $vols = @($img | Get-Volume -ErrorAction Stop | Where-Object { $_.DriveLetter })
        if ($vols.Count -eq 0) { throw 'Kein Laufwerksbuchstabe vergeben' }
        foreach ($v in $vols) {
            Copy-Item -Path ("{0}:\*" -f $v.DriveLetter) -Destination $Dest -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log ('  Kopiert von {0}:' -f $v.DriveLetter) 'OK'
        }
        return $true
    } catch {
        Write-Log ('  Mount fehlgeschlagen: ' + $_.Exception.Message) 'WARN'
        return $false
    } finally {
        if ($img) { Dismount-DiskImage -ImagePath $Path -ErrorAction SilentlyContinue }
    }
}

function Get-Partitions {
    param([string]$Path, [string]$Kind)
    $parts = @()
    if ($Kind -eq 'mbr') {
        $tbl = Read-Bytes -Path $Path -Offset 0x1BE -Count 64
        if ($tbl.Length -lt 64) { return @() }
        for ($i = 0; $i -lt 4; $i++) {
            $e = $tbl[($i * 16)..($i * 16 + 15)]
            $type = $e[4]
            if ($type -eq 0) { continue }
            $start = [BitConverter]::ToUInt32($e, 8)
            $cnt   = [BitConverter]::ToUInt32($e, 12)
            if ($cnt -eq 0) { continue }
            $parts += [pscustomobject]@{
                Index = $i + 1
                Type  = ('0x{0:X2}' -f $type)
                Offset = ([long]$start * 512)
                Length = ([long]$cnt * 512)
                Label  = ('partition{0}_t{1:X2}' -f ($i + 1), $type)
            }
        }
    } elseif ($Kind -eq 'gpt') {
        $hdr = Read-Bytes -Path $Path -Offset 512 -Count 92
        if ($hdr.Length -lt 92) { return @() }
        $entryLba = [BitConverter]::ToUInt64($hdr, 72)
        $num      = [BitConverter]::ToUInt32($hdr, 80)
        $esz      = [BitConverter]::ToUInt32($hdr, 84)
        if ($esz -lt 128 -or $esz -gt 4096) { $esz = 128 }
        if ($num -gt 256) { $num = 256 }
        $tbl = Read-Bytes -Path $Path -Offset ([long]$entryLba * 512) -Count ([int]($num * $esz))
        if ($tbl.Length -lt 128) { return @() }
        for ($i = 0; $i -lt $num; $i++) {
            $base = $i * $esz
            if ($base + $esz -gt $tbl.Length) { break }
            $isZero = $true
            for ($j = 0; $j -lt 16; $j++) { if ($tbl[$base + $j] -ne 0) { $isZero = $false; break } }
            if ($isZero) { continue }
            $first = [BitConverter]::ToUInt64($tbl, $base + 32)
            $last  = [BitConverter]::ToUInt64($tbl, $base + 40)
            if ($last -lt $first) { continue }
            $parts += [pscustomobject]@{
                Index = $i + 1
                Type  = 'GPT'
                Offset = ([long]$first * 512)
                Length = ([long](($last - $first + 1) * 512))
                Label  = ('partition{0}' -f ($i + 1))
            }
        }
    }
    return $parts
}

# ------------------------------------------------------------- SLB / SLD

function Expand-SlideLibrary {
    param([string]$Path, [string]$Dest)
    $len = (Get-Item -LiteralPath $Path).Length
    $fs  = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    $idx = 0
    $bad = 0
    try {
        $pos = 0L
        while ($pos -lt $len) {
            if ($len - $pos -lt 64) { break }
            $fs.Position = $pos
            $nameBuf = New-Object byte[] 32
            if ($fs.Read($nameBuf, 0, 32) -ne 32) { break }
            $name  = ([Text.Encoding]::ASCII.GetString($nameBuf)).Trim([char]0, ' ')
            $valid = $name.Length -gt 0
            if ($valid) {
                foreach ($ch in $name.ToCharArray()) {
                    if ([int]$ch -lt 0x20 -or [int]$ch -gt 0x7E) { $valid = $false; break }
                }
            }
            if ($valid) {
                $hdr = New-Object byte[] 32
                if ($fs.Read($hdr, 0, 32) -lt 32 -or $hdr[0] -ne 0x41) { $valid = $false }
            }
            if (-not $valid) {
                $pos++
                $bad++
                if ($bad -gt 8192) { break }
                continue
            }
            $bad = 0
            $start = $fs.Position - 32
            $end   = 0L
            $ok    = $true
            while ($true) {
                if ($fs.Position + 2 -gt $len) { $ok = $false; break }
                $two = New-Object byte[] 2
                if ($fs.Read($two, 0, 2) -ne 2) { $ok = $false; break }
                $w  = [BitConverter]::ToUInt16($two, 0)
                $op = [int]($w -band 3)
                $sz = [int]($w -shr 2)
                $adv = 0
                if ($op -eq 0) { $adv = 4 + $sz }
                elseif ($op -eq 1 -or $op -eq 2) { $adv = 6 + $sz * 8 }
                if ($fs.Position + $adv -gt $len) { $ok = $false; break }
                if ($adv -gt 0) { [void]$fs.Seek($adv, 'Current') }
                if ($op -eq 3) { $end = $fs.Position; break }
            }
            if (-not $ok -or $end -le $start) { $pos++; continue }

            $idx++
            $outPath = Join-Path $Dest ((Get-SafeName $name) + '.sld')
            $k = 1
            while (Test-Path -LiteralPath $outPath) {
                $outPath = Join-Path $Dest ('{0}_{1}.sld' -f (Get-SafeName $name), $k)
                $k++
            }
            Copy-Range -Path $Path -Offset $start -Length ($end - $start) -Dest $outPath
            Write-Log ('  Slide {0} ({1:N0} Bytes)' -f (Split-Path $outPath -Leaf), ($end - $start)) 'OK'
            $pos = $end
        }
    } finally { $fs.Dispose() }

    if ($idx -eq 0) { Write-Log '  Keine Slide-Records gefunden.' 'WARN'; return $false }
    return $true
}

# ---------------------------------------------------------------- Carving

function Invoke-Carve {
    param([string]$Path, [string]$Dest)
    $enc = [Text.Encoding]::GetEncoding(28591)
    $sigs = @(
        @{ Ext = 'jpg'; Pat = [byte[]](0xFF, 0xD8, 0xFF);          Max = 20MB },
        @{ Ext = 'png'; Pat = [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A); Max = 20MB },
        @{ Ext = 'gif'; Pat = [byte[]](0x47, 0x49, 0x46, 0x38);    Max = 5MB  },
        @{ Ext = 'bmp'; Pat = [byte[]](0x42, 0x4D);                Max = 10MB },
        @{ Ext = 'pdf'; Pat = [byte[]](0x25, 0x50, 0x44, 0x46, 0x2D); Max = 20MB },
        @{ Ext = 'zip'; Pat = [byte[]](0x50, 0x4B, 0x03, 0x04);    Max = 50MB },
        @{ Ext = 'ogg'; Pat = [byte[]](0x4F, 0x67, 0x67, 0x53);    Max = 20MB },
        @{ Ext = 'wav'; Pat = [byte[]](0x52, 0x49, 0x46, 0x46);    Max = 20MB },
        @{ Ext = 'mp3'; Pat = [byte[]](0x49, 0x44, 0x33);          Max = 20MB }
    )
    $prep = foreach ($s in $sigs) { [pscustomobject]@{ Ext = $s.Ext; Pat = $enc.GetString($s.Pat); Max = $s.Max } }
    $maxLen = 8
    $win    = 8MB
    $size   = (Get-Item -LiteralPath $Path).Length
    $hits   = New-Object System.Collections.Generic.List[object]

    Write-Log '  Carving laeuft...'
    $fs = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
    try {
        $buf = New-Object byte[] ($win + $maxLen)
        $pos = 0L
        while ($pos -lt $size -and $hits.Count -lt 20000) {
            [void]$fs.Seek($pos, 'Begin')
            $r = $fs.Read($buf, 0, $buf.Length)
            if ($r -le 0) { break }
            $txt = $enc.GetString($buf, 0, $r)
            foreach ($s in $prep) {
                $i = 0
                while (($i = $txt.IndexOf($s.Pat, $i, [StringComparison]::Ordinal)) -ge 0) {
                    $hits.Add([pscustomobject]@{ Offset = ($pos + $i); Ext = $s.Ext; Max = $s.Max })
                    $i++
                }
            }
            $pos += $win
        }
    } finally { $fs.Dispose() }

    $sorted = $hits | Sort-Object Offset
    $n = 0
    for ($k = 0; $k -lt $sorted.Count; $k++) {
        $h = $sorted[$k]
        if ($h.Offset -lt 0 -or $h.Offset -ge $size) { continue }
        $nextOff = if ($k + 1 -lt $sorted.Count) { $sorted[$k + 1].Offset } else { $size }
        $l = [Math]::Min($nextOff - $h.Offset, $h.Max)
        if ($l -lt 16) { $l = [Math]::Min(16, $size - $h.Offset) }
        if ($l -le 0) { continue }
        $n++
        $out = Join-Path $Dest ('carved_{0:D5}_{1:x8}.{2}' -f $n, $h.Offset, $h.Ext)
        Copy-Range -Path $Path -Offset $h.Offset -Length $l -Dest $out
    }
    Write-Log ('  {0} Treffer ausgeschnitten.' -f $n) 'OK'
    return ($n -gt 0)
}

# -------------------------------------------------------------- Dispatcher

function Invoke-Target {
    param([string]$Path, [int]$Depth = 0)

    try { $file = Get-Item -LiteralPath $Path -ErrorAction Stop } catch {
        Write-Log ('Nicht lesbar: ' + $Path) 'ERR'; $script:Fail++; return
    }
    if ($file.Length -eq 0) { Write-Log ('Leer: ' + $file.Name) 'WARN'; return }

    $script:Seen++
    $ext  = $file.Extension.ToLowerInvariant()
    $kind = if ($ext -eq '.slb' -or $ext -eq '.sld') { 'slb' } else { Get-FileKind -Path $Path }
    Write-Log ('{0}  [{1}, {2:N0} Bytes]' -f $file.Name, $kind, $file.Length) 'HEAD'
    if ($List) { return }

    $dest = New-OutDir -Base $OutDir -Name (Get-SafeName $file.BaseName)

    switch ($kind) {
        'slb' {
            if ($ext -eq '.sld') {
                Copy-Item -LiteralPath $Path -Destination (Join-Path $dest $file.Name) -Force
                Write-Log '  Einzelne Slide uebernommen.' 'OK'
                $script:Count++
            } elseif (Expand-SlideLibrary -Path $Path -Dest $dest) { $script:Count++ }
            else { $script:Fail++ }
        }
        { $_ -in 'zip', '7z', 'rar', 'gzip', 'xz', 'bzip2' } {
            if (Invoke-SevenZip -Archive $Path -Dest $dest) {
                $script:Count++
                if ($Depth -lt 2) {
                    Get-ChildItem -LiteralPath $dest -Recurse -File -ErrorAction SilentlyContinue |
                        Where-Object { $_.Extension -in '.img', '.slb' } |
                        ForEach-Object { Invoke-Target -Path $_.FullName -Depth ($Depth + 1) }
                }
            } else { $script:Fail++ }
        }
        { $_ -in 'iso', 'vhd', 'vhdx' } {
            if (Mount-And-Copy -Path $Path -Dest $dest) { $script:Count++ }
            elseif (Invoke-SevenZip -Archive $Path -Dest $dest) { $script:Count++ }
            else { $script:Fail++ }
        }
        { $_ -in 'mbr', 'gpt' } {
            $parts = @(Get-Partitions -Path $Path -Kind $kind)
            if ($parts.Count -eq 0) {
                Write-Log '  Keine Partitionseintraege lesbar.' 'WARN'
                if ($Carve) { if (Invoke-Carve -Path $Path -Dest $dest) { $script:Count++ } else { $script:Fail++ } }
                else { $script:Fail++ }
                return
            }
            foreach ($p in $parts) {
                if ($p.Offset -le 0 -or $p.Length -le 0) { continue }
                $pf = Join-Path $dest ('{0}.bin' -f $p.Label)
                Copy-Range -Path $Path -Offset $p.Offset -Length $p.Length -Dest $pf
                Write-Log ('  Partition {0} ({1}) -> {2} ({3:N0} Bytes)' -f $p.Index, $p.Type, (Split-Path $pf -Leaf), $p.Length) 'OK'
                $sub = New-OutDir -Base $dest -Name ('{0}_files' -f $p.Label)
                $got = Invoke-SevenZip -Archive $pf -Dest $sub
                if ($got) { Write-Log ('  Dateisystem von Partition {0} entpackt.' -f $p.Index) 'OK' }
                else { Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue }
                if (-not $KeepPartitions) { Remove-Item -LiteralPath $pf -Force -ErrorAction SilentlyContinue }
            }
            $script:Count++
        }
        { $_ -in 'fat', 'ntfs', 'ext' } {
            if (Invoke-SevenZip -Archive $Path -Dest $dest) { $script:Count++ } else { $script:Fail++ }
        }
        default {
            if (Invoke-SevenZip -Archive $Path -Dest $dest) { $script:Count++ }
            elseif ($Carve) {
                if (Invoke-Carve -Path $Path -Dest $dest) { $script:Count++ } else { $script:Fail++ }
            } else {
                Write-Log '  Format unbekannt. Mit -Carve Signatur-Carving versuchen oder 7-Zip installieren.' 'WARN'
                $script:Fail++
            }
        }
    }
}

# -------------------------------------------------------------------- Main

$script:SevenZip = Find-SevenZip

if (-not $OutDir) {
    $first = Resolve-Path -LiteralPath $InputPath[0] -ErrorAction SilentlyContinue
    $baseDir = if ($first) {
        $p = $first.Path
        if (Test-Path -LiteralPath $p -PathType Container) { $p } else { Split-Path -Parent $p }
    } else { (Get-Location).Path }
    $OutDir = Join-Path $baseDir '_extracted'
}
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$script:LogFile = Join-Path $OutDir ('log_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')

Write-Log '=== IMG/SLB Extractor gestartet ===' 'HEAD'
Write-Log ('Ziel: ' + (Resolve-Path -LiteralPath $OutDir).Path)
if ($script:SevenZip) { Write-Log ('7-Zip: ' + $script:SevenZip) }
else {
    Write-Log '7-Zip wurde nicht gefunden. Partitionen und Slide-Libraries werden trotzdem verarbeitet,' 'WARN'
    Write-Log 'Dateisysteme in Images aber nicht. Download: https://www.7-zip.org/download.html' 'WARN'
}
if (-not $Carve) { Write-Log 'Tipp: -Carve aktiviert Signatur-Carving fuer unbekannte Rohdaten.' }

$targets = @()
foreach ($p in $InputPath) {
    $rp = Resolve-Path -LiteralPath $p -ErrorAction SilentlyContinue
    if (-not $rp) { Write-Log ('Pfad nicht gefunden: ' + $p) 'ERR'; $script:Fail++; continue }
    $item = Get-Item -LiteralPath $rp.Path
    if ($item.PSIsContainer) {
        $flt = if ($Recurse) { @('*.img', '*.slb', '*.sld') } else { @() }
        $found = if ($Recurse) { Get-ChildItem -LiteralPath $item.FullName -Recurse -File -Include $flt -ErrorAction SilentlyContinue }
                 else { Get-ChildItem -LiteralPath $item.FullName -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.img', '.slb', '.sld' } }
        $targets += @($found | ForEach-Object { $_.FullName })
    } else { $targets += $item.FullName }
}

if ($targets.Count -eq 0) {
    Write-Log 'Keine passenden Dateien (.img/.slb/.sld) gefunden.' 'WARN'
} else {
    foreach ($t in ($targets | Select-Object -Unique)) { Invoke-Target -Path $t }
}

Write-Log '=== Fertig ===' 'HEAD'
Write-Log ('Bearbeitet: {0}   Fehlgeschlagen: {1}' -f $script:Count, $script:Fail)
Write-Log ('Protokoll: ' + $script:LogFile)
if ($script:Fail -gt 0) { exit 1 } else { exit 0 }