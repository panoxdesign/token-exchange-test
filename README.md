# keycloak-token-exchange-test

Lernlabor zu **Token Exchange zwischen zwei Keycloak-Instanzen**: Ein Service-Account-Client im
Frontend-Keycloak tauscht sein Token gegen ein Token des Backend-Keycloak, zugeschnitten auf genau
einen von zwei Ziel-Diensten.

```
Frontend (localhost:8080)              Backend (localhost:8181)
─────────────────────────              ────────────────────────
domain-5678  (Service Account)         backend-requester  (Requester)
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

Das Labor zeigt inzwischen **zwei** Mechanismen: die cross-realm Kette oben, und daneben einen
internen Token Exchange innerhalb des Frontend-Realms — ein Gateway tauscht ein User-Token gegen
ein auf eine Domain zugeschnittenes Token, ganz ohne zweiten Keycloak. Details in
**[docs/Interner-Token-Exchange.md](docs/Interner-Token-Exchange.md)**.

Die cross-realm Kette selbst lässt sich auch mit einem echten Menschen statt dem Service Account als
Subjekt durchspielen — händisch, additiv zum bestehenden Setup. Details in
**[docs/User-Token-Exchange.md](docs/User-Token-Exchange.md)**.

Zwei **Custom Protocol Mapper** schärfen die cross-realm Kette auf Mandanten: Mapper 1
(`requested-tenant-mapper/`) trägt den gewählten Mandanten als `tenant`-Claim in token2, Mapper 2
(`tenant-restriction-mapper/`) verengt token3 im Backend auf die Rollen genau dieses Mandanten —
fail-closed ohne bestätigte Gruppenmitgliedschaft. Details und gemessene Fälle in
**[docs/Mapper2-Spezifikation.md](docs/Mapper2-Spezifikation.md)**.

## Voraussetzungen

- Docker mit Compose
- `jq` (`brew install jq`)
- Die Ports **8080** und **8181** frei

## Schnellstart

```bash
docker compose up -d      # beide Keycloaks + je eine Postgres, ~30 s bis erreichbar
./setup-realms.sh --recreate
./check-setup.sh
```

`setup-realms.sh` legt beide Realms komplett an und gibt am Ende die curl-Aufrufe mit eingesetzten
Werten aus. Danach lässt sich die cross-realm Kette direkt in der Shell oder mit den Bruno-Requests
`01` → `02` → `03a`/`03b` durchspielen, der interne Exchange über `04` → `05a`/`05b`.

Admin-Konsolen: <http://localhost:8080> und <http://localhost:8181>, jeweils `admin`/`admin`.

## Dateien

| Datei | Zweck |
|---|---|
| `docker-compose.yaml` | zwei Keycloak 26.7.2 auf je einer Postgres 18. `KC_HOSTNAME` fixiert die Issuer |
| `setup-realms.sh` | Provisionierung beider Realms über die Admin-API. Idempotent; `--recreate` baut von null |
| `check-setup.sh` | prüft die Konfiguration Punkt für Punkt, rein lesend, Exit-Code 1 bei Lücken |
| `SETUP.md` | die Erklärung: Aufbau, Token-Claims, Stolperfallen, Troubleshooting |
| `docs/Interner-Token-Exchange.md` | zweiter Mechanismus: interner Token Exchange über ein Gateway, ohne zweiten Keycloak |
| `docs/User-Token-Exchange.md` | dieselbe cross-realm Kette mit einem echten User statt dem Service Account, händisch umgestellt |
| `requested-tenant-mapper/` | Custom Protocol Mapper 1: leitet den `tenant`-Claim in token2 aus dem `domain`-Claim des subject_token (token1) ab (Docker-Build) |
| `tenant-restriction-mapper/` | Custom Protocol Mapper 2: verengt token3 auf die Rollen der bestätigten Mandanten-Gruppe (Docker-Build) |
| `docs/Mapper2-Spezifikation.md` | Spezifikation + gemessener Nachweis von Mapper 2 |
| `docs/Mapper2-Recherche.md` | Quellcode-Belege (Keycloak 26.7.2) zur Machbarkeit von Mapper 2 |
| `HANDOFF-2026-08-28.md` | Session-Protokoll: Entscheidungen, Fallen aus dem ersten Durchgang, offene Fragen |
| `bruno/Keycloak-TokenExchange-Test/` | Bruno-Collection: `01`-`03b` für die cross-realm Kette, `04`-`05b` für den internen Exchange, plus die Environment `Test` |
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
