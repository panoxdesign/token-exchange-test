# CLAUDE.md

Hinweise für die Arbeit an diesem Repository. Das übergeordnete
`/Users/patrick/projekte/docker/CLAUDE.md` (Sandbox-Umgebung, Netzwerk, Git) gilt zusätzlich.

1. Erst denken, dann coden

Nicht annehmen. Verwirrung nicht verstecken. Zielkonflikte aufzeigen.

Vor der Umsetzung:

    Benenne deine Annahmen explizit. Wenn du unsicher bist, frage nach.

    Wenn es mehrere Interpretationen gibt, stelle sie vor – wähle nicht stillschweigend eine aus.

    Wenn es einen einfacheren Ansatz gibt, sage es. Widersprich, wenn es angebracht ist.

    Wenn etwas unklar ist, halte inne. Benenne, was verwirrend ist. Frage nach.

2. Einfachheit an erster Stelle

Minimaler Code, der das Problem löst. Nichts Spekulatives.

    Keine Funktionen über das Hinaus, was gefordert wurde.

    Keine Abstraktionen für Code, der nur an einer Stelle genutzt wird.

    Keine "Flexibilität" oder "Konfigurierbarkeit", nach der nicht gefragt wurde.

    Keine Fehlerbehandlung für unmögliche Szenarien.

    Wenn du 200 Zeilen schreibst und es auch 50 sein könnten, schreibe es um.

Frage dich: "Würde ein Senior Engineer sagen, dass das zu kompliziert ist?" Wenn ja, vereinfache es.
3. Punktgenaue Änderungen

Rühre nur an, was du musst. Räume nur deinen eigenen Mess auf.

Beim Bearbeiten von bestehendem Code:

    "Verbessere" keinen angrenzenden Code, keine Kommentare oder Formatierungen.

    Refactore nichts, was nicht kaputt ist.

    Passe dich dem bestehenden Stil an, selbst wenn du es anders machen würdest.

    Wenn dir unbeteiligter, toter Code auffällt, erwähne ihn – lösche ihn nicht.

Wenn deine Änderungen ungenutzten Code hinterlassen:

    Entferne Imports, Variablen oder Funktionen, die durch DEINE Änderungen nutzlos wurden.

    Entferne keinen bereits zuvor vorhandenen toten Code, außer du wirst darum gebeten.

Der Test: Jede geänderte Zeile muss sich direkt auf die Anfrage des Nutzers zurückführen lassen.
4. Zielorientierte Ausführung

Kriterien für Erfolg definieren. Schleife ausführen, bis es überprüft ist.

Verwandle Aufgaben in überprüfbare Ziele:

    "Validierung hinzufügen" → "Tests für ungültige Eingaben schreiben, dann dafür sorgen, dass sie bestehen"

    "Bug beheben" → "Einen Test schreiben, der ihn reproduziert, dann dafür sorgen, dass er besteht"

    "X refactoren" → "Sicherstellen, dass die Tests vorher und nachher bestehen"

Bei mehrstufigen Aufgaben, erstelle einen kurzen Plan:

1. [Schritt] → überprüfen: [Check]
2. [Schritt] → überprüfen: [Check]
3. [Schritt] → überprüfen: [Check]

## Worum es geht

Lernlabor für **Token Exchange zwischen zwei Keycloak-Instanzen** (Identity Chaining: Token Exchange
V2 + JWT Authorization Grant, Keycloak 26.7). Kein Anwendungscode — das Repo besteht aus einem
Compose-Stack, zwei Bash-Skripten, einer Bruno-Collection und der Dokumentation.

Ziel ist **Verständnis**, nicht Betrieb. Änderungen sollen den Mechanismus deutlicher machen; die
Erklärung in `SETUP.md` ist Teil des Produkts, nicht Beiwerk.

Reihenfolge beim Einlesen: `README.md` → `SETUP.md` → `setup-realms.sh` (der Kommentarkopf listet
alle angelegten Objekte) → `check-setup.sh`.

## Sprache

Alles auf **Deutsch** — Dokumentation, Kommentare, Skript-Ausgaben, Commit-Messages. In Bash-Skripten
ohne Umlaute (`Ausfuehren`, `pruefen`), in Markdown mit.

## Setup und Ausführung

```bash
docker compose up -d          # ~30 s bis beide Keycloaks erreichbar sind
./setup-realms.sh --recreate  # Realms von null aufbauen
./check-setup.sh              # verifizieren, rein lesend
```

Beide Skripte konfigurieren sich über Umgebungsvariablen mit Defaults (`FE`, `BE`, `FE_REALM`,
`BE_REALM`, `DOMAIN`, `ADMIN_USER`/`ADMIN_PASS`, …). Neue Parameter nach demselben Muster ergänzen:
`X="${X:-default}"`.

## Konventionen

