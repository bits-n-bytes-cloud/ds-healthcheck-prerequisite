[![LinkedIn][linkedin-shield]][linkedin-url]
# GDPR HealthCheck-Prerequisite
## Information
Um den GDPR HealthCheck erfolgreich auszuführen, müssen bestimmte Voraussetzungen erfüllt sein. Dieses Skript überprüft, ob alle erforderlichen Bedingungen gegeben sind, und installiert bei Bedarf die fehlenden PowerShell-Module automatisch nach.
Es ist zudem erforderlich, dass das Prerequisite-Skript mit **administrativen Rechten auf dem Computer** ausgeführt wird. Darüber hinaus müssen bei der **Anmeldung am Tenant globale Administratorrechte** vorhanden sein.

## Voraussetzungen
PowerShell 7.5 oder neuer wird benötigt, um den HealthCheck durchführen zu können. Öffnen Sie die **CMD (mit Adminrechten)** und starten Sie den folgenden Befehl:
```sh
winget install --id Microsoft.PowerShell --source winget
```

### Prerequisite für den HealthCheck prüfen
Mit **PowerShell 7 (mit Adminrechten)** den folgenden Befehl starten:
```powershell
iex (irm 'https://raw.githubusercontent.com/bits-n-bytes-cloud/ds-healthcheck-prerequisite/main/Prerequisite.ps1')
```
Der bisherige Aufruf mit `System.Net.WebClient` funktioniert weiterhin.

Das Skript beendet die PowerShell nicht selbst. Das Fenster bleibt nach dem Lauf offen, sodass alle Meldungen gelesen werden können. Der Exit-Code steht anschließend in `$LASTEXITCODE`.

#### Optionale Parameter
Parameter lassen sich mit der folgenden Aufrufform übergeben:
```powershell
& ([scriptblock]::Create((irm 'https://raw.githubusercontent.com/bits-n-bytes-cloud/ds-healthcheck-prerequisite/main/Prerequisite.ps1'))) -SkipUpload
```

| Parameter | Beschreibung |
| --- | --- |
| `-SkipUpload` | Trockenlauf: Das Ergebnis wird angezeigt, aber nicht an bits-n-bytes übermittelt. |
| `-LoginTimeoutMinutes` | Maximale Wartezeit pro Anmeldung in Minuten (Standard: 10, erlaubt: 1-60). |
| `-LogPath` | Pfad der Logdatei (Standard: `%TEMP%\DS-HealthCheck-Prerequisite_<Zeitstempel>.log`). |

## Was macht dieses Script? ##
Dieses Skript prüft, ob die technischen Voraussetzungen für den DS HealthCheck auf dem System erfüllt sind.
Während der Ausführung führt das Skript folgende Schritte aus:

1. **Umgebung:** PowerShell-Version (mindestens 7.5), Windows, Administratorrechte, Ausführungsrichtlinie und Erreichbarkeit der benötigten Internetadressen (Microsoft-Anmeldung, Exchange Online, Microsoft Graph, PowerShell Gallery, Ergebnis-Server).
2. **PowerShell-Module:** Fehlende oder zu alte Module werden automatisch installiert bzw. aktualisiert und anschließend geprüft.

   | Modul | Mindestversion |
   | --- | --- |
   | ExchangeOnlineManagement | 3.6.0 |
   | MicrosoftTeams | 5.0.0 |
   | Microsoft.Graph.Authentication | 2.0.0 |
   | Microsoft.Graph.Identity.DirectoryManagement | 2.0.0 |

3. **Anmeldung an den Microsoft-Diensten** (Exchange Online, Microsoft Teams, Microsoft Graph): Jeder Dienst wird in einer eigenen, isolierten PowerShell-Sitzung getestet. Nach der Anmeldung führt das Skript eine kleine **lesende** Abfrage aus, um zu prüfen, dass die Berechtigungen tatsächlich ausreichen. Es werden keine Änderungen am Tenant vorgenommen.
4. **Konsistenzprüfung:** Es wird geprüft, dass bei allen Diensten derselbe Tenant und dasselbe Benutzerkonto verwendet wurde.
5. **Übermittlung des Ergebnisses** an unsere Server (siehe unten).

Aus diesem Grund erscheinen mehrere Anmeldefenster während der Ausführung. Wird ein Anmeldefenster nicht innerhalb der Wartezeit (Standard 10 Minuten) bedient, wird der Vorgang abgebrochen.

