# Mapper 2 — Buchungs-Zuschnitt von token3 (Spezifikation & Nachweis)

Fachliche Spezifikation und **gemessener** Nachweis des zweiten Custom Protocol Mappers
(`oidc-booking-restriction-mapper`, Domain B / Backend-Keycloak). Ergänzt die
Machbarkeitsanalyse in [`Mapper2-Recherche.md`](Mapper2-Recherche.md) (Quellcode-Belege) und den
Modul-`README` in [`../booking-restriction-mapper/`](../booking-restriction-mapper/README.md).

## 1. Ziel & Motivation

Vorher trug der Backend-Realm das Mandanten-Wissen selbst (Gruppen `/domain-5678`, `/domain-1234`).
Jeder neue Mandant im Frontend musste im Backend nachgezogen werden (Gruppe, Gruppenrollen,
Mitgliedschaft) — eine Synchronisation, die entfallen soll. Künftig kennt das Backend **keine
Mandanten** mehr. Die Buchung „welcher Mandant hat welchen Dienst gebucht" liegt in einer CSV
([`buchungen.csv`](buchungen.csv)), die **nur das Frontend/BFF** liest (in diesem Lab manuell
simuliert). Die Buchung reist als signierte `service:*`-Scopes im `scope`-Claim der Assertion
(token2); Mapper 2 erzwingt im Backend, dass `resource_access` in token3 nur die dort gebuchten
Dienste enthält.

## 2. Akteure

- **Frontend/BFF** (simuliert) — liest die CSV und fordert beim externen Exchange (Schritt 02) nur
  die dort gebuchten `service:*`-Scopes an. In diesem Lab manuell über den `scope=`-Parameter des
  Requests, kein Anwendungscode.
- **`gateway`** (Frontend) — löst den externen Exchange aus; die angeforderten `service:*`-Scopes
  landen unverändert im `scope`-Claim von token2 (kein eigener Mapper nötig, die Standard-Scope-
  Auflösung reicht).
- **`backend-requester`** (Backend) — löst die Assertion per jwt-bearer ein; für seinen Bau von
  token3 greift Mapper 2.
- **Ziel-User `lab-user`** (Backend) — trägt die Dienst-Rollen **beider** Dienste direkt (keine
  Mandanten-Gruppen mehr). Welcher Dienst tatsächlich freigeschaltet wird, entscheidet allein die
  Buchung in der Assertion.

## 3. Fachliche Kernregel

> token3 bekommt die Rollen für den Dienst `service` **genau dann**, wenn die Assertion (token2)
> `service:<service>` im `scope`-Claim trägt UND der Backend-User Rollen für `service` hat UND
> `scope=<service>` beim jwt-bearer-Request (Schritt 03) angefordert wurde. Fehlt die Buchung,
> **fail-closed**: der Client-Eintrag verschwindet komplett aus `resource_access`.

- **Buchung**: kommt aus den `service:*`-Einträgen im `scope`-Claim der Assertion (token2), vom
  Frontend/BFF anhand der CSV gewählt.
- **Dienst-Auswahl**: kommt aus `scope=` im jwt-bearer-Request (Schritt 03), wie schon vorher — er
  muss ohnehin mit, sonst löst Keycloak die Dienst-Rollen nicht auf (Role Scope Mappings).
- Beide Bedingungen sind unabhängig und müssen beide erfüllt sein: `scope=fahrtkostenerstattung`
  ohne `service:fahrtkostenerstattung` in der Assertion bleibt leer, und umgekehrt bucht ein
  `service:fahrtkostenerstattung` in der Assertion ohne `scope=fahrtkostenerstattung` im Request
  gar nichts (Keycloak löst dann von vornherein keine Rollen für den Client auf).

## 4. Design-Entscheidungen (mit Begründung)

