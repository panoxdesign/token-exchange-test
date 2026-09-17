# Selfservice Exchange Gate

Custom Protocol Mapper "Selfservice Exchange Gate" fuer **Domain A** (`frontend-keycloak`). Er
gated den externen Token Exchange (token2 -> token3): nur wenn `lab-user` die Client-Rolle
`selfservice` im **aktiven Mandanten** hat - der Domain, auf die das subject_token (token1)
zugeschnitten ist -, traegt er die Backend-Issuer-URL als `aud` in token2 ein. Der interne Exchange
(token1) ist davon unberuehrt.

## Warum nicht einfach eine Rolle + Role Scope Mapping?

Weil Standard Token Exchange V2 den aktiven Mandanten dabei nicht sehen wuerde. Der eingebaute
`AudienceResolveProtocolMapper` (im Client Scope `roles`) leitet die `aud` aus den **statischen**
Rollenzuweisungen des Users ab - unabhaengig davon, fuer welche Domain token1 gerade ausgestellt
wurde. Traegt `lab-user` `selfservice` an domain-5678, waere diese Rolle fuer den Mapper immer
sichtbar, auch wenn token1 gerade fuer domain-1234 gilt. Ein rollenbasiertes Gate an einem
eigenstaendigen Audience-Ziel-Client waere ebenso blind: es fragt "hat der User irgendwo
`selfservice`?", nicht "hat der User `selfservice` in der Domain, fuer die token1 ausgestellt
wurde?".

Der aktive Mandant steht ausschliesslich **im Inhalt von token1** selbst: dessen `domain`-Claim
(Hardcoded-Claim-Mapper auf dem jeweiligen Domain-Scope) und die darunter aufgeloesten Rollen in
`resource_access`. Nur ein Mapper, der token1 (den subject_token des Exchange) tatsaechlich liest,
kann diese beiden Werte gegeneinander pruefen - genau das Muster von `RequestedTenantMapper`
(`requested-tenant-mapper/`).

## Wie der Gate wirkt

`TokenManager.transformAccessToken` laesst beim Bau von token2 zuerst **alle** Protocol-Mapper
laufen und entfernt erst danach ueber `restrictRequestedAudience` aus der angeforderten Audience
alles, was nicht im Token steht. Setzt dieser Mapper die konfigurierte Audience (weil die Rolle im
aktiven Mandanten vorhanden ist), bleibt sie erhalten und Schritt 02 liefert token2. Setzt er sie
nicht, bleibt `aud` leer, und Schritt 02 scheitert hart mit `invalid_request: Requested audience
not available` - es gibt dann gar kein token2, Schritt 03 ist unerreichbar.

Fail-closed: Fehlt der subject_token, laeuft kein Token-Exchange-Grant, ist die Signatur des
subject_token ungueltig, steht `domain` nicht in dessen `aud`, oder fehlen `domain`-Claim,
`resource_access` fuer diese Domain oder die Rolle darin, wird nichts hinzugefuegt.

## Warum der Mapper selbst prueft

`grant_type` und Signatur waren bisher ungeprueft, weil `access-backend` nur an `gateway` haengt und
der nur Token Exchange kann - eine reine Konfigurationsannahme, die kein Code erzwingt. Haengt ein
Admin `access-backend` faelschlich an einen anderen Client oder schaltet an `gateway` einen weiteren
Grant frei, koennte ein Aufrufer einen selbstgebauten, unsignierten `subject_token`-Parameter
unterschieben. Gemessener Gegenbeweis: Password Grant mit `scope=access-backend` und einem
selbstgebauten `subject_token` (`domain=domain-1234`,
`resource_access.domain-1234.roles=[selfservice]`) liefert seit dieser Haertung ein Token ohne
Backend-`aud` - vorher haette der Mapper sie faelschlich gesetzt.

## Konfiguration

Zwei Config-Properties:

| Property | Bedeutung | Default |
|---|---|---|
| `included.client.audience` | Client-ID (Issuer-URL des Backends), die bei bestandenem Gate als `aud` gesetzt wird | keiner, Pflichtfeld |
| `role` | Client-Rolle, die im aktiven Mandanten vorhanden sein muss | `selfservice` |

## JAR bauen

Auf dem Host wird weder Java noch Maven benoetigt — der Build laeuft komplett in Docker.

**Variante a) ueber das Dockerfile (BuildKit-Output):**

Aus dem Repo-Root:

```bash
docker build --output type=local,dest=./selfservice-exchange-gate/target ./selfservice-exchange-gate
```

Aus diesem Unterordner:

```bash
docker build --output type=local,dest=./target .
```

Beide Varianten legen `selfservice-exchange-gate.jar` unter `target/` ab.

**Variante b) ohne Dockerfile, direkt mit dem Maven-Image:**

```bash
docker run --rm -v "$PWD":/app -w /app maven:3.9-eclipse-temurin-21 mvn -B clean package
```

Das JAR liegt dann unter `target/selfservice-exchange-gate.jar`.

## Einbinden in die bestehende Instanz

Es wird **kein** neues Keycloak-Image gebaut. Das JAR wird per Volume-Mount in die bestehende,
unveraenderte `keycloak/keycloak:26.7.2`-Instanz eingehaengt — **nur bei `frontend-keycloak`
(Domain A)**, wie `requested-tenant-mapper`.

`docker-compose.yaml` bringt den Mount bereits mit:

```yaml
volumes:
  - ./selfservice-exchange-gate/target/selfservice-exchange-gate.jar:/opt/keycloak/providers/selfservice-exchange-gate.jar
```

**Reihenfolge beachten:** Erst das JAR bauen (siehe oben), dann `docker compose up -d` starten —
sonst schlaegt der Bind-Mount fehl, weil die Datei noch nicht existiert.

## Am richtigen Client Scope registrieren

`setup-realms.sh` registriert den Mapper automatisch am Client Scope `access-backend` (Variable
`ACCESS_SCOPE`) - demselben Scope, der auch den RTM-Mapper traegt. So greift er nur beim
Exchange-Schritt token1 -> token2 (Schritt 02).

Von Hand: Admin-Console von Domain A (`http://localhost:8080`) -> Client Scope `access-backend` ->
Reiter **Mappers** -> **Configure a new mapper** -> **"Selfservice Exchange Gate"** auswaehlen
(dass er in der Liste steht, beweist, dass Keycloak den Provider geladen hat) -> `included.client.audience`
auf die Backend-Issuer-URL setzen -> **Save**.
