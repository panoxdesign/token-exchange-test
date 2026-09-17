# keycloak-token-exchange-test

Lernlabor zu **Token Exchange zwischen zwei Keycloak-Instanzen**: Ein Nutzer meldet sich im
Frontend-Keycloak per Password Grant an, ein Gateway tauscht sein Token intern auf eine Ziel-Domain
zu und dann extern gegen ein Token des Backend-Keycloak, zugeschnitten auf genau einen von zwei
Ziel-Diensten.

```
Frontend (localhost:8080)                              Backend (localhost:8181)
─────────────────────────                              ────────────────────────
lab-user (Password Grant, self-service-portal)         backend-requester  (Requester)
     │                                                       │ jwt-bearer + scope=e-rechnung
     ▼                                                       ▼
  token_sp ──gateway, exchange──► token1 ──gateway, exchange──► token2 ──────────────► token3
                  (aud: domain-5678)              (Assertion)                        aud: e-rechnung
                                                                                      roles: reader, writer
```

Technisch ist das **Identity Chaining**: Standard Token Exchange V2 arbeitet nur realm-intern, der
instanzübergreifende Fall geht in Keycloak 26.7 über Token Exchange **plus** JWT Authorization Grant
(RFC 7523). Das Frontend ist für das Backend ein Identity Provider.

Die vollständige Erklärung — warum das so aussieht, was jedes Objekt tut, welche Claims real
herauskommen — steht in **[SETUP.md](SETUP.md)**. Dieses README ist nur der Einstieg.

Der interne Token Exchange über das Gateway (token_sp → token1) ist dabei keine unabhängige
Nebenkette, sondern die erste Stufe derselben Kette — ganz ohne zweiten Keycloak lässt sich damit
auch zeigen, dass Token Exchange V2 ausschließlich realm-intern arbeitet. Details in
**[docs/Interner-Token-Exchange.md](docs/Interner-Token-Exchange.md)**.

Drei **Custom Protocol Mapper** schärfen die cross-realm Kette: Mapper 1
(`requested-tenant-mapper/`) trägt den aktiven Mandanten aus token1 als mandantenbindenden
`tenant`-Claim in token2. Der **Selfservice Exchange Gate** (`selfservice-exchange-gate/`) lässt den
externen Exchange (token1 → token2) nur zu, wenn der User im *aktiven* Mandanten aus token1 die
Rolle `selfservice` trägt — `lab-user` hat sie nur auf `domain-5678`, aus `domain-1234` bleibt das
Backend unerreichbar. Mapper 2 (`booking-restriction-mapper/`) verengt token3 im Backend auf die
Dienste, die laut `scope`-Claim der Assertion tatsächlich gebucht sind — fail-closed ohne Treffer.
Das Backend kennt dabei keine Mandanten mehr; welcher Mandant welchen Dienst gebucht hat, steht nur
im Frontend/BFF (**[docs/buchungen.csv](docs/buchungen.csv)**, später eine DB; bewusst nie in
Keycloak — das Gateway/BFF setzt die Buchung durch, Keycloak signiert sie nur). Alle
drei Mapper prüfen dabei den Grant-Typ selbst, RTM und Gate zusätzlich die Signatur des
subject_token — ein fremder Grant am selben Client kann ihnen also keinen selbstgebauten Parameter
unterschieben. Details und gemessene Fälle in
**[docs/Mapper2-Spezifikation.md](docs/Mapper2-Spezifikation.md)**, der Gate-Testablauf in
SETUP.md, ein automatisierter Regressionstest der ganzen Kette in `test-chain.sh`.

## Voraussetzungen

- Docker mit Compose
- `jq` (`brew install jq`)
- Die Ports **8080** und **8181** frei

## Schnellstart

```bash
# einmalig: die drei Mapper-JARs bauen (Docker-Build, kein Java/Maven auf dem Host)
docker build --output type=local,dest=./requested-tenant-mapper/target    ./requested-tenant-mapper
docker build --output type=local,dest=./booking-restriction-mapper/target ./booking-restriction-mapper
docker build --output type=local,dest=./selfservice-exchange-gate/target   ./selfservice-exchange-gate

docker compose up -d      # beide Keycloaks + je eine Postgres, ~30 s bis erreichbar
./setup-realms.sh --recreate
./check-setup.sh
./test-chain.sh           # Verhaltens-Regressionstest der Kette, 12 Faelle
```

