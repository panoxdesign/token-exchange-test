# Review: Sinnhaftigkeit, Praxistauglichkeit und Sicherheit des Ansatzes

Bewertung des Ist-Stands (main `c1cc4ce`, Keycloak 26.7.2): dreistufige Kette
`token_sp → token1 → token2 → token3` mit den drei Custom-Mappern RTM, Selfservice-Exchange-Gate
und Booking-Restriction. Grundlage sind `SETUP.md`, `docs/Interner-Token-Exchange.md`,
`docs/Mapper2-*.md`, `setup-realms.sh`, `check-setup.sh`, der Java-Code der drei Mapper sowie ein
Abgleich der sicherheitskritischen Annahmen mit dem Keycloak-Quellcode (Tag 26.7.2).

## 0. Umsetzungsstand

| Punkt | Stand |
|---|---|
| L1 | **umgesetzt.** RTM und Gate prüfen `grant_type`, Signatur (`session.tokens().decode`) und `domain ∈ aud` selbst; Mapper 2 prüft `grant_type`. `check-setup.sh` meldet Scope-Drift und zusätzliche Grants. Gegenbeweis gemessen: Scope am Portal plus gefälschter `subject_token` im Password Grant ergibt weder Backend-`aud` noch `tenant`. |
| L2 | offen (nur Doku-Präzisierung, siehe Abschnitt 4.2). |
| L3 | **umgesetzt** (Doku: `tenant` als mandantenbindender Claim). |
| L4 | **umgesetzt** (Code: `domain ∈ aud` in Gate und RTM; Doku korrigiert). |
| L5 | offen, erst bei zweitem Backend-Requester relevant. |
| L6 | **umgesetzt.** `test-chain.sh` mit 12 Fällen, alle bestanden (Keycloak 26.7.2). |
| L7 | offen, Lab-Charakter. |

## 1. Kurzfazit

| Frage | Antwort |
|---|---|
| Ist der Ansatz technisch korrekt? | **Ja.** Die Kette entspricht dem von Keycloak dokumentierten Identity Chaining (Token Exchange V2 + JWT Authorization Grant). Die drei Mapper tun, was die Doku behauptet; die Messungen sind nachvollziehbar. |
| Ist er praxistauglich? | **Bedingt.** Als Lernlabor sehr gut. Für Produktion tragen drei Punkte Kosten: Custom-SPI-JARs auf undokumentierten Internas, ein Backend-User pro Frontend-User (Provisionierung), und vier Token-Requests pro Kette ohne Refresh. |
| Kann ein Dritter ihn ausnutzen? | **Ohne ein Client-Secret: nein.** Jeder Schritt braucht ein Secret; nichts ist öffentlich aufrufbar. Die relevanten Risiken liegen in Konfigurationsdrift und in dem, was ein kompromittiertes Gateway darf. |
| Gibt es Lücken? | **Ja, fünf nennenswerte plus eine bewusste Vertrauensgrenze.** Eine Lücke ist latent hoch (Mapper prüfen weder Signatur noch Grant-Kontext), keine ist im Ist-Stand ausnutzbar. Die Buchung setzt das Gateway durch, nicht Keycloak (L2); das ist gewollt und muss nur so benannt werden. Details in Abschnitt 4. |

## 2. Was verifiziert korrekt ist

Die folgenden Aussagen der Doku habe ich gegen den Keycloak-Quellcode 26.7.2 geprüft:

