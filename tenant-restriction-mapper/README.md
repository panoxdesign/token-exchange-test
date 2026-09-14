# Tenant Restriction Mapper

Custom Protocol Mapper "Tenant Restriction Mapper" für **Domain B** (`backend-keycloak`) — das ist
Mapper 2 der Token-Exchange-Kette. Er liest beim JWT Authorization Grant (token3) den `tenant`-Claim
aus der mitgeschickten Assertion und verengt `resource_access` im ausgestellten Access Token auf die
Client-Rollen der gleichnamigen Mandanten-Gruppe des Users. Ohne bestätigte Gruppenmitgliedschaft
wird `resource_access` komplett geleert (fail-closed) und kein `tenant`-Claim gesetzt.

Läuft mit Priorität 100, also nach den Standard-Rollen-Mappern (Priorität 40), damit
`resource_access` beim Verengen bereits befüllt ist. Details und Quellcode-Belege in
[`../docs/Mapper2-Recherche.md`](../docs/Mapper2-Recherche.md).

## JAR bauen

Auf dem Host wird weder Java noch Maven benötigt — der Build läuft komplett in Docker.

**Variante a) über das Dockerfile (BuildKit-Output):**

Aus dem Repo-Root:

```bash
docker build --output type=local,dest=./target ./tenant-restriction-mapper
```

Aus diesem Unterordner:

```bash
docker build --output type=local,dest=./target .
```

Beide Varianten legen `tenant-restriction-mapper.jar` unter `target/` ab.

**Variante b) ohne Dockerfile, direkt mit dem Maven-Image:**

```bash
docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -B clean package
```

Das JAR liegt dann unter `target/tenant-restriction-mapper.jar`.

## Einbinden

Das JAR wird per Volume-Mount in `backend-keycloak` eingehängt (`docker-compose.yaml`) und über
`setup-realms.sh` an einem Default-Client-Scope des Backend-Requester-Clients registriert, damit der
Mapper bei jedem JWT-Authorization-Grant-Request (token3) greift. `start-dev` lädt den Provider
automatisch.
