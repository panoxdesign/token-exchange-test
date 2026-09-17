# Requested Tenant Mapper

Custom Protocol Mapper "Requested Tenant Mapper" fuer **Domain A** (`frontend-keycloak`). Er liest
beim Standard Token Exchange (token1 -> token2) den `domain`-Claim aus dem subject_token (token1)
und schreibt ihn als `tenant`-Claim in die ausgestellte Assertion (token2). Der subject_token ist
bereits vom Exchange signaturgeprueft, bevor Mapper laufen - eine erneute Pruefung ist hier nicht
noetig. Ein Request-Parameter wird bewusst **nicht** entgegengenommen: fruehere Fassungen lasen
`requested_tenant` frei aus den Form-Parametern, was Privilege Escalation erlaubte (Aufrufer konnte
sich einen beliebigen Mandanten aussuchen). Seit der Umstellung auf Buchungs-Scopes ist `tenant`
ein reiner Audit-Claim: Domain B kennt keine Mandanten mehr, Mapper 2 (`booking-restriction-mapper/`)
kopiert ihn nur nach token3 und wertet ihn nicht zur Autorisierung aus.

## JAR bauen

Auf dem Host wird weder Java noch Maven benoetigt — der Build laeuft komplett in Docker.

**Variante a) ueber das Dockerfile (BuildKit-Output):**

Aus dem Repo-Root:

```bash
docker build --output type=local,dest=./requested-tenant-mapper/target ./requested-tenant-mapper
```

Aus diesem Unterordner:

```bash
docker build --output type=local,dest=./target .
```

Beide Varianten legen `requested-tenant-mapper.jar` unter `target/` ab.

**Variante b) ohne Dockerfile, direkt mit dem Maven-Image:**

```bash
docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -B clean package
```

Das JAR liegt dann unter `target/requested-tenant-mapper.jar`.

## Einbinden in die bestehende Instanz

Es wird **kein** neues Keycloak-Image gebaut. Das JAR wird per Volume-Mount in die bestehende,
unveraenderte `keycloak/keycloak:26.7.2`-Instanz eingehaengt — **nur bei `frontend-keycloak`
(Domain A)**, nicht bei `backend-keycloak`.

`docker-compose.yaml` bringt den Mount bereits mit:

```yaml
volumes:
  - ./requested-tenant-mapper/target/requested-tenant-mapper.jar:/opt/keycloak/providers/requested-tenant-mapper.jar
```

**Reihenfolge beachten:** Erst das JAR bauen (siehe oben), dann `docker compose up -d` starten —
sonst schlaegt der Bind-Mount fehl, weil die Datei noch nicht existiert.

Bei `start-dev` liest Keycloak neue Provider unter `/opt/keycloak/providers/` beim Start automatisch
ein. Ein manuelles `kc.sh build` ist hier nicht noetig.

## Am richtigen Client Scope registrieren

Den Mapper an den Client Scope haengen, der token2 die Backend-Audience gibt — im Lab-Setup ist das
`access-backend` (Variable `ACCESS_SCOPE` in `setup-realms.sh`). So greift der Mapper nur beim
Exchange-Schritt token1 → token2.

1. Admin-Console von Domain A oeffnen (`http://localhost:8080`).
2. Client Scope `access-backend` → Reiter **Mappers** → **Configure a new mapper**.
3. **"Requested Tenant Mapper"** auswaehlen (dass er in der Liste steht, beweist, dass Keycloak den
   Provider geladen hat) → **Save**.

Der Mapper hat **keine** Konfigurationsoptionen und muss keine haben: er schreibt den Claim immer in
das Access Token, sobald er greift (er ueberschreibt dafuer `transformAccessToken`). Der sonst
uebliche Schalter "Add to access token" waere hier wirkungslos und entfaellt bewusst.

## Claim-Ableitung testen

Zwei Dinge muessen stimmen, sonst laeuft der Mapper nicht:

- **Der Scope muss angefordert werden** (`scope=access-backend`) — und der anfragende Client muss
  diesen Scope zugewiesen haben. Im Lab-Setup hat ihn `gateway`. Ohne diesen Scope antwortet
  Keycloak mit `invalid_scope`.
- Der subject_token (token1) braucht einen `domain`-Claim — den setzt der Hardcoded-Claim-Mapper
  auf dem Domain-Scope (siehe `setup-realms.sh`, `ensure_hardcoded_claim_mapper`).

Vollstaendige Kette (siehe `SETUP.md`, Abschnitt "Die Kette durchlaufen"):

```bash
FE=http://localhost:8080

token_sp=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=password \
  -d username=lab-user -d password=lab-user \
  -d client_id=self-service-portal -d client_secret=lab-frontend-sp-secret | jq -r .access_token)

token1=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token_sp" \
  -d audience=domain-5678 -d scope=domain-5678 \
  -d client_id=gateway -d client_secret=lab-frontend-gateway-secret | jq -r .access_token)

token2=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1" \
  -d scope=access-backend \
  -d audience=http://localhost:8181/realms/Backend-Microservices \
  -d client_id=gateway -d client_secret=lab-frontend-gateway-secret | jq -r .access_token)

echo "$token2" | cut -d. -f2 | base64 -d 2>/dev/null | jq .tenant
```

Erwartet (gemessen):

```json
"tenant": "domain-5678"
```

Ein zusaetzlich mitgeschickter `requested_tenant=domain-1234` aendert daran nichts mehr — der
Mapper liest den Parameter gar nicht erst.