| Aussage in der Doku | Befund |
|---|---|
| Der Exchange validiert den subject_token, bevor Mapper laufen (`SETUP.md`, „Vorbehalt") | **Bestätigt.** `StandardTokenExchangeProvider.tokenExchange()` ruft zu Beginn `AuthenticationManager.verifyIdentityToken(…)` (Signatur, aktiv, Session) auf; der Token-Bau mit Mapper-Lauf kommt erst danach über `tokenManager.responseBuilder()`. |
| Der jwt-bearer-Grant validiert die Assertion (iss, Signatur, aud, exp, jti) vor dem Token-Bau | **Bestätigt.** `JWTAuthorizationGrantType`: `validateIssuer`, `validateSignatureAlgorithm`, `validateAuthorizationGrantAssertion`, `validateTokenActive`, `validateTokenAudience`, dann `createTokenResponseBuilder`. |
| `scope` beim jwt-bearer kommt nur aus dem Request-Parameter, keine Schnittmenge mit der Assertion | **Bestätigt** (`getRequestedScopes()`). Mapper 2 ist also nötig. |
| `restrictRequestedAudience` läuft **nach** allen Mappern und filtert `aud` und `resource_access` per `retainAll` | **Bestätigt** in `TokenManager.transformAccessToken`. Der Gate-Mechanismus funktioniert genau so. |
| Nur Access Tokens sind als subject_token erlaubt | **Bestätigt.** Andere `subject_token_type`-Werte werden abgewiesen. Ein ID- oder Refresh-Token kann also nicht als token1 untergeschoben werden. |
| Der Ziel-User wird ausschließlich über `sub` + Federated Identity gefunden, kein Parameter beeinflusst ihn | **Bestätigt** (`lookupUserByFederatedIdentity`). |
| Assertions gelten einmal | Konfiguriert (`jwtAuthorizationGrantAssertionReuseAllowed=false`) und gemessen. |

Weitere richtige Entscheidungen: `fullScopeAllowed=false` an beiden Requestern, Domain-Scopes als
Optional, keine Service Accounts an reinen Zielen, `validateSignature=true` mit JWKS, Issuer per
`KC_HOSTNAME` fixiert, Fail-closed in allen drei Mappern, `check-setup.sh` prüft die tragenden
Schalter einzeln.

## 3. Praxistauglichkeit

### Was für den Ansatz spricht

- **Keine Rollen wandern über die Realm-Grenze.** Das Backend entscheidet allein anhand seines
  Users; die Assertion transportiert nur Identität plus zwei Behauptungen (`tenant`, `service:*`).
- **Einmal-Assertion statt Bearer-Weitergabe.** token2 ist nur für Schritt 03 brauchbar und genau
  einmal. Ein abgefangenes token2 nützt ohne Backend-Requester-Secret nichts.
- **Mandantenabhängiger Gate.** Die Frage „darf dieser User *aus diesem Mandanten heraus* zum
  Backend" ist mit Bordmitteln nicht ausdrückbar; der Gate-Mapper löst das sauber und fail-closed.
- **Reproduzierbar und prüfbar.** Setup-Skript, Check-Skript und Bruno-Collection machen den
  Zustand jederzeit nachvollziehbar.

### Was Kosten verursacht

| Kostenpunkt | Auswirkung | Einordnung |
|---|---|---|
| Drei Custom-SPI-JARs, die undokumentierte Internas nutzen (Form-Parameter im Mapper lesen, `transformAccessToken` überschreiben, Mapper-Prioritäten, Validierung-vor-Mapper) | Jedes Keycloak-Upgrade kann den Ansatz still brechen, und zwar in Richtung „Exchange schlägt fehl" (fail-closed), nicht in Richtung „zu viel Zugriff". | Tragbar, wenn ein automatisierter Regressionstest die Gegenproben aus `SETUP.md` bei jedem Upgrade ausführt. Liegt seit L6 als `test-chain.sh` vor. |
| Ein Backend-User pro Frontend-User, Federated Identity muss vorab existieren | Der jwt-bearer-Grant provisioniert nicht. Ohne Sync-Job oder Erst-Login-Flow scheitert jeder neue User mit `User not found`. | Größter Betriebsaufwand in Produktion. Muss vor einem Rollout gelöst sein. |
| Rollen im Backend sind pro User, nicht pro Mandant | „reader in Mandant A, writer in Mandant B" ist nicht abbildbar. Die Spezifikation nennt das ausdrücklich als Annahme. | Design-Entscheidung, muss zur Fachlichkeit passen. Falls nicht: Mandanten-Gruppen im Backend (die gerade abgeschafft wurden) oder Rollen-Schnitt im Gate. |
| Vier Token-Requests pro Kette, token3 ohne Refresh Token, Assertion einmalig | Ein BFF muss token3 pro (User, Mandant, Dienst) cachen und bei Ablauf die Kette ab Schritt 02 neu laufen lassen. Das Backend erzeugt pro token3 eine transiente Session. | Handhabbar, aber die Latenz und Last der Token-Endpoints gehören in die Kapazitätsplanung. |
| Buchung liegt in CSV/DB, die nur das Gateway/BFF liest | Keycloak setzt die Buchung nicht durch, es setzt nur durch, dass das Backend nichts über das hinaus freigibt, was das Gateway behauptet. | Bewusste Trennung: Geschäftsdaten bleiben außerhalb von Keycloak. Das Gateway ist damit Enforcement Point und muss so betrieben werden, siehe L2. |
| Password Grant (ROPC) als Einstieg | In OAuth 2.1 gestrichen; für ein Lab in Ordnung. | In Produktion Authorization Code + PKCE; die Kette ab token_sp ändert sich dadurch nicht. |

## 4. Sicherheitsanalyse

### 4.1 Angreifermodell: was ein Dritter braucht

Alle Endpunkte sind Token-Endpoints, die Client-Authentifizierung verlangen. Ohne ein Secret gibt es
keinen Einstieg. Was der Verlust eines einzelnen Geheimnisses ergibt:

| Verloren | Was der Angreifer damit erreicht | Was ihn stoppt |
|---|---|---|
| User-Passwort | nichts ohne SP-Secret | SP ist confidential |
| SP-Secret + User-Passwort | token_sp (aud gateway) | kein Exchange ohne Gateway-Secret; token_sp ohne `domain`-Claim scheitert am Gate |
| Gateway-Secret allein | nichts, es fehlt ein subject_token | Exchange braucht ein gültiges, signiertes token_sp/token1 |
| Gateway-Secret + ein gültiges token_sp/token1 | token2 für jeden Mandanten, in dem der User `selfservice` hat, mit **beliebiger** Buchung (`service:*` frei wählbar) | nur noch die Rollen des Backend-Users; die CSV greift nicht |
| Backend-Requester-Secret | nichts ohne eine frische Assertion | Assertion ist einmalig, kurzlebig und vom Frontend signiert |
| Backend-Requester-Secret + abgefangenes token2 | genau ein token3, verengt auf die gebuchten Dienste | Einmaligkeit, `exp` ≤ 600 s |
| Frontend-Signaturschlüssel | alles (beliebige Assertions) | keine Gegenmaßnahme in diesem Design, Schlüsselschutz ist Voraussetzung |

Fazit: Das Design ist gestaffelt. Der wertvollste Einzelpunkt ist das **Gateway** (Secret plus
Zugriff auf User-Tokens), weil es Requester beider Exchanges ist und die Buchung frei behauptet.

### 4.2 Lücken, Schweregrad, Behebung

Schweregrade: **Hoch** = Mandanten- oder Dienstgrenze überschreitbar; **Mittel** = Umgehung
einer fachlichen Regel oder erhebliches Betriebsrisiko; **Niedrig** = Robustheit, Doku, Härtung.

#### L1 — Mapper dekodieren Tokens ohne Signatur- und ohne Kontextprüfung

**Schweregrad: Hoch (latent). Im Ist-Stand nicht ausnutzbar.**

Alle drei Mapper lesen `subject_token` bzw. `assertion` roh aus den Form-Parametern und dekodieren
mit `JWSInput.readJsonContent` — ohne Signaturprüfung und ohne zu prüfen, in welchem Grant sie
gerade laufen. Das ist nur deshalb sicher, weil

- `access-backend` ausschließlich an `gateway` hängt und `gateway` **nur** Token Exchange kann
  (Standard Flow, Direct Access Grants, Service Accounts, Implicit sind aus), und
- `booking-restriction` an `backend-requester` hängt, der **nur** den jwt-bearer-Grant kann.

Das ist eine reine Konfigurationsannahme, die kein Code erzwingt. Sobald ein Admin z. B.
`access-backend` an `self-service-portal` hängt oder am `gateway` Direct Access Grants einschaltet,
kann ein Aufrufer mit gültigen User-Credentials einen **selbstgebauten**, unsignierten
`subject_token`-Parameter mitschicken (`{"domain":"domain-1234","resource_access":{"domain-1234":
{"roles":["selfservice"]}}}`). Der Gate-Mapper setzt dann die Backend-`aud`, der RTM-Mapper den
gefälschten `tenant`, und Keycloak signiert das Ergebnis mit dem Frontend-Schlüssel: eine gültige
Assertion für einen Mandanten, in dem der User gar nicht `selfservice` hat, mit beliebigem
`tenant`-Claim. Beim Booking-Restriction-Mapper ist derselbe Fehler harmloser (er kann nur
verengen), aber das Muster ist identisch.

`check-setup.sh` prüft heute weder, dass `access-backend` an keinem anderen Client hängt, noch
dass `gateway`/`backend-requester` keine weiteren Grants können.

**Behebung (in dieser Reihenfolge, alle günstig):**

1. **Grant-Kontext prüfen.** Der Mapper liest `grant_type` aus denselben Form-Parametern und tut
   nichts, wenn er nicht `urn:ietf:params:oauth:grant-type:token-exchange` (bzw. `jwt-bearer`)
   ist. Zusätzlich lässt sich im Exchange-Fall die Client-Session-Note
   `Constants.TOKEN_EXCHANGE_SUBJECT_CLIENT + <azp>` (setzt `StandardTokenExchangeProvider`)
   als Beleg nutzen, dass wirklich ein Exchange läuft.
2. **Signatur selbst prüfen.** Statt `JWSInput` den Realm-eigenen Verifier nutzen:
   `session.tokens().decode(subjectToken, AccessToken.class)` liefert `null` bei ungültiger
   Signatur. Der Schlüssel ist lokal, die Kosten sind eine Signaturprüfung pro Exchange. Damit
   entfällt die Abhängigkeit davon, dass die Validierung „schon vorher" passiert ist (der
   „Vorbehalt" in `SETUP.md` wird gegenstandslos). Für Mapper 2 im Backend geht das nicht (fremder
   Aussteller); dort reicht Punkt 1, weil der Grant selbst verifiziert.
