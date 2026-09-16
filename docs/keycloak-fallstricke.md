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
- **Standard Token Exchange V2 kennt keinen Gate über eine User-Rolle.** Es gibt keine Einstellung
  „nur User mit Rolle X dürfen tauschen" — Protocol Mapper laufen scope-, nicht rollengesteuert,
  und eine Role-Scope-Mapping-Zuweisung allein schaltet nichts ab. Der native Weg führt über `aud`:
  der eingebaute `AudienceResolveProtocolMapper` trägt einen Client nur dann in `aud` ein, wenn der
  User dort eine **gescopte** Rolle hat (`fullScopeAllowed:false` vorausgesetzt). Eine Rolle am
  Ziel-Client plus Role Scope Mapping auf den anfordernden Scope wird damit zum User-Rollen-Gate —
  ohne die Rolle bleibt `aud` leer und der Exchange schlägt mit `Requested audience not available`
  fehl. Siehe `SETUP.md`, Abschnitt „Ohne die Rolle `selfservice`: der externe Exchange bleibt zu".
