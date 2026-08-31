# Review: Loesungsansaetze.md

Prüfung der fünf Ansätze auf Stimmigkeit. Alle technischen Aussagen sind gegen Keycloak 26.7.2
gemessen; das Protokoll steht unten. Zeilennummern beziehen sich auf den Stand vom 30.08.2026.

## Kurzurteil

Das Dokument ist als Entscheidungsgrundlage tragfähig: Die Ansätze sind real umsetzbar, die
Pro/Contra-Listen ehrlich, die offenen Punkte benannt statt kaschiert. Drei Dinge stehen einer
Entscheidung im Weg:

1. Die Mandanten-Bindung ist nur zur Hälfte geklärt. Das User-Token trägt einen Claim je Mandant —
   alle verfügbaren plus den aktuell gültigen. Das beantwortet die Broker-Seite; offen bleibt die
   Strecke bis zum Microservice.
2. Zwei technische Annahmen halten nicht: die Begründung, warum Token-Exchange-Chaining ausscheidet,
   und der Versions-Vorbehalt beim Down-Scoping. Beides ist inzwischen gemessen.
3. Die fünf Ansätze sind keine Alternativen, sondern drei unabhängige Entscheidungen.

Zählung: 1 Blocker, 1 offene Frage, 4 Korrekturen, 2 erledigt, 5 Lücken.

---

## Im Labor nachgemessen

Isolierter Compose-Stack aus diesem Repo, provisioniert mit `setup-realms.sh`, danach mit `down -v`
abgeräumt.

### Messung 1 — Down-Scoping funktioniert beim Client-Credentials-Flow

Ein Client mit allen Rollen beider Dienste (= Super-Client aus Ansatz 4), **Full scope allowed Off**,
beide Dienst-Scopes als *Optional*. Angefordert wurde jeweils nur der `scope`-Parameter:

| `scope=` | `aud` | `resource_access` |
|---|---|---|
| (nicht gesetzt) | — | — |
| `e-rechnung` | `e-rechnung` | `e-rechnung: reader, writer` |
| `fahrtkostenerstattung` | `fahrtkostenerstattung` | `fahrtkostenerstattung: reader, approver` |
| beide | beide | beide |
| `gibtsnicht` | HTTP 400 · `invalid_scope: Invalid scopes: gibtsnicht` | — |

Die Einengung pro Request trägt also. Keine Versionsfrage, sondern drei Schalter: Client Scopes als
*Optional*, Audience-Mapper und Role Scope Mappings je Scope, **Full scope allowed = Off**.

### Messung 2 — Granularität bis auf die einzelne Rolle

Das Diagramm in Ansatz 4 zeigt `scope=Z:write`. Das geht, braucht aber ein Modell: einen Client Scope
je Rollen-Bündel, nicht je Dienst. Angelegt als `e-rechnung-read` mit Role Scope Mapping nur auf
`reader`:

| `scope=` | `aud` | `resource_access` |
|---|---|---|
| `e-rechnung-read` | `e-rechnung` | `e-rechnung: reader` |
| `e-rechnung` | `e-rechnung` | `e-rechnung: reader, writer` |

### Messung 3 — Signierter Mandanten-Claim, aber statisch pro Account

Attribut `tenant=mandant-Y` am Service-Account-User plus User-Attribute-Mapper auf dem Client Scope
ergibt `"tenant": "mandant-Y"` im Client-Credentials-Token — und nur, wenn der Scope angefordert wird.
Der Claim hängt am *Account*, nicht am Request: Einen Mandanten pro Request in ein
Client-Credentials-Token zu schreiben, geht mit Bordmitteln nicht.

### Messung 4 — Token-Exchange über zwei Instanzen läuft

Steht in `SETUP.md`: `client_credentials` → Token Exchange (Assertion mit `aud` = Backend-Issuer) →
`jwt-bearer` im Backend. In 26.7 offiziell supported, kein Preview. Damit ist die Begründung in
Zeile 320 widerlegt.

---

## Befunde

### 1 — Erreicht der Mandant den Microservice signiert? · offene Frage · Ansätze 1, 2, 4, 5

Die erste Hälfte ist geklärt: Das User-Token trägt einen Claim je Mandant, mit allen verfügbaren und
dem aktuell gültigen. Der Broker leitet daraus ab, für welchen Mandanten er handelt, signiert.

