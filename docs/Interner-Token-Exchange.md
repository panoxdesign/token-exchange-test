# Interner Token Exchange über ein Gateway

Zweiter, in sich geschlossener Mechanismus im Frontend-Realm: ein Self-Service-Portal tauscht das
Token seines Users gegen ein auf eine Ziel-Domain zugeschnittenes Token, das ein Gateway ausstellt.

## Was das ist

Standard Token Exchange V2, realm-intern: ein Aussteller, ein Realm. Kein Identity Provider, kein
gespiegelter User — der Exchange bleibt vollständig innerhalb von `frontend`.

Das ist die Abgrenzung zur cross-realm Kette aus `SETUP.md`: Dort tauscht Token Exchange V2 gegen
eine JWT-*Assertion*, die erst der Backend-Keycloak über den JWT Authorization Grant gegen ein
echtes Token einlöst — Identity Chaining über zwei Instanzen. Hier bleibt alles in einem Realm, und
das ändert praktisch zwei Dinge:

- Das Ergebnis ist ein **normales Bearer-Token**, kein Einmal-Ticket. Es lässt sich mehrfach
  verwenden; `Token reuse detected` gibt es hier nicht, weil kein `jti`-präfixiertes
  Assertion-Objekt entsteht, das nur einmal eingelöst werden darf.
- Es braucht **keinen zweiten Keycloak**. Kein IdP, kein Federated-Identity-Eintrag, kein
  gespiegelter User — der Exchange bedient sich direkt am User, der schon im Realm existiert.

## Die Kette

```
FRONTEND-REALM  frontend  (intern, kein zweiter Keycloak)
───────────────────────────────────────────────────────

lab-user
  Rollen: domain-5678 [admin, selfservice], domain-1234 [admin, selfservice]
      │
      │ grant_type=password
      ▼
self-service-portal                              domain-5678 (Doppelrolle, s.u.)
  Full scope allowed: OFF                           Rollen: admin, selfservice
  Scope to-gateway (Default)                             ▲
      │  Audience-Mapper ──► gateway                     │  Role Scope Mappings
      ▼                                                   │
   token_sp   (aud: gateway)                              │
      │                                                    │
      │ token-exchange                                     │
      │ audience=domain-5678 & scope=domain-5678            │
      ▼                                                     │
   gateway ────────────────────────────────────────────────┘
     Standard token exchange: ON        domain-1234
     Full scope allowed: OFF              Rollen: admin, selfservice
     Scope roles: Default                      ▲
       (AudienceResolveProtocolMapper)          │  Role Scope Mappings
     Scopes domain-5678 / domain-1234           │
       (beide Optional) ──────────────────────────┘
      │
      │ scope= waehlt die Domain, audience= schneidet zu
      ▼
   token_dom   (aud: domain-5678, resource_access: admin, selfservice)
```

Drei Objekte tragen die Kette: `self-service-portal` (Ausgangstoken), `gateway` (Requester des
Exchange), und die Ziel-Domains `domain-5678`/`domain-1234` (Audience-Ziele über ihre Rollen).

## Was angelegt wird

| Objekt | Zweck |
|---|---|
| Client `gateway` | Requester des internen Exchange. **Standard token exchange** On, **Full scope allowed** Off, Client Scope `roles` als Default (bringt den `AudienceResolveProtocolMapper` mit), `domain-5678`/`domain-1234` als **Optional** |
| Client `self-service-portal` | Client für den Password Grant des Lab-Users. *Direct Access Grants* On, **Full scope allowed** Off, Client Scope `to-gateway` als **Default** |
| Client `domain-1234` | reine Ziel-Domain, existiert nur wegen ihrer Rollen `admin`, `selfservice` |
| Client `domain-5678` | **Doppelrolle.** Derselbe Client ist außen (cross-realm Kette aus `SETUP.md`) Service-Account-Client mit Token Exchange, und innen (dieser Mechanismus) reine Ziel-Domain mit den Rollen `admin`, `selfservice`. Zwei Zuständigkeiten, ein Client-Objekt |
| Client Scope `to-gateway` | expliziter `oidc-audience-mapper` auf `gateway`, als Default am SP-Client |
| Client Scope `domain-5678` | Role Scope Mappings auf die Rollen von `domain-5678`, `oidc-hardcoded-claim-mapper` `domain=domain-5678` |
| Client Scope `domain-1234` | Role Scope Mappings auf die Rollen von `domain-1234`, `oidc-hardcoded-claim-mapper` `domain=domain-1234` |
| User `lab-user` | trägt die Rollen beider Domains, meldet sich per Passwort-Grant an |

