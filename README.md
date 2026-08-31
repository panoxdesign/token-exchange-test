# keycloak-token-exchange-test

Lernlabor zu **Token Exchange zwischen zwei Keycloak-Instanzen**: Ein Service-Account-Client im
Frontend-Keycloak tauscht sein Token gegen ein Token des Backend-Keycloak, zugeschnitten auf genau
einen von zwei Ziel-Diensten.

```
Frontend (localhost:8080)              Backend (localhost:8081)
─────────────────────────              ────────────────────────
domain-5678  (Service Account)         domain-5678  (Requester)
     │ client_credentials                   │ jwt-bearer + scope=e-rechnung
     ▼                                      ▼
  token1  ──token-exchange──►  token2  ───────────────►  token3
                            (Assertion)                  aud: e-rechnung
                                                         roles: reader, writer
```

Technisch ist das **Identity Chaining**: Standard Token Exchange V2 arbeitet nur realm-intern, der
instanzübergreifende Fall geht in Keycloak 26.7 über Token Exchange **plus** JWT Authorization Grant
(RFC 7523). Das Frontend ist für das Backend ein Identity Provider.

Die vollständige Erklärung — warum das so aussieht, was jedes Objekt tut, welche Claims real
herauskommen — steht in **[SETUP.md](SETUP.md)**. Dieses README ist nur der Einstieg.

## Voraussetzungen

- Docker mit Compose
- `jq` (`brew install jq`)
- Die Ports **8080** und **8081** frei

## Schnellstart

```bash
docker compose up -d      # beide Keycloaks + je eine Postgres, ~30 s bis erreichbar
./setup-realms.sh --recreate
./check-setup.sh
```

`setup-realms.sh` legt beide Realms komplett an und gibt am Ende die drei curl-Aufrufe mit
eingesetzten Werten aus. Danach lässt sich die Kette direkt in der Shell oder mit den
Bruno-Requests `01` → `02` → `03a`/`03b` durchspielen.

Admin-Konsolen: <http://localhost:8080> und <http://localhost:8081>, jeweils `admin`/`admin`.

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yaml` | zwei Keycloak 26.7.2 auf je einer Postgres 18. `KC_HOSTNAME` fixiert die Issuer |
| `setup-realms.sh` | Provisionierung beider Realms über die Admin-API. Idempotent; `--recreate` baut von null |
| `check-setup.sh` | prüft die Konfiguration Punkt für Punkt, rein lesend, Exit-Code 1 bei Lücken |
| `SETUP.md` | die Erklärung: Aufbau, Token-Claims, Stolperfallen, Troubleshooting |
| `HANDOFF-2026-08-28.md` | Session-Protokoll: Entscheidungen, Fallen aus dem ersten Durchgang, offene Fragen |
| `bruno/Keycloak-TokenExchange-Test/` | Bruno-Collection mit den vier Requests und der Environment `Test` |
| `etc/{frontend,backend}-db/data/` | Postgres-Daten der beiden Instanzen (nicht versioniert) |

## Anpassen

Beide Skripte lesen ihre Werte aus Umgebungsvariablen, die Defaults stehen im Kopf der Dateien:

```bash
DOMAIN=domain-1234 ./setup-realms.sh
FE=http://localhost:8080 BE=http://localhost:8081 ./check-setup.sh
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
