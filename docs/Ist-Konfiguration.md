# Ist-Konfiguration (Momentaufnahme)

Diese Seite beschreibt den tatsächlichen Zustand der laufenden Instanz, wie er sich aus einem
Partial-Export beider Realms und ihrer User ergibt (`ist-export/frontend.json`,
`ist-export/backend.json`, `ist-export/frontend-users.json`, `ist-export/backend-users.json` — ein
Snapshot, kein Repo-Artefakt, siehe `.gitignore`). Werte hier sind **gemessen**, nicht erfunden.

Der bereinigte Teil dieses Standes (Abschnitt „Der umgebaute Flow") ist das, was `setup-realms.sh`
seit dem Umbau aufbaut. Daneben trägt die laufende Instanz vier Altlasten aus der Entwicklung des
neuen Flows, die im letzten Abschnitt benannt sind.

## Frontend-Realm `frontend`

### Clients

| Client | Zweck | Wichtige Attribute |
|---|---|---|
| `domain-5678` | Ziel-Domain des internen Exchange | confidential; `serviceAccountsEnabled=false`; `standard.token.exchange.enabled=false`; Rollen `admin`, `selfservice`; optionale Scopes u. a. **`access-backend`** (Altlast H, siehe unten) |
| `domain-1234` | zweite Ziel-Domain | confidential; `serviceAccountsEnabled=false`; Rollen `admin`, `selfservice` |
| `gateway` | Requester des internen **und** externen Exchange | confidential; `standard.token.exchange.enabled=true`; `fullScopeAllowed=false`; optionale Scopes `domain-5678`, `domain-1234`, `access-backend` |
| `self-service-portal` | Password-Grant-Client des Lab-Users | confidential; `directAccessGrantsEnabled=true`; `fullScopeAllowed=false`; Default-Scope `to-gateway` |
| `http://localhost:8181/realms/Backend-Microservices` (Name „backend") | reines Audience-Ziel für den externen Exchange | confidential; keine Flows aktiv |
| `external-token-exchange` (**Altlast E**) | ungenutzter Exchange-Client | `fullScopeAllowed=true`; `standard.token.exchange.enabled=true`; optionaler Scope `access-backend`; von keinem Bruno-Request referenziert |

### Client Scopes

| Scope | Protocol Mapper | Role Scope Mappings |
|---|---|---|
| `access-backend` | `audience` (`oidc-audience-mapper`) → `http://localhost:8181/realms/Backend-Microservices`; `RTM` (`oidc-requested-tenant-mapper`, `config:{}`) | — |
| `domain-5678` | `domain` (`oidc-hardcoded-claim-mapper`) → `domain-5678` | `domain-5678`: admin, selfservice |
| `domain-1234` | `domain` (`oidc-hardcoded-claim-mapper`) → `domain-1234` | `domain-1234`: admin, selfservice |
| `to-gateway` | `audience` (`oidc-audience-mapper`) → `gateway` | — |

### User `lab-user`

- id `8eb1bec2-6c88-4b9a-83fd-d645ee1f2021`
- Client-Rollen: `domain-5678`: admin, selfservice; `domain-1234`: admin, selfservice; `self-service-portal`:
  **`test`** (Altlast G, siehe unten)
- keine Federated Identity — das ist der Ursprungs-User der Kette

## Backend-Realm `Backend-Microservices`

### Identity Provider

| Alias | issuer | jwksUrl | JWT Authorization Grant | Assertion Reuse | Max Expiration |
|---|---|---|---|---|---|
| `frontend` | `http://localhost:8080/realms/frontend` | `http://frontend-keycloak:8080/realms/frontend/protocol/openid-connect/certs` | `true` | `false` | `600` s |

### Clients

| Client | Zweck | Wichtige Attribute |
|---|---|---|
| `backend-requester` | Requester, löst die Assertion ein | confidential; `oauth2.jwt.authorization.grant.enabled=true`; `oauth2.jwt.authorization.grant.idp=frontend`; `fullScopeAllowed=false`; optionale Scopes `e-rechnung`, `fahrtkostenerstattung`; **Default-Scope `tenant-restriction`** (Mapper 2) |
| `e-rechnung` | Ziel-Dienst | `serviceAccountsEnabled=false`; Rollen `reader`, `writer` |
| `fahrtkostenerstattung` | Ziel-Dienst | `serviceAccountsEnabled=false`; Rollen `reader`, `approver` |

### Client Scopes

| Scope | Protocol Mapper | Role Scope Mappings |
|---|---|---|
| `e-rechnung` | `audience` (`oidc-audience-mapper`) → `e-rechnung` | reader, writer |
| `fahrtkostenerstattung` | `audience` (`oidc-audience-mapper`) → `fahrtkostenerstattung` | approver, reader |
| `tenant-restriction` | `tenant-restriction` (`oidc-tenant-restriction-mapper`, Mapper 2, `config:{}`) | — |

### User `lab-user` (Ziel-User der bereinigten Kette)

- id `b54323e7-8fd1-4071-84ea-2c8a3e2def11`
- Federated Identity: `frontend` → `userId=8eb1bec2-6c88-4b9a-83fd-d645ee1f2021` (Frontend-`lab-user`),
  `userName=lab-user`
- Direkte Client-Rollen: **keine** — seit Mapper 2 sind die Mandanten-Gruppen die alleinige
  Rollenquelle; `setup-realms.sh` entfernt direkte Dienst-Rollen aktiv (sie wären tenant-agnostisch
  und würden den Zuschnitt unterlaufen)
- **Gruppen-Mitgliedschaft:** `/domain-5678` **und** `/domain-1234` (siehe Abschnitt „Gruppen")

### User `frontend-domain-5678` (**Altlast F**, verwaist)

- id `12a1387b-b7ad-4003-851e-2906c9e6d155`
- Federated Identity: `frontend` → `userId=5f074e80-378d-433a-a79b-8c3e0c856ab1` — diesen
  Frontend-User gibt es nicht mehr. Er war der Service-Account von `domain-5678`, bevor dieser
  Client seinen Service Account verlor
- Client-Rollen: `e-rechnung`: writer, reader; `fahrtkostenerstattung`: reader, approver
- Ohne gültige Federated Identity kann kein JWT Authorization Grant mehr an diesen User binden — der
  Eintrag ist reiner Datenmüll

### Gruppen (Mandanten-Modell)

Der Backend-Realm modelliert die Mandanten als Gruppen; jede trägt die dienst-spezifischen
Client-Rollen ihres Mandanten. Der Ziel-User `lab-user` ist Mitglied **beider** Gruppen.

| Gruppe | `e-rechnung` | `fahrtkostenerstattung` |
|---|---|---|
| `/domain-5678` | writer, reader | reader, approver |
| `/domain-1234` | reader | reader |

Jede Gruppe trägt die Rollen **beider** Dienste, asymmetrisch gesplittet je Mandant. Sie sind die
**alleinige** Rollenquelle des Ziel-Users (keine direkten Rollen mehr). Der User ist Mitglied beider
Gruppen — erst darüber entsteht die **Vereinigung** über beide Mandanten. Genau diese Vereinigung
schneidet **Mapper 2** (`oidc-tenant-restriction-mapper`, Domain B, gebaut und verifiziert) zu:
anhand des `tenant`-Claims aus token2 bestätigt er genau eine Mitgliedschaft und gibt nur deren
Rollen in token3 aus (fail-closed ohne Treffer). Gemessene Fälle:
[`Mapper2-Spezifikation.md`](Mapper2-Spezifikation.md). `setup-realms.sh` legt Gruppen, Rollen und
Mitgliedschaft an (Arrays `BE_GROUPS` / `TARGET_GROUPS`) und entfernt direkte Rollen am Ziel-User.

## Der umgebaute Flow (04 → 05 → 02 → 03)

```
04  self-service-portal --(Password Grant)--------------------> token_sp   (aud: gateway)
05  gateway              --(interner Exchange, scope/audience=domain-5678)-> token1  (aud: domain-5678)
02  gateway              --(externer Exchange, scope=access-backend,
                             audience=<Backend-Issuer>)---> token2 (Assertion, tenant aus token1.domain)
03  backend-requester (Backend) --(jwt-bearer, assertion=token2)------> token3    (aud: e-rechnung | fahrtkostenerstattung)
```

Der entscheidende Unterschied zur Vorgängerfassung: `sub` von token1 und token2 ist der
**Frontend-lab-user** (`8eb1bec2-…`), kein Service-Account mehr. `gateway` ist jetzt der Requester
beider Exchange-Schritte — des internen auf die Ziel-Domain und des externen auf das Backend. Der
Claim `tenant` in token2 (RTM-Mapper) leitet sich aus dem `domain`-Claim von **token1 selbst** ab,
unabhängig vom `audience=`-Parameter, der nur `aud`/`resource_access` filtert.

## Bekannte Altlasten in der laufenden Instanz

Diese vier Punkte sind Teil des gemessenen Ist-Standes, aber **nicht** Teil dessen, was
`setup-realms.sh` aufbaut — der Nutzer hat sich für ein bereinigtes Skript entschieden. Sie sind hier
dokumentiert, damit sie beim Aufräumen der echten Instanz nicht verloren gehen.

- **E — Client `external-token-exchange`.** `fullScopeAllowed=true`, `standard.token.exchange.enabled=true`,
  optionaler Scope `access-backend` — aber von keinem Bruno-Request und keinem Skript-Schritt
  referenziert. **Empfehlung:** löschen, oder zumindest deaktivieren; `fullScopeAllowed=true` an einem
  Exchange-fähigen Client ist ein unnötiges Risiko, selbst wenn er ungenutzt ist.
- **F — Backend-User `frontend-domain-5678`.** Verwaiste Federated Identity auf einen
  Frontend-User (`5f074e80-…`), den es nicht mehr gibt, seit `domain-5678` im Frontend seinen
  Service Account verlor. **Empfehlung:** User löschen — er kann durch keinen Grant mehr erreicht
  werden und hat nur noch historischen Wert.
- **G — Frontend-`lab-user` trägt die Client-Rolle `self-service-portal=test`.** Eine Streurolle ohne
  Funktion in der Kette (kein Scope mappt sie durch). **Empfehlung:** Rollenzuweisung entfernen, oder
  falls sie für einen anderen Zweck angelegt wurde, die Rolle `test` am Client
  `self-service-portal` ganz löschen.
- **H — `domain-5678` (Frontend) trägt weiterhin `access-backend` als optionalen Scope.** Aus der
  Zeit, in der `domain-5678` noch selbst den externen Exchange auslöste. Folgenlos, weil
  `domain-5678` keinen Service Account und kein Token-Exchange-Recht mehr hat und den Scope daher nie
  aktivieren kann — aber unnötige Angriffsfläche, falls sich das je ändert. **Empfehlung:** Optionalen
  Scope entfernen.