| Entscheidung | Gewählt | Warum |
|---|---|---|
| Custom Mapper vs. nativ | **Custom Mapper** | Keycloak bildet beim jwt-bearer-Grant keine Schnittmenge aus Assertion-`scope` und Request-`scope` (belegt in `Mapper2-Recherche.md`) — ohne Mapper wäre die Buchung wirkungslos. |
| Transport der Buchung | **echte `service:*`-Scopes im `scope`-Claim von token2** | Signiert, vom Frontend gewählt, ohne Frontend-Umbau über die Scope-Auflösung. |
| Verengung | **Client-weiser Filter** (nicht Rollen-Schnittmenge) | Buchung ist boolesch je (Mandant, Dienst); innerhalb eines Dienstes gelten für alle Mandanten dieselben Rollen — es gibt keine Rollen-Quelle mehr zum Schneiden. |
| Fehlerfall | **Fail-closed** | Kein `service:<dienst>` in der Assertion → Eintrag entfernt. Sicher, im Mapper ohne Sonderfall umsetzbar. |
| Rollenquelle Backend | **Direkte Dienst-Rollen am User** | Ersetzt die Mandanten-Gruppen; Scope (Schritt 03) + Mapper 2 schneiden zu, nicht mehr die Gruppenmitgliedschaft. |
| `tenant`-Claim | **bleibt, wird von Mapper 2 nicht ausgewertet, aber fail-closed-konsistent nach token3 kopiert** | Reiner Audit-Claim; `token1.domain` bleibt CSV-Schlüssel fürs Frontend/BFF. `requested-tenant-mapper` (Mapper 1) bleibt unverändert. Kopiert wird nur, wenn nach dem Verengen mindestens ein Dienst in `resource_access` übrig bleibt — sonst bliebe „ohne Rollen, aber mit tenant" ein Widerspruch zum Fail-closed-Verhalten. |

## 5. Mechanismus

- **Brücke A:** Mapper 2 liest die `assertion` direkt aus den Form-Parametern des Requests
  (`getDecodedFormParameters().getFirst("assertion")`) und dekodiert sie als `JsonWebToken` — wie
  der jwt-bearer-Grant selbst. `scope` ist dort kein deklariertes Feld (nur in der Unterklasse
  `AccessToken`), landet aber über `@JsonAnySetter` in `otherClaims` — genau wie `tenant`/`domain`
  bei den anderen beiden Mappern. Keine erneute Signaturprüfung nötig (der Grant validiert vor dem
  Token-Bau). Beleg: [`Mapper2-Recherche.md`](Mapper2-Recherche.md).
- **Priorität 100:** Mapper 2 läuft nach den Rollen-Mappern (Priorität 40), damit `resource_access`
  beim Verengen bereits befüllt ist. `transformAccessToken` wird überschrieben (sonst greift die
  Config-Flag-Falle wie bei den anderen Mappern).
- **Ein Codepfad:** `scope.split(whitespace)` → Einträge mit Präfix `service:` → Präfix strippen →
  Menge gebuchter Dienste. Jeder `resource_access`-Eintrag, dessen Client-ID nicht in dieser Menge
  liegt, wird entfernt. Ohne Buchung ist die Menge leer → fail-closed fällt ohne Sonderfall heraus.
- **`tenant`-Audit-Claim:** aus derselben Dekodierung wird auch `otherClaims.get("tenant")` gelesen
  und, falls vorhanden, erst *nach* dem Verengen nach token3 geschrieben — und nur, wenn
  `resource_access` dann nicht leer ist. So bleibt der Fail-closed-Fall ohne `tenant`-Claim.

## 6. Datenmodell-Änderungen (`setup-realms.sh`)

- **Frontend:** Client Scopes `service:e-rechnung`, `service:fahrtkostenerstattung` — reine Marker
  ohne Role Scope Mappings, als **Optional** am `gateway`.
- **Backend:** Mandanten-Gruppen `/domain-5678`, `/domain-1234` entfallen ersatzlos. Der
  Backend-Ziel-User `lab-user` trägt stattdessen **direkte** Client-Rollen beider Dienste
  (`e-rechnung`: reader, writer / `fahrtkostenerstattung`: reader, approver) — für alle Mandanten
  gleich, der frühere asymmetrische Split entfällt.
- **Neuer Client Scope `booking-restriction`** mit Mapper 2, als **Default-Scope** am
  Backend-Requester `backend-requester` — greift damit bei jedem token3.
- **`docker-compose.yaml`:** JAR unter `backend-keycloak` gemountet
  (`/opt/keycloak/providers/booking-restriction-mapper.jar`).

## 7. Akzeptanzkriterien — gemessen

Gemessen gegen Keycloak 26.7.2 im isolierten kctest-Stack (`-p kctest`, benannte Volumes),
`./setup-realms.sh --recreate`, kompletter Flow (04 → 05a → 02 mit `service:*`-Scope → 03
jwt-bearer). Alle vier Fälle bestanden:

| Fall | `scope` in Schritt 02 (token2) | `scope` in Schritt 03 (token3) | token3.`resource_access` |
|---|---|---|---|
| A — Positiv | `access-backend service:e-rechnung` | `e-rechnung` | `{ "e-rechnung": { "roles": ["reader", "writer"] } }` |
| B — Positiv, zweiter Dienst | `access-backend service:fahrtkostenerstattung` | `fahrtkostenerstattung` | `{ "fahrtkostenerstattung": { "roles": ["approver", "reader"] } }` |
| C — Fail-closed, ungebucht | `access-backend service:e-rechnung` | `fahrtkostenerstattung` | `{}` (leer) |
| D — Fail-closed, keine Buchung | `access-backend` (kein `service:*`) | `e-rechnung` | `{}` (leer) |