3. **Konfigurationsdrift sichtbar machen.** `check-setup.sh` ergänzen: `access-backend` hängt an
   genau einem Client; `gateway` und `backend-requester` haben keine weiteren Grants aktiv;
   `booking-restriction` ist an keinem Client außer `backend-requester`.

#### L2 — Die Buchung setzt das Gateway durch, nicht Keycloak

**Schweregrad: Niedrig (bewusste Vertrauensgrenze, Doku-Präzisierung).**

`service:*`-Scopes sind Optional-Scopes am `gateway`; Keycloak prüft nur, dass sie dem Gateway
zugewiesen sind, nicht, ob der Mandant aus token1 den Dienst gebucht hat. Die Buchungsquelle (heute
CSV, perspektivisch eine DB) liest allein das Gateway/BFF. Das ist eine **bewusste Entscheidung**:
Buchungsstände sind Geschäftsdaten, Keycloak ist ein Token-Aussteller und soll sie nicht halten.
Sie ist konsistent mit der Abschaffung der Mandanten-Gruppen im Backend — jede Kopie der Buchung
in Keycloak (Gruppen, Client-Attribute) brächte das Sync-Problem zurück. Auch eine Laufzeitabfrage
der DB aus einem Mapper heraus ist nicht zu empfehlen: der Token-Endpoint hinge dann an der
Verfügbarkeit und Latenz der Buchungs-DB, bei drei Exchanges pro Kette multipliziert.

