[![LinkedIn][linkedin-shield]][linkedin-url]
# GDPR HealthCheck-Prerequisite
## Information
Um den GDPR HealthCheck-Prerequisite erfolgreich auszuführen, müssen bestimmte Voraussetzungen erfüllt sein. Dieses Skript überprüft, ob alle erforderlichen Bedingungen gegeben sind, und installiert bei Bedarf die fehlenden PowerShell-Module automatisch nach.
Es ist zudem erforderlich, dass das Prerequisite-Skript mit **administrativen Rechten auf dem Computer** ausgeführt wird. Darüber hinaus müssen bei der **Anmeldung am Tenant globale Administratorrechte** vorhanden sein.

## Vorraussetzungen
PowerShell wird in einer aktuellen Version benötigt um den Healtch Check durchführen zu können. Öffnen sie die **CMD (mit Adminrechten)** den folgenden Befehl starten:
```sh
winget install --id Microsoft.PowerShell --source winget
```

### Prerequisite für den HealtchCheck prüfen
Mit **PowerShell 7 (mit Adminrechten)** den folgenden Befehl starten:
```sh
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/bits-n-bytes-cloud/ds-healthcheck-prerequisite/main/Prerequisite.ps1'))
```

## Was macht dieses Script? ##
Dieses Skript prüft, ob die technischen Voraussetzungen für den DS HealthCheck auf dem System erfüllt sind.
Während der Ausführung führt das Skript folgende Schritte aus:

Es überprüft, ob alle für den DS HealthCheck benötigten PowerShell‑Module vorhanden sind. Fehlende Module werden automatisch installiert bzw. aktualisiert.
Anschließend meldet sich das Skript bei den benötigten Microsoft‑Diensten an (z. B. Exchange Online, Microsoft Teams, Microsoft Graph).

Aus diesem Grund erscheinen mehrere Anmeldefenster während der Ausführung.
⚠️ **Wichtig**: Bitte melden Sie sich jedes Mal mit denselben Zugangsdaten an (dem gleichen Benutzerkonto), da die Ergebnisse sonst nicht korrekt zugeordnet werden können.
Nach Abschluss aller Prüfungen wird das Testergebnis automatisch an unsere Server übermittelt.
Im Rahmen dieser Übermittlung werden ausschließlich die folgenden Informationen übertragen:

Ergebnis der technischen Prüfungen (z. B. erfolgreich / fehlgeschlagen)
Tenant‑ID
Tenant‑Name
Angemeldeter Benutzer (E‑Mail/UPN)
Zeitstempel
Hostname

Beispiel:

```json
{
  "timestamp":"2026-03-12T12:34:56.7890123+01:00",
  "hostname":"DESKTOP-XYZ",
  "results":{"exchangeOnline":"OK","teams":"OK","graph":"OK","overall":"OK"},
  "tenant":{"tenantId":"6799xxxx-96xx-4axx-80xx-704b4ebexxxx","tenantName":"bits-n-bytes","signedInUser":"user@domain.tld"}
}
```

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[linkedin-shield]: https://img.shields.io/badge/-LinkedIn-black.svg?style=for-the-badge&logo=linkedin&colorB=555
[linkedin-url]: https://linkedin.com/in/ralfes
