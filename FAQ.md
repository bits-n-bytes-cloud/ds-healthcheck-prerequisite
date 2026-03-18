# FAQ
## Fehler
### 0x80131040
```
OperationStopped: Could not load file or assembly 'C:\Program
Files\PowerShell\Modules\ExchangeOnlineManagement\3.9.2\netCore\Microsoft.Identity.Client.dll'. The located assembly's
manifest definition does not match the assembly reference. (0x80131040)
```
Dieser Fehler ist klassisch für eine “Assembly-Version-Kollision” in PowerShell/.NET, dass passiert häuffig, wenn:
- mehrere Versionen von ExchangeOnlineManagement parallel installiert sind (AllUsers + CurrentUser),
- oder ein anderes Modul bereits eine andere MSAL-Version geladen hat,
- oder du PowerShell 5.1 vs 7 mischst und Module im falschen Host geladen werden.

Lösung:
PowerShell komplett schließen. Assemblies bleiben im Prozess geladen. Also alle PowerShell-Fenster schließen.

Prüfe, welche Module-Versionen du hast
Starte PowerShell als Administrator und führe aus:
```
Get-Module ExchangeOnlineManagement -ListAvailable |
  Select-Object Name, Version, ModuleBase | 
  Sort-Object Version -Descending
```

Wenn mehrere Einträge zu sehen sind (z. B. unter):
- C:\Program Files\PowerShell\Modules\... (AllUsers)
- C:\Users\<Benutzer>\Documents\PowerShell\Modules\... (CurrentUser)

… dann ist die Kollision sehr wahrscheinlich.

Entferne ALLE ExchangeOnlineManagement Versionen (radikal sauber)
```
# Entfernt alle installierten Versionen (falls möglich)
Get-InstalledModule ExchangeOnlineManagement -AllVersions -ErrorAction SilentlyContinue |
  ForEach-Object { Uninstall-Module ExchangeOnlineManagement -AllVersions -Force }
```

Falls Get-InstalledModule nichts findet oder Uninstall nicht alles erwischt, dann manuell löschen:
```
# AllUsers Pfad
Remove-Item "C:\Program Files\PowerShell\Modules\ExchangeOnlineManagement" -Recurse -Force -ErrorAction SilentlyContinue

# CurrentUser Pfad
Remove-Item "$env:USERPROFILE\Documents\PowerShell\Modules\ExchangeOnlineManagement" -Recurse -Force -ErrorAction SilentlyContinue
```

Neuinstallation – nur eine Version, nur ein Scope

```
Install-Module ExchangeOnlineManagement -Scope AllUsers -Force -AllowClobber
```

Optional (aber hilfreich): einmal direkt prüfen:
```
Import-Module ExchangeOnlineManagement -Force
Get-Module ExchangeOnlineManagement
```