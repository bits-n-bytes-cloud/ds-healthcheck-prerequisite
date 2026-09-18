#Requires -Version 7.5
<#
.SYNOPSIS
    Prüft die technischen Voraussetzungen für den DS (Datenschutz) M365 HealthCheck.

.DESCRIPTION
    Prüft Umgebung (PowerShell 7.5, Windows, Administrator), installiert fehlende PowerShell-Module
    und testet die Anmeldung samt Leseprobe an Exchange Online, Microsoft Teams und Microsoft Graph.
    Jeder Dienst läuft in einem eigenen, sauberen pwsh-Prozess (keine Assembly-Konflikte, die
    Session des Aufrufers bleibt unberührt). Das Ergebnis wird an den bits-n-bytes Webhook übermittelt
    und lokal in eine Logdatei geschrieben.

    Das Script ist auch per "iex" ausführbar. Es beendet die aufrufende PowerShell nie per "exit";
    der Exit-Code steht dann in $LASTEXITCODE.

.PARAMETER SkipUpload
    Trockenlauf: Ergebnis wird angezeigt, aber nicht an den Webhook gesendet.

.PARAMETER LoginTimeoutMinutes
    Maximale Wartezeit pro Dienst-Anmeldung, bevor der Vorgang abgebrochen wird (Standard: 10).

.PARAMETER LogPath
    Pfad der Logdatei. Standard: %TEMP%\DS-HealthCheck-Prerequisite_<Zeitstempel>.log

.NOTES
    Exit-Codes:
      0   Alle Voraussetzungen erfüllt
      1   Kein Administrator
      10  Exchange Online fehlgeschlagen
      20  Microsoft Teams fehlgeschlagen
      30  Microsoft Graph fehlgeschlagen
      40  Übermittlung an den Webhook fehlgeschlagen
      50  Anmeldungen gehören zu unterschiedlichen Tenants
      99  Unerwarteter Fehler
      100 Modul-Installation fehlgeschlagen
      101 PowerShell-Version bzw. Plattform nicht unterstützt
#>
[CmdletBinding()]
param(
    [switch] $SkipUpload,
    [ValidateRange(1, 60)][int] $LoginTimeoutMinutes = 10,
    [string] $LogPath
)

