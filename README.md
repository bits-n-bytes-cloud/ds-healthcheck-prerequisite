[![LinkedIn][linkedin-shield]][linkedin-url]
# GDPR HealthCheck Prerequisite
## Information
Um den GDPR HealthCheck-Prerequisite erfolgreich auszuführen, müssen bestimmte Voraussetzungen erfüllt sein. Dieses Skript überprüft, ob alle erforderlichen Bedingungen gegeben sind, und installiert bei Bedarf die fehlenden PowerShell-Module automatisch nach.
Es ist zudem erforderlich, dass das Prerequisite-Skript mit administrativen Rechten auf dem Computer ausgeführt wird. Darüber hinaus müssen bei der Anmeldung am Tenant globale Administratorrechte vorhanden sein.

## Vorraussetzungen
PowerShell wird in einer aktuellen Version benötigt um den Healtch Check durchführen zu können. Öffnen sie die CMD (mit Adminrechten) den folgenden Befehl starten:
```sh
winget install --id Microsoft.PowerShell --source winget
```sh

## Aufruf
Mit PowerShell 7 (mit Adminrechten) den folgenden Befehl starten:
### Prerequisite für den Healtch Check prüfen
```sh
iex ((New-Object System.Net.WebClient).DownloadString('https://raw.githubusercontent.com/RalfEs73/ds-healthcheck-prerequisite/main/Prerequisite.ps1'))
```

<!-- MARKDOWN LINKS & IMAGES -->
<!-- https://www.markdownguide.org/basic-syntax/#reference-style-links -->
[linkedin-shield]: https://img.shields.io/badge/-LinkedIn-black.svg?style=for-the-badge&logo=linkedin&colorB=555
[linkedin-url]: https://linkedin.com/in/ralfes
