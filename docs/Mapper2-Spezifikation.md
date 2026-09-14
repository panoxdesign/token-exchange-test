# Mapper 2 — Mandanten-Zuschnitt von token3 (Spezifikation & Nachweis)

Fachliche Spezifikation und **gemessener** Nachweis des zweiten Custom Protocol Mappers
(`oidc-tenant-restriction-mapper`, Domain B / Backend-Keycloak). Ergänzt die
Machbarkeitsanalyse in [`Mapper2-Recherche.md`](Mapper2-Recherche.md) (Quellcode-Belege) und den
Modul-`README` in [`../tenant-restriction-mapper/`](../tenant-restriction-mapper/README.md).

## 1. Ziel & Motivation

Ein Backend-User kann mehreren Mandanten-Gruppen angehören (`/domain-5678`, `/domain-1234`), die
je Dienst unterschiedliche Client-Rollen tragen. Ohne weitere Information bekam token3 die
**Vereinigung** aller Rollen über alle Gruppen — nicht die Rollen des einen Mandanten, für den der
Request gedacht ist. Mapper 2 schneidet token3 auf **genau den angeforderten Mandanten** zu und
setzt einen **bestätigten** `tenant`-Claim.

## 2. Akteure

- **`gateway`** (Frontend) — löst den externen Exchange aus und wählt den Mandanten per
  `requested_tenant=`. Mapper 1 (RTM) schreibt ihn als `tenant`-Claim in token2.
  > **Hinweis (Stand nach der RTM-Härtung):** `requested_tenant=` war der Eingabemechanismus zum
  > Zeitpunkt dieser Spezifikation. Seit der Härtung von Mapper 1 (RTM) leitet dieser den
  > `tenant`-Claim stattdessen aus `token1.domain` (dem subject_token des Exchange) ab — ein
  > Request-Parameter existiert nicht mehr. Das hier beschriebene Verhalten von Mapper 2 selbst
  > (Zuschnitt anhand des `tenant`-Claims) ist davon unberührt. Details: `SETUP.md`,
  > `requested-tenant-mapper/README.md`.
- **`backend-requester`** (Backend-Requester) — löst die Assertion per jwt-bearer ein; für seinen Bau von
  token3 greift Mapper 2.
- **Ziel-User `lab-user`** (Backend) — Mitglied beider Mandanten-Gruppen; die Gruppen sind seit
  Mapper 2 seine **alleinige** Rollenquelle.

## 3. Fachliche Kernregel

> token3 bekommt die Rollen für (Tenant, Service) **genau dann**, wenn die Mandanten-Gruppe
> `tenant` im Backend die Rollen des Dienstes `service` gewährt. Andernfalls **fail-closed**:
> leeres `resource_access`, kein `tenant`-Claim.

- **Tenant**: kommt aus dem `tenant`-Claim der Assertion (token2), gesetzt von Mapper 1.
- **Service**: kommt aus `scope=` im jwt-bearer-Request (Schritt 03). Er muss ohnehin mit, sonst
  löst Keycloak die Dienst-Rollen nicht auf. **Kein** zusätzlicher Service-Claim in token2 nötig.

## 4. Design-Entscheidungen (mit Begründung)

| Entscheidung | Gewählt | Warum |
|---|---|---|
| Custom Mapper vs. nativ | **Custom Mapper** | Keycloak flacht die Rollen-Herkunft ein; „nur Rollen aus Gruppe X" gibt es nativ nicht. |
| Service-Quelle | **`scope=` in Schritt 03** | Muss ohnehin mit; kein Frontend-Umbau, Mapper 1 bleibt unangetastet. |
| Verengung | **Filtern (Schnittmenge)** | Entfernt nur, fügt nie hinzu → respektiert Scope-Gating, subsumiert direkte Rollen und Mehrfach-Mitgliedschaft. |
| Fehlerfall | **Fail-closed** | Kein Tenant/keine Mitgliedschaft → leeres `resource_access`, kein `tenant`. Sicher, im Mapper sauber umsetzbar. |
| Rollenquelle | **Nur Gruppen** | Direkte User-Rollen wären tenant-agnostisch und würden den Zuschnitt unterlaufen — deshalb entfernt. |
| Gruppen-Rollen | **Asymmetrischer Split** | Trennung an beiden Diensten sichtbar (siehe Datenmodell). |

## 5. Mechanismus

- **Brücke A (empirisch bestätigt):** Mapper 2 liest die `assertion` direkt aus den
  Form-Parametern des Requests (`getDecodedFormParameters().getFirst("assertion")`) und dekodiert
  den `tenant`-Claim selbst (`JWSInput`/`JsonWebToken`) — dieselbe Quelle, die der jwt-bearer-Grant
  nutzt. Keine erneute Signaturprüfung nötig (der Grant validiert vor dem Token-Bau). Kein
  IdP-Mapper, keine Session Note.
- **Priorität 100:** Mapper 2 läuft nach den Rollen-Mappern (Priorität 40), damit `resource_access`
  beim Verengen bereits befüllt ist. `transformAccessToken` wird überschrieben (sonst greift die
  Config-Flag-Falle wie bei Mapper 1). Belege: [`Mapper2-Recherche.md`](Mapper2-Recherche.md).
- **Ein Codepfad:** `resource_access[client].roles ∩ Rollen(bestätigte Gruppe, client)`; leere
  Einträge werden entfernt. Ohne bestätigte Gruppe ist die erlaubte Menge überall leer → fail-closed
  fällt ohne Sonderfall heraus.

## 6. Datenmodell-Änderungen (`setup-realms.sh`)

