# Cross-realm Kette mit einem echten User

Dieselbe Kette aus `SETUP.md`, aber mit einem menschlichen User (`lab-user`) statt dem Service
Account als Subjekt. `setup-realms.sh` baut nur den Service-Account-Flow auf; diese Doku beschreibt
die **händische** Umstellung auf einen User — additiv, der Service-Account-Flow bleibt daneben
funktionsfähig.

## Was das ist / Abgrenzung

Identity Chaining ist Identity Chaining, egal wer das Subjekt ist. Token Exchange V2 und JWT
Authorization Grant — Schritt 2 und Schritt 3 der Kette — kümmert es nicht, ob der `sub`, den sie
weiterreichen, zu einem Service Account oder zu einem eingeloggten Menschen gehört. Nur **zwei**
Dinge ändern sich gegenüber `SETUP.md`:

1. **token1** kommt aus einem echten Login (Password Grant) statt aus `client_credentials`.
2. Im Backend braucht es einen **zweiten** Ziel-User, verlinkt auf den `sub` des Frontend-*Users*
   statt auf den `sub` des Frontend-*Service-Accounts*.

Schritt 2 (Exchange) und Schritt 3 (JWT-Bearer) laufen **identisch** zu `SETUP.md` — gleicher
Requester-Client, gleiche Scopes, gleiche Audience. Der Mechanismus prüft nirgends, welcher Art von
User der `sub` gehört.

## Kettendiagramm

```
Frontend (localhost:8080)                    Backend (localhost:8181)
─────────────────────────                    ────────────────────────
lab-user            domain-5678               domain-5678  (Requester)
     │ Password Grant     │                        │ jwt-bearer + scope=e-rechnung
     ▼                    │                        ▼
  token1  ──token-exchange──►  token2  ───────────────►  token3
                        (Assertion)                      aud: e-rechnung
                                                         roles: reader, writer

sub-Verlauf:
  lab-user (FE-sub) ──── unverändert ────► token1.sub ── unverändert ──► token2.sub
                                                                              │
                                                            Federated Identity │ Übersetzung
                                                                              ▼
                                                    frontend-lab-user (BE-sub) = token3.sub
```

Vergleiche mit dem Diagramm in `SETUP.md`: Nur der linke Rand — wie token1 entsteht — ist anders.
Ab token1 ist die Kette ununterscheidbar vom Service-Account-Flow.

## Konfiguration händisch in der Admin-Konsole

Das ist die primäre Methode hier — keine Skript-Änderung, `setup-realms.sh` bleibt unangetastet.

### 1. Direct Access Grants am Frontend-Client einschalten

Password Grant setzt voraus, dass der Client ihn überhaupt anbietet. Heute steht
`directAccessGrantsEnabled:false` fest in `setup-realms.sh:348` (im JSON-Block `FE_DOMAIN_JSON`,
Zeilen 345-350) — der Service-Account-Flow braucht diesen Grant nicht, also ist er aus.

- Admin-Konsole → Realm `frontend` → *Clients* → `domain-5678`
- Reiter **Settings** → Abschnitt **Capability config** → **Direct access grants** auf **On**
- **Save**

Gemessen: Das Umschalten false→true ist die einzige nötige Änderung an diesem Client.
`serviceAccountsEnabled` und `standard.token.exchange.enabled` bleiben davon unberührt — der
Service-Account-Flow läuft nach dem Umschalten unverändert weiter.

### 2. Frontend-`sub` von `lab-user` ermitteln

- Admin-Konsole → Realm `frontend` → *Users* → `lab-user` → die **User ID** oben auf der Detailseite

Alternativ: token1 holen (siehe unten) und den `sub`-Claim ablesen — beides liefert denselben Wert.

### 3. Backend-User `frontend-lab-user` anlegen

Der Grant sucht die Ziel-Identität über eine Federated Identity und legt sie **nicht** selbst an
(genau wie beim Service Account, siehe `SETUP.md` §1) — fehlt sie, kommt `User not found`.

