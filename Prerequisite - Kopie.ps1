#Requires -Version 7.5
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------- Hilfsfunktionen ----------------------

function Test-IsAdmin {
    $principal = [Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent()
    )
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-Module {
    param(
        [Parameter(Mandatory)][string] $Name,
        [version] $MinVersion = '0.0.0'
    )

    Write-Host "Modul $Name prüfen..." -ForegroundColor DarkCyan

    $installed = Get-InstalledModule -Name $Name -ErrorAction SilentlyContinue

    if (-not $installed -or $installed.Version -lt $MinVersion) {
        Write-Host "Installiere/Aktualisiere $Name (min. $MinVersion)..." -ForegroundColor DarkCyan
        Install-Module $Name -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
    }
}

function Invoke-CleanPwsh {
    param(
        [Parameter(Mandatory)][scriptblock] $ScriptBlock
    )

    # ScriptBlock als EncodedCommand starten (Unicode/Base64)
    $encodedCommand = [Convert]::ToBase64String(
        [Text.Encoding]::Unicode.GetBytes($ScriptBlock.ToString())
    )

    # Aktueller pwsh-Pfad (sicherer als "pwsh" im PATH)
    $pwshPath = (Get-Process -Id $PID).Path

    # Output-Dateien anlegen
    $stdoutFile = [IO.Path]::GetTempFileName()
    $stderrFile = [IO.Path]::GetTempFileName()

    try {
        $process = Start-Process `
            -FilePath $pwshPath `
            -ArgumentList @(
                '-NoProfile',
                '-NonInteractive',
                '-EncodedCommand', $encodedCommand
            ) `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError  $stderrFile `
            -Wait `
            -PassThru

        $stdout = Get-Content $stdoutFile -Raw
        $stderr = Get-Content $stderrFile -Raw

        [pscustomobject]@{
            ExitCode = $process.ExitCode
            StdOut   = $stdout.Trim()
            StdErr   = $stderr.Trim()
        }
    }
    finally {
        Remove-Item $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
    }
}

# ---------------------- Admin Check ----------------------

if (-not (Test-IsAdmin)) {
    Write-Warning "Dieses Skript muss als Administrator ausgeführt werden. Bitte PowerShell 'Als Administrator ausführen'."
    exit 1
}

# ---------------------- Modul-Voraussetzungen ----------------------

Write-Host "Überprüfe Voraussetzungen..." -ForegroundColor Cyan

# MinVersion optional anpassen (oder weglassen)
Ensure-Module -Name ExchangeOnlineManagement -MinVersion '3.6.0'
Ensure-Module -Name MicrosoftTeams          -MinVersion '5.0.0'

Write-Host "Alle Module vorhanden." -ForegroundColor Green

# ---------------------- Exchange Online (Clean Session) ----------------------

Write-Host "Verbinde zu Exchange Online (isolierte Session)..." -ForegroundColor Cyan

$exoResult = Invoke-CleanPwsh {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module ExchangeOnlineManagement -ErrorAction Stop

    try {
        Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
        "EXO_CONNECTED"
        # Optional sauber trennen:
        Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue | Out-Null
        exit 0
    }
    catch {
        Write-Error ("EXO_CONNECT_FAILED: " + $_.Exception.Message)
        exit 10
    }
}

if ($exoResult.ExitCode -ne 0) {
    Write-Host "Exchange Online Verbindung FEHLGESCHLAGEN (ExitCode $($exoResult.ExitCode))" -ForegroundColor Red
    if ($exoResult.StdErr) { Write-Host $exoResult.StdErr -ForegroundColor DarkRed }
    if ($exoResult.StdOut) { Write-Host $exoResult.StdOut -ForegroundColor DarkYellow }
    exit 10
}

Write-Host "Exchange Online Verbindung erfolgreich." -ForegroundColor Green

# ---------------------- Microsoft Teams (Clean Session) ----------------------

Write-Host "Verbinde zu Microsoft Teams (isolierte Session)..." -ForegroundColor Cyan

$teamsResult = Invoke-CleanPwsh {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    Import-Module MicrosoftTeams -ErrorAction Stop

    try {
        Connect-MicrosoftTeams -ErrorAction Stop | Out-Null
        "TEAMS_CONNECTED"
        # Optional sauber trennen:
        Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue | Out-Null
        exit 0
    }
    catch {
        Write-Error ("TEAMS_CONNECT_FAILED: " + $_.Exception.Message)
        exit 20
    }
}

if ($teamsResult.ExitCode -ne 0) {
    Write-Host "Microsoft Teams Verbindung FEHLGESCHLAGEN (ExitCode $($teamsResult.ExitCode))" -ForegroundColor Red
    if ($teamsResult.StdErr) { Write-Host $teamsResult.StdErr -ForegroundColor DarkRed }
    if ($teamsResult.StdOut) { Write-Host $teamsResult.StdOut -ForegroundColor DarkYellow }
    exit 20
}

Write-Host "Microsoft Teams Verbindung erfolgreich." -ForegroundColor Green

# ---------------------- Fertig ----------------------

Write-Host "Alle Verbindungen erfolgreich hergestellt." -ForegroundColor Cyan
exit 0