Die zweite Hälfte bleibt offen. Das Service-Token entsteht über `client_credentials` und weiß vom
User nichts — es sagt „read/write auf Microservice Z", nennt aber keinen Mandanten. Hält Z
Mandantendaten, entscheidet er die Datentrennung anhand eines Headers, den Zeile 13 selbst als nicht
autorisierungsrelevant einstuft.

Drei Auswege: **(a)** Token-Relay bzw. besser ein per Token Exchange zugeschnittenes Identitäts-Token
(siehe `Ansatz-Token-Exchange.md`), **(b)** ein Gateway-signiertes internes JWT, **(c)** Service-Account
pro Mandant mit Mandant als Claim am Account (Ansatz 3, Messung 3).

> **Empfehlung:** Im Dokument festhalten, ob Z überhaupt Mandantendaten hält. Falls ja, den
> Mandanten-Transport ausmodellieren statt ihn als Logging-Nebensache zu führen.

### 2 — Das Service-Token zurück ans SP ist kein Trade-off · Blocker · Zeile 99

Sobald das SP im Browser läuft, ist es ein Defekt: Der User hält dann ein Bearer-Token mit
`write`-Rollen und kann den Microservice über dessen Lebensdauer direkt und beliebig oft aufrufen.
Die Lizenzprüfung des Brokers galt aber für *einen* Request — sie ist damit umgangen, nicht
durchgesetzt.

> **Empfehlung:** Broker oder Gateway proxyen den Aufruf, das Backend-Token verlässt die Serverseite
> nie. Läuft das SP serverseitig, ist der Punkt unkritisch — dann aber genau das hinschreiben.

### 3 — Token-Exchange-Chaining ist richtig verworfen, aber falsch begründet · Korrektur · Zeile 320

Es „bricht" nicht an der Grenze zwischen den zwei Keycloaks. Genau dieser Fall läuft in diesem Repo
(Messung 4). Mit der jetzigen Begründung kippt der Punkt in der Team-Diskussion, sobald jemand das
Gegenbeispiel kennt.

Die belastbaren Gründe sind andere: Der JWT-Grant findet den Ziel-User ausschließlich über eine
bestehende Federated Identity und legt ihn nicht an. Und Chaining beantwortet „wer bin ich?", was
laut Zeile 13 nicht autorisierungsrelevant ist. Ausführlich in `Ansatz-Token-Exchange.md`.

### 4 — Der Versions-Vorbehalt beim Down-Scoping entfällt · erledigt · Zeilen 15, 247, 308

Messung 1 und 2 lösen den offenen Punkt auf. Kein PoC nötig.

Was bleibt, ist ein anderer Punkt, der im Contra fehlt: Down-Scoping ist eine *Selbstbeschränkung des
Aufrufers*, keine Sicherheitsgrenze. Der Broker kann jederzeit den vollen Scope anfordern — die
Sicherheit von Ansatz 4 hängt weiterhin vollständig an der Prüfung davor.

### 5 — „Secure by construction" ist für Ansatz 3 zu stark · Korrektur · Zeilen 195–205

- **Widerruf wirkt erst mit der Token-Lebensdauer.** Abbuchen entfernt die Rolle, ausgestellte Tokens
  bleiben gültig. Ansatz 1 prüft pro Request und ist damit frischer — der behauptete Vorteil dreht
  sich um.
- **„Auf falschen Mandanten schalten ist strukturell ausgeschlossen" stimmt nicht.** Das Risiko
  wandert nur von der Rollen- zur Credential-Wahl: Der Broker muss den richtigen Mandanten-Account
  auswählen, ein Fehler dort hat dieselbe Wirkung.
- **Das ⚠️ zielt auf das falsche Risiko.** 1000 Service-Accounts sind für Keycloak keine nennenswerte
  Last. Teuer sind Provisionierung, 1000 Secrets und die Kopplung des Buchungsprozesses an die
  Admin-API.
- **Ein echter Vorteil fehlt:** Ansatz 3 ist der einzige, der Befund 1 nebenbei löst.

### 6 — Fünf Nummern, drei unabhängige Entscheidungen · Struktur

Wahrheitsquelle (1, 3) · Credential-Modell (2, 3, 4) · Durchsetzungspunkt (Broker, 5). Sichtbar wird
der Bruch in der Spalte „Least Privilege": Für Ansatz 1 ist sie nicht ausfüllbar, „mittel" ist dort
ein Platzhalter.