- **Mandanten-Gruppen (asymmetrischer Split):**

  | Gruppe | `e-rechnung` | `fahrtkostenerstattung` |
  |---|---|---|
  | `/domain-5678` | reader, writer | reader, approver |
  | `/domain-1234` | reader | reader |

- **Ziel-User `lab-user`:** **keine** direkten Client-Rollen mehr (aktiv entfernt); Rollen kommen
  ausschließlich über die Gruppen. Mitglied beider Gruppen.
- **Neuer Client Scope `tenant-restriction`** mit Mapper 2, als **Default-Scope** am
  Backend-Requester `backend-requester` — greift damit bei jedem token3.
- **`docker-compose.yaml`:** JAR unter `backend-keycloak` gemountet
  (`/opt/keycloak/providers/tenant-restriction-mapper.jar`).

## 7. Akzeptanzkriterien — gemessen

Gemessen gegen Keycloak 26.7.2 im isolierten kctest-Stack, `./setup-realms.sh --recreate`,
kompletter Flow (04 → 05 → 02 mit `requested_tenant` → 03 jwt-bearer). Alle sechs Fälle bestanden:

> **Hinweis:** Die Spalte `requested_tenant` bildet den Eingabemechanismus zum Zeitpunkt dieser
> Messung ab (unveränderte Rohwerte, kein Nacherfinden). Seit der RTM-Härtung kommt der
> `tenant`-Claim, den Mapper 2 hier verarbeitet, aus `token1.domain` statt aus diesem Parameter —
> die Werte in der Spalte entsprachen damals 1:1 dem resultierenden `tenant`-Claim, weil RTM den
> Parameter seinerzeit ungeprüft übernahm. Mapper 2 selbst kennt `requested_tenant` nie, nur den
> `tenant`-Claim der Assertion — insofern ist diese Tabelle weiterhin ein gültiger Nachweis für
> Mapper 2.

| Fall | `requested_tenant` | `scope` | token3.`resource_access` | token3.`tenant` |
|---|---|---|---|---|
| A | domain-5678 | e-rechnung | `e-rechnung: [reader, writer]` | domain-5678 |
| **B** | **domain-1234** | **e-rechnung** | **`e-rechnung: [reader]`** | **domain-1234** |
| C | domain-5678 | fahrtkostenerstattung | `fahrtkostenerstattung: [reader, approver]` | domain-5678 |
| D | domain-1234 | fahrtkostenerstattung | `fahrtkostenerstattung: [reader]` | domain-1234 |
| E | *(weggelassen)* | e-rechnung | `{}` (leer) | *(kein)* |
| F | domain-9999 *(keine Mitgliedschaft)* | e-rechnung | `{}` (leer) | *(kein)* |

Fall **B** ist der Kernbeweis: die Vereinigung `[reader, writer]` wird auf die eine Mandanten-Rolle
`[reader]` zugeschnitten. **E/F** belegen fail-closed.

### Gemessene Claims (kanonischer Fall A)

> Gemessen vor der RTM-Härtung, mit `requested_tenant=domain-5678` als Eingabe. Der `tenant`-Claim
> in token2 kommt seither aus `token1.domain` statt aus diesem Parameter; der gezeigte Claim-Wert
> selbst ist unverändert gültig.

```jsonc
// token2 - Exchange/Assertion, client gateway, requested_tenant=domain-5678
{
  "iss": "http://localhost:8080/realms/frontend",
  "azp": "gateway",
  "sub": "b0d49895-…",                 // = lab-user im Frontend
  "aud": "http://localhost:8181/realms/Backend-Microservices",
  "scope": "profile access-backend email",
  "tenant": "domain-5678",             // Mapper 1 (RTM)
  "resource_access": null
}

// token3 - jwt-bearer, scope=e-rechnung, client backend-requester
{
  "iss": "http://localhost:8181/realms/Backend-Microservices",
  "azp": "backend-requester",
  "sub": "ab474215-…",                 // = lab-user im Backend
  "aud": "e-rechnung",
  "scope": "profile email e-rechnung tenant-restriction",
  "preferred_username": "lab-user",
  "tenant": "domain-5678",             // Mapper 2: bestaetigt
  "resource_access": { "e-rechnung": { "roles": ["reader", "writer"] } }
}
```

## 8. Edge Cases

- **Tenant fehlt / keine Mitgliedschaft / Gruppe existiert nicht** → fail-closed (Fälle E/F).
- **Composite-Rollen / Parent-Gruppen:** Das Labor nutzt flache Rollen und Gruppen; `direkt ==
  effektiv`. Bei Composites müsste die erlaubte Menge expandiert werden — hier nicht nötig.
- **`account`/Fremd-Clients in `resource_access`:** Im Flow steht nur der Dienst-Client
  (`fullScopeAllowed=false`). Ein etwaiger `account`-Eintrag würde mit-gefiltert — im Labor
  irrelevant, als Annahme notiert.
- **Assertion gilt genau einmal** (`Token reuse detected`): für den zweiten Dienst token2 neu holen.

## 9. Offene Punkte

- **Sicherheits-Variante (aufgeschoben):** Service zusätzlich als Claim in token2 binden und
  gegen `scope` gegenprüfen — bindet die (Tenant, Service)-Freigabe kryptografisch an die
  Frontend-Assertion. Für ein Lernlabor bewusst nicht umgesetzt (Overkill, zweite Mapper-1-Änderung).
- **Nicht Teil dieser Aufgabe:** Push/Merge der Mapper-1-Commits, Altlasten E–H der Live-Instanz.

---

Gemessen am 2026-09-14 gegen Keycloak 26.7.2 in einem isolierten Compose-Stack (`-p kctest`,
benannte Volumes), provisioniert mit `./setup-realms.sh --recreate`, verifiziert mit
`./check-setup.sh` (grün) und dem vollständigen Flow.