- Admin-Konsole → Realm `Backend-Microservices` → *Users* → **Add user**
- Username: `frontend-lab-user`
- **Email verified**: On
- Keine Required Actions setzen
- **Create**

> **Namensfalle wie beim Service Account:** Der Name ist frei wählbar, muss aber eindeutig sein und
> darf nicht mit einem von Keycloak selbst vergebenen `service-account-<client>`-Namen kollidieren.
> `frontend-lab-user` folgt demselben Muster wie `frontend-domain-5678` in `SETUP.md`.

### 4. Federated Identity setzen

- Backend-User `frontend-lab-user` öffnen → Reiter **Identity provider links**
- Beim Provider `frontend` (falls die Aktion in der jeweiligen KC-26.7-Version nicht direkt in der
  Zeile sichtbar ist, über das Kontextmenü/den Button am Zeilenende) **Link account** wählen
- **User ID**: der Frontend-`sub` von `lab-user` aus Schritt 2
- **Username**: `frontend-lab-user`

Der Klickpfad für Federated-Identity-Links ist in der Admin-Konsole nicht immer an derselben
Stelle zu finden (abhängig vom genauen Patch-Level). Verlässlicher und **verifiziert** (liefert
HTTP 204) ist der direkte Admin-API-Aufruf, analog zu dem, was `setup-realms.sh:587-589` für den
Service Account tut:

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST \
  "$BE/admin/realms/Backend-Microservices/users/$BACKEND_USER_ID/federated-identity/frontend" \
  -H "Authorization: Bearer $BE_ADMIN_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"identityProvider":"frontend","userId":"<FRONTEND_SUB_VON_LAB_USER>","userName":"frontend-lab-user"}'
# 204
```

`$BACKEND_USER_ID` ist die User-ID von `frontend-lab-user` im Backend-Realm (aus der Konsole oder
per `GET /admin/realms/Backend-Microservices/users?username=frontend-lab-user&exact=true`).

### 5. Rollen zuweisen

- Backend-User `frontend-lab-user` → Reiter **Role mapping** → **Assign role**
- Filter auf **Filter by clients** umstellen
- Von `e-rechnung`: `reader`, `writer`
- Von `fahrtkostenerstattung`: `reader`, `approver`

Genau wie beim Service Account (`SETUP.md` §3): Die Rollen kommen ausschließlich vom
Backend-User, nie aus dem Frontend-Token.

## Die Kette durchlaufen

Nur **token1** ist neu. token2 und token3 sind wortgleich mit `SETUP.md`.

```bash
FE=http://localhost:8080
BE=http://localhost:8181
FS=lab-frontend-domain-5678-secret
BS=lab-backend-domain-5678-secret
BI=http://localhost:8181/realms/Backend-Microservices

# token1 - NEU: Password Grant statt client_credentials
token1=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=password \
  -d username=lab-user -d password=lab-user \
  -d client_id=domain-5678 -d client_secret="$FS" | jq -r .access_token)

# token2 - unverändert aus SETUP.md
token2=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token1" \
  -d scope=access-backend \
  -d audience="$BI" \
  -d client_id=domain-5678 -d client_secret="$FS" | jq -r .access_token)