Die Konsequenz muss aber klar benannt sein: **Das Gateway ist der Policy Enforcement Point für
die Buchung.** Keycloak setzt die Buchung nicht durch, es transportiert und signiert die
Entscheidung des Gateways. Mapper 2 im Backend erzwingt „nicht mehr als das Gateway behauptet",
nicht „die Buchung". Ein Fehler oder eine Kompromittierung im Gateway gibt jedem Mandanten mit
`selfservice` jeden Dienst; Keycloak fängt das nicht auf. Die Formulierung „Mapper 2 erzwingt die
Buchung" in `Mapper2-Spezifikation.md` überzeichnet deshalb.

Mapper 2 behält trotzdem seinen Wert: Die Buchungsentscheidung liegt signiert in der Assertion,
die Backend-Dienste brauchen keinen Zugriff auf die Buchungs-DB, und token3 dokumentiert
nachweisbar, was das Gateway behauptet hat.

**Behebung (Doku und Betriebsanforderungen, kein Keycloak-Umbau):**

1. In `Mapper2-Spezifikation.md`, `SETUP.md` und `booking-restriction-mapper/README.md` die
   Rollenverteilung präzisieren: Gateway entscheidet die Buchung anhand der DB, Keycloak signiert
   und das Backend verengt auf das Behauptete.
2. Anforderungen an das Gateway als Enforcement Point festhalten: rein serverseitig, Secret
   geschützt, die Scope-Wahl stammt ausschließlich aus der Buchungsquelle und nie aus
   User-Input, jede Buchungsentscheidung wird mit Mandant, User und Dienst geloggt.
3. Optional als Defense in Depth, wenn die DB steht: Backend-Dienste können die Buchung für den
   `tenant` aus token3 zusätzlich gegen die DB prüfen. Das ist ein Zusatz, kein Ersatz für die
   signierte Assertion.

#### L3 — `tenant` ist kein „reiner Audit-Claim"

