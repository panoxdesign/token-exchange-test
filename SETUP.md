# Token Exchange zwischen zwei Keycloak-Instanzen

Ein Nutzer meldet sich im **Frontend-Keycloak** per Password Grant an, ein Gateway tauscht sein
Token intern auf eine Ziel-Domain zu und dann extern gegen ein Token des **Backend-Keycloak**,
zugeschnitten auf genau einen von zwei Ziel-Diensten.

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

Mit `scope=fahrtkostenerstattung` liefert derselbe Aufruf ein Token für den anderen Dienst.
Das ist der Kern: **ein Exchange, zwei Zuschnitte.**

## Schnellstart

```bash
docker compose up -d
./setup-realms.sh --recreate
./check-setup.sh
```

Das Provisionierungs-Skript legt beide Realms komplett an und gibt am Ende die drei curl-Aufrufe
mit eingesetzten Werten aus. `check-setup.sh` prüft jeden Punkt einzeln und ist rein lesend.

---

## Warum das nicht ein einzelner Request ist

Der naheliegende Gedanke — das Frontend-Token einfach an den Token-Endpoint des Backends schicken —
geht nicht: **Standard Token Exchange V2 arbeitet ausschließlich realm-intern.** Er tauscht ein
Token, das *dieser* Realm ausgestellt hat, gegen ein anderes Token *desselben* Realms. Ein fremder
Issuer wird nicht akzeptiert.

Keycloak 26.7 löst den instanzübergreifenden Fall über **Identity Chaining**, zwei hintereinander
geschaltete Bausteine:

| Schritt | Wo | Grant | Ergebnis |
|---|---|---|---|
| 1 | Frontend | `password` | **token1** — gewöhnliches Token des Nutzers |
| 2 | Frontend | `…:grant-type:token-exchange` | **token2** — JWT-*Assertion* für das Backend |
| 3 | Backend | `…:grant-type:jwt-bearer` | **token3** — Access Token des Backends |

Der Kniff steckt in Schritt 2: Der Token Exchange erzeugt kein Bearer-Token, sondern ein JWT, dessen
`aud` die **Issuer-URL des Backends** ist. Das Backend nimmt dieses JWT als Autorisierungs-*Nachweis*
(RFC 7523) und stellt daraufhin ein eigenes Token aus. Das Frontend ist für das Backend ein
Identity Provider.

Beide Bausteine sind in 26.7 offiziell supported — **kein** Preview-Feature, kein `--features`-Flag.

> **Begriffsfalle:** Was umgangssprachlich „Token Exchange zwischen zwei Keycloaks" heißt, ist
> technisch Token Exchange **plus** JWT Authorization Grant. Der alte einzelne Request mit
> `subject_issuer` (Legacy Token Exchange V1) kann das zwar, ist aber deprecated.

Dass V2 ausschließlich realm-intern arbeitet, lässt sich auch **ohne** zweiten Keycloak vorführen:
`setup-realms.sh` baut im selben Frontend-Realm eine zweite, unabhängige Kette auf — ein Gateway
tauscht das Token eines Self-Service-Portals gegen ein auf eine Domain zugeschnittenes Token. Kein
IdP, kein gespiegelter User, dafür ein normales Bearer-Token statt des Einmal-Tickets aus Schritt 2
oben. Beschrieben in [`docs/Interner-Token-Exchange.md`](docs/Interner-Token-Exchange.md).

---

## Die fünf Dinge, die man wissen muss

### 1. Es ist immer ein User im Spiel

Jedes Keycloak-Token hat einen `sub`, und `sub` ist immer ein User. Ein Service Account **ist** ein
User — nur einer, den Keycloak automatisch anlegt, sobald *Service accounts roles* am Client aktiv
ist. Er heißt `service-account-<client-id>`.

Im Backend braucht die Kette deshalb ebenfalls einen User, an den sie andocken kann. Der JWT
Authorization Grant sucht ihn über eine **Federated Identity** und legt ihn **nicht** an — fehlt er,
antwortet Keycloak mit `User not found` (`JWTAuthorizationGrantType.java:139`). Normalerweise
entstünde diese Verknüpfung beim ersten Browser-Login des Nutzers über den IdP; das geskriptete Lab
löst keinen solchen Login aus, also setzt `setup-realms.sh` sie über die Admin-API.

Daher tragen token1/token2 einen anderen `sub` als token3: dieselbe Identität, zwei Realms, zwei IDs.
Die Federated Identity ist das Wörterbuch dazwischen.

In diesem Lab ist das Subjekt bereits ein menschlicher User (`lab-user`, Password Grant über
`self-service-portal`) statt eines Service Accounts — dieselbe Kette liefe unverändert auch mit
einem Service Account als Subjekt, dann über `client_credentials` statt Password Grant.

