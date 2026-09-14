# Token Exchange zwischen zwei Keycloak-Instanzen

Ein Service-Account-Client im **Frontend-Keycloak** tauscht sein Token gegen ein Token des
**Backend-Keycloak**, zugeschnitten auf genau einen von zwei Ziel-Diensten.

```
Frontend (localhost:8080)              Backend (localhost:8181)
─────────────────────────              ────────────────────────
domain-5678  (Service Account)         domain-5678  (Requester)
     │ client_credentials                   │ jwt-bearer + scope=e-rechnung
     ▼                                      ▼
  token1  ──token-exchange──►  token2  ───────────────►  token3
                            (Assertion)                  aud: e-rechnung
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
| 1 | Frontend | `client_credentials` | **token1** — gewöhnliches Service-Account-Token |
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
antwortet Keycloak mit `User not found` (`JWTAuthorizationGrantType.java:139`). Bei einem Menschen
entstünde diese Verknüpfung beim ersten Browser-Login über den IdP; ein Service Account kann sich
nicht einloggen, also setzt `setup-realms.sh` sie über die Admin-API.

Daher tragen token1/token2 einen anderen `sub` als token3: dieselbe Identität, zwei Realms, zwei IDs.
Die Federated Identity ist das Wörterbuch dazwischen.

Dass hier überhaupt ein Service Account steht, ist eine Wahl, keine Notwendigkeit: Dieselbe Kette
läuft unverändert mit einem menschlichen User als Subjekt — nur token1 entsteht dann per Password
Grant statt `client_credentials`, und im Backend braucht es einen zweiten Ziel-User. Schritt für
Schritt in [`docs/User-Token-Exchange.md`](docs/User-Token-Exchange.md).

> **Namensfalle:** Der Ziel-User heißt `frontend-domain-5678`, bewusst **nicht**
> `service-account-domain-5678`. Diesen Namen vergibt Keycloak selbst. Und weil
> `GET /users?username=…&exact=true` Service Accounts mitliefert (`UsersResource.java:364`), die
> Users-Liste der Konsole aber nicht (Zeile 327/368), hängt man die Verknüpfung sonst versehentlich
> an den Service Account eines Backend-Clients — und erbt dessen Rollen.

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
       │ scope=domain-5678, sub bleibt lab-user       domain-5678  (Requester)
       ▼                                                JWT Auth Grant: ON
domain-5678  (Ziel-Domain)                              Full scope allowed: OFF
  Rollen admin, selfservice                             Scopes e-rechnung /
       │                                                       fahrtkostenerstattung
       │ zurueck an gateway:                                  (beide optional)
       │ scope=access-backend,                                     │
       │ requested_tenant=domain-5678                              │ scope= entscheidet
       ▼                                                           ▼
<backend-issuer-url>                              federated identity
  Client, nur Audience-Ziel                               │
       ▲                                                  ▼
       │ Audience-Mapper + RTM                       lab-user            e-rechnung
access-backend (Client Scope)                     Rollen s.o.          reader, writer
                                                                     fahrtkostenerstattung
                                                                           reader
```

> **`domain-5678` gibt es zweimal** — einmal pro Realm. Die beiden Clients haben nichts miteinander
> zu tun außer dem Namen; kein Keycloak-Mechanismus verbindet sie. Im Frontend ist es eine reine
> Ziel-Domain des internen Exchange, ohne eigenen Service Account und ohne eigenes Token-Exchange-
> Recht. Im Backend ist es der Requester, der die Assertion einlöst — bewusst **ohne** eigenen
> Service Account, denn eine eigene Identität braucht er nicht. Wessen Antrag er stellt, steht in
> der Assertion.
>
> Beide Exchange-Schritte der cross-realm Kette laufen über denselben Client: **`gateway`**. Er
> tauscht zuerst das SP-Token gegen ein auf `domain-5678` zugeschnittenes Token (intern), und
> dieses dann gegen die Assertion für das Backend (extern, mit `requested_tenant=domain-5678`).
> Dazu kommt ein gleichnamiger **Client Scope** `domain-5678`. Der Name bezeichnet damit drei
> Objekte — den Frontend-Client, den Backend-Client und den Frontend-Client-Scope. Beim Lesen der
> Admin-Konsole hilft nur, jedes Mal zu fragen: Client oder Client Scope, und in welchem Realm?

