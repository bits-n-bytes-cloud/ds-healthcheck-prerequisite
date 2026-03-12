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

Ensure-Module -Name ExchangeOnlineManagement -MinVersion '3.6.0'
Ensure-Module -Name MicrosoftTeams          -MinVersion '5.0.0'
Ensure-Module -Name Microsoft.Graph         -MinVersion '2.0.0'

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

# ---------------------- Tenant Infos via Microsoft Graph (Option 1: Interactive) ----------------------

Write-Host "Lese Tenant-ID, Firmenname und angemeldeten Benutzer via Microsoft Graph (Interactive Login)..." -ForegroundColor Cyan

try {
    Import-Module Microsoft.Graph -ErrorAction Stop

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    try { Remove-MgGraphContext -Scope Process -ErrorAction SilentlyContinue | Out-Null } catch {}

    Connect-MgGraph `
        -Scopes "Organization.Read.All" `
        -ContextScope Process `
        -ClientTimeout 120 `
        -NoWelcome `
        -WarningAction SilentlyContinue `
        -ErrorAction Stop | Out-Null

    # Aktueller Graph-Context (liefert UPN/E-Mail)
    $ctx = Get-MgContext
    $loggedInUser = $ctx.Account

    # Tenant Infos
    $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1

    Write-Host "Tenant-Informationen erfolgreich ermittelt:" -ForegroundColor Green
    Write-Host "  TENANT_ID=$($org.Id)" -ForegroundColor Green
    Write-Host "  TENANT_NAME=$($org.DisplayName)" -ForegroundColor Green
    Write-Host "  SIGNED_IN_USER=$loggedInUser" -ForegroundColor Green

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
}
catch {
    Write-Host "Tenant-Info Abfrage FEHLGESCHLAGEN (ExitCode 30)" -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor DarkRed
    exit 30
}


# ---------------------- Fertig ----------------------

Write-Host "Alle Verbindungen erfolgreich hergestellt." -ForegroundColor Cyan
exit 0