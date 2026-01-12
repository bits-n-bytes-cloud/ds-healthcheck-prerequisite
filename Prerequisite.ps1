#Requires -Version 7.5 # PowerShell 7.5 oder höher

function Ensure-Module {
  param(
    [Parameter(Mandatory=$true)][string]$Name
  )
  Write-Host "Modul $Name..." -ForegroundColor DarkCyan
  if (-not (Get-Module -ListAvailable -Name $Name)) {
    try {
      Write-Host "Installiere Modul $Name..." -ForegroundColor DarkCyan
      Install-Module $Name -Scope AllUsers -Force -Confirm:$false -AllowClobber -ErrorAction Stop
    } catch {
      throw "Konnte Modul $Name nicht installieren: $($_.Exception.Message)"
    }
  }
  Import-Module $Name -ErrorAction Stop | Out-Null
}


# Prüfen, ob Skript mit Administratorrechten läuft
$IsAdmin = [Security.Principal.WindowsPrincipal]::new(
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $IsAdmin) {
    Write-Warning "Dieses Skript muss mit Administratorrechten ausgeführt werden. Bitte PowerShell 'Als Administrator ausführen'."
    exit 1
}


Write-Host "Überprüfe Vorrausetzungen..."
Ensure-Module -Name ExchangeOnlineManagement
# Ensure-Module -Name MicrosoftTeams
# Ensure-Module -Name Microsoft.Graph
# Ensure-Module -Name Microsoft.Online.SharePoint.PowerShell 
Write-Host "Alle erforderlichen Module sind installiert und importiert."

# ---------------------- Verbindungen -------------------------
Write-Host "Verbinde zu Exchange Online..." -ForegroundColor Cyan
try {
  Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop | Out-Null
  Write-Host "Exchange Online Verbindung erfolgreich hergestellt." -ForegroundColor Green
} catch { Write-Host  "Exchange Online Verbindung Fail: " $_.Exception.Message "" -ForegroundColor Red}

# ------------------------------------------------------------
