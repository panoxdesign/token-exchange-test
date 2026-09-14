# Mapper 2 — Machbarkeit am Keycloak-26.7.2-Quellcode

Belegt die drei offenen Fragen aus dem Handoff, **bevor** Code entsteht. Alle Aussagen mit
Datei:Zeile gegen den Tag `26.7.2` (`raw.githubusercontent.com`; `www.keycloak.org` ist blockiert).
Endgültiger Beweis bleibt der kctest-Lauf — hier geht es darum, dass der Ansatz *tragen kann*.

## Ergebnis in einem Satz

Mapper 2 ist als **Custom OIDC Access-Token-Mapper** umsetzbar: er liest den `tenant`-Claim direkt
aus der `assertion` (Brücke A), läuft dank hoher **Priorität** nach der Rollen-Auflösung und
verengt `resource_access` per Schnittmenge gegen die Rollen der bestätigten Mandanten-Gruppe.

## Frage 1 — Wie gelangt der `tenant`-Claim in den Backend-Mapper?

**Brücke A (gewählt): Mapper liest die `assertion` aus den Form-Parametern und dekodiert sie selbst.**

- Der jwt-bearer-Grant liest die Assertion selbst aus den Form-Parametern:
  `String assertion = formParams.getFirst(OAuth2Constants.ASSERTION)`
  (`JWTAuthorizationGrantType.java:64`). Die Form-Parameter stammen aus dem Request-Kontext
  (`OAuth2GrantTypeBase.java:108`, `this.formParams = context.formParams`) — **dieselbe Quelle**, die
  Mapper 1 über `keycloakSession.getContext().getHttpRequest().getDecodedFormParameters()` schon
  erfolgreich nutzt.
- Die Assertion wird **vor** dem Bau von token3 validiert (Signatur/Issuer/Audience/Reuse:
  `JWTAuthorizationGrantType.java:129-171`), der Token-Bau passiert erst danach
  (`createTokenResponseBuilder`, `:180`). Wenn Mapper 2 läuft, ist die Assertion also bereits geprüft
  — er muss sie nur noch dekodieren, nicht erneut verifizieren.
- Dekodieren wie der Grant selbst: `new JWSInput(assertion).readJsonContent(JsonWebToken.class)`
  (`JWTAuthorizationGrantType.java:75-76`), dann `jwt.getOtherClaims().get("tenant")`.

**Brücke B (Fallback, nicht nötig):** IdP-Mapper am `frontend`-IdP schreibt `tenant` in eine User
Session Note, Mapper 2 liest `userSession.getNote(...)`. Mehr bewegliche Teile (zusätzliches
Keycloak-Objekt, passender IdP-Mapper-Typ), kein Vorteil für ein Labor. Verworfen zugunsten A.

## Frage 2 — Läuft Mapper 2 *nach* dem Befüllen von `resource_access`?

Ja, wenn er eine **Priorität > 40** setzt.

- `TokenManager.transformAccessToken` ruft alle Access-Token-Mapper in **sortierter** Reihenfolge auf
  (`TokenManager.java:824-830`, `ProtocolMapperUtils.getSortedProtocolMappers`).
- Sortiert wird **aufsteigend nach `getPriority()`** — „Lower goes first"
  (`ProtocolMapperUtils.java:177-183`; `ProtocolMapper.java:41-43`, Default `0`).
- Die Rollen-Mapper, die `resource_access` befüllen, laufen bei Priorität **40**
  (`AbstractUserRoleMappingMapper.java:44-45` → `PRIORITY_ROLE_MAPPER`;
  Konstanten in `ProtocolMapperUtils.java:80-92`: role-names 10, hardcoded-role 20,
  audience-resolve 30, **role 40**, script 50).
- ⇒ Mapper 2 überschreibt `getPriority()` mit z. B. **100**, läuft damit nach allen Rollen-/
  Script-Mappern und sieht das fertig aufgelöste `resource_access`.

Der Default `0` (wie in Mapper 1) würde Mapper 2 **vor** den Rollen laufen lassen — dann wäre nichts
zu filtern. Das Überschreiben der Priorität ist also Pflicht, nicht Kür.

Zusätzlich (wie bei Mapper 1): `transformAccessToken` selbst überschreiben, weil die Basisklasse
`setClaim`/die Transformation nur bei gesetztem Config-Flag `access.token.claim` ausführt
(`AbstractOIDCProtocolMapper.java:89-99`).

## Frage 3 — Mitgliedschaft prüfen, Gruppen-Rollen lesen, `resource_access` verengen

- **Mitgliedschaft + Gruppe in einem Schritt:** `user.getGroupsStream()` (`UserModel.java:182`) liefert
  die Gruppen des Users; die mit `getName().equals(tenant)` (`GroupModel.java:227`) ist die bestätigte
  Mitgliedschaft. Keine Treffer → fail-closed. (`UserModel.isMemberOf` `:227` existiert ebenfalls.)
- **Rollen der Gruppe je Dienst:** `GroupModel extends RoleMapperModel` (`GroupModel.java:31`), also
  `group.getClientRoleMappingsStream(client)` (`RoleMapperModel.java:40`) → die dem Mandanten
  zugewiesenen Client-Rollen des Dienst-Clients.