Vier Fragen, vier Zuständigkeiten:

| Frage | Beantwortet durch |
|---|---|
| **Wer bin ich?** | der verlinkte User — kommt über die Federated Identity aus dem Frontend |
| **Wer fragt?** | der Backend-Client `domain-5678`, ausgewiesen mit eigenem Secret → `azp` |
| **Wofür gilt es?** | `scope=` wählt den Ziel-Dienst, der Audience-Mapper setzt `aud` |
| **Was darf ich?** | die Rollen des Users, gefiltert über die Role Scope Mappings des gewählten Scopes |

Im Ergebnis-Token stehen diese drei Dinge nebeneinander und werden leicht verwechselt:
`azp` ist der handelnde Client, `aud` der Dienst, für den das Token gilt, `sub` die Identität.

Der interne Token Exchange über das Gateway ist keine unabhängige Nebenkette mehr: Er ist die
**erste Stufe** derselben Kette, die auch das Backend erreicht. `gateway` tauscht das SP-Token
zunächst gegen ein auf `domain-5678` (oder `domain-1234`) zugeschnittenes Token, danach — mit dem
Scope `access-backend` und `requested_tenant=` — dasselbe Token erneut gegen die Assertion für das
Backend.

```
self-service-portal ──token_sp (aud: gateway)──► gateway ──scope=/audience=──► token1
                                                              (aud: domain-5678 oder domain-1234)
```

Ausführlich in [`docs/Interner-Token-Exchange.md`](docs/Interner-Token-Exchange.md) — dort auch, wie
die `aud` hier über Rollen statt über einen Audience-Mapper entsteht.

### Frontend-Realm `frontend`

| Objekt | Zweck |
|---|---|
| Client `http://localhost:8181/realms/Backend-Microservices` | existiert nur als Audience-Ziel. Der Audience-Mapper kann nur die ID eines *existierenden* Clients in `aud` schreiben, und `aud` muss der Issuer des Empfängers sein — daher der URL-förmige Name |
| Client Scope `access-backend` | Audience-Mapper auf diesen Client **und** Mapper `RTM` (`oidc-requested-tenant-mapper`), der `requested_tenant=` in den Claim `tenant` überträgt. Der Schalter, der token1 zu token2 macht |
| Client `domain-5678` | confidential, reine Ziel-Domain des internen Exchange, Rollen `admin`/`selfservice`. **Kein** Service Account, **kein** Token Exchange |
| Client `domain-1234` | zweite Ziel-Domain des internen Exchange, Rollen `admin`/`selfservice` |
| Client `gateway` | Requester des internen **und** externen Exchange. **Standard token exchange** On, **Full scope allowed** Off, Scope `roles` als Default, `domain-5678`/`domain-1234`/`access-backend` als **Optional** |
| Client `self-service-portal` | Client für den Password Grant des Lab-Users, Scope `to-gateway` als **Default** |
| Client Scopes `domain-5678`, `domain-1234` | Role Scope Mappings auf die jeweiligen Rollen, Hardcoded-Claim-Mapper `domain=<Name>` |
| Client Scope `to-gateway` | Audience-Mapper auf `gateway` |
| User `lab-user` | trägt die Rollen beider Domains, meldet sich per Passwort-Grant an |

Details zum internen Exchange — wie die `aud` entsteht, warum `scope=` und `audience=` beide Pflicht
sind — stehen in [`docs/Interner-Token-Exchange.md`](docs/Interner-Token-Exchange.md).

### Backend-Realm `Backend-Microservices`