**Schweregrad: Mittel (Einordnung/Doku, mit Folgen für künftige Änderungen).**

Das Backend kennt keine Mandanten, und der Backend-User trägt für alle Mandanten dieselben Rollen.
Jeder Backend-Dienst, der mandantengetrennte Daten hält, **muss** `token3.tenant` zur
Datentrennung heranziehen — es gibt sonst keinen Mandanten-Hinweis im Token. Damit ist `tenant` der
autorisierungsrelevanteste Claim der ganzen Kette, nicht ein Audit-Claim. Seine Integrität ist heute
in Ordnung (Ableitung aus `token1.domain`, das an `resource_access[domain]` gebunden ist), aber
die Doku-Einordnung führt dazu, dass eine spätere Änderung (z. B. „Parameter wieder zulassen, ist
ja nur Audit") nicht als Sicherheitsänderung erkannt wird.

**Behebung:** In `SETUP.md`, `Mapper2-Spezifikation.md` und den Mapper-READMEs `tenant` als
**mandantenbindenden Claim** führen, dessen Integrität von RTM + Gate abhängt; die Anforderung an
Backend-Dienste („Daten nach `tenant` filtern, Token ohne `tenant` ablehnen") explizit notieren.
Ergänzend im Gate-Mapper prüfen, dass `token1.domain` in `token1.aud` steht (siehe L4).

#### L4 — `domain`-Claim ist nicht über Rollen gated, und mehrdeutig bei zwei Domain-Scopes

**Schweregrad: Niedrig (Robustheit + Doku-Korrektheit).**

`SETUP.md` sagt, `domain` in token1 sei „über die echten Rollen des Users gated". Das stimmt nicht:
Der Hardcoded-Claim-Mapper feuert, sobald der Scope aktiv ist, unabhängig von Rollen. Ohne
`audience=` erhält ein User ohne jede Rolle auf `domain-1234` ein token1 mit
`domain=domain-1234`, leerer `aud` und ohne `resource_access` (Gegenprobe G3 zeigt den Mechanismus).
Sicher bleibt die Kette nur, weil der **Gate-Mapper** `resource_access[domain]` prüft, nicht wegen
des `domain`-Claims selbst. Zweitens: Werden beide Domain-Scopes gleichzeitig angefordert
(`scope=domain-5678 domain-1234`), schreiben zwei Mapper denselben Claim `domain`; welcher gewinnt,
hängt an der Mapper-Reihenfolge. Mit `audience=domain-5678` kann dann ein token1 mit
`domain=domain-1234`, aber `resource_access` nur für `domain-5678` entstehen. Keine Eskalation
(der Gate schlägt fail-closed zu), aber ein schwer diagnostizierbarer Fehler.

**Behebung:** Gate und RTM prüfen zusätzlich `domain ∈ aud` von token1 und brechen sonst
fail-closed ab. Doku-Satz korrigieren: gated ist nicht `domain`, gated ist die Kombination
`domain` + `resource_access[domain]`, und zwar erst im Gate.

#### L5 — Realm-weite Vertrauensbeziehung im Backend

**Schweregrad: Niedrig (in der Doku bereits benannt).**

Jeder Backend-Client mit JWT Authorization Grant und `frontend` in der Allow-Liste löst jede
Assertion ein und wählt `scope=` selbst. Der jwt-bearer-Grant prüft `azp` der Assertion nicht
gegen die `clientId` des IdP (im Quellcode nicht vorhanden). Mit nur einem Requester ist das
unkritisch; mit mehreren wird der Kreis der Einlöser zur Konfigurationsfrage.

**Behebung:** Client Policy mit `jwt-claim-enforcer` (z. B. `azp == gateway`), oder pro Requester
eine eigene Audience-Client-ID im Frontend, so dass `aud` der Assertion den Einlöser festlegt.

#### L6 — Kein automatisierter Regressionstest für die Sicherheitseigenschaften

**Schweregrad: Niedrig heute, Mittel bei jedem Upgrade.**

Die Gegenproben (Negativfall `domain-1234`, Fail-closed Fall C, `requested_tenant`-Spoofing,
Token-Reuse, token1 als Assertion) sind nur in `SETUP.md` beschrieben und in Bruno klickbar.
`check-setup.sh` prüft Konfiguration, nicht Verhalten. Genau die Eigenschaften, die an
undokumentierten Internas hängen (L1, Mapper-Reihenfolge), sind damit ungetestet.

**Behebung:** `test-chain.sh` (rein lesend wie `check-setup.sh`, Exit 1 bei Abweichung), das die
Positivkette und alle Gegenproben durchläuft und die erwarteten Claims/Fehlercodes assertet. Bei
jedem Image-Bump ausführen.

#### L7 — Lab-Hygiene (bekannt, nur der Vollständigkeit halber)

**Schweregrad: Niedrig im Lab, Hoch bei versehentlicher Übernahme.**

Klartext-Secrets im Skript und in Bruno, `admin`/`admin`, HTTP statt TLS (auch der JWKS-Abruf
zwischen den Containern), `start-dev`, ROPC. Alles dokumentiert und gewollt. Für einen produktiven
Ableger: Secrets aus einer Secret-Quelle in die Skripte injizieren, `start --optimized` mit TLS,
`KC_HOSTNAME_STRICT`, Auth Code + PKCE am Portal, Realm-Keys rotieren, JWKS-Cache am IdP prüfen.

### 4.3 Bewusst geprüft und in Ordnung

- **token_sp direkt als subject_token für Schritt 02** (05a überspringen): scheitert, token_sp hat
  keinen `domain`-Claim, Gate setzt keine `aud`.
- **`scope=access-backend domain-1234` in Schritt 02 mit token1 für domain-5678:** token2 trägt
  dann `domain=domain-1234`, aber `tenant=domain-5678` (aus token1); token3 entsteht ohnehin aus
  dem Backend-User. Keine Eskalation.
- **Fremde Strings im `scope`-Claim:** Keycloak weist beim Exchange nicht zugewiesene Scopes mit
  `invalid_scope` ab; in den `scope`-Claim gelangen nur echte Client-Scope-Namen. Mapper 2 kann
  nicht mit Nutzereingaben gefüttert werden.
- **Default-Rollen des Realms:** mit `fullScopeAllowed=false` und Scopes ohne Role Scope Mappings
  landen sie nicht in token1/token3 (gemessen, `resource_access` in token_sp ist `null`).
- **Refresh-Token beim Exchange:** standardmäßig aus. Wäre er an, liefen RTM/Gate beim Refresh
  ohne `subject_token` und token2 verlöre `aud` und `tenant` — fail-closed, aber überraschend.
  Nicht einschalten, oder in L1 mitdenken.

## 5. Unsicherheiten und Annahmen

| Annahme | Status |
|---|---|
| Validierung des subject_token vor dem Mapper-Lauf | im Quellcode 26.7.2 bestätigt, bleibt undokumentiertes Verhalten; L1 Punkt 2 macht die Kette davon unabhängig |
| Form-Parameter sind im Mapper über `getDecodedFormParameters()` erreichbar | gemessen, undokumentiert; bei Upgrade prüfen (L6) |
| Mapper-Priorität 100 läuft nach den Rollen-Mappern (40) | im Quellcode belegt (`ProtocolMapperUtils`), stabil seit mehreren Major-Versionen |
| `AudienceResolveProtocolMapper` erzeugt `aud` nur aus aufgelösten Rollen | belegt, gemessen (G1/G3/G7) |
| Backend-Rollen pro User reichen fachlich aus (kein Rollen-Split je Mandant) | fachliche Annahme, nicht technisch prüfbar |
| Buchungsquelle bleibt außerhalb von Keycloak (CSV, später DB) | Entscheidung, keine Zwischenlösung; das Gateway ist Enforcement Point, Anforderungen in L2 |

## 6. Empfohlene Reihenfolge

1. **L1** Grant-Kontext- und Signaturprüfung in den Mappern, plus die drei Zusatzchecks in
   `check-setup.sh`. Kleiner Eingriff, schließt die einzige Lücke mit Eskalationspotenzial.
2. **L6** `test-chain.sh` mit allen Gegenproben, damit L1 und die Internas-Abhängigkeiten
   dauerhaft überwacht sind.
3. **L3 + L4** Doku-Korrekturen (`tenant` als bindender Claim, `domain`-Gating präzisieren) und
   die `domain ∈ aud`-Prüfung im Gate.
4. **L2** Doku-Präzisierung: Gateway als Enforcement Point der Buchung benennen, Anforderungen
   an sein Betriebsumfeld festhalten. Kein Keycloak-Umbau.
5. **L5** nur, sobald ein zweiter Backend-Requester dazukommt.
6. Vor einem produktiven Ableger: User-Provisionierung ins Backend klären (Abschnitt 3) und L7.