# Der gesamte Code läuft in einem eigenen Scope: StrictMode, ErrorActionPreference und Hilfsfunktionen
# bleiben nach dem Lauf nicht in der Session des Aufrufers (relevant bei "iex").
$main = {
    param(
        [switch] $SkipUpload,
        [int] $LoginTimeoutMinutes,
        [string] $LogPath
    )

    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    # ---------------------- Konfiguration ----------------------

    $config = @{
        ScriptVersion = '2.0.0'
        WebhookUrl    = 'https://n8n.ralfes.cloud/webhook/813ecb39-84d3-483b-adbc-0db9ae84597e'
        MinPowerShell = [version]'7.5'
        Modules       = @(
            @{ Name = 'ExchangeOnlineManagement';                  MinVersion = [version]'3.6.0' }
            @{ Name = 'MicrosoftTeams';                            MinVersion = [version]'5.0.0' }
            @{ Name = 'Microsoft.Graph.Authentication';            MinVersion = [version]'2.0.0' }
            @{ Name = 'Microsoft.Graph.Identity.DirectoryManagement'; MinVersion = [version]'2.0.0' }
        )
    }

    if (-not $LogPath) {
        $LogPath = Join-Path ([IO.Path]::GetTempPath()) ('DS-HealthCheck-Prerequisite_{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    }

    # Laufzeitkontext (Referenztyp, damit die verschachtelten Funktionen ihn ändern können)
    $ctx = @{
        LogFile = $LogPath
        Summary = [Collections.Generic.List[object]]::new()
    }

    # ---------------------- Hilfsfunktionen ----------------------

    function Write-Log {
        param(
            [Parameter(Mandatory)][ValidateSet('Step', 'Info', 'Ok', 'Warn', 'Error')][string] $Level,
            [Parameter(Mandatory)][string] $Message,
            [switch] $FileOnly
        )

        if (-not $FileOnly) {
            $color = switch ($Level) {
                'Step'  { 'Cyan' }
                'Info'  { 'Gray' }
                'Ok'    { 'Green' }
                'Warn'  { 'Yellow' }
                'Error' { 'Red' }
            }
            $prefix = switch ($Level) {
                'Ok'    { '[ OK ] ' }
                'Warn'  { '[WARN] ' }
                'Error' { '[FEHL] ' }
                default { '' }
            }
            Write-Host "$prefix$Message" -ForegroundColor $color
        }

        # Logfehler (z. B. Datei gesperrt) dürfen den Lauf nie beeinträchtigen
        try {
            Add-Content -LiteralPath $ctx.LogFile -Encoding utf8 -Value ('{0} [{1}] {2}' -f (Get-Date -Format 'o'), $Level.ToUpper(), $Message)
        }
        catch { }
    }

    function Add-Step {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][ValidateSet('OK', 'WARN', 'FAIL', 'SKIP')][string] $Status,
            [string] $Detail = ''
        )

        $ctx.Summary.Add([pscustomobject]@{ Schritt = $Name; Status = $Status; Detail = $Detail })
        $level = switch ($Status) { 'OK' { 'Ok' } 'WARN' { 'Warn' } 'FAIL' { 'Error' } default { 'Info' } }
        Write-Log $level ('{0}: {1}' -f $Name, $Detail)
    }

    function Test-IsAdmin {
        $principal = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        )
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }

    function Get-ModuleState {
        param([Parameter(Mandatory)][string] $Name)

        # Höchste installierte Version, unabhängig davon, womit das Modul installiert wurde
        Get-Module -ListAvailable -Name $Name -ErrorAction SilentlyContinue |
            Where-Object { -not $_.CompatiblePSEditions -or $_.CompatiblePSEditions -contains 'Core' } |
            Sort-Object -Property Version -Descending |
            Select-Object -First 1
    }

    function Test-Endpoint {
        param([Parameter(Mandatory)][string] $Uri)

        try {
            # Jede HTTP-Antwort (auch 4xx/5xx) beweist, dass der Endpunkt erreichbar ist
            $null = Invoke-WebRequest -Uri $Uri -Method Head -TimeoutSec 10 -SkipHttpErrorCheck -ErrorAction Stop
            return [pscustomobject]@{ Reachable = $true; Detail = '' }
        }
        catch {
            return [pscustomobject]@{ Reachable = $false; Detail = $_.Exception.Message }
        }
    }

    function Install-RequiredModule {
        param(
            [Parameter(Mandatory)][string] $Name,
            [Parameter(Mandatory)][version] $MinVersion
        )

        # 1. Bevorzugt PSResourceGet (in PowerShell 7.4+ enthalten)
        if (Get-Command -Name Install-PSResource -ErrorAction SilentlyContinue) {
            try {
                Install-PSResource -Name $Name -Version "[$MinVersion,)" -Repository PSGallery `
                    -Scope AllUsers -TrustRepository -AcceptLicense -Quiet -ErrorAction Stop
                return
            }
            catch {
                Write-Log Warn "Install-PSResource für $Name fehlgeschlagen, versuche Install-Module: $($_.Exception.Message)"
            }
        }

        # 2. Fallback PowerShellGet; -SkipPublisherCheck nur, wenn es sonst nicht geht
        try {
            Install-Module -Name $Name -MinimumVersion $MinVersion -Repository PSGallery `
                -Scope AllUsers -Force -AllowClobber -ErrorAction Stop
        }
        catch {
            Write-Log Warn "Install-Module für $Name fehlgeschlagen, letzter Versuch mit -SkipPublisherCheck: $($_.Exception.Message)"
            Install-Module -Name $Name -MinimumVersion $MinVersion -Repository PSGallery `
                -Scope AllUsers -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
        }
    }

    function Invoke-CleanPwsh {
        param(
            [Parameter(Mandatory)][string] $Script,
            [Parameter(Mandatory)][int] $TimeoutSeconds
        )

        # Script als EncodedCommand starten (Unicode/Base64)
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))

        # Genau die pwsh-Instanz verwenden, die dieses Script ausführt
        $pwshPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName

        $stdoutFile = [IO.Path]::GetTempFileName()
        $stderrFile = [IO.Path]::GetTempFileName()
        $process = $null

        try {
            $process = Start-Process `
                -FilePath $pwshPath `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
                -RedirectStandardOutput $stdoutFile `
                -RedirectStandardError  $stderrFile `
                -PassThru

            # Handle zwischenspeichern, sonst kann ExitCode nach dem Beenden $null sein
            $null = $process.Handle

            $timedOut = -not $process.WaitForExit($TimeoutSeconds * 1000)
            if ($timedOut) {
                try { $process.Kill($true) } catch { }
                $null = $process.WaitForExit(5000)
            }
            else {
                $process.WaitForExit()   # stellt sicher, dass die Ausgabe vollständig geschrieben ist
            }

            $stdout = [IO.File]::ReadAllText($stdoutFile, [Text.Encoding]::UTF8)
            $stderr = [IO.File]::ReadAllText($stderrFile, [Text.Encoding]::UTF8)

            # Ergebnis ist die letzte Zeile mit Marker; alles andere (Banner, Warnungen) wird ignoriert
            $result = $null
            $markerLine = $stdout -split '\r?\n' |
                Where-Object { $_.StartsWith('##DSHC##') } |
                Select-Object -Last 1
            if ($markerLine) {
                try { $result = $markerLine.Substring(8) | ConvertFrom-Json } catch { }
            }

            [pscustomobject]@{
                TimedOut = $timedOut
                ExitCode = if ($timedOut) { -1 } else { $process.ExitCode }
                Result   = $result
                StdOut   = $stdout.Trim()
                StdErr   = $stderr.Trim()
            }
        }
        finally {
            if ($process) { $process.Dispose() }
            Remove-Item -LiteralPath $stdoutFile, $stderrFile -ErrorAction SilentlyContinue
        }
    }

    # Gemeinsamer Rahmen der Dienst-Prüfungen im Kind-Prozess. Genau eine Ergebniszeile mit Marker,
    # Fehlercode = Phase, in der der Fehler auftrat (Rohtexte gehen nur ins lokale Log).
    $childTemplate = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$WarningPreference = 'SilentlyContinue'
try { [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false) } catch { }
$result = [ordered]@{ ok = $false; errorCode = $null; message = $null; account = $null; tenantId = $null; tenantName = $null }
$stage = 'IMPORT_FAILED'
try {
#BODY#
    $stage = 'DONE'
}
catch {
    $result.errorCode = $stage
    $result.message = $_.Exception.Message
}
finally {
    try { #DISCONNECT# } catch { }
}
$result.ok = ($stage -eq 'DONE')
Write-Output ('##DSHC##' + ($result | ConvertTo-Json -Compress))
exit $(if ($result.ok) { 0 } else { 1 })
'@

    $exoBody = @'
    Import-Module ExchangeOnlineManagement -ErrorAction Stop
    $stage = 'CONNECT_FAILED'
    Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
    $connection = Get-ConnectionInformation | Where-Object { $_.State -eq 'Connected' } | Select-Object -First 1
    if ($connection) {
        $result.account  = [string]$connection.UserPrincipalName
        $result.tenantId = [string]$connection.TenantID
    }
    $stage = 'PROBE_FAILED'
    $null = Get-OrganizationConfig -ErrorAction Stop
'@

    $teamsBody = @'
    Import-Module MicrosoftTeams -ErrorAction Stop
    $stage = 'CONNECT_FAILED'
    $connection = Connect-MicrosoftTeams -ErrorAction Stop
    if ($connection) {
        $accountId = $connection.Account.Id
        $result.account  = if ($accountId) { [string]$accountId } else { [string]$connection.Account }
        $result.tenantId = [string]$connection.TenantId
    }
    $stage = 'PROBE_FAILED'
    $tenant = Get-CsTenant -ErrorAction Stop
    if ($tenant) {
        if (-not $result.tenantId) { $result.tenantId = [string]$tenant.TenantId }
        $result.tenantName = [string]$tenant.DisplayName
    }
'@

    $graphBody = @'
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Import-Module Microsoft.Graph.Identity.DirectoryManagement -ErrorAction Stop
    $stage = 'CONNECT_FAILED'
    $null = Connect-MgGraph -Scopes 'Organization.Read.All' -ContextScope Process -ClientTimeout 120 -NoWelcome -ErrorAction Stop
    $context = Get-MgContext
    $result.account  = [string]$context.Account
    $result.tenantId = [string]$context.TenantId
    $stage = 'PROBE_FAILED'
    $org = Get-MgOrganization -ErrorAction Stop | Select-Object -First 1
    $result.tenantId   = [string]$org.Id
    $result.tenantName = [string]$org.DisplayName
'@

    $services = @(
        [pscustomobject]@{
            Key = 'exchangeOnline'; Label = 'Exchange Online'; ExitCode = 10
            Modules = @('ExchangeOnlineManagement')
            Script  = $childTemplate.Replace('#BODY#', $exoBody).Replace('#DISCONNECT#', 'Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue')
        }
        [pscustomobject]@{
            Key = 'teams'; Label = 'Microsoft Teams'; ExitCode = 20
            Modules = @('MicrosoftTeams')
            Script  = $childTemplate.Replace('#BODY#', $teamsBody).Replace('#DISCONNECT#', 'Disconnect-MicrosoftTeams -ErrorAction SilentlyContinue')
        }
        [pscustomobject]@{
            Key = 'graph'; Label = 'Microsoft Graph'; ExitCode = 30
            Modules = @('Microsoft.Graph.Authentication', 'Microsoft.Graph.Identity.DirectoryManagement')
            Script  = $childTemplate.Replace('#BODY#', $graphBody).Replace('#DISCONNECT#', 'Disconnect-MgGraph -ErrorAction SilentlyContinue')
        }
    )

    function Invoke-ServiceCheck {
        param(
            [Parameter(Mandatory)] $Service,
            [Parameter(Mandatory)][hashtable] $ModuleOk
        )

        $check = [pscustomobject]@{
            Key        = $Service.Key
            Label      = $Service.Label
            ExitCode   = $Service.ExitCode
            Ok         = $false
            ErrorCode  = $null
            Account    = $null
            TenantId   = $null
            TenantName = $null
        }

        $missing = @($Service.Modules | Where-Object { -not $ModuleOk[$_] })
        if ($missing.Count -gt 0) {
            $check.ErrorCode = 'MODULE_MISSING'
            Add-Step $Service.Label 'FAIL' ('übersprungen, Modul fehlt: ' + ($missing -join ', '))
            return $check
        }

        Write-Log Info "Verbinde zu $($Service.Label) (isolierte Session)..."
        $run = Invoke-CleanPwsh -Script $Service.Script -TimeoutSeconds ($LoginTimeoutMinutes * 60)

        if ($run.StdOut) { Write-Log Info "[$($Service.Key)] stdout: $($run.StdOut)" -FileOnly }
        if ($run.StdErr) { Write-Log Info "[$($Service.Key)] stderr: $($run.StdErr)" -FileOnly }

        if ($run.TimedOut) {
            $check.ErrorCode = 'TIMEOUT'
            Add-Step $Service.Label 'FAIL' "Keine Anmeldung innerhalb von $LoginTimeoutMinutes Minuten, Vorgang abgebrochen."
            return $check
        }
        if (-not $run.Result) {
            $check.ErrorCode = 'NO_RESULT'
            Add-Step $Service.Label 'FAIL' "Prüfprozess lieferte kein Ergebnis (ExitCode $($run.ExitCode)). Details siehe Log."
            return $check
        }

        $check.Account    = $run.Result.account
        $check.TenantId   = $run.Result.tenantId
        $check.TenantName = $run.Result.tenantName

        if ($run.Result.ok) {
            $check.Ok = $true
            Add-Step $Service.Label 'OK' 'Verbindung und Leseprobe erfolgreich.'
        }
        else {
            $check.ErrorCode = [string]$run.Result.errorCode
            Add-Step $Service.Label 'FAIL' "$($run.Result.errorCode): $($run.Result.message)"
        }
        return $check
    }

    function Send-Payload {
        param(
            [Parameter(Mandatory)][string] $Url,
            [Parameter(Mandatory)][string] $Json
        )

        $body = [Text.Encoding]::UTF8.GetBytes($Json)

        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                $null = Invoke-RestMethod -Method Post -Uri $Url -ContentType 'application/json; charset=utf-8' `
                    -Body $body -TimeoutSec 30 -ErrorAction Stop
                return $true
            }
            catch {
                $status = $null
                if ($_.Exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                    $status = [int]$_.Exception.Response.StatusCode
                }

                # Wiederholen nur bei vorübergehenden Fehlern (Netzwerk/Timeout, 408, 429, 5xx)
                $transient = ($null -eq $status) -or $status -ge 500 -or $status -eq 408 -or $status -eq 429
                Write-Log Warn "Übermittlung Versuch $attempt/3 fehlgeschlagen: $($_.Exception.Message)"
                if (-not $transient -or $attempt -eq 3) { return $false }
                Start-Sleep -Seconds (2 * $attempt)
            }
        }
        return $false
    }

    # ---------------------- Ablauf ----------------------

    try {
        Write-Host ''
        Write-Log Step "DS HealthCheck - Prerequisite v$($config.ScriptVersion)"
        Write-Log Info "Logdatei: $($ctx.LogFile)"

        # ---- 1. Umgebung ----
        Write-Host ''
        Write-Log Step '[1/6] Umgebung prüfen...'

        $psVersion = [version]::new($PSVersionTable.PSVersion.Major, $PSVersionTable.PSVersion.Minor)
        if ($psVersion -lt $config.MinPowerShell) {
            Add-Step 'PowerShell-Version' 'FAIL' "Version $($PSVersionTable.PSVersion) gefunden, erforderlich ist $($config.MinPowerShell) oder höher."
            Write-Log Info 'Installation: winget install --id Microsoft.PowerShell --source winget  (danach "pwsh" als Administrator starten)'
            return 101
        }
        Add-Step 'PowerShell-Version' 'OK' "$($PSVersionTable.PSVersion)"

        if (-not $IsWindows) {
            Add-Step 'Betriebssystem' 'FAIL' 'Dieses Script wird nur unter Windows unterstützt.'
            return 101
        }

        if (-not (Test-IsAdmin)) {
            Add-Step 'Administratorrechte' 'FAIL' 'Fehlen. Bitte PowerShell 7 über Rechtsklick "Als Administrator ausführen" starten.'
            return 1
        }
        Add-Step 'Administratorrechte' 'OK' 'vorhanden'

        $policy = Get-ExecutionPolicy
        if ($policy -in 'Restricted', 'AllSigned') {
            Add-Step 'Ausführungsrichtlinie' 'WARN' "$policy kann das Laden von Modulen blockieren. Bei Fehlern: Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned"
        }
        else {
            Add-Step 'Ausführungsrichtlinie' 'OK' "$policy"
        }

        # ---- 2. Netzwerk ----
        Write-Host ''
        Write-Log Step '[2/6] Erreichbarkeit prüfen...'

        # Modulstatus vorab ermitteln: PowerShell Gallery wird nur gebraucht, wenn installiert werden muss
        $moduleInfo = @{}
        foreach ($module in $config.Modules) {
            $moduleInfo[$module.Name] = Get-ModuleState -Name $module.Name
        }
        $needsInstall = @($config.Modules | Where-Object {
            -not $moduleInfo[$_.Name] -or $moduleInfo[$_.Name].Version -lt $_.MinVersion
        })

        $endpoints = [Collections.Generic.List[string]]@(
            'https://login.microsoftonline.com'
            'https://outlook.office365.com'
            'https://graph.microsoft.com'
            ([uri]$config.WebhookUrl).GetLeftPart([UriPartial]::Authority)
        )
        if ($needsInstall.Count -gt 0) { $endpoints.Add('https://www.powershellgallery.com') }

        foreach ($endpoint in $endpoints) {
            $probe = Test-Endpoint -Uri $endpoint
            if ($probe.Reachable) {
                Add-Step "Netzwerk $(([uri]$endpoint).Host)" 'OK' 'erreichbar'
            }
            else {
                Add-Step "Netzwerk $(([uri]$endpoint).Host)" 'WARN' "nicht erreichbar (Proxy/Firewall?): $($probe.Detail)"
            }
        }

        # ---- 3. Module ----
        Write-Host ''
        Write-Log Step '[3/6] PowerShell-Module prüfen...'

        $moduleOk = @{}
        $moduleFailed = $false
        foreach ($module in $config.Modules) {
            $name = $module.Name
            $state = $moduleInfo[$name]

            if ($state -and $state.Version -ge $module.MinVersion) {
                $moduleOk[$name] = $true
                Add-Step "Modul $name" 'OK' "Version $($state.Version) vorhanden (min. $($module.MinVersion))"
                continue
            }

            Write-Log Info "Installiere/aktualisiere $name (min. $($module.MinVersion)), das kann einige Minuten dauern..."
            try {
                Install-RequiredModule -Name $name -MinVersion $module.MinVersion
                $state = Get-ModuleState -Name $name
                if ($state -and $state.Version -ge $module.MinVersion) {
                    $moduleOk[$name] = $true
                    Add-Step "Modul $name" 'OK' "Version $($state.Version) installiert"
                }
                else {
                    $moduleOk[$name] = $false
                    $moduleFailed = $true
                    Add-Step "Modul $name" 'FAIL' "Nach der Installation nicht in Version >= $($module.MinVersion) verfügbar."
                }
            }
            catch {
                $moduleOk[$name] = $false
                $moduleFailed = $true
                Add-Step "Modul $name" 'FAIL' "Installation fehlgeschlagen: $($_.Exception.Message)"
            }
        }

        # ---- 4. Dienste ----
        Write-Host ''
        Write-Log Step '[4/6] Anmeldung an den Microsoft-Diensten prüfen...'
        Write-Log Info 'Es erscheinen mehrere Anmeldefenster. Bitte immer dasselbe Benutzerkonto verwenden.'

        $checks = foreach ($service in $services) {
            Invoke-ServiceCheck -Service $service -ModuleOk $moduleOk
        }
        $checks = @($checks)

        # ---- 5. Auswertung ----
        Write-Host ''
        Write-Log Step '[5/6] Ergebnisse auswerten...'

        $succeeded = @($checks | Where-Object { $_.Ok })

        $tenantIds = @($succeeded | Where-Object { $_.TenantId } | ForEach-Object { $_.TenantId.ToLowerInvariant() } | Sort-Object -Unique)
        $accounts  = @($succeeded | Where-Object { $_.Account }  | ForEach-Object { $_.Account.ToLowerInvariant() }  | Sort-Object -Unique)

        $consistency = 'OK'
        if (@($succeeded | Where-Object { $_.TenantId }).Count -lt 2) {
            $consistency = 'SKIPPED'
            Add-Step 'Konsistenz' 'SKIP' 'Weniger als zwei erfolgreiche Anmeldungen, kein Vergleich möglich.'
        }
        elseif ($tenantIds.Count -gt 1) {
            $consistency = 'FAIL'
            Add-Step 'Konsistenz' 'FAIL' 'Die Anmeldungen gehören zu unterschiedlichen Tenants. Bitte mit demselben Konto wiederholen.'
        }
        elseif ($accounts.Count -gt 1) {
            $consistency = 'WARN'
            Add-Step 'Konsistenz' 'WARN' 'Es wurden unterschiedliche Benutzerkonten verwendet. Bitte mit demselben Konto wiederholen.'
        }
        else {
            Add-Step 'Konsistenz' 'OK' 'Tenant und Benutzerkonto sind bei allen Diensten identisch.'
        }

        # Identität für den Payload: Graph bevorzugt, sonst erster erfolgreicher Dienst mit Angabe
        $identitySources = @($succeeded | Sort-Object { if ($_.Key -eq 'graph') { 0 } else { 1 } })
        $tenantId     = ($identitySources | Where-Object { $_.TenantId }   | Select-Object -First 1 | ForEach-Object { $_.TenantId })
        $tenantName   = ($identitySources | Where-Object { $_.TenantName } | Select-Object -First 1 | ForEach-Object { $_.TenantName })
        $signedInUser = ($identitySources | Where-Object { $_.Account }    | Select-Object -First 1 | ForEach-Object { $_.Account })

        # ---- Exit-Code: erster fehlgeschlagener Prüfschritt ----
        $exitCode = 0
        if ($moduleFailed) { $exitCode = 100 }
        if ($exitCode -eq 0) {
            $firstFailed = $checks | Where-Object { -not $_.Ok } | Select-Object -First 1
            if ($firstFailed) { $exitCode = $firstFailed.ExitCode }
        }
        if ($exitCode -eq 0 -and $consistency -eq 'FAIL') { $exitCode = 50 }

        $allChecksOk = (@($checks | Where-Object { -not $_.Ok }).Count -eq 0)

        # ---- 6. Payload und Übermittlung ----
        Write-Host ''
        Write-Log Step '[6/6] Ergebnis übermitteln...'

        $errors = [ordered]@{}
        foreach ($check in $checks) {
            if (-not $check.Ok) { $errors[$check.Key] = $check.ErrorCode }
        }

        $payload = [ordered]@{
            timestamp     = (Get-Date).ToString('o')
            hostname      = $env:COMPUTERNAME
            scriptVersion = $config.ScriptVersion
            results       = [ordered]@{
                exchangeOnline = if (($checks | Where-Object Key -eq 'exchangeOnline').Ok) { 'OK' } else { 'FAIL' }
                teams          = if (($checks | Where-Object Key -eq 'teams').Ok) { 'OK' } else { 'FAIL' }
                graph          = if (($checks | Where-Object Key -eq 'graph').Ok) { 'OK' } else { 'FAIL' }
                overall        = if ($allChecksOk -and $consistency -ne 'FAIL') { 'OK' } else { 'FAIL' }
                consistency    = $consistency
            }
            errors        = $errors
            tenant        = [ordered]@{
                tenantId     = $tenantId
                tenantName   = $tenantName
                signedInUser = $signedInUser
            }
        }
        $json = $payload | ConvertTo-Json -Depth 6 -Compress
        Write-Log Info "Payload: $json" -FileOnly

        if (-not $tenantId) {
            Add-Step 'Übermittlung' 'WARN' 'Keine Tenant-ID ermittelt, das Ergebnis wäre nicht zuordenbar und wird nicht gesendet.'
        }
        elseif ($SkipUpload) {
            Add-Step 'Übermittlung' 'SKIP' '-SkipUpload gesetzt. Es wird nichts gesendet. Payload:'
            Write-Host ($payload | ConvertTo-Json -Depth 6)
        }
        elseif (Send-Payload -Url $config.WebhookUrl -Json $json) {
            Add-Step 'Übermittlung' 'OK' 'Ergebnis wurde an bits-n-bytes übermittelt.'
        }
        else {
            $payloadFile = Join-Path (Split-Path -Parent $ctx.LogFile) (
                'DS-HealthCheck-Prerequisite_Ergebnis_{0}.json' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
            try { Set-Content -LiteralPath $payloadFile -Value ($payload | ConvertTo-Json -Depth 6) -Encoding utf8 } catch { $payloadFile = $null }

            Add-Step 'Übermittlung' 'FAIL' 'Senden an bits-n-bytes fehlgeschlagen. Bitte das Ergebnis manuell weitergeben:'
            Write-Host ($payload | ConvertTo-Json -Depth 6)
            if ($payloadFile) { Write-Log Info "Ergebnis gespeichert in: $payloadFile" }
            if ($exitCode -eq 0) { $exitCode = 40 }
        }

        # ---- Zusammenfassung ----
        Write-Host ''
        Write-Log Step 'Zusammenfassung'
        $width = ($ctx.Summary | ForEach-Object { $_.Schritt.Length } | Measure-Object -Maximum).Maximum
        foreach ($row in $ctx.Summary) {
            $color = switch ($row.Status) { 'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'Gray' } }
            Write-Host ('  {0}  {1}' -f $row.Schritt.PadRight($width), $row.Status) -ForegroundColor $color
        }

        Write-Host ''
        if ($exitCode -eq 0) {
            if (@($ctx.Summary | Where-Object { $_.Status -eq 'WARN' }).Count -gt 0) {
                Write-Log Ok 'Alle Voraussetzungen sind erfüllt (mit Hinweisen, siehe WARN in der Zusammenfassung).'
            }
            else {
                Write-Log Ok 'Alle Voraussetzungen sind erfüllt.'
            }
        }
        else {
            Write-Log Error "Nicht alle Voraussetzungen sind erfüllt (Exit-Code $exitCode)."
            Write-Log Info "Details siehe Logdatei: $($ctx.LogFile)"
        }
        return $exitCode
    }
    catch {
        Write-Log Error "Unerwarteter Fehler: $($_.Exception.Message)"
        Write-Log Info ($_ | Out-String) -FileOnly
        Write-Log Info "Details siehe Logdatei: $($ctx.LogFile)"
        return 99
    }
}

# ---------------------- Start ----------------------

$exitCode = [int](@(& $main -SkipUpload:$SkipUpload -LoginTimeoutMinutes $LoginTimeoutMinutes -LogPath $LogPath)[-1])

# Als Datei gestartet: echten Exit-Code liefern. Über "iex"/Scriptblock würde "exit" das gesamte
# PowerShell-Fenster schließen und die Meldungen wären nicht mehr lesbar; dort nur $LASTEXITCODE setzen.
$startedAsFile = [bool](Get-Variable -Name PSCommandPath -ValueOnly -ErrorAction SilentlyContinue)
if ($startedAsFile) {
    exit $exitCode
}
else {
    $global:LASTEXITCODE = $exitCode
}