# token3 - unverändert aus SETUP.md
token3=$(curl -s -X POST "$BE/realms/Backend-Microservices/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  -d assertion="$token2" \
  -d scope=e-rechnung \
  -d client_id=domain-5678 -d client_secret="$BS" | jq -r .access_token)
```

Für `scope=fahrtkostenerstattung` **token2 neu holen** — dieselbe Regel wie im Service-Account-Flow:
Jede Assertion gilt genau einmal (`Token reuse detected`).

## Gemessene Claims

Gemessen gegen Keycloak 26.7.2 im isolierten kctest-Stack, nach der Umstellung oben. Die `sub`-Werte
sind instanzspezifisch (Keycloak vergibt sie bei jedem Realm-Neuaufbau neu) — hier beispielhaft und
gekürzt (`exp`/`iat`/`typ`/`acr`/`sid`/Profil-Claims weggelassen).

> **Hinweis (Mapper 2):** Diese token3-Claims wurden gemessen, **bevor** Mapper 2
> (`oidc-tenant-restriction-mapper`) als Default-Scope am Backend-Requester aktiv war. Seither trägt
> token3 zusätzlich einen bestätigten `tenant`-Claim und ist auf die Rollen der bestätigten
> Mandanten-Gruppe verengt (fail-closed ohne Mitgliedschaft); ein hier direkt zugewiesener Rollensatz
> würde vom Mapper auf die Gruppenrollen zugeschnitten. Die aktuell gemessenen Werte stehen in
> [`Mapper2-Spezifikation.md`](Mapper2-Spezifikation.md) — der Mechanismus gilt unabhängig davon, ob
> das Subjekt ein Service Account oder ein Mensch ist.

```jsonc
// token1 - Password Grant, client domain-5678
{
  "iss": "http://localhost:8080/realms/frontend",
  "azp": "domain-5678",
  "sub": "b8819e0d-…",                 // = lab-user im Frontend
  "aud": ["domain-1234", "account"],
  "preferred_username": "lab-user",
  "scope": "email profile",
  "realm_access": { "roles": ["offline_access", "uma_authorization", "default-roles-frontend"] },
  "resource_access": {
    "domain-5678": { "roles": ["admin", "selfservice"] },
    "domain-1234": { "roles": ["admin", "selfservice"] },
    "account": { "roles": ["manage-account", "manage-account-links", "view-profile"] }
  }
}

// token2 - Exchange/Assertion, client domain-5678
{
  "iss": "http://localhost:8080/realms/frontend",
  "azp": "domain-5678",
  "sub": "b8819e0d-…",                 // unverändert
  "aud": "http://localhost:8181/realms/Backend-Microservices",
  "scope": "email profile access-backend",
  "resource_access": {},
  "jti": "onrtte:5befe217-…"            // Präfix onrtte: — anders als beim SA-Flow
}

// token3 - JWT-Bearer, scope=e-rechnung, client domain-5678
{
  "iss": "http://localhost:8181/realms/Backend-Microservices",
  "azp": "domain-5678",
  "sub": "75ab5574-…",                 // = frontend-lab-user im Backend, NEUER sub
  "aud": "e-rechnung",
  "scope": "email e-rechnung profile",
  "preferred_username": "frontend-lab-user",
  "jti": "trrtag:…",                    // transient, deshalb kein Refresh Token
  "resource_access": { "e-rechnung": { "roles": ["reader", "writer"] } }
}
```

Mit `scope=fahrtkostenerstattung` (gemessen, token2 dafür neu geholt):

```jsonc
{
  "sub": "75ab5574-…",
  "aud": "fahrtkostenerstattung",
  "resource_access": { "fahrtkostenerstattung": { "roles": ["approver", "reader"] } }
}
```

**Wichtiges Detail:** `domain-5678` steht **nicht** in `token1.aud`, obwohl `lab-user` dort Rollen
hat — der `AudienceResolveProtocolMapper` schließt den `azp`-Client explizit aus
(`domain-1234` erscheint dagegen, weil der User dort ebenfalls Rollen hat und `domain-1234` nicht
`azp` ist). Genau deshalb funktioniert der Exchange trotzdem: Der tauschende Client `domain-5678`
ist zugleich der `azp` des Subject-Tokens, und die `azp`-Ausnahme der Audience-Prüfung
(`StandardTokenExchangeProvider.java:203-205`, siehe Gegenprobe G5 in
[`docs/Interner-Token-Exchange.md`](Interner-Token-Exchange.md)) lässt ihn trotzdem tauschen. Ein
eigener Audience-Mapper auf token1 ist überflüssig — dieselbe Ausnahme, die im Service-Account-Flow
mit `aud: account` in token1 (siehe `SETUP.md`) greift, greift hier mit `aud: [domain-1234,
account]`.

Der `sub`-Wechsel token2 → token3 ist derselbe Übersetzungsschritt wie im Service-Account-Flow —
über die Federated Identity, nur zeigt sie jetzt auf `frontend-lab-user` statt auf
`frontend-domain-5678`.

## Warum SA- und User-Flow koexistieren

Nach der Umstellung existieren im Backend **zwei** Ziel-User: `frontend-domain-5678` (verlinkt auf
den `sub` des Frontend-Service-Accounts) und `frontend-lab-user` (verlinkt auf den `sub` von
`lab-user`). Das ist kein Konflikt — die beiden Frontend-`sub`s sind verschieden, und der Guard in
`JpaUserProvider.java:755` verbietet nur **zwei Links auf denselben** `sub` (er wirft eine
`IllegalStateException`, siehe `SETUP.md` §5). Zwei verschiedene `sub`s bekommen zwei verschiedene
Backend-Identitäten — genau das Verhalten, das dort schon für den Fall beschrieben ist, dass
`domain-5678` je nach Kontext als mehrere Backend-Identitäten auftreten soll.

Gemessen: Nach der Umstellung liefern beide Flows parallel ein korrektes token3 — der
Service-Account-Flow weiterhin mit `sub` = `frontend-domain-5678`, der User-Flow mit `sub` =
`frontend-lab-user`. Keiner beeinflusst den anderen.

## Stolperfallen

- **Ein erneuter `./setup-realms.sh`-Lauf (auch ohne `--recreate`) setzt Direct Access Grants
  wieder auf Off.** `ensure_client` aktualisiert bestehende Clients per `PUT` mit der **vollen**
  Repräsentation (`setup-realms.sh:170-171`), und `FE_DOMAIN_JSON` (Zeilen 345-350) trägt fest
  `directAccessGrantsEnabled:false`. Nach jedem Skript-Lauf muss der Schalter in der Admin-Konsole
  erneut auf On gestellt werden. `setup-realms.sh` bewusst **nicht** ändern (Konvention: additiv,
  rein manuell) — stattdessen den Schritt aus diesem Dokument nach jedem `setup-realms.sh` wiederholen.
- **token3 trägt einen anderen `sub` als token1/token2.** Das ist die Übersetzung über die
  Federated Identity, kein Fehler — siehe `SETUP.md` §1 und §5.
- **Jede Assertion gilt genau einmal** (`invalid_grant: Token reuse detected`). Für den zweiten
  Dienst token2 neu holen, nicht token1 wiederverwenden.
- Die aussagekräftige Fehlermeldung steht im Server-Log, nicht in der HTTP-Antwort:
  `docker compose logs -f backend-keycloak`.

## Quellen

Verifiziert gegen Keycloak 26.7.0/26.7.2, Datei:Zeile:

| Fundstelle | Aussage |
|---|---|
| `StandardTokenExchangeProvider.java:203-205` | tauschender Client muss in der `aud` des Subject-Tokens stehen, außer er ist dessen `azp` — deshalb funktioniert der Exchange trotz `domain-5678` außerhalb von `token1.aud` |
| `JpaUserProvider.java:755` | zwei Federated-Identity-Links auf denselben `sub` → `IllegalStateException`; zwei verschiedene `sub`s sind dagegen unproblematisch |
| `JWTAuthorizationGrantType.java:139` | `User not found`, wenn keine Federated Identity auf den `sub` der Assertion verweist |

Basis-Doku: [`SETUP.md`](../SETUP.md) — dort der vollständige Service-Account-Flow, das
Hostnamen-Problem, alle fünf Grundregeln und das Troubleshooting, die hier unverändert gelten.

---

Gemessen am 2026-09-12 gegen Keycloak 26.7.2 in einem isolierten Compose-Stack, provisioniert mit
`./setup-realms.sh --recreate` und der händischen Umstellung aus diesem Dokument.
