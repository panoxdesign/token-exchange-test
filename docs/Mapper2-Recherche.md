# Mapper 2 — Machbarkeit am Keycloak-26.7.0-Quellcode

Belegt die offenen Fragen zur Buchungs-Durchsetzung, **bevor** Code entsteht. Alle Aussagen mit
Datei:Zeile gegen den Tag `26.7.0` (`raw.githubusercontent.com`; `www.keycloak.org` ist blockiert).
Endgültiger Beweis bleibt der kctest-Lauf — hier geht es darum, dass der Ansatz *tragen kann*.

## Ergebnis in einem Satz

Mapper 2 (`oidc-booking-restriction-mapper`) ist als **Custom OIDC Access-Token-Mapper** umsetzbar:
er liest den `scope`-Claim direkt aus der `assertion` (Brücke A, wie Mapper 1), läuft dank hoher
**Priorität** nach der Rollen-Auflösung und verengt `resource_access` auf die Clients, deren Name
unter den `service:*`-Einträgen dieses Claims steht.

## Frage 1 — Bildet Keycloak beim jwt-bearer-Grant selbst eine Schnittmenge aus Assertion-`scope`
## und Request-`scope`?

**Nein.** Das ist der Kern, warum ein Custom-Mapper überhaupt nötig ist:

- Der Grant liest den angeforderten Scope ausschließlich aus dem **Request-Parameter** `scope=`,
  nicht aus der Assertion:
  ```java
  // OAuth2GrantTypeBase.java:265-275
  protected String getRequestedScopes() {
      String scope = formParams.getFirst(OAuth2Constants.SCOPE);
      if (!TokenManager.isValidScope(session, scope, client)) { … }
      return scope;
  }
  ```
  `TokenManager.isValidScope` prüft nur, ob `scope` unter den (Default-/Optional-)Client-Scopes des
  **anfragenden Clients** liegt (`backend-requester`) — die Assertion kommt darin nicht vor.
- `JWTAuthorizationGrantType.java:154` übergibt genau dieses `scopeParam` unverändert an
  `createTokenResponseBuilder(...)`, das darüber die Rollen/Client-Scopes für token3 auflöst.
- Die Assertion selbst wird nur für Identität und Vertrauen geprüft (Signatur, `iss`, `aud`, `jti`,
  Federated Identity) — ihr `scope`-Claim spielt für die **native** Scope-Auflösung keine Rolle.

⇒ Ohne eigenen Mapper würde `scope=fahrtkostenerstattung` in Schritt 3 diesen Dienst freischalten,
selbst wenn die Assertion nur `service:e-rechnung` bucht — solange der Backend-User überhaupt
Rollen für `fahrtkostenerstattung` trägt. Das ist genau die Lücke, die Mapper 2 schließt.

## Frage 2 — Wie gelangt der `scope`-Claim der Assertion in den Backend-Mapper?

**Brücke A (gewählt, wie bei Mapper 1): Mapper liest die `assertion` aus den Form-Parametern und
dekodiert sie selbst.**

- Der jwt-bearer-Grant liest die Assertion selbst aus den Form-Parametern:
  `String assertion = formParams.getFirst(OAuth2Constants.ASSERTION)` (`JWTAuthorizationGrantType.java:29`),
  dann `jwt = jws.readJsonContent(JsonWebToken.class)` (`JWTAuthorizationGrantType.java:37-40`).
  Die Form-Parameter stammen aus dem Request-Kontext — dieselbe Quelle, die Mapper 1 über
  `keycloakSession.getContext().getHttpRequest().getDecodedFormParameters()` schon nutzt.
- Die Assertion wird **vor** dem Bau von token3 validiert (Signatur/Issuer/Audience/Reuse), der
  Token-Bau passiert erst danach. Wenn Mapper 2 läuft, ist die Assertion also bereits geprüft — er
  muss sie nur noch dekodieren, nicht erneut verifizieren.

## Frage 3 — Steht `scope` beim Dekodieren als `JsonWebToken` überhaupt zur Verfügung?

**Ja, über `otherClaims` — kein Sonderfall.**

- `scope` ist **kein** deklariertes Feld von `JsonWebToken`, sondern nur von dessen Unterklasse
  `AccessToken`:
  ```java
  // AccessToken.java:162-163
  @JsonProperty("scope")
  protected String scope;
  ```
- `JsonWebToken` fängt jede unbekannte JSON-Property über `@JsonAnySetter` ab und legt sie in
  `otherClaims` ab:
  ```java
  // JsonWebToken.java:275-283
  @JsonAnyGetter
  public Map<String, Object> getOtherClaims() { return otherClaims; }

  @JsonAnySetter
  public void setOtherClaims(String name, Object value) { otherClaims.put(name, value); }
  ```
- Der jwt-bearer-Grant selbst dekodiert die Assertion als `JsonWebToken` (nicht als `AccessToken`,
  s. o.) — also landet `scope` beim Dekodieren dort exakt so in `otherClaims`, wie es `tenant` bzw.
  `domain` bei den anderen beiden Mappern schon tun. Keine zweite Dekodierung als `AccessToken`
  nötig, kein Sonderfall gegenüber Mapper 1/2 alt.