## Wie die `aud` entsteht — der Kern

Es gibt zwei Wege, wie ein Client in der `aud` eines Tokens landet:

- ein expliziter **`oidc-audience-mapper`** in einem Client Scope, der eine `client_id` fest
  hineinschreibt, oder
- **implizit** über den eingebauten `AudienceResolveProtocolMapper`, der im Client Scope `roles`
  sitzt — und den jeder Client per Default trägt. Er schreibt jeden Client in die `aud`, in dem der
  User *aufgelöste* Rollen hat (`AudienceResolveProtocolMapper.java:140-155`).

Dieser Aufbau nutzt **beide, an verschiedenen Stellen**, und das ist Absicht:

- Die Domain-Scopes (`domain-5678`, `domain-1234`) gehen den **Rollen-Weg**. Kein eigener
  Audience-Mapper nötig — ein Objekt weniger — und der Zusammenhang „keine Rolle auf der Domain =
  kein Token für die Domain" wird **hart** statt weich: Ohne Rolle gibt es keinen Eintrag im
  aufgelösten `resource_access`, also keinen Eintrag in der `aud`, also keinen Exchange.
- `to-gateway` braucht den **expliziten Mapper**, weil `gateway` keine Rollen hat und auch keine
  bekommen soll — er ist reines Audience-Ziel, kein Berechtigungsträger. Für ein Ziel ohne Rollen
  funktioniert der Rollen-Weg prinzipiell nicht: ohne aufgelöste Rolle gibt es nichts, das der
  `AudienceResolveProtocolMapper` finden könnte.

Der bewusst akzeptierte Preis, der klar dastehen muss — gemessen als Gegenprobe G7: Ein User ohne
Rolle auf der Ziel-Domain bekommt **HTTP 400 `Requested audience not available`** — **nicht** ein Token mit korrekter `aud`
und leerem `resource_access`. Fehlende Berechtigung sieht damit aus wie ein Konfigurationsfehler,
nicht wie ein Zugriff, der sauber auf null Rechte zugeschnitten wurde. Wer das anders haben will,
ergänzt im Domain-Scope einen eigenen `oidc-audience-mapper`; dann ist die `aud` von den Rollen
entkoppelt, und ein Token ohne Rolle ist wieder möglich (mit leerem `resource_access`).

## Was `audience=` tut

Er **filtert** nur (`TokenManager.restrictRequestedAudience`, `retainAll` gegen die bereits
aufgelöste `aud`), er fügt nichts hinzu — und filtert dabei auch `resource_access` mit. Ohne einen
Mapper, der die `aud` überhaupt erzeugt, bleibt die Schnittmenge leer, und der Request scheitert mit
`Requested audience not available`.

## Warum `scope=` Pflicht ist

Die Domain-Scopes hängen als **Optional** am `gateway`, nicht als Default. Ohne `scope=domain-5678`
wird der Scope nicht aktiv, seine Role Scope Mappings laufen nicht, es resolven keine Rollen — und
ohne aufgelöste Rollen erzeugt der `AudienceResolveProtocolMapper` keine `aud`. Ergebnis: HTTP 400.

## Was `Full scope allowed = Off` hier leistet

Wichtig: Die Begründung ist eine **andere** als in `SETUP.md` für die Backend-Kette. Dort hebelt
`On` die Zuschneidung komplett aus, unabhängig davon, ob `audience=` mitgeschickt wird. Hier ist das
anders: Solange `audience=` mitgeschickt wird, filtert `restrictRequestedAudience` ohnehin — das
Ergebnis ist mit `On` und `Off` **identisch**. Der Schalter greift genau dann, wenn `audience=`
**weggelassen** wird. Gemessen durch Umschalten am `gateway`, mit `scope=domain-1234`:

| `fullScopeAllowed` | mit `audience=domain-1234` | ohne `audience` |
|---|---|---|
| `false` | `aud: domain-1234`, `resource_access`: nur `domain-1234` | `aud: domain-1234`, `resource_access`: nur `domain-1234` |
| `true` | `aud: domain-1234`, `resource_access`: nur `domain-1234` | `aud: [domain-5678, domain-1234, account]`, `resource_access`: alle drei |

## Die Kette durchlaufen

Entweder mit den Bruno-Requests `04` → `05a`/`05b`, oder in der Shell:

```bash
FE=http://localhost:8080
SP=lab-frontend-sp-secret
GW=lab-frontend-gateway-secret

token_sp=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=password \
  -d username=lab-user -d password=lab-user \
  -d client_id=self-service-portal -d client_secret="$SP" | jq -r .access_token)

token_dom=$(curl -s -X POST "$FE/realms/frontend/protocol/openid-connect/token" \
  -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \
  -d subject_token="$token_sp" \
  -d audience=domain-5678 -d scope=domain-5678 \
  -d client_id=gateway -d client_secret="$GW" | jq -r .access_token)
```

Für `domain-1234` denselben Exchange mit `audience=domain-1234 -d scope=domain-1234` wiederholen —
`token_sp` muss dafür **nicht** neu geholt werden, anders als die Assertion in der cross-realm
Kette.

So sehen die Claims aus (gemessen, `exp`/`iat`/`jti`/`sid` und Profil-Claims weggelassen). Der
konkrete `sub` ist instanzspezifisch — Keycloak vergibt ihn neu, sobald der Realm neu aufgebaut
wird; entscheidend ist, dass er über beide Exchanges hinweg derselbe bleibt:

```jsonc
// token_sp - grant_type=password, client self-service-portal
{
  "iss": "http://localhost:8080/realms/frontend",
  "aud": "gateway",
  "azp": "self-service-portal",
  "sub": "f0ecdfd7-d30f-40c9-a4bd-97e33d24edc0",
  "preferred_username": "lab-user",
  "domain": null,
  "scope": "to-gateway profile email",
  "resource_access": null,
  "realm_access": null
}

// token_dom - token-exchange, client gateway, audience=domain-5678 & scope=domain-5678
{
  "iss": "http://localhost:8080/realms/frontend",
  "aud": "domain-5678",
  "azp": "gateway",
  "sub": "f0ecdfd7-d30f-40c9-a4bd-97e33d24edc0",
  "preferred_username": "lab-user",
  "domain": "domain-5678",
  "scope": "domain-5678 profile email",
  "resource_access": { "domain-5678": { "roles": ["admin", "selfservice"] } },
  "realm_access": null
}

// token_dom - token-exchange, client gateway, audience=domain-1234 & scope=domain-1234
{
  "iss": "http://localhost:8080/realms/frontend",
  "aud": "domain-1234",
  "azp": "gateway",
  "sub": "f0ecdfd7-d30f-40c9-a4bd-97e33d24edc0",
  "preferred_username": "lab-user",
  "domain": "domain-1234",
  "scope": "profile email domain-1234",
  "resource_access": { "domain-1234": { "roles": ["admin", "selfservice"] } },
  "realm_access": null
}
```

Dieselbe Dreiteilung wie bei der Backend-Kette in `SETUP.md`: `azp` ist der Client, der gehandelt
hat (`self-service-portal`, dann `gateway`), `aud` ist der Dienst, für den das Token gilt (`gateway`,
dann die jeweilige Domain), `sub` ist die Identität — und bleibt über beide Exchanges hinweg
konstant, derselbe `lab-user`.

`resource_access` fehlt in `token_sp` komplett (`null`), nicht etwa leer. Den Client Scope `roles`
trägt `self-service-portal` sehr wohl — er steht als Default an jedem Client. Aber der SP-Client hat
**Full scope allowed Off**, und keiner seiner Scopes trägt Role Scope Mappings; `to-gateway` enthält
nur den Audience-Mapper. Also löst sich nichts auf, und der `AudienceResolveProtocolMapper` findet
nichts vor. Selbst die Default-Rollen des Realms (`account: view-profile`, `manage-account`) bleiben
deshalb draußen. Erst der Exchange gegen `gateway` mit `scope=domain-5678` bringt Rollen ins Spiel.

### Gegenproben

Alle sieben gemessen. Fünf davon scheitern, zwei liefern ein Token — G2 und G3 zeigen, was
passiert, wenn man den Zuschnitt weglässt:

| # | Aufruf | Ergebnis | Zeigt |
|---|---|---|---|
| G1 | `scope=` weggelassen, `audience=domain-1234` | 400 `invalid_request` — „Requested audience not available: domain-1234" | ohne `scope=` resolven keine Rollen, ohne Rollen keine `aud` — siehe „Warum `scope=` Pflicht ist" |
| G2 | `audience=` weggelassen, `scope=domain-1234` | 200, `aud: domain-1234`, `resource_access` nur `domain-1234` (weil `fullScopeAllowed=Off`) | der Rollen-Weg erzeugt die `aud` auch ganz ohne `audience=`; `Full scope allowed Off` hält `resource_access` dabei von sich aus eng |
| G3 | beide weggelassen | 200, aber `aud: null`, kein `domain`-Claim, kein `resource_access` | ohne Rollen und ohne Audience-Mapper entsteht gar keine `aud` — das Minimum ist die leere Menge, nicht alles |
| G4 | Requester `self-service-portal` (gültiges Secret, kein Exchange-Flag) | 400 `invalid_request` — „Standard token exchange is not enabled for the requested client" | ein gültiges Secret reicht nicht; Token Exchange muss am tauschenden Client selbst freigeschaltet sein |
| G5 | Subject-Token ohne `gateway` in der `aud` (SA-Token von `domain-5678`, `aud: account`) | 403 `access_denied` — „Client is not within the token audience" | der tauschende Client muss in der `aud` des Subject-Tokens stehen (`StandardTokenExchangeProvider.java:203-205`) |
| G6 | `audience=gibts-nicht` | 400 `invalid_client` — „Audience not found" | `audience` wird zu einem existierenden Client aufgelöst; eine unbekannte ID scheitert, bevor überhaupt gefiltert wird |
| G7 | User mit Rolle **nur** auf `domain-5678`, Exchange auf `domain-1234` | 400 `invalid_request` — „Requested audience not available: domain-1234"; derselbe User bekommt für `domain-5678` ein normales Token | der Preis des Rollen-Wegs, direkt gemessen: fehlende Berechtigung endet im Fehler, nicht in einem Token mit leerem `resource_access` |

## Stolperfallen / Troubleshooting

- **`Account is not fully set up` bei leerer `requiredActions`-Liste.** Ursache ist das deklarative
  User Profile: Fehlt `email`, `firstName` oder `lastName`, löst Keycloak beim Login **dynamisch**
  `VERIFY_PROFILE` aus, obwohl am User selbst keine Required Action steht. Im Server-Log erscheint
  dann `error="resolve_required_actions"`. Das hat beim Aufbau real Zeit gekostet — `check-setup.sh`
  prüft `email`/`firstName`/`lastName` deshalb explizit, nicht nur `requiredActions`.
- **`domain-5678` hat im Frontend-Realm jetzt zwei Rollen.** Einmal Besitzer des Ausgangstokens der
  cross-realm Kette (Service-Account-Client mit Token Exchange), einmal Audience-Ziel des internen
  Exchange (Ziel-Domain mit Rollen). Dazu kommt ein gleichnamiger Client Scope. Sauber trennen: das
  eine ist der **Client** `domain-5678`, das andere der **Client Scope** `domain-5678` — der Client
  Scope hat mit dem Client außer dem Namen nichts zu tun.
- Die aussagekräftige Fehlermeldung steht im Server-Log, nicht in der HTTP-Antwort:
  `docker compose logs -f frontend-keycloak`.
- **Der Client Scope `roles` am `gateway` ist tragend.** Wird er entfernt, bricht die ganze Kette
  mit `Requested audience not available` — ohne ihn läuft kein `AudienceResolveProtocolMapper`, also
  entsteht überhaupt keine `aud`. `check-setup.sh` prüft ihn deshalb explizit als Default-Scope.

## Quellen

Verifiziert gegen Keycloak 26.7.0, Datei:Zeile:

| Fundstelle | Aussage |
|---|---|
| `StandardTokenExchangeProvider.java:203-205` | tauschender Client muss in der `aud` des Subject-Tokens stehen, ausser er ist dessen `azp` |
| `AbstractTokenExchangeProvider.java:196-216` | `audience` wird zu Clients aufgeloest; unbekannt → `Audience not found`; ohne `audience` faellt Keycloak auf den tauschenden Client zurueck |
| `TokenManager.java:833-838`, `restrictRequestedAudience:1470-1478` | `audience` filtert per `retainAll`, auch `resource_access`; laeuft nur, wenn `audience` gesetzt ist |
| `TokenUtils.checkRequestedAudiences:99-110` | fehlt die angeforderte Audience im Ergebnis → 400 `Requested audience not available` |
| `AudienceResolveProtocolMapper.java:140-155` | setzt `aud` fuer jeden Client, in dem der User aufgeloeste Rollen hat |
| `HardcodedClaim.java:61,105-120` | `oidc-hardcoded-claim-mapper`, Config-Keys `claim.name`, `claim.value`, `jsonType.label` |

---

Gemessen am 2026-09-11 gegen Keycloak 26.7.2 in einem isolierten Compose-Stack, provisioniert mit
`./setup-realms.sh --recreate`.
