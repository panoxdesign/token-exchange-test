# Booking Restriction Mapper

Custom Protocol Mapper "Booking Restriction Mapper" für **Domain B** (`backend-keycloak`) — das ist
Mapper 2 der Token-Exchange-Kette. Er liest beim JWT Authorization Grant (token3) den `scope`-Claim
aus der mitgeschickten Assertion, filtert darin die Einträge mit Präfix `service:` (die gebuchten
Dienste) und verengt `resource_access` im ausgestellten Access Token auf genau diese Dienste. Ohne
Treffer wird `resource_access` komplett geleert (fail-closed).

Anders als der frühere `tenant-restriction-mapper` kennt das Backend dabei **keine Mandanten**
mehr: Es prüft nur noch, ob ein Dienst laut Assertion gebucht ist — welcher Mandant das ist und ob
er den Dienst gebucht hat, entscheidet ausschließlich das Frontend/BFF (siehe
[`../docs/buchungen.csv`](../docs/buchungen.csv)).

Läuft mit Priorität 100, also nach den Standard-Rollen-Mappern (Priorität 40), damit
`resource_access` beim Verengen bereits befüllt ist.

## `scope` beim Dekodieren der Assertion

Die Assertion wird wie beim `jwt-bearer`-Grant selbst als `JsonWebToken` dekodiert
(`JWTAuthorizationGrantType.java`, Keycloak 26.7.0). `scope` ist dort **kein** deklariertes Feld —
das liegt nur in der Unterklasse `AccessToken` (`AccessToken.java:162-163`, `@JsonProperty("scope")`).
Beim Dekodieren als `JsonWebToken` fängt dessen `@JsonAnySetter` (`JsonWebToken.java:293-296`) jede
unbekannte Property ab und legt sie in `otherClaims` ab — `scope` landet also dort, genau wie
`tenant`/`domain` bei den anderen beiden Mappern. Kein Sonderfall, keine zweite Dekodierung als
`AccessToken` nötig.

## JAR bauen

Auf dem Host wird weder Java noch Maven benötigt — der Build läuft komplett in Docker.

**Variante a) über das Dockerfile (BuildKit-Output):**

Aus dem Repo-Root:

```bash
docker build --output type=local,dest=./target ./booking-restriction-mapper
```

Aus diesem Unterordner:

```bash
docker build --output type=local,dest=./target .
```

Beide Varianten legen `booking-restriction-mapper.jar` unter `target/` ab.

**Variante b) ohne Dockerfile, direkt mit dem Maven-Image:**

```bash
docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -B clean package
```

Das JAR liegt dann unter `target/booking-restriction-mapper.jar`.

## Einbinden

Das JAR wird per Volume-Mount in `backend-keycloak` eingehängt (`docker-compose.yaml`) und über
`setup-realms.sh` an einem Default-Client-Scope des Backend-Requester-Clients registriert, damit der
Mapper bei jedem JWT-Authorization-Grant-Request (token3) greift. `start-dev` lädt den Provider
automatisch.