| Objekt | Zweck |
|---|---|
| IdP `frontend` | OIDC, ohne Discovery, `jwtAuthorizationGrantEnabled`, Max assertion expiration 600s |
| Clients `e-rechnung`, `fahrtkostenerstattung` | Ziel-Dienste (Resource Server) mit Rollen `reader`/`writer` bzw. `reader`/`approver`. **Service accounts Off** — als reine Ziele brauchen sie keine eigene Identität |
| Client Scopes gleichen Namens | Audience-Mapper **und** Role Scope Mappings. Die Mappings entscheiden, welche Rollen bei aktivem Scope überhaupt ins Token dürfen |
| Client `domain-5678` | Requester. *JWT Authorization Grant* On, Allow-Liste `frontend`, **Full scope allowed Off**, beide Dienst-Scopes als **Optional**, Client Scope `tenant-restriction` als **Default** |
| Client Scope `tenant-restriction` | Mapper 2 (`oidc-tenant-restriction-mapper`): verengt `resource_access` in token3 auf die Rollen der bestätigten Mandanten-Gruppe. Default am Requester, greift bei jedem token3 |
| Gruppen `/domain-5678`, `/domain-1234` | Mandanten-Modell: tragen je Mandant die Client-Rollen **beider** Dienste (asymmetrischer Split). Alleinige Rollenquelle des Ziel-Users |
| User `lab-user` | Ziel-Identität, verknüpft mit dem Frontend-`lab-user` (Federated Identity), **Mitglied beider Gruppen, keine direkten Rollen** (Rollen kommen über die Gruppen, Zuschnitt über Mapper 2) |

---

## Die Kette durchlaufen

Entweder mit den Bruno-Requests `04` → `05a` → `02` → `03a`/`03b`, oder in der Shell. Anders als in
der ursprünglichen Fassung tauscht **derselbe Client (`gateway`)** zweimal: erst intern auf die
Ziel-Domain, dann extern auf das Backend.

```bash
FE=http://localhost:8080
BE=http://localhost:8181
SP_SECRET=lab-frontend-sp-secret
GW_SECRET=lab-frontend-gateway-secret
BS=lab-backend-domain-5678-secret
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

# 02 - externer Exchange via gateway auf das Backend, mit requested_tenant
token2=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1" \
  -d scope=access-backend \
  -d audience="$BI" \
  -d requested_tenant=domain-5678 \
  -d client_id=gateway -d client_secret="$GW_SECRET" | jq -r .access_token)

# 03a - jwt-bearer im Backend via Requester domain-5678
token3=$(curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  -d assertion="$token2" \
  -d scope=e-rechnung \
  -d client_id=domain-5678 -d client_secret="$BS" | jq -r .access_token)

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

// token2 - die Assertion, externer Exchange (02) via gateway
{ "iss": "http://localhost:8080/realms/frontend", "azp": "gateway",
  "sub": "8eb1bec2-…", "aud": "http://localhost:8181/realms/Backend-Microservices",
  "scope": "access-backend profile email", "tenant": "domain-5678",
  "jti": "trrtte:1e1451ae-…" }

// token3 - finales Access Token, jwt-bearer im Backend (03), scope=e-rechnung
{ "iss": "http://localhost:8181/realms/Backend-Microservices", "azp": "domain-5678",
  "sub": "80d521cb-…", "aud": "e-rechnung",
  "scope": "e-rechnung profile email tenant-restriction",
  "tenant": "domain-5678",
  "resource_access": { "e-rechnung": { "roles": ["reader", "writer"] } } }
```

Neu gegenüber der Vorgängerfassung: `sub` in token2 ist jetzt der **Frontend-lab-user**, kein
Service-Account mehr. Und der Claim `tenant` (RTM-Mapper) trägt die Ziel-Domain aus
`requested_tenant=` — unabhängig vom `audience=`-Parameter, der nur die `aud` filtert.