Die JARs werden per Volume in die Keycloaks gemountet und liegen nicht im Git — ohne sie startet
der Stack nicht. `setup-realms.sh` legt beide Realms komplett an und gibt am Ende die curl-Aufrufe
mit eingesetzten Werten aus. Danach lässt sich die Kette direkt in der Shell oder mit den
Bruno-Requests `04` → `05a` → `02` → `03a`/`03b` durchspielen (`05b` für die andere Domain, `03c`
für die Gegenprobe „ungebuchter Dienst → leer").

Admin-Konsolen: <http://localhost:8080> und <http://localhost:8181>, jeweils `admin`/`admin`.

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yaml` | zwei Keycloak 26.7.2 auf je einer Postgres 18. `KC_HOSTNAME` fixiert die Issuer |
| `setup-realms.sh` | Provisionierung beider Realms über die Admin-API. Idempotent; `--recreate` baut von null |
| `check-setup.sh` | prüft die Konfiguration Punkt für Punkt, rein lesend, Exit-Code 1 bei Lücken |
| `test-chain.sh` | Verhaltens-Regressionstest der Kette, 12 Fälle, rein lesend, Exit-Code 1 bei Abweichung |
| `SETUP.md` | die Erklärung: Aufbau, Token-Claims, Stolperfallen, Troubleshooting |
| `docs/Interner-Token-Exchange.md` | erste Stufe der Kette im Detail: interner Token Exchange über ein Gateway, ohne zweiten Keycloak |
| `requested-tenant-mapper/` | Custom Protocol Mapper 1: leitet den `tenant`-Claim in token2 aus dem `domain`-Claim des subject_token (token1) ab (Docker-Build) |
| `selfservice-exchange-gate/` | Custom Protocol Mapper (Gate): setzt die Backend-`aud` in token2 nur, wenn token1 im aktiven Mandanten die Rolle `selfservice` trägt (Docker-Build) |
| `booking-restriction-mapper/` | Custom Protocol Mapper 2: verengt token3 auf die im `scope`-Claim der Assertion gebuchten Dienste (Docker-Build) |
| `docs/buchungen.csv` | Beispiel-Buchungsdaten (Mandant → Service), Platzhalter für die spätere Buchungs-DB; liest nur das Frontend/BFF, nie Keycloak |
| `docs/Mapper2-Spezifikation.md` | Spezifikation + gemessener Nachweis von Mapper 2 |
| `docs/Mapper2-Recherche.md` | Quellcode-Belege (Keycloak 26.7.0) zur Machbarkeit von Mapper 2 |
| `docs/keycloak-fallstricke.md` | Kurzliste der Stolperfallen, die real Zeit gekostet haben |
| `docs/archiv/` | Design-Historie aus der Zeit vor dem gebauten Lab, kein Ist-Stand |
| `bruno/Keycloak-TokenExchange-Test/` | Bruno-Collection: `04` → `05a`/`05b` → `02` → `03a`/`03b` für die Kette, `03c` als Fail-closed-Gegenprobe, plus die Environment `Test` |
| `etc/{frontend,backend}-db/data/` | Postgres-Daten der beiden Instanzen (nicht versioniert) |

## Anpassen

Beide Skripte lesen ihre Werte aus Umgebungsvariablen, die Defaults stehen im Kopf der Dateien:

```bash
DOMAIN=domain-1234 ./setup-realms.sh
FE=http://localhost:8080 BE=http://localhost:8181 ./check-setup.sh
```

Wer die Ziel-Dienste ändern will, passt das Array `SERVICES` in beiden Skripten an
(`name:rolle,rolle`).

## Zurücksetzen

```bash
./setup-realms.sh --recreate                # nur die Realms neu aufbauen
docker compose down -v && docker compose up -d && ./setup-realms.sh --recreate   # alles
```

Die Konfiguration liegt in Postgres und übersteht ein `docker compose down` ohne `-v`.

## Lab-Charakter

Die Client-Secrets stehen im Klartext in `setup-realms.sh` und in der Bruno-Environment, der
Admin-Zugang ist überall `admin`/`admin`. Das ist Absicht — es macht den Neuaufbau reproduzierbar
und die Collection sofort lauffähig. Für alles außer einem Testlabor ist es falsch.