- **Ausführbare Skripte statt Copy-Paste-Blöcken.** Wiederkehrende Handgriffe gehören in ein Skript.
- **`setup-realms.sh` bleibt idempotent.** Ein zweiter Lauf ohne `--recreate` muss grün bleiben und
  nichts zerstören. Bestehende Objekte werden ergänzt, nicht neu angelegt.
- **`check-setup.sh` bleibt rein lesend.** Nur GET-Requests, Exit-Code 1 bei Lücken. Jede neue
  Eigenschaft, die `setup-realms.sh` setzt, bekommt dort eine eigene Prüfung.
- **Ausgabe-Helfer benutzen** statt roher `echo`: `step`/`ok`/`skip`/`die` im Setup,
  `ok`/`bad`/`warn`/`head_` im Check.
- **Kommentare erklären das Warum.** Warum `jwksUrl` einen anderen Host nennt als `issuer`, warum
  `${5:+-H "..."}` nicht funktioniert — nicht, was die Zeile tut.
- **Lab-Secrets bleiben im Klartext** und müssen zwischen `setup-realms.sh` und
  `bruno/…/environments/Test.yml` identisch sein. Ändert man eines, das andere mitziehen.
- **Nach `sed -i` das Ausführungs-Bit prüfen** (`chmod 755`) — es geht dabei verloren.
- Realm-Namen sind gesetzt: `frontend` und `Backend-Microservices` (mit Großbuchstaben).

## Keycloak-Fallstricke

Diese Punkte haben schon Zeit gekostet und sind in `SETUP.md` ausführlich beschrieben:

- **Attributnamen rät man nicht.** Die relevanten:

  ```
  standard.token.exchange.enabled           Client (Frontend), Token Exchange
  oauth2.jwt.authorization.grant.enabled    Client (Backend), JWT Grant
  oauth2.jwt.authorization.grant.idp        Client (Backend), Allow-Liste
  jwtAuthorizationGrantEnabled              IdP-Config
  fullScopeAllowed                          Top-Level-Feld, KEIN Attribut
  ```

- **`Full scope allowed` muss am Requester-Client `Off` sein.** Auf `On` (Keycloak-Default) landen
  alle Rollen im Token, egal welcher Scope angefordert wurde. Daran hängt die gesamte Trennung der
  beiden Ziel-Dienste.
- **`issuer` und `jwksUrl` des IdP nennen absichtlich verschiedene Hosts** — `localhost:8080` im
  Token, `frontend-keycloak:8080` für den JWKS-Abruf aus dem Backend-Container. Deshalb ist der
  Discovery-Endpoint im Admin-UI unbenutzbar, und alle Requests müssen über `localhost:8080`/`:8181`
  laufen.
- **Der Ziel-User im Backend ist `lab-user`, kein Service Account.** Die Falle steckt im Lookup:
  `GET /users?username=…&exact=true` liefert auch Service Accounts mit, deshalb landet die Federated
  Identity sonst leicht am Service Account eines Backend-Clients (falsche Rollen). `setup-realms.sh`
  bricht ab, wenn der gewählte Ziel-User ein Service Account ist.
- **Jede Assertion gilt genau einmal** (`Token reuse detected`). Für den zweiten Dienst token2 neu
  holen.
- Das Admin-Token des `master`-Realms lebt **60 Sekunden**.
- Die aussagekräftige Fehlermeldung steht im Server-Log, nicht in der HTTP-Antwort:
  `docker compose logs -f backend-keycloak`.

## Testen aus der Sandbox

Die Keycloaks des Nutzers laufen auf seinem macOS-Host und sind aus der Sandbox **nicht erreichbar**
(Netzwerk-Policy, anderer Docker-Daemon). Verifiziert wird deshalb mit einem eigenen Stack:

- Compose-Kopie im Scratchpad, `-p kctest`, **benannte Volumes statt der Bind-Mounts** — sonst
  fasst der Testlauf `etc/{frontend,backend}-db/data` des Nutzers an.
- Vor Sessionende `docker compose -p kctest down -v`.
- Behauptungen über Keycloak-Verhalten im Quellcode belegen: Tag `26.7.0` über
  `raw.githubusercontent.com` (erreichbar). `www.keycloak.org` ist blockiert — Doku stattdessen aus
  dem Repo unter `docs/guides/securing-apps/*.adoc`.

## Doku pflegen

Änderungen am Aufbau schlagen auf mehrere Dateien durch. Bei einer Änderung an `setup-realms.sh`
prüfen, ob `check-setup.sh`, `SETUP.md` (Diagramm, Objekt-Tabellen, Troubleshooting), `README.md`
und die Bruno-Environment mitgezogen werden müssen.

Token-Claims in `SETUP.md` sind **gemessene** Werte, keine erfundenen. Wer sie ändert, misst neu.
