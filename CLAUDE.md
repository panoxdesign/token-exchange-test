# CLAUDE.md

Übergeordnetes `/Users/patrick/projekte/docker/CLAUDE.md` gilt zusätzlich.

## 1. Arbeitsweise

- **Denken vor Coden:** Annahmen explizit benennen, Alternativen/Einfacheres aufzeigen, bei Unklarheit sofort nachfragen.
- **Einfachheit:** Minimaler Code. Keine spekulativen Funktionen, unbeauftragte Abstraktionen, Konfigurierbarkeit oder unnötige Fehlerbehandlung.
- **Punktgenaue Änderungen:** Nur Relevantestem anfassen. Kein Refactoring/Formatieren von funktionierendem/fremdem Code. Toter Code nur erwähnen, nicht löschen.
- **Eigene Aufräumarbeiten:** Durch deine Änderung ungenutzte Imports/Variablen löschen.
- **Zielorientierung:** Aufgaben in prüfbare Ziele zerlegen (z. B. fehlschlagenden Test schreiben -> fixen). Bei Multi-Step-Tasks kurze Pläne mit Überprüfungs-Steps erstellen.

## 2. Projekt-Kontext

Lernlabor für **Keycloak 26.7 Token Exchange V2 + JWT Authorization Grant** (Identity Chaining). kein App-Code, nur Docker Compose, 2 Bash-Skripte, Bruno-Collection, Doku.

- **Ziel:** Verständnis > Betrieb. `SETUP.md` ist Kernprodukt.
- **Einlese-Reihenfolge:** `README.md` -> `SETUP.md` -> `setup-realms.sh` (Header) -> `check-setup.sh` -> `test-chain.sh`.
- **Sprache:** Deutsch (Docs, Kommentare, Commits, Skript-Outputs). Bash ohne Umlaute, MD mit Umlauten.

## 3. Setup & Skripte

```bash
docker compose up -d          # ~30s Startzeit
./setup-realms.sh --recreate  # Realms neu aufbauen
./check-setup.sh              # Rein lesende Prüfung (Exit 1 bei Fehlern)
./test-chain.sh               # Verhaltenstest der Kette (Exit 1 bei Abweichung)
```