> **Namensfalle:** Der Ziel-User ist hier `lab-user`. Die Falle steckt im Lookup: weil
> `GET /users?username=…&exact=true` Service Accounts mitliefert (`UsersResource.java:364`), die
> Users-Liste der Konsole aber nicht (Zeile 327/368), hängt man die Federated Identity sonst
> versehentlich an den Service Account eines Backend-Clients — und erbt dessen Rollen.
> `setup-realms.sh` bricht deshalb ab, wenn der gewählte Ziel-User ein Service Account ist.

### 2. Die Assertion zielt auf den Realm, nicht auf einen Client

`aud` in token2 ist die Issuer-URL des Backend-*Realms*. Beim Einlösen prüft das Backend nur, ob das
sein eigener Issuer ist — nicht, welcher Client einlöst. Jeder Backend-Client mit *JWT Authorization
Grant* und passender Allow-Liste kann jede gültige Assertion einlösen. Die Vertrauensbeziehung ist
realm-weit, nicht client-genau. Enger wird sie über Client Policies (`jwt-claim-enforcer`).

### 3. Rollen kommen nie aus dem Frontend

Die Assertion transportiert Identität, keine Berechtigungen. Was der Aufrufer im Backend darf,
entscheidet allein der verlinkte Backend-User — über seine Rollen, seine Gruppen und die
**Default-Rollen des Realms**. Letztere sind die häufigste Erklärung für Einträge in
`resource_access`, die man dem User nirgends zugewiesen hat; `check-setup.sh` gibt sie deshalb aus.

### 4. `Full scope allowed` hebelt die Zuschneidung aus

Der Requester-Client im Backend muss **Full scope allowed = Off** haben. Auf `On` (Keycloak-Default)
landen *alle* Rollen des Users im Token, egal welcher Scope angefordert wurde. Gemessen mit
`scope=e-rechnung`:

| | `aud` | `resource_access` |
|---|---|---|
| **On** | `e-rechnung`, `fahrtkostenerstattung`, `account` | alle drei |
| **Off** | `e-rechnung` | nur `e-rechnung` |

Die ganze Trennung zwischen den beiden Diensten hängt an diesem einen Schalter.

### 5. Die Abbildung ist eindeutig — und nicht beeinflussbar

Ein Frontend-Service-Account entspricht **genau einer** Backend-Identität, dauerhaft. Der Grant
schlägt den Ziel-User ausschließlich über den `sub` der Assertion nach
(`FederatedIdentityEntity.java:40`):

```sql
select link.user from FederatedIdentityEntity link
 where link.realmId = :realmId
   and link.identityProvider = :identityProvider
   and link.userId = :userId      -- der sub aus dem Frontend
```

Der Aufrufer hat darauf keinerlei Einfluss: Weder ein Request-Parameter noch der einlösende Client
noch der Scope können den Ziel-User verändern. Wer welchen `sub` präsentiert, entscheidet allein die
Signatur des Frontends.

Variieren kann die Kette deshalb nur zwei Dinge — **welchen Dienst** das Token adressiert (`scope=`)
und **wie viel** es dort darf (die Rollen des Users). Nie *wer* es ist. Soll `domain-5678` je nach
Kontext als verschiedene Backend-Identitäten auftreten, braucht es entsprechend viele
**Frontend**-Service-Accounts; die Abbildung hängt am `sub`.

Zwei Details am Rand: Der Primärschlüssel der Tabelle ist `(user, identityProvider)` — ein User kann
pro IdP nur eine Verknüpfung haben. Er verhindert aber *nicht*, dass zwei Backend-User auf denselben
Frontend-`sub` zeigen; davor schützt erst `JpaUserProvider.java:755`, und zwar mit einer
`IllegalStateException` statt mit einer Auswahl. Ein zweiter Link auf denselben `sub` legt den Grant
also lahm, statt ihn mehrdeutig zu machen.

Und **Impersonation**, der Mechanismus zum bewussten Wechsel auf einen anderen User, existiert hier
nicht: In der Vergleichstabelle der Keycloak-Doku steht zu Standard Token Exchange V2 ausdrücklich
„Subject impersonation (including direct naked impersonation): *Not implemented yet*". Nur das
deprecated Legacy V1 hatte es.

Für dieses Szenario ist die Eindeutigkeit die gewünschte Eigenschaft: Ein kompromittiertes
Frontend-Secret gibt einem Angreifer die Rechte *dieser einen* Backend-Identität — und keinen Hebel,
sich eine andere auszusuchen.

---

## Die Hostnamen-Konstruktion

Hier steckt die häufigste Fehlerquelle. Zwei Anforderungen stehen sich im Weg:

1. Der `iss` in token2 muss **exakt** dem `issuer` des IdP im Backend entsprechen. Von deinem Host
   aus ist das `http://localhost:8080/realms/frontend`.
2. Das Backend muss die **JWKS** des Frontends abrufen. Aus dem Backend-*Container* heraus zeigt
   `localhost` aber auf das Backend selbst.

Gelöst über zwei getrennte Felder im IdP, die verschiedene Hosts nennen dürfen:

| Feld | Wert | Perspektive |
|---|---|---|
| `issuer` | `http://localhost:8080/realms/frontend` | wie es im Token steht (Host) |
| `jwksUrl` | `http://frontend-keycloak:8080/realms/frontend/protocol/openid-connect/certs` | wie das Backend es erreicht (Docker-DNS) |

Konsequenzen: Der **Discovery endpoint** im Admin-UI ist unbenutzbar (das Backend suchte
`localhost:8080` bei sich selbst) — `setup-realms.sh` konfiguriert den IdP deshalb von Hand. Und alle
Requests müssen konsequent über `localhost:8080` bzw. `:8181` laufen; unter einem anderen Namen
ändert sich der berechnete Issuer und die `aud`-Prüfung schlägt fehl.

`docker-compose.yaml` setzt dafür `KC_HOSTNAME` auf beiden Instanzen. Prüfen:

```bash
curl -s http://localhost:8080/realms/frontend/.well-known/openid-configuration | jq -r .issuer
# http://localhost:8080/realms/frontend

docker compose exec backend-keycloak \
  curl -sf http://frontend-keycloak:8080/realms/frontend/protocol/openid-connect/certs | jq '.keys|length'
# eine Zahl > 0
```

---

## Was angelegt wird

```
FRONTEND-REALM  frontend                          BACKEND-REALM  Backend-Microservices
──────────────────────────────                    ─────────────────────────────────────

self-service-portal                               IdP "frontend"
  Password Grant, aud: gateway                       issuer  = FE-Realm-URL
       │                                              jwksUrl = frontend-keycloak:8080/...
       ▼                                              JWT Authorization Grant: ON
gateway  (Requester, intern UND extern)                     ▲
  Token Exchange: ON                                        │ prüft Signatur + iss
       │ scope=domain-5678, sub bleibt lab-user       backend-requester  (Requester)
       ▼                                                JWT Auth Grant: ON
domain-5678  (Ziel-Domain)                              Full scope allowed: OFF
  Rollen admin, selfservice                             Scopes e-rechnung /
       │                                                       fahrtkostenerstattung
       │ zurueck an gateway:                                  (beide optional)
       │ scope=access-backend                                      │
       │ (Gate-Mapper prueft die Rolle selfservice IM               │ scope= entscheidet
       │  aktiven Mandanten aus token1, RTM liest domain)           │
       ▼                                                           ▼
<backend-issuer-url>                               federated identity
  Client, nur Audience-Ziel                                │
       ▲                                                   ▼
       │ Gate-Mapper + RTM                          lab-user            e-rechnung
access-backend (Client Scope)                      Rollen s.o.          reader, writer
                                                                     fahrtkostenerstattung
                                                                           reader
```

> **`domain-5678` bezeichnet zwei Objekte — beide im Frontend.** Einmal den Client, der als reine
> Ziel-Domain des internen Exchange dient (ohne eigenen Service Account, ohne eigenes
> Token-Exchange-Recht), einmal den gleichnamigen **Client Scope** dazu. Der Backend-Requester heißt
> bewusst **nicht** `domain-5678`, sondern `backend-requester` — vom Mandanten entkoppelt, denn er
> löst die Assertion für jede Ziel-Domain gleichermaßen ein und braucht dafür keine eigene Identität.
> Wessen Antrag er stellt, steht in der Assertion.
>
> Beide Exchange-Schritte der cross-realm Kette laufen über denselben Client: **`gateway`**. Er
> tauscht zuerst das SP-Token gegen ein auf `domain-5678` zugeschnittenes Token (intern, token1),
> und dieses dann gegen die Assertion für das Backend (extern, token2) — der RTM-Mapper liest dabei
> den `domain`-Claim aus token1 selbst, ein Request-Parameter ist dafür nicht mehr nötig.
> Beim Lesen der Admin-Konsole hilft trotzdem, jedes Mal zu fragen: Client oder Client Scope, und in
> welchem Realm?

Vier Fragen, vier Zuständigkeiten:

| Frage | Beantwortet durch |
|---|---|
| **Wer bin ich?** | der verlinkte User — kommt über die Federated Identity aus dem Frontend |
| **Wer fragt?** | der Backend-Client `backend-requester`, ausgewiesen mit eigenem Secret → `azp` |
| **Wofür gilt es?** | `scope=` wählt den Ziel-Dienst, der Audience-Mapper setzt `aud` |
| **Was darf ich?** | die Rollen des Users, gefiltert über die Role Scope Mappings des gewählten Scopes |

Im Ergebnis-Token stehen diese drei Dinge nebeneinander und werden leicht verwechselt:
`azp` ist der handelnde Client, `aud` der Dienst, für den das Token gilt, `sub` die Identität.