⚠️ **Wichtig**: Bitte melden Sie sich jedes Mal mit denselben Zugangsdaten an (dem gleichen Benutzerkonto), da die Ergebnisse sonst nicht korrekt zugeordnet werden können. Das Skript weist darauf hin, wenn unterschiedliche Konten oder Tenants verwendet wurden.

Ein vorhandenes Microsoft-Graph-Login in Ihrer PowerShell-Sitzung wird nicht getrennt oder verändert, da alle Prüfungen in separaten Prozessen laufen.

### Übermittlung des Ergebnisses
Nach Abschluss aller Prüfungen wird das Testergebnis automatisch an unsere Server übermittelt. Das geschieht **auch dann, wenn einzelne Prüfungen fehlgeschlagen sind**, damit wir Sie gezielt unterstützen können. Ist keine Tenant-ID ermittelbar, wird nichts übermittelt, da das Ergebnis nicht zuordenbar wäre.
Im Rahmen dieser Übermittlung werden ausschließlich die folgenden Informationen übertragen:

Ergebnis der technischen Prüfungen (z. B. erfolgreich / fehlgeschlagen) mit einem kurzen Fehlercode, Version des Skripts, Tenant‑ID, Tenant‑Name, Angemeldeter Benutzer (E‑Mail/UPN), Zeitstempel, Hostname

Es werden keine Fehlertexte und keine Inhalte Ihres Tenants übertragen. Ausführliche Fehlermeldungen stehen nur in der lokalen Logdatei.

Beispiel:

```json
{
  "timestamp":"2026-03-12T12:34:56.7890123+01:00",
  "hostname":"DESKTOP-XYZ",
  "scriptVersion":"2.0.0",
  "results":{"exchangeOnline":"OK","teams":"OK","graph":"OK","overall":"OK","consistency":"OK"},
  "errors":{},
  "tenant":{"tenantId":"6799xxxx-96xx-4axx-80xx-704b4ebexxxx","tenantName":"bits-n-bytes","signedInUser":"user@domain.tld"}
}
```

Bei einem fehlgeschlagenen Dienst enthält `errors` einen Fehlercode, z. B. `"errors":{"teams":"CONNECT_FAILED"}`. Mögliche Codes: `MODULE_MISSING`, `IMPORT_FAILED`, `CONNECT_FAILED`, `PROBE_FAILED` (Anmeldung ok, aber keine Leseberechtigung), `TIMEOUT`, `NO_RESULT`. `consistency` ist `OK`, `WARN` (unterschiedliche Konten), `FAIL` (unterschiedliche Tenants) oder `SKIPPED`.

Schlägt die Übermittlung selbst fehl (z. B. wegen einer Firewall), versucht das Skript es bis zu dreimal. Danach wird das Ergebnis im Fenster angezeigt und als JSON-Datei neben der Logdatei gespeichert, sodass Sie es uns manuell zusenden können.

## Fehlersuche
Jeder Lauf schreibt eine Logdatei (Pfad steht am Anfang und am Ende der Ausgabe), standardmäßig unter `%TEMP%\DS-HealthCheck-Prerequisite_<Zeitstempel>.log`. Bitte senden Sie diese Datei mit, falls etwas nicht funktioniert.

| Exit-Code | Bedeutung |
| --- | --- |
| 0 | Alle Voraussetzungen erfüllt |
| 1 | Skript wurde nicht als Administrator gestartet |
| 10 | Exchange Online: Anmeldung oder Leseprobe fehlgeschlagen |
| 20 | Microsoft Teams: Anmeldung oder Leseprobe fehlgeschlagen |
| 30 | Microsoft Graph: Anmeldung oder Leseprobe fehlgeschlagen |
| 40 | Übermittlung an unsere Server fehlgeschlagen |
| 50 | Die Anmeldungen gehören zu unterschiedlichen Tenants |
| 99 | Unerwarteter Fehler (Details in der Logdatei) |
| 100 | Installation eines PowerShell-Moduls fehlgeschlagen |
| 101 | PowerShell-Version zu alt oder Betriebssystem nicht unterstützt |

Bei mehreren Fehlern wird der Code des ersten fehlgeschlagenen Schritts zurückgegeben.

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[linkedin-shield]: https://img.shields.io/badge/-LinkedIn-black.svg?style=for-the-badge&logo=linkedin&colorB=555
[linkedin-url]: https://linkedin.com/in/ralfes