*(Im Stand vom 30.08. bereits teilweise adressiert durch den Abschnitt „Wie die Ansätze
zusammenspielen".)*

### 7 — Eine Anforderung, die kein Ansatz einlöst · Widerspruch · Zeile 9 vs. 92

Zeile 9 verlangt, dass nur die Rollen des aktiven Mandanten im Token landen. Ausgewertet werden die
User-Rollen aber nirgends: Ansatz 1 hält ausdrücklich fest, dass jeder User des Mandanten alles darf,
was der Mandant gebucht hat. Entweder die Anforderung streichen oder den User-Check im Broker
vorsehen.

### 8 — Der „aktive Mandant" ist im echten Projekt gelöst · erledigt · Zeilen 115, 47

Der Claim im User-Token enthält alle verfügbaren Mandanten und den aktuell gültigen, signiert vom
Frontend-Keycloak. Damit stammt der Mandant nicht aus dem Request, und die Mitgliedschaftsprüfung
fällt implizit mit an: Was nicht in der Liste steht, ist nicht signiert.

Im Dokument steht davon allerdings nichts — der Kontext-Abschnitt erwähnt den Claim nicht, im
Sequenzdiagramm bleibt die Herkunft offen. Für Leser, die das Projekt nicht kennen, fehlt eine der
tragenden Annahmen.

### 9 — Das Gateway existiert bereits · Korrektur · Zeile 290

Contra von Ansatz 5: „Setzt voraus, dass ein Gateway in der Landschaft existiert." Gravitee steht
aber schon im Ablauf von Ansatz 1. Ansatz 5 ist damit keine zusätzliche Infrastruktur, sondern nur
die Frage, ob Token-Beschaffung und Identitäts-Weitergabe im Broker liegen oder ins vorhandene
Gateway wandern.

### 10 — Der Least-Privilege-Gewinn von Ansatz 2 ist kleiner als dargestellt · Lücke

„Ein geleaktes Secret öffnet nur einen Service" gilt gegen ein einzelnes verlorenes Secret. Der
Broker hält aber alle N Secrets — wird er kompromittiert, sind alle weg.

Außerdem fehlt in beiden Ansätzen die Alternative zum Secret: Mit `private_key_jwt` oder mTLS
entfällt der Rotationsaufwand weitgehend — genau der Punkt, der in 2 und 3 im Contra steht.

### 11 — Betriebsthemen fehlen komplett · Lücke

- **Caching.** Im Sequenzdiagramm holt der Broker die JWKS pro Request. Ohne Token- und JWKS-Cache
  wird der Token-Endpoint zum Hot Path — bei Ansatz 3 zusätzlich mit Session-Churn über 1000 Accounts.
- **Token-Lebensdauern und Widerruf.** Bestimmt, wie schnell ein Abbuchen wirkt (Befund 5).
- **Ausfall des Lizenz-Service.** Fail-closed oder fail-open? Der Broker steht synchron im Pfad.
- **Der Validierungs-Kontrakt des Microservice.** Was prüft Z genau — `iss`, `aud`, `exp`, und wo
  stehen die Rollen (`resource_access.<client>` oder Realm-Rollen)? Das ist die eigentliche
  Schnittstelle zu den MS-Teams und steht nirgends.
- **Audit.** Wer hat wann gebucht? Der Lizenz-Service bekommt das geschenkt, Keycloak-Rollenänderungen
  nur über Admin-Events.

### 12 — Fehlender Ansatz: Buchung als Claim aus dem Frontend-Keycloak · Lücke

Der Frontend-Keycloak kennt die Mandanten bereits. Gebuchte Services als Gruppe oder Attribut am
Mandanten modellieren und per Mapper ins User-Token geben (`entitlements: ["e-rechnung"]`). Der Broker
liest den Claim: kein Lizenz-Service, keine zweite Wahrheitsquelle, keine 1000 Backend-Accounts — und
es bleibt „Keycloak-zentrisch", was den organisatorischen Widerstand aus dem Contra von Ansatz 1
adressiert.

Preis: Buchungsänderungen wirken erst beim Token-Refresh, Keycloak wird Zustandsspeicher, keine
Buchungshistorie und keine Vertragsdaten, das Token wächst mit der Zahl der Services. Ist der
Frontend-Keycloak auf 26.x, lohnt ein Blick auf Organizations als Modellierungsprimitiv.

### 13 — Kleinigkeiten · Detail

- Die Diagramme in 3 und 4 zeichnen Service-Account und Super-Client als Knoten, die Tokens
  ausstellen. Aussteller ist immer Keycloak.
- Benennung uneinheitlich: „Backend (Wächter)", „Broker", „BE", „SP" meinen teils dasselbe.
- Ansatz 2: Die Namenskonvention spart die gepflegte Liste im Code, nicht das Anlegen der Accounts.

---

## Bewertung der Ansätze

| Ansatz | Achse | Tragfähig | Aufwand | Urteil |
|---|---|---|---|---|
| **1** Lizenz-Service | Wahrheitsquelle | ja | mittel | Erste Wahl, sobald Buchung mehr ist als ein Flag — Vertrag, Laufzeit, Kontingente, Historie |
| **2** Client pro Microservice | Credential-Modell | ja | mittel | Empfohlen, mit `private_key_jwt` statt Secrets |
| **3** Account pro Mandant | beide zugleich | bedingt | hoch | Nur wenn eine signierte Mandanten-Identität gebraucht wird *und* Provisionierung automatisiert ist |
| **4** Super-Client | Credential-Modell | ja | niedrig | Technisch bestätigt. Als Einstieg vertretbar, langfristig das Least-Privilege-Problem. Migration zu 2 ist billig, die Scope-Mechanik bleibt |
| **5** API-Gateway | Durchsetzungspunkt | ja | niedrig | Besser als im Dokument bewertet: Gravitee ist da |
| **6** Claim im Frontend-KC *(neu)* | Wahrheitsquelle | ja | niedrig | Schlanker Gegenentwurf zu 1, solange Buchung ein Flag ist |

## Empfehlung

| Achse | Wahl |
|---|---|
| Wahrheitsquelle | **Ansatz 1** — Lizenz-Service. Bei reinem Ja/Nein-Zustand und Druck Richtung Keycloak stattdessen **Ansatz 6** |
| Credentials | **Ansatz 2** — ein Client pro Microservice, `private_key_jwt`, Client-ID per Namenskonvention. **Ansatz 4** als Startpunkt |
| Durchsetzung | **Ansatz 5** — Gravitee, weil vorhanden. Das Backend-Token bleibt serverseitig (Befund 2) |
| Identität | Zugeschnittenes Identitäts-Token per Token Exchange (`Ansatz-Token-Exchange.md`) statt Roh-Relay |

---

## Konkrete Änderungen am Dokument

| Stelle | Änderung |
|---|---|
| Z. 15 | Down-Scoping aus der Unsicherheiten-Liste streichen (Messung 1) |
| Z. 1–13 | Mandanten-Claim im User-Token in den Kontext aufnehmen: alle verfügbaren plus der aktuell gültige |
| Z. 9 / 92 | Widerspruch auflösen: Anforderung „nur Rollen des aktiven Mandanten" streichen oder User-Check ergänzen |
| Z. 115 | Im Sequenzdiagramm benennen, dass der Mandant aus diesem Claim stammt — nicht aus dem Request |
| Z. 99 | Token-Rückgabe an SP: vom Trade-off zum Defekt umformulieren, oder festhalten, dass SP serverseitig läuft |
| Z. 195–205 | Ansatz 3: „strukturell ausgeschlossen" relativieren, Widerrufs-Latenz ergänzen, Lasttest-Warnung durch Secret-Lifecycle ersetzen, Mandanten-Claim als Pro aufnehmen |
| Z. 247 | ⚠️ streichen; stattdessen: Down-Scoping ist Selbstbeschränkung, keine Sicherheitsgrenze. Scope-Modell je Rollen-Bündel ergänzen |
| Z. 290 | Gateway-Contra korrigieren — Gravitee existiert bereits |
| Z. 308 | Offenen Punkt schließen, auf die Messung verweisen |
| Z. 320 | Begründung ersetzen, siehe `Ansatz-Token-Exchange.md` |
| neu | Mandanten-Transport als eigener Abschnitt (Befund 1); Ansatz 6 ergänzen; Betriebsthemen aus Befund 11 als Checkliste |
