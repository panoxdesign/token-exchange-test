# Bekannte Keycloak Fallstricke

Diese Punkte haben schon Zeit gekostet und sind in `SETUP.md` ausführlich beschrieben:

- **Attributnamen rät man nicht.** Die relevanten:

  ```
  standard.token.exchange.enabled           Client (Frontend), Token Exchange
  oauth2.jwt.authorization.grant.enabled    Client (Backend), JWT Grant
  oauth2.jwt.authorization.grant.idp        Client (Backend), Allow-Liste
  jwtAuthorizationGrantEnabled              IdP-Config
  fullScopeAllowed                          Top-Level-Feld, KEIN Attribut
  ```

- **`Full scope allowed` muss am Requester-Client `Off` sein.** Auf `On` (Keycloak-Default) landen
  alle Rollen im Token, egal welcher Scope angefordert wurde. Daran hängt die gesamte Trennung der
  beiden Ziel-Dienste.
- **`issuer` und `jwksUrl` des IdP nennen absichtlich verschiedene Hosts** — `localhost:8080` im
  Token, `frontend-keycloak:8080` für den JWKS-Abruf aus dem Backend-Container. Deshalb ist der
  Discovery-Endpoint im Admin-UI unbenutzbar, und alle Requests müssen über `localhost:8080`/`:8181`
  laufen.
- **Der Ziel-User im Backend ist `lab-user`, kein Service Account.** Die Falle steckt im Lookup:
  `GET /users?username=…&exact=true` liefert auch Service Accounts mit, deshalb landet die Federated
  Identity sonst leicht am Service Account eines Backend-Clients (falsche Rollen). `setup-realms.sh`
  bricht ab, wenn der gewählte Ziel-User ein Service Account ist.
- **Jede Assertion gilt genau einmal** (`Token reuse detected`). Für den zweiten Dienst token2 neu
  holen.
- Das Admin-Token des `master`-Realms lebt **60 Sekunden**.
- Die aussagekräftige Fehlermeldung steht im Server-Log, nicht in der HTTP-Antwort:
  `docker compose logs -f backend-keycloak`.
- **Ein mandanten-abhängiger Gate über eine User-Rolle braucht einen Custom-Mapper — ein
  natives Role Scope Mapping reicht nicht.** Naheliegend wäre, den externen Exchange über eine
  Rolle an einem Ziel-Client zu gaten (Role Scope Mapping, ausgewertet vom eingebauten
  `AudienceResolveProtocolMapper`). Das gated aber nur **statisch** — der Mapper leitet `aud` aus
  den Rollenzuweisungen des Users ab, unabhängig davon, für welchen Mandanten das `subject_token`
  gerade ausgestellt wurde. Er kann den „aktiven Mandanten" gar nicht sehen: der steckt
  ausschließlich im **Inhalt** des `subject_token` (hier: `domain`-Claim plus
  `resource_access.<domain>.roles`), und kein natives Mapping liest diesen Inhalt aus. Nur ein
  Custom-Mapper, der das `subject_token` selbst dekodiert (wie `RequestedTenantMapper`), kann
  „hat der User Rolle X **im gerade aktiven Mandanten**" prüfen und danach `aud` setzen oder
  fail-closed leer lassen. Siehe `selfservice-exchange-gate/README.md` und `SETUP.md`, Abschnitt
  „Ohne die Rolle `selfservice` im aktiven Mandanten: der externe Exchange bleibt zu".