## Frage 4 — Läuft Mapper 2 *nach* dem Befüllen von `resource_access`?

Ja, wenn er eine **Priorität > 40** setzt (unverändert gegenüber der Vorgänger-Recherche):

- `TokenManager.transformAccessToken` ruft alle Access-Token-Mapper **aufsteigend nach
  `getPriority()`** auf (`ProtocolMapperUtils.java`, „Lower goes first").
- Die Rollen-Mapper, die `resource_access` befüllen, laufen bei Priorität **40**
  (`AbstractUserRoleMappingMapper.PRIORITY_ROLE_MAPPER`).
- ⇒ Mapper 2 überschreibt `getPriority()` mit **100**, läuft damit nach allen Rollen-Mappern und
  sieht das fertig aufgelöste `resource_access`.
- Zusätzlich (wie bei Mapper 1/altem Mapper 2): `transformAccessToken` selbst überschreiben, weil
  die Basisklasse `setClaim`/die Transformation nur bei gesetztem Config-Flag `access.token.claim`
  ausführt (`AbstractOIDCProtocolMapper.java`).

## Empfohlene Mapper-Logik (ein Codepfad, fail-closed fällt heraus)

```text
transformAccessToken(token, ...):                    // Prioritaet 100
  scope = leseScopeAusAssertion()                    // Bruecke A; null wenn fehlt/undekodierbar
  gebucht = { s ohne "service:"-Praefix | s in scope.split(whitespace), s startsWith "service:" }

  fuer jeden clientId in token.resource_access.keys():
    clientId nicht in gebucht -> Eintrag aus resource_access entfernen
```

- **Client-weiser Filter, keine Rollen-Schnittmenge:** anders als beim alten `tenant-restriction-mapper`
  gibt es keine Rollen-Quelle zum Schneiden — die Buchung ist boolesch je (Mandant, Dienst), und
  innerhalb eines Dienstes gelten für alle Mandanten dieselben Rollen. Der Mapper entscheidet nur
  „Dienst gebucht ja/nein", nicht „welche Rolle".
- **Fail-closed ohne Sonderfall:** fehlt der `scope`-Claim, fehlt die Assertion, oder bucht sie den
  Dienst nicht → `gebucht` enthält den Client nicht → der Eintrag verschwindet aus
  `resource_access`. Kein `if`-Zweig extra für den Fehlerfall nötig.

## Registrierung — wo greift Mapper 2 für token3?

Wie beim Vorgänger: ein eigener Client Scope (`booking-restriction`) mit Mapper 2, als
**Default-Scope** an `backend-requester`. So läuft der Mapper bei **jedem** token3 — auch
fail-closed, wenn gar kein Dienst-Scope aktiv ist.

## Offene Feinheiten (in kctest gegenprüfen, unkritisch fürs Labor)

- **`account`/Fremd-Clients in `resource_access`:** Im Labor-Flow (`fullScopeAllowed=false`, nur
  der angeforderte Dienst-Scope aktiv) steht dort ohnehin nur der Dienst-Client. Ein etwaiger
  `account`-Eintrag würde ebenfalls entfernt, da er nicht unter `service:*` gebucht sein kann — im
  Labor irrelevant, als Annahme notiert.
- **Mehrere gebuchte Dienste gleichzeitig:** Da `scope=` in Schritt 3 ohnehin nur einen Dienst
  gleichzeitig aktiviert (`fullScopeAllowed=false`), ist `resource_access` vor dem Mapper-Lauf
  praktisch immer einelementig — der Mapper filtert trotzdem generisch über alle Einträge.

## Belegte Fundstellen

| Fundstelle | Aussage |
|---|---|
| `OAuth2GrantTypeBase.java:265-275` | `getRequestedScopes()` liest `scope` nur aus dem Request-Parameter, prüft nur gegen die Scopes des anfragenden Clients — **keine** Schnittmenge mit der Assertion |
| `JWTAuthorizationGrantType.java:29` | Grant liest `assertion` aus `formParams` |
| `JWTAuthorizationGrantType.java:37-40` | Assertion-Dekodierung via `JWSInput`/`JsonWebToken` |
| `AccessToken.java:162-163` | `scope` ist ein deklariertes Feld **nur** von `AccessToken`, nicht von `JsonWebToken` |
| `JsonWebToken.java:275-283` | `@JsonAnySetter`/`@JsonAnyGetter` — unbekannte Properties (u.a. `scope` beim Dekodieren als `JsonWebToken`) landen in `otherClaims` |
| `TokenManager.java` | Access-Token-Mapper laufen sortiert, aufsteigend nach Priorität |
| `AbstractUserRoleMappingMapper.java` | Rollen-Mapper bei Priorität 40 |
| `AbstractOIDCProtocolMapper.java` | `transformAccessToken` nur bei `access.token.claim` (Basisklasse) |
| `AccessToken.java` | `resource_access`/`Access`-API (`getResourceAccess()`, Entfernen von Einträgen) |

---

Recherchiert gegen Keycloak 26.7.0. Grundlage für `booking-restriction-mapper/` (Mapper 2) und die
Anpassungen an `setup-realms.sh`/`check-setup.sh`. Ersetzt die frühere, gruppenbasierte Recherche
zum inzwischen gelöschten `tenant-restriction-mapper`.