In `token3` ist `sub` der **Backend-`lab-user`** (verknüpft mit dem Frontend-lab-user, eigene UUID,
bei jedem Neuaufbau anders) statt wie früher `frontend-domain-5678`. **`token3` trägt jetzt einen
bestätigten `tenant`-Claim und ist auf genau diesen Mandanten zugeschnitten** — das leistet Mapper 2
(`oidc-tenant-restriction-mapper`, Domain B): Er liest den `tenant` aus der Assertion, prüft die
Gruppenmitgliedschaft des Backend-Users und verengt `resource_access` auf die Rollen der bestätigten
Mandanten-Gruppe (fail-closed ohne Treffer). Hier `tenant=domain-5678` → dessen Gruppenrollen für
`e-rechnung` = reader,writer; mit `tenant=domain-1234` blieben nur `[reader]`. Details, alle
gemessenen Fälle und die Quellcode-Belege:
[`docs/Mapper2-Spezifikation.md`](docs/Mapper2-Spezifikation.md) und
[`docs/Mapper2-Recherche.md`](docs/Mapper2-Recherche.md). Werte oben gemessen (Keycloak 26.7.2,
Stand dieses Setups).

### Gegenproben

Zwei Fehlschläge, die zeigen, dass die Kette hält:

```bash
# token1 direkt als Assertion  ->  invalid_grant: Invalid token audience (aud ist domain-5678, nicht das Backend)
curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer -d assertion="$token1" \
  -d client_id=domain-5678 -d client_secret="$BS" | jq

# dieselbe Assertion (token2) zweimal einloesen   ->  invalid_grant: Token reuse detected
```

Die erste zeigt, wofür Schritt 02 da ist. Die zweite, dass jede Assertion genau einmal gilt.

---

## Troubleshooting

Die aussagekräftige Meldung steht im Server-Log, nicht in der HTTP-Antwort:

```bash
docker compose logs -f backend-keycloak
```

| Fehler | Ursache |
|---|---|
| `unauthorized_client` in Schritt 2 | *Standard token exchange* am Frontend-Client aus |
| token2 ohne `aud` | `scope=access-backend` vergessen, oder Scope nicht als *Optional* zugewiesen |
| `No Identity Provider for provided issuer` | `iss` ≠ `issuer` im IdP — meist eine localhost/Container-Verwechslung |
| Timeout in Schritt 3 | `jwksUrl` zeigt auf `localhost` statt auf `frontend-keycloak` |
| `Identity Provider is not allowed for the client` | IdP fehlt in der Allow-Liste des Requester-Clients |
| `User not found` | Federated Identity fehlt, oder falscher `sub` verlinkt |
| `Account is not fully set up` | offene Required Actions am Ziel-User |
| `invalid_grant: Token reuse detected` | erwartetes Verhalten, Assertions gelten einmal |
| `invalid_grant: Invalid token audience` | die Assertion war nicht an diesen Realm adressiert |
| `invalid_scope` | der Scope existiert nicht oder ist dem Requester nicht zugewiesen |
| zu viele Rollen in token3 | **Full scope allowed** ist On, oder die Rollen stecken in den Default-Rollen des Realms |
| token3 ohne Rollen und ohne `tenant`-Claim | Mapper 2 hat fail-closed: `tenant` fehlt in der Assertion, oder der Backend-User ist nicht Mitglied der genannten Mandanten-Gruppe |

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

Verifiziert gegen Keycloak 26.7.0.

- [OAuth Identity and Authorization Chaining Across Domains](https://www.keycloak.org/securing-apps/oauth-identity-authorization-chaining-across-domains) — das Referenz-Setup, dort mit einem menschlichen User und zwei Realms auf einem Server
- [Configuring and using token exchange](https://www.keycloak.org/securing-apps/token-exchange)
- [JWT Authorization Grant](https://www.keycloak.org/securing-apps/jwt-authorization-grant)
- [RFC 8693 — OAuth 2.0 Token Exchange](https://datatracker.ietf.org/doc/html/rfc8693)
- [RFC 7523 — JWT Profile for OAuth 2.0 Authorization Grants](https://datatracker.ietf.org/doc/html/rfc7523)