Fall **C** ist der Kernbeweis: der Backend-User hat direkte Rollen für `fahrtkostenerstattung`
(`reader`, `approver`) und der Scope ist `backend-requester` als Optional zugewiesen — `aud` im
Ergebnis-Token ist korrekt `fahrtkostenerstattung`, Keycloak hätte die Rollen also normal aufgelöst.
Weil die Assertion aber nur `service:e-rechnung` bucht, leert Mapper 2 `resource_access`
nachträglich vollständig (siehe `Mapper2-Recherche.md`, Frage 1, für den Beleg, dass die native
Scope-Auflösung das ohne den Mapper nicht getan hätte).

Seit der Ergänzung des `tenant`-Audit-Claims gilt zusätzlich: token3 trägt `tenant` genau dann,
wenn `resource_access` nach dem Verengen nicht leer ist — gemessen für Fall A (`tenant` gesetzt)
und Fall C (`tenant` fehlt). Fälle B/D folgen demselben Codepfad, wurden für diese Ergänzung nicht
gesondert neu gemessen.

### Gemessene Claims (kanonischer Fall A)

```jsonc
// token2 - Exchange/Assertion, client gateway, scope=access-backend service:e-rechnung
{
  "iss": "http://localhost:8080/realms/frontend",
  "azp": "gateway",
  "sub": "72401c31-…",                 // = lab-user im Frontend
  "aud": "http://localhost:8181/realms/Backend-Microservices",
  "scope": "profile email access-backend service:e-rechnung",
  "tenant": "domain-5678",             // Mapper 1 (RTM) - Audit-Claim; Mapper 2 liest ihn nur durch, wertet ihn nicht aus
  "jti": "ntrtte:…"
}

// token3 - jwt-bearer, scope=e-rechnung, client backend-requester
{
  "iss": "http://localhost:8181/realms/Backend-Microservices",
  "azp": "backend-requester",
  "sub": "ed761e0b-…",                 // = lab-user im Backend
  "aud": "e-rechnung",
  "scope": "profile booking-restriction email e-rechnung",
  "preferred_username": "lab-user",
  "resource_access": { "e-rechnung": { "roles": ["reader", "writer"] } },
  "tenant": "domain-5678"              // Audit-Claim, von Mapper 2 aus der Assertion kopiert
}
```

### Gemessener Fail-closed-Fall (C)

```jsonc
// token2 - bucht NUR service:e-rechnung
{ "scope": "profile email access-backend service:e-rechnung", … }

// token3 - jwt-bearer, scope=fahrtkostenerstattung (NICHT gebucht)
{
  "iss": "http://localhost:8181/realms/Backend-Microservices",
  "aud": "fahrtkostenerstattung",       // Audience-Mapper feuert normal
  "resource_access": {},                // Mapper 2: nicht gebucht -> geleert
  "scope": "fahrtkostenerstattung profile booking-restriction email"
  // kein "tenant"-Claim - resource_access ist nach dem Verengen leer, also fail-closed auch hier
}
```

## 8. Edge Cases

- **Buchung fehlt / falscher Dienst gebucht** → fail-closed (Fälle C/D).
- **`account`/Fremd-Clients in `resource_access`:** Im Flow steht nur der Dienst-Client
  (`fullScopeAllowed=false`). Ein etwaiger `account`-Eintrag würde ebenfalls entfernt (kann nicht
  unter `service:*` gebucht sein) — im Labor irrelevant, als Annahme notiert.
- **Assertion gilt genau einmal** (`Token reuse detected`): für den zweiten Dienst token2 neu holen.

## 9. Nicht Teil dieser Aufgabe

- Push/Merge früherer Mapper-1-Commits, Altlasten der Live-Instanz des Nutzers.
- Eine kryptografische Bindung von (Mandant, Dienst) über einen zusätzlichen Claim hinaus — die
  Buchung ist bereits über den signierten `scope`-Claim der Assertion abgesichert.

---

Ersetzt die frühere, gruppenbasierte Spezifikation zum inzwischen gelöschten
`tenant-restriction-mapper`. Gemessen in einem isolierten Compose-Stack (`-p kctest`, benannte
Volumes), provisioniert mit `./setup-realms.sh --recreate`, verifiziert mit `./check-setup.sh`
(grün) und dem vollständigen Flow.