- **`resource_access` lesen/schreiben** (`AccessToken.java`): `getResourceAccess()` → `Map<String,
  Access>` (`:174`), `Access.getRoles()`/`roles(Set)` (`:66-73`), `setResourceAccess(Map)` (`:178`),
  `getResourceAccess(clientId)` (`:211`). Client zum `resource_access`-Schlüssel:
  `realm.getClientByClientId(clientId)`.

## Empfohlene Mapper-Logik (ein Codepfad, fail-closed fällt heraus)

```text
transformAccessToken(token, ...):                    // Priorität 100
  tenant = leseTenantAusAssertion()                  // Brücke A; null wenn fehlt/undekodierbar
  bestätigteGruppe = tenant==null ? null
                     : user.getGroupsStream().filter(g -> g.name == tenant).findFirst()

  für jeden Eintrag (clientId -> access) in token.resource_access:
    client       = realm.getClientByClientId(clientId)
    erlaubteRollen = bestätigteGruppe==null || client==null ? {}                // leer => alles raus
                     : bestätigteGruppe.getClientRoleMappingsStream(client).map(name).toSet()
    access.roles = access.roles ∩ erlaubteRollen
    ist access.roles leer -> Eintrag aus resource_access entfernen

  wenn bestätigteGruppe != null:  token.otherClaims["tenant"] = tenant          // bestätigter Claim
```

- **Nur Schnittmenge, nie hinzufügen** → respektiert Scope-Gating, kann keine Rolle an der
  Berechtigung vorbei injizieren.
- **Fail-closed ohne Sonderfall:** keine bestätigte Gruppe ⇒ `erlaubteRollen` überall leer ⇒
  `resource_access` wird geleert, `tenant`-Claim bleibt weg. Genau das gewünschte Verhalten für
  „tenant fehlt / keine Mitgliedschaft / Gruppe existiert nicht".

## Registrierung — wo greift Mapper 2 für token3?

token3 wird für den **Backend-Requester-Client `domain-5678`** gebaut. Empfehlung: ein **eigener
Client Scope** (z. B. `tenant-restriction`) mit Mapper 2, als **Default-Scope** an `domain-5678`.
So läuft der Mapper bei **jedem** token3 — auch fail-closed, wenn gar kein Dienst-Scope aktiv ist —
statt an je einen Dienst-Scope gehängt zu werden.

## Offene Feinheiten (in kctest gegenprüfen, unkritisch fürs Labor)

- **Composite-Rollen / Parent-Gruppen:** `getClientRoleMappingsStream` liefert die *direkt*
  zugewiesenen Client-Rollen der Gruppe. Das Labor nutzt flache, nicht-composite Rollen und flache
  Gruppen — direkt == effektiv. Bei Composites müsste man expandieren; hier nicht nötig.
- **`account`/Fremd-Clients in `resource_access`:** Im gemessenen token3 steht nur der Dienst-Client
  (`fullScopeAllowed=false`, nur der Dienst-Scope aktiv). Die Schnittmenge würde einen etwaigen
  `account`-Eintrag mit entfernen — im Labor-Flow irrelevant, aber als Annahme notiert.
- **Brücke A, Endbeweis:** Dass `getDecodedFormParameters()` im Mapper-Kontext des jwt-bearer-Grants
  die `assertion` führt, folgt aus der gemeinsamen Quelle und dem Mapper-1-Präzedenzfall; final im
  kctest-Lauf bestätigen.

## Belegte Fundstellen

| Fundstelle | Aussage |
|---|---|
| `JWTAuthorizationGrantType.java:64` | Grant liest `assertion` aus `formParams` |
| `JWTAuthorizationGrantType.java:75-76` | Assertion-Dekodierung via `JWSInput`/`JsonWebToken` |
| `JWTAuthorizationGrantType.java:129-180` | Assertion wird vor dem Token-Bau validiert |
| `OAuth2GrantTypeBase.java:108` | `formParams` kommt aus dem Request-Kontext |
| `TokenManager.java:824-830` | Access-Token-Mapper laufen sortiert |
| `ProtocolMapperUtils.java:80-92,177-183` | Prioritäts-Konstanten; aufsteigende Sortierung |
| `ProtocolMapper.java:41-43` | Default-Priorität 0, „Lower goes first" |
| `AbstractUserRoleMappingMapper.java:44-45` | Rollen-Mapper bei Priorität 40 |
| `AbstractOIDCProtocolMapper.java:89-99` | `transformAccessToken` nur bei `access.token.claim` |
| `AccessToken.java:66-73,174-224` | `resource_access`/`Access`-API |
| `RoleMapperModel.java:40` | `getClientRoleMappingsStream(ClientModel)` |
| `UserModel.java:182,227` | `getGroupsStream()`, `isMemberOf` |
| `GroupModel.java:31,227` | `GroupModel extends RoleMapperModel`; `getName()` |

---

Recherchiert am 2026-09-14 gegen Keycloak 26.7.2. Grundlage für `tenant-restriction-mapper/`
(Mapper 2) und die Anpassungen an `setup-realms.sh`/`check-setup.sh`.