Der interne Token Exchange über das Gateway ist keine unabhängige Nebenkette mehr: Er ist die
**erste Stufe** derselben Kette, die auch das Backend erreicht. `gateway` tauscht das SP-Token
zunächst gegen ein auf `domain-5678` (oder `domain-1234`) zugeschnittenes Token (token1), danach —
mit dem Scope `access-backend` — dasselbe Token erneut gegen die Assertion für das Backend
(token2). Der `domain`-Claim aus token1 ist dabei der Trust-Anker für den `tenant`-Claim in
token2 (RTM-Mapper, siehe Tabelle unten und Abschnitt „Die Kette durchlaufen").

```
self-service-portal ──token_sp (aud: gateway)──► gateway ──scope=/audience=──► token1
                                                              (aud: domain-5678 oder domain-1234)
```

Ausführlich in [`docs/Interner-Token-Exchange.md`](docs/Interner-Token-Exchange.md) — dort auch, wie
die `aud` hier über Rollen statt über einen Audience-Mapper entsteht.

> **Ein Custom-Mapper autorisiert jetzt Schritt 02 — mandantenabhängig.** `aud:
> <backend-issuer-url>` in token2 entsteht weder über einen fest verdrahteten
> `oidc-audience-mapper` noch über ein natives Role Scope Mapping auf einen Audience-Ziel-Client
> (das wäre **mandanten-blind**: der eingebaute `AudienceResolveProtocolMapper` sieht nur
> *statische* Rollenzuweisungen des Users, nicht für welche Domain token1 gerade ausgestellt
> wurde). Stattdessen liest der Custom-Mapper `SelfserviceExchangeGateMapper`
> (`oidc-selfservice-exchange-gate`, siehe [`selfservice-exchange-gate/README.md`](selfservice-exchange-gate/README.md))
> **token1 selbst**: dessen `domain`-Claim (der aktive Mandant) und die darunter aufgelösten
> Rollen in `resource_access`. Nur wenn dort `selfservice` steht, trägt er die Backend-Issuer-URL
> in `aud` ein. `lab-user` hat `selfservice` nur auf `domain-5678`, nicht auf `domain-1234`
> (`LAB_USER_DOMAIN_ROLES` in `setup-realms.sh`) — der externe Exchange gelingt deshalb nur, wenn
> token1 für `domain-5678` ausgestellt wurde. Aus `domain-1234` bleibt `aud` leer, der Exchange
> scheitert mit `Requested audience not available`, während der interne Exchange (token1) aus
> beiden Domains unverändert funktioniert (`admin` reicht dafür). Siehe den gemessenen Beleg unten.

### Frontend-Realm `frontend`

| Objekt | Zweck |
|---|---|
| Client `http://localhost:8181/realms/Backend-Microservices` | existiert nur als Audience-Ziel, **keine eigene Rolle**. Der Audience-Mapper/Gate-Mapper kann nur die ID eines *existierenden* Clients in `aud` schreiben, und `aud` muss der Issuer des Empfängers sein — daher der URL-förmige Name |
| Client Scope `access-backend` | Mapper `RTM` (`oidc-requested-tenant-mapper`, schreibt `tenant` aus `token1.domain`) **und** Mapper `Selfservice Exchange Gate` (`oidc-selfservice-exchange-gate`): setzt `aud` auf die Backend-Issuer-URL nur, wenn `token1.resource_access[token1.domain]` die Rolle `selfservice` enthält — liest also den **aktiven** Mandanten aus token1, nicht die statischen Rollen des Users. Der Schalter, der token1 zu token2 macht |
| Client `domain-5678` | confidential, reine Ziel-Domain des internen Exchange, Rollen `admin`/`selfservice`. **Kein** Service Account, **kein** Token Exchange |
| Client `domain-1234` | zweite Ziel-Domain des internen Exchange, Rollen `admin`/`selfservice` |
| Client `gateway` | Requester des internen **und** externen Exchange. **Standard token exchange** On, **Full scope allowed** Off, Scope `roles` als Default, `domain-5678`/`domain-1234`/`access-backend`/`service:e-rechnung`/`service:fahrtkostenerstattung` als **Optional** |
| Client `self-service-portal` | Client für den Password Grant des Lab-Users, Scope `to-gateway` als **Default** |
| Client Scopes `domain-5678`, `domain-1234` | Role Scope Mappings auf die jeweiligen Rollen, Hardcoded-Claim-Mapper `domain=<Name>` |
| Client Scope `to-gateway` | Audience-Mapper auf `gateway` |
| Client Scopes `service:e-rechnung`, `service:fahrtkostenerstattung` | reine Marker, **keine** Role Scope Mappings. Werden vom Frontend/BFF anhand der Buchung ([`docs/buchungen.csv`](docs/buchungen.csv)) angefordert und landen unverändert im `scope`-Claim von token2 — Mapper 2 im Backend liest sie dort wieder aus |
| User `lab-user` | trägt auf `domain-5678` die Rollen `admin`+`selfservice`, auf `domain-1234` **nur** `admin` (`LAB_USER_DOMAIN_ROLES`) — die Asymmetrie, die den externen Gate testbar macht. Meldet sich per Passwort-Grant an |

Details zum internen Exchange — wie die `aud` entsteht, warum `scope=` und `audience=` beide Pflicht
sind — stehen in [`docs/Interner-Token-Exchange.md`](docs/Interner-Token-Exchange.md).

### Backend-Realm `Backend-Microservices`

| Objekt | Zweck |
|---|---|
| IdP `frontend` | OIDC, ohne Discovery, `jwtAuthorizationGrantEnabled`, Max assertion expiration 600s |
| Clients `e-rechnung`, `fahrtkostenerstattung` | Ziel-Dienste (Resource Server) mit Rollen `reader`/`writer` bzw. `reader`/`approver`. **Service accounts Off** — als reine Ziele brauchen sie keine eigene Identität |
| Client Scopes gleichen Namens | Audience-Mapper **und** Role Scope Mappings. Die Mappings entscheiden, welche Rollen bei aktivem Scope überhaupt ins Token dürfen |
| Client `backend-requester` | Requester. *JWT Authorization Grant* On, Allow-Liste `frontend`, **Full scope allowed Off**, beide Dienst-Scopes als **Optional**, Client Scope `booking-restriction` als **Default** |
| Client Scope `booking-restriction` | Mapper 2 (`oidc-booking-restriction-mapper`): verengt `resource_access` in token3 auf die Dienste, die laut `scope`-Claim der Assertion gebucht sind (Präfix `service:`). Default am Requester, greift bei jedem token3 |
| User `lab-user` | Ziel-Identität, verknüpft mit dem Frontend-`lab-user` (Federated Identity), trägt die Client-Rollen **beider** Dienste **direkt** (keine Mandanten-Gruppen mehr — welcher Mandant was gebucht hat, weiß nur das Frontend/BFF, s. [`docs/buchungen.csv`](docs/buchungen.csv)) |

---

## Die Kette durchlaufen

Entweder mit den Bruno-Requests `04` → `05a` → `02` → `03a`/`03b`, oder in der Shell. **Derselbe
Client (`gateway`)** tauscht zweimal: erst intern auf die Ziel-Domain, dann extern auf das Backend.

```bash
FE=http://localhost:8080
BE=http://localhost:8181
SP_SECRET=lab-frontend-sp-secret
GW_SECRET=lab-frontend-gateway-secret
BS=lab-backend-requester-secret
BI=http://localhost:8181/realms/Backend-Microservices

jwt() {
  cut -d. -f2 <<<"$1" | python3 -c "
import sys, base64, json
d = sys.stdin.read().strip()
print(json.dumps(json.loads(base64.urlsafe_b64decode(d + '=' * (-len(d) % 4))), indent=2))"
}

# 04 - Password Grant des Lab-Users am self-service-portal
token_sp=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=password \
  -d username=lab-user -d password=lab-user \
  -d client_id=self-service-portal -d client_secret="$SP_SECRET" | jq -r .access_token)

# 05a - interner Exchange via gateway auf die Ziel-Domain domain-5678
token1=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token_sp" \
  -d audience=domain-5678 -d scope=domain-5678 \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq -r .access_token)

# 02 - externer Exchange via gateway auf das Backend. RTM liest den domain-Claim
# aus token1 (subject_token) selbst - kein Parameter noetig. scope traegt hier
# zusaetzlich die Buchung: das Frontend/BFF liest sie aus docs/buchungen.csv und
# fordert nur die dort gebuchten service:*-Scopes an.
token2=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1" \
  -d scope="access-backend service:e-rechnung" \
  -d audience="$BI" \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq -r .access_token)

# 03a - jwt-bearer im Backend via Requester backend-requester
token3=$(curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  -d assertion="$token2" \
  -d scope=e-rechnung \
  -d client_id=backend-requester -d client_secret="$BS" | jq -r .access_token)

jwt "$token3"
```

So sehen die Tokens bis token2 aus (gemessen, gekürzt — siehe die Bruno-Requests `04`, `05a`, `02`):

```jsonc
// token_sp - Password Grant, noch ohne jeden Bezug zur Ziel-Domain
{ "iss": "http://localhost:8080/realms/frontend", "azp": "self-service-portal",
  "sub": "8eb1bec2-…" /* lab-user */, "aud": "gateway", "scope": "to-gateway profile email" }

// token1 - interner Exchange (05a), zugeschnitten auf domain-5678
{ "iss": "http://localhost:8080/realms/frontend", "azp": "gateway",
  "sub": "8eb1bec2-…" /* derselbe lab-user */, "aud": "domain-5678", "domain": "domain-5678",
  "scope": "domain-5678 profile email",
  "resource_access": { "domain-5678": { "roles": ["admin", "selfservice"] } } }

// token2 - die Assertion, externer Exchange (02) via gateway. aud entsteht nur, weil
// token1.resource_access.domain-5678 (s.o.) die Rolle selfservice enthaelt - der
// Selfservice-Exchange-Gate-Mapper hat sie dort gelesen, nicht am User statisch nachgeschlagen.
{ "iss": "http://localhost:8080/realms/frontend", "azp": "gateway",
  "sub": "8eb1bec2-…", "aud": "http://localhost:8181/realms/Backend-Microservices",
  "scope": "profile email access-backend service:e-rechnung", "tenant": "domain-5678",
  "jti": "ntrtte:1e1451ae-…" }

// token3 - finales Access Token, jwt-bearer im Backend (03), scope=e-rechnung
{ "iss": "http://localhost:8181/realms/Backend-Microservices", "azp": "backend-requester",
  "sub": "80d521cb-…", "aud": "e-rechnung",
  "scope": "profile booking-restriction email e-rechnung",
  "resource_access": { "e-rechnung": { "roles": ["reader", "writer"] } },
  "tenant": "domain-5678" }
```

`token2.tenant` bleibt stehen (Mapper 1/RTM setzt ihn weiterhin, reiner Audit-Claim) — Mapper 2
kopiert ihn seit dieser Ergänzung als Audit-Claim nach `token3`, aber fail-closed-konsistent: nur
wenn nach dem Verengen mindestens ein Dienst in `resource_access` übrig bleibt. Zur Autorisierung
selbst trägt der Claim nichts bei — die Zuschneidung läuft allein über `resource_access`.

`sub` in token2 ist der **Frontend-lab-user**, kein Service-Account. Der Claim `tenant`
(RTM-Mapper) trägt den `domain`-Claim aus **token1 selbst** (dem subject_token des Exchange) —
unabhängig vom `audience=`-Parameter, der nur die `aud` filtert, und ohne einen vom Aufrufer frei
wählbaren Request-Parameter.

> **Warum das sicher ist.** `domain` in token1 stammt aus einem Hardcoded-Claim-Mapper auf dem
> Domain-Scope (`domain-5678`/`domain-1234`), der wiederum über die echten Rollen des Users
> gated ist: `gateway` hat `Full scope allowed` Off, also bekommt token1 den Scope `domain-5678`
> nur, wenn er angefordert wird **und** der User Rollen in `domain-5678` hat. Der Exchange
> validiert token1 als subject_token, bevor Mapper laufen — RTM liest daraus nur, was der Exchange
> bereits geprüft hat. Ein zusätzlicher `requested_tenant=`-Parameter existiert seit dieser Härtung
> nicht mehr: Wer ihn trotzdem mitschickt, bewirkt nichts — der `tenant`-Claim in token2 folgt
> ausschließlich `token1.domain`. Siehe Troubleshooting unten für den gemessenen Beleg.
>
> **Vorbehalt:** Dass die Signaturvalidierung des subject_token *vor* dem Mapper-Lauf passiert, ist
> beobachtetes internes Verhalten von Keycloak 26.7 — kein dokumentierter API-Vertrag. Für die
> gepinnte Version verlässlich (der praktische Beleg dafür sind der Positiv- und der
> Fail-closed-Test unten), bei einem Major-Upgrade aber neu zu prüfen.

In `token3` ist `sub` der **Backend-`lab-user`** (verknüpft mit dem Frontend-lab-user, eigene UUID,
bei jedem Neuaufbau anders). **Das Backend kennt dabei keinen Mandanten** — `token2.tenant` ist ein
reiner Audit-Claim, den Mapper 2 nicht zur Autorisierung auswertet. Stattdessen verengt Mapper 2
(`oidc-booking-restriction-mapper`, Domain B) `resource_access` auf die Dienste, die laut
`scope`-Claim der Assertion gebucht sind (Präfix `service:`): Er liest `scope` aus der Assertion,
bildet daraus die Menge gebuchter Dienste und entfernt jeden `resource_access`-Eintrag, dessen
Client nicht darin vorkommt (fail-closed ohne Treffer). Hier bucht token2 `service:e-rechnung` und
der Request fordert `scope=e-rechnung` → die direkten Rollen des Backend-Users für `e-rechnung`
(`reader`, `writer`) bleiben stehen; forderte derselbe Request stattdessen
`scope=fahrtkostenerstattung`, obwohl nur `e-rechnung` gebucht ist, bliebe `resource_access` leer
(siehe Gegenproben unten). Bleibt nach dem Verengen mindestens ein Dienst übrig, kopiert Mapper 2
zusätzlich `tenant` aus der Assertion nach `token3` (reiner Audit-Claim); bleibt `resource_access`
leer, bleibt `token3` fail-closed-konsistent auch ohne `tenant`-Claim. Details, alle gemessenen
Fälle und die Quellcode-Belege:
[`docs/Mapper2-Spezifikation.md`](docs/Mapper2-Spezifikation.md) und
[`docs/Mapper2-Recherche.md`](docs/Mapper2-Recherche.md). Werte oben gemessen (Keycloak 26.7.2,
Stand dieses Setups).

### Gegenproben

Zwei Fehlschläge, die zeigen, dass die Kette hält:

```bash
# token1 direkt als Assertion  ->  invalid_grant: Invalid token audience (aud ist domain-5678, nicht das Backend)
curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer -d assertion="$token1" \
  -d client_id=backend-requester -d client_secret="$BS" | jq

# dieselbe Assertion (token2) zweimal einloesen   ->  invalid_grant: Token reuse detected

# token2 aus dem Beispiel oben bucht nur service:e-rechnung - Schritt 03 mit dem
# ANDEREN Dienst anfordern (Bruno-Request 03c):
curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer -d assertion="$token2" \
  -d scope=fahrtkostenerstattung \
  -d client_id=backend-requester -d client_secret="$BS" | jq '.access_token | split(".")[1]'
#  -> resource_access: {}  (fail-closed, Mapper 2: nicht gebucht - siehe Mapper2-Spezifikation.md)
```

Die erste zeigt, wofür Schritt 02 da ist. Die zweite, dass jede Assertion genau einmal gilt. Die
dritte, dass Mapper 2 tatsächlich durchsetzt statt nur zu vertrauen: der Backend-User *hat* Rollen
für `fahrtkostenerstattung` und der Scope ist dem Requester zugewiesen — ohne Mapper 2 käme hier ein
normales Token zurück (belegt in `docs/Mapper2-Recherche.md`).

### Der geschlossene Angriffsweg: `requested_tenant`-Spoofing

Vor dieser Härtung transportierte der RTM-Mapper den Form-Parameter `requested_tenant` unverändert
als `tenant`-Claim in token2 — ein Aufrufer im Kontext `domain-5678` konnte `requested_tenant=domain-1234`
mitschicken und bekam, sofern der Ziel-User im Backend Mitglied der Gruppe `domain-1234` ist, dessen
Rechte. Der Beweis, dass das jetzt wirkungslos ist (gemessen gegen einen kctest-Stack, Keycloak 26.7.2):

```bash
# token1 fuer domain-5678 holen (wie oben), dann Schritt 02 mit gespooftem Parameter
token2=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1" \
  -d scope=access-backend -d audience="$BI" \
  -d requested_tenant=domain-1234 \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq -r .access_token)
```

Gemessenes Ergebnis: `token2.tenant` ist `domain-5678` — **nicht** `domain-1234`. `requested_tenant`
wird von der Server-Implementierung gar nicht mehr gelesen; der Claim folgt ausschließlich
`token1.domain`. Vor der Härtung wäre `token2.tenant` hier `domain-1234` gewesen.

Seit der Umstellung auf Buchungs-Scopes (Mapper 2, s. u.) hat dieser Claim ohnehin **keine**
Auswirkung mehr auf `resource_access` in token3: das hängt nur noch an den gebuchten
`service:*`-Scopes. Mapper 2 liest `tenant` zwar (und kopiert ihn fail-closed-konsistent als
Audit-Claim nach token3), wertet ihn aber nicht zur Autorisierung aus. `token2.tenant` bleibt ein
reiner Audit-Claim — die ursprüngliche Spoofing-Gefahr (fremder Mandant → fremde Rollen) existiert
im Backend nicht mehr, weil das Backend
seit diesem Umbau gar keine Mandanten mehr kennt.

### Ohne die Rolle `selfservice` im aktiven Mandanten: der externe Exchange bleibt zu

Der Gate-Punkt für „darf dieser User gerade zum Backend wechseln" ist die Rolle `selfservice`
**im aktiven Mandanten** — nicht irgendeine statische Zuweisung. `lab-user` trägt `selfservice`
nur auf `domain-5678`, auf `domain-1234` nur `admin` (`LAB_USER_DOMAIN_ROLES` in
`setup-realms.sh`). Der interne Exchange (05a) braucht `selfservice` gar nicht — er gelingt aus
**beiden** Domains, `admin` reicht:

```bash
# 05a fuer domain-1234 statt domain-5678 - Rollen dort: nur admin
token1_1234=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token_sp" \
  -d audience=domain-1234 -d scope=domain-1234 \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq -r .access_token)
```

Gemessen (kctest-Stack, Keycloak 26.7.2) liefert das ein gültiges token1 mit
`"resource_access": { "domain-1234": { "roles": ["admin"] } }` — **kein** `selfservice` darin, weil
`lab-user` es für diese Domain nicht trägt. Schritt 02 mit genau diesem token1 als subject_token:

```bash
curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1_1234" \
  -d scope="access-backend service:e-rechnung" -d audience="$BI" \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq
```

Gemessene Antwort (kctest-Stack, Keycloak 26.7.2):

```json
{ "error": "invalid_request",
  "error_description": "Requested audience not available: http://localhost:8181/realms/Backend-Microservices" }
```

Dieselbe Meldung steht im Frontend-Log (`docker compose logs frontend-keycloak`, Event
`TOKEN_EXCHANGE_ERROR`, gemessen):

```
type="TOKEN_EXCHANGE_ERROR", ... clientId="gateway", ... error="invalid_request",
reason="Requested audience not available: http://localhost:8181/realms/Backend-Microservices",
auth_method="token_exchange", grant_type="urn:ietf:params:oauth:grant-type:token-exchange", ...
username="lab-user"
```

Der `Selfservice-Exchange-Gate-Mapper` hat hier `token1_1234.domain` (`domain-1234`) gelesen,
darunter in `resource_access` nachgesehen, `selfservice` nicht gefunden und **nichts** zu `aud`
hinzugefügt (fail-closed). Weil der Request `audience=` explizit anfordert, prüft
`restrictRequestedAudience` sofort, ob sich diese Audience überhaupt auflösen lässt, und bricht
ohne Treffer den ganzen Exchange ab (`invalid_request`, kein Token). Schritt 03 wird dadurch gar
nicht erst erreicht — ohne gültiges token2 gibt es keine Assertion, die sich einlösen ließe.

Mit demselben `token1_1234` gelingt dagegen weiterhin der interne Exchange (05a) — der ist mit dem
obigen Aufruf bereits erfolgreich demonstriert; `admin` allein reicht dafür aus. Nur der externe
Schritt (02) unterscheidet die beiden Domains, und zwar **ausschließlich** anhand des Inhalts von
token1 — nicht anhand einer für den User global geltenden Rolle.

---

## Troubleshooting

Die aussagekräftige Meldung steht im Server-Log, nicht in der HTTP-Antwort:

```bash
docker compose logs -f backend-keycloak
```

| Fehler | Ursache |
|---|---|
| `unauthorized_client` in Schritt 2 | *Standard token exchange* am Frontend-Client aus |
| token2 ohne `aud` (bei `audience=` weggelassen) | `scope=access-backend` vergessen, Scope nicht als *Optional* zugewiesen, oder token1 wurde für einen Mandanten ausgestellt, in dem `lab-user` die Rolle `selfservice` nicht hat |
| `invalid_request: Requested audience not available: <backend-issuer-url>` in Schritt 02 | derselbe Grund wie oben, aber mit explizitem `audience=` im Request (wie in der Kette oben) — `restrictRequestedAudience` bricht dann sofort ab statt still auf `aud` zu verzichten. Meist: token1 (subject_token) stammt aus einem Mandanten ohne `selfservice`, z.B. `domain-1234` (s. Abschnitt oben) — der Gate-Mapper liest das aus token1, nicht aus einer statischen User-Rolle |
| `No Identity Provider for provided issuer` | `iss` ≠ `issuer` im IdP — meist eine localhost/Container-Verwechslung |
| Timeout in Schritt 3 | `jwksUrl` zeigt auf `localhost` statt auf `frontend-keycloak` |
| `Identity Provider is not allowed for the client` | IdP fehlt in der Allow-Liste des Requester-Clients |
| `User not found` | Federated Identity fehlt, oder falscher `sub` verlinkt |
| `Account is not fully set up` | offene Required Actions am Ziel-User |
| `invalid_grant: Token reuse detected` | erwartetes Verhalten, Assertions gelten einmal |
| `invalid_grant: Invalid token audience` | die Assertion war nicht an diesen Realm adressiert |
| `invalid_scope` | der Scope existiert nicht oder ist dem Requester nicht zugewiesen |
| zu viele Rollen in token3 | **Full scope allowed** ist On, oder die Rollen stecken in den Default-Rollen des Realms |
| `resource_access` in token3 leer | Mapper 2 hat fail-closed: der in Schritt 03 angeforderte `scope=` ist nicht als `service:<scope>` im `scope`-Claim der Assertion gebucht (erwartetes Verhalten, s. Gegenproben und Request `03c`). Fail-closed-konsistent trägt token3 dann auch **keinen** `tenant`-Claim |
| `requested_tenant=…` im Request 02 ändert nichts an `token2.tenant` | erwartetes Verhalten seit der Härtung — RTM liest `tenant` ausschließlich aus `token1.domain`, ein Request-Parameter wird nicht mehr ausgewertet |

---

## Hinweise zum Lab-Charakter

- **Die Client-Secrets stehen im Klartext** in `setup-realms.sh` und in der Bruno-Environment. Das
  ist Absicht: Es macht den Neuaufbau reproduzierbar und die Collection sofort lauffähig. Für alles
  außer einem Testlabor ist es falsch.
- **Admin-Zugang** ist überall `admin`/`admin`. Das Token des `master`-Realms lebt standardmäßig nur
  60 Sekunden — bei Handarbeit über die Admin-API läuft es gern zwischendurch ab.
- **Beide Instanzen liegen auf Postgres.** Die Konfiguration übersteht `docker compose down`. Ein
  kompletter Neuaufbau ist trotzdem billig: `docker compose down -v && docker compose up -d &&
  ./setup-realms.sh --recreate`.

## Quellen

Verifiziert gegen Keycloak 26.7.2.

- [OAuth Identity and Authorization Chaining Across Domains](https://www.keycloak.org/securing-apps/oauth-identity-authorization-chaining-across-domains) — das Referenz-Setup, dort mit einem menschlichen User und zwei Realms auf einem Server
- [Configuring and using token exchange](https://www.keycloak.org/securing-apps/token-exchange)
- [JWT Authorization Grant](https://www.keycloak.org/securing-apps/jwt-authorization-grant)
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [RFC 7523 — JWT Profile for OAuth 2.0 Authorization Grants](https://datatracker.ietf.org/doc/html/rfc7523)
