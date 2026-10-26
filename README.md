# Redmine macOS Timeclock

Menüleisten-App für macOS, die mit einem Redmine-6-Server spricht:

- Ein-/Ausstempeln und Pause über das Plugin [redmine_human-resources](https://github.com/leanderkretschmer/redmine_human-resources)
- Live-Arbeitszeit in der Menüleiste
- Laufende Ticket-Stoppuhr ([jkraemer/stopwatch](https://github.com/jkraemer/stopwatch)) mit Ticket-ID und gebuchter Zeit
- Liste zugewiesener bzw. beobachteter Tickets (`#ID Titel`), Klick öffnet das Ticket im Browser

## Anmeldung

| Funktion | Nur API-Key | Zusätzlich Benutzer/Passwort |
|---|---|---|
| Tickets | ✅ | ✅ |
| Ein-/Ausstempeln | ✅ (Quick-Schnittstelle) | ✅ |
| Pause, Live-Status | ❌ | ✅ |
| Ticket-Stoppuhr | ❌ | ✅ |

Mit `accept_api_auth :status, :start, :pause, :resume, :stop` im `HrTimeclockController`
funktioniert alles auch nur mit API-Key.

## Build

Xcode-Projekt öffnen, Scheme `MyApp` auf „My Mac“ ausführen.
