#!/usr/bin/env bash
#
# Baut die komplette Token-Exchange-Kette in beiden Keycloak-Instanzen auf.
#
#   Frontend-Realm  frontend
#     domain-5678                Ziel-Domain des internen Exchange, Rollen admin, selfservice
#     domain-1234                zweite Ziel-Domain, Rollen admin, selfservice
#     <backend-issuer-url>       Client, der nur als Audience-Ziel existiert, traegt die Rolle
#                                 selfservice - gated den externen Exchange
#     access-backend             Client Scope mit RTM-Mapper (subject_token.domain -> Claim
#                                 tenant); aud entsteht ueber Role Scope Mapping auf die
#                                 selfservice-Rolle des Audience-Ziel-Clients, kein eigener
#                                 Audience-Mapper mehr
#     service:e-rechnung / ...   Client Scopes, reine Marker (keine Role Scope Mappings).
#                                 Transportieren die Buchung eines Dienstes im scope-Claim
#                                 von token2 - das Frontend/BFF waehlt sie anhand der CSV
#     gateway                    Requester-Client des internen UND externen Exchange,
#                                 darf Token Exchange
#     self-service-portal        Client fuer den Password Grant des Lab-Users
#     to-gateway                 Client Scope mit Audience-Mapper auf gateway
#     lab-user                   User, traegt die Rollen aus domain-5678 und domain-1234
#                                 sowie selfservice am Audience-Ziel-Client (externer Exchange)
#
#   Backend-Realm   Backend-Microservices
#     frontend                   Identity Provider, akzeptiert JWT Authorization Grants
#     e-rechnung                 Ziel-Dienst mit Rollen reader, writer
#     fahrtkostenerstattung      Ziel-Dienst mit Rollen reader, approver
#     e-rechnung / fahrt...      Client Scopes: Audience-Mapper + Role Scope Mappings
#     backend-requester          Requester-Client, loest die Assertion ein
#     booking-restriction        Client Scope am Requester mit Mapper 2
#                                 (oidc-booking-restriction-mapper), Default-Scope
#     lab-user                   Ziel-User, verknuepft mit dem Frontend-lab-user, traegt
#                                 die Dienst-Rollen BEIDER Dienste DIREKT (keine Mandanten-
#                                 Gruppen mehr - welcher Mandant was gebucht hat, weiss
#                                 nur noch das Frontend/BFF, s. docs/buchungen.csv)
#
# Idempotent: mehrfaches Ausfuehren ist unschaedlich.
#
#   ./setup-realms.sh              fehlende Objekte ergaenzen
#   ./setup-realms.sh --recreate   beide Realms vorher loeschen und neu aufbauen

set -uo pipefail

# --- Konfiguration -----------------------------------------------------------
FE="${FE:-http://localhost:8080}"
BE="${BE:-http://localhost:8181}"
FE_REALM="${FE_REALM:-frontend}"
BE_REALM="${BE_REALM:-Backend-Microservices}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

DOMAIN="${DOMAIN:-domain-5678}"
BE_REQUESTER="${BE_REQUESTER:-backend-requester}"
IDP_ALIAS="${IDP_ALIAS:-frontend}"
ACCESS_SCOPE="${ACCESS_SCOPE:-access-backend}"
TARGET_USER="${TARGET_USER:-lab-user}"

FE_ISSUER="$FE/realms/$FE_REALM"
BE_ISSUER="$BE/realms/$BE_REALM"
# Aus dem Backend-Container heraus zeigt localhost auf das Backend selbst. Fuer den
# JWKS-Abruf braucht es deshalb den Docker-Servicenamen, waehrend der issuer die
# localhost-URL bleiben muss - sie steht so im Token.
FE_JWKS="${FE_JWKS:-http://frontend-keycloak:8080/realms/$FE_REALM/protocol/openid-connect/certs}"

# Feste Lab-Secrets. Bewusst nicht generiert, damit die Bruno-Environment ohne
# Abtippen laeuft. Fuer ein Testlabor in Ordnung, fuer sonst nichts.
SEC_AUDIENCE="${SEC_AUDIENCE:-lab-backend-audience-secret}"
SEC_BE_REQUESTER="${SEC_BE_REQUESTER:-lab-backend-requester-secret}"

GATEWAY="${GATEWAY:-gateway}"
SP_CLIENT="${SP_CLIENT:-self-service-portal}"
SP_SCOPE="${SP_SCOPE:-to-gateway}"
LAB_USER="${LAB_USER:-lab-user}"
LAB_PASS="${LAB_PASS:-lab-user}"
SEC_GATEWAY="${SEC_GATEWAY:-lab-frontend-gateway-secret}"
SEC_SP="${SEC_SP:-lab-frontend-sp-secret}"

# Ziel-Domains des internen Token Exchange:  name:rolle,rolle
# Die Rollen sind nicht Beiwerk - ueber sie entsteht die aud des Ergebnis-Tokens.
FE_DOMAINS=(
  "domain-5678:admin,selfservice"
  "domain-1234:admin,selfservice"
)

# Ziel-Dienste:  name:rolle,rolle
# Zugleich die Namen der Buchungs-Marker-Scopes im Frontend (service:<name>) und der
# direkten Dienst-Rollen, die der Backend-Ziel-User traegt - fuer alle Mandanten gleich,
# der asymmetrische Split entfaellt (Buchung ist boolesch je Mandant und Dienst, s.
# docs/buchungen.csv).
SERVICES=(
  "e-rechnung:reader,writer"
  "fahrtkostenerstattung:reader,approver"
)
SERVICE_SCOPE_PREFIX="${SERVICE_SCOPE_PREFIX:-service:}"

RECREATE=0
[ "${1:-}" = "--recreate" ] && RECREATE=1

# --- Ausgabe -----------------------------------------------------------------
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m+\033[0m %s\n' "$1"; }
skip() { printf '  \033[90m=\033[0m %s\n' "$1"; }
die()  { printf '  \033[31mFEHLER\033[0m %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null || die "jq wird gebraucht (brew install jq)"

BODY=$(mktemp); trap 'rm -f "$BODY"' EXIT

# --- HTTP --------------------------------------------------------------------
# Setzt Statuscode in RC, Antwortkoerper in $BODY.
req() { # base token method path [json]
  # Kein ${5:+-H "..."}: Anfuehrungszeichen aus einer Expansion werden nicht
  # erneut geparst, das Header-Argument wuerde am Leerzeichen zerfallen.
  if [ -n "${5:-}" ]; then
    RC=$(curl -s -o "$BODY" -w '%{http_code}' -X "$3" "$1$4" \
          -H "Authorization: Bearer $2" \
          -H "Content-Type: application/json" \
          -d "$5")
  else
    RC=$(curl -s -o "$BODY" -w '%{http_code}' -X "$3" "$1$4" \
          -H "Authorization: Bearer $2")
  fi
}

admin_token() {
  curl -s -o "$BODY" -w '%{http_code}' -X POST "$1/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d grant_type=password \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" >/dev/null 2>&1
  jq -r '.access_token // empty' <"$BODY" 2>/dev/null
}

# Nach "docker compose up -d" braucht Keycloak mit Postgres gut eine halbe Minute.
# Ohne dieses Warten scheitert der erste Login und sieht wie ein Konfigurationsfehler aus.
wait_ready() { # base name
  local i
  for i in $(seq 1 "${WAIT_SECONDS:-90}"); do
    curl -sf "$1/realms/master/.well-known/openid-configuration" >/dev/null 2>&1 && {
      [ "$i" -gt 1 ] && ok "$2 erreichbar (nach ${i}s)" || ok "$2 erreichbar"
      return 0
    }
    [ "$i" = 1 ] && printf '  warte auf %s ' "$2"
    printf '.'
    sleep 1
  done
  printf '\n'
  die "$2 unter $1 nicht erreichbar. Laeuft der Container?  docker compose ps"
}

# Setzt TOKEN. Bewusst kein "TOKEN=$(login ...)": ein die() in einer Subshell
# beendet nur diese, und das Skript liefe mit leerem Token weiter.
login() { # base name
  TOKEN=$(admin_token "$1")
  [ -n "$TOKEN" ] || die "Admin-Login an $2 ($1) fehlgeschlagen.
         Antwort: $(jq -r '.error_description // .error // .' <"$BODY" 2>/dev/null | head -1)
         Erwartet wird $ADMIN_USER / <ADMIN_PASS>.
         Abweichend?  ADMIN_USER=... ADMIN_PASS=... ./setup-realms.sh"
}

step "Anmelden"
wait_ready "$FE" "Frontend"
wait_ready "$BE" "Backend"
login "$FE" "Frontend"; FE_TOK="$TOKEN"
login "$BE" "Backend";  BE_TOK="$TOKEN"
ok "angemeldet an beiden Instanzen"

# --- Bausteine ---------------------------------------------------------------
ensure_realm() { # base token realm
  if [ "$RECREATE" -eq 1 ]; then
    req "$1" "$2" DELETE "/admin/realms/$3"
    [ "$RC" = "204" ] && ok "Realm '$3' geloescht"
  fi
  req "$1" "$2" GET "/admin/realms/$3"
  if [ "$RC" = "200" ]; then skip "Realm '$3' existiert"; return; fi
  req "$1" "$2" POST "/admin/realms" \
    "$(jq -nc --arg r "$3" '{realm:$r, enabled:true}')"
  [ "$RC" = "201" ] || die "Realm '$3' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Realm '$3' angelegt"
}

client_uuid() { # base token realm clientId
  req "$1" "$2" GET "/admin/realms/$3/clients?clientId=$(jq -rn --arg s "$4" '$s|@uri')"
  jq -r '.[0].id // empty' <"$BODY"
}

ensure_client() { # base token realm clientId json  -> echo uuid
  local uuid; uuid=$(client_uuid "$1" "$2" "$3" "$4")
  if [ -n "$uuid" ]; then
    req "$1" "$2" PUT "/admin/realms/$3/clients/$uuid" "$5"
    [ "$RC" = "204" ] || die "Client '$4' aktualisieren fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
    skip "Client '$4' aktualisiert" >&2
  else
    req "$1" "$2" POST "/admin/realms/$3/clients" "$5"
    [ "$RC" = "201" ] || die "Client '$4' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
    uuid=$(client_uuid "$1" "$2" "$3" "$4")
    ok "Client '$4' angelegt" >&2
  fi
  echo "$uuid"
}

scope_id() { # base token realm name
  req "$1" "$2" GET "/admin/realms/$3/client-scopes"
  jq -r --arg n "$4" '.[] | select(.name == $n) | .id' <"$BODY"
}

ensure_scope() { # base token realm name -> echo id
  local id; id=$(scope_id "$1" "$2" "$3" "$4")
  if [ -n "$id" ]; then skip "Client Scope '$4' existiert" >&2; echo "$id"; return; fi
  req "$1" "$2" POST "/admin/realms/$3/client-scopes" "$(jq -nc --arg n "$4" '{
    name:$n, protocol:"openid-connect",
    attributes:{
      "include.in.token.scope":"true",
      "display.on.consent.screen":"false",
      "include.in.openid.provider.metadata":"false"
    }}')"
  [ "$RC" = "201" ] || die "Client Scope '$4' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Client Scope '$4' angelegt" >&2
  scope_id "$1" "$2" "$3" "$4"
}

ensure_audience_mapper() { # base token realm scopeId audienceClientId
  req "$1" "$2" GET "/admin/realms/$3/client-scopes/$4/protocol-mappers/models"
  if jq -e --arg a "$5" 'any(.protocolMapper == "oidc-audience-mapper"
        and .config["included.client.audience"] == $a)' <"$BODY" >/dev/null; then
    skip "Audience-Mapper auf '$5' vorhanden"; return
  fi
  req "$1" "$2" POST "/admin/realms/$3/client-scopes/$4/protocol-mappers/models" \
    "$(jq -nc --arg a "$5" '{
      name:"audience", protocol:"openid-connect", protocolMapper:"oidc-audience-mapper",
      config:{"included.client.audience":$a,"access.token.claim":"true",
              "id.token.claim":"false","introspection.token.claim":"true"}}')"
  [ "$RC" = "201" ] || die "Audience-Mapper anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Audience-Mapper auf '$5' angelegt"
}

ensure_requested_tenant_mapper() { # base token realm scopeId
  # Leitet beim Exchange (Request 02) den Claim 'tenant' aus dem domain-Claim
  # des subject_token (token1) ab und legt ihn in token2 ab - config bleibt
  # leer, der Mapper braucht keine weitere Einstellung.
  req "$1" "$2" GET "/admin/realms/$3/client-scopes/$4/protocol-mappers/models"
  if jq -e 'any(.protocolMapper == "oidc-requested-tenant-mapper")' <"$BODY" >/dev/null; then
    skip "RTM-Mapper vorhanden"; return
  fi
  req "$1" "$2" POST "/admin/realms/$3/client-scopes/$4/protocol-mappers/models" \
    "$(jq -nc '{name:"RTM", protocol:"openid-connect",
      protocolMapper:"oidc-requested-tenant-mapper", config:{}}')"
  [ "$RC" = "201" ] || die "RTM-Mapper anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "RTM-Mapper angelegt"
}

ensure_booking_restriction_mapper() { # base token realm scopeId
  # Mapper 2: verengt resource_access in token3 auf die Dienste, die laut scope-Claim
  # der Assertion (Praefix "service:") gebucht sind. config bleibt leer, der Mapper
  # braucht keine Einstellung.
  req "$1" "$2" GET "/admin/realms/$3/client-scopes/$4/protocol-mappers/models"
  if jq -e 'any(.protocolMapper == "oidc-booking-restriction-mapper")' <"$BODY" >/dev/null; then
    skip "Booking-Restriction-Mapper vorhanden"; return
  fi
  req "$1" "$2" POST "/admin/realms/$3/client-scopes/$4/protocol-mappers/models" \
    "$(jq -nc '{name:"booking-restriction", protocol:"openid-connect",
      protocolMapper:"oidc-booking-restriction-mapper", config:{}}')"
  [ "$RC" = "201" ] || die "Booking-Restriction-Mapper anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Booking-Restriction-Mapper angelegt"
}

ensure_client_role() { # base token realm clientUuid role
  req "$1" "$2" GET "/admin/realms/$3/clients/$4/roles/$5"
  if [ "$RC" = "200" ]; then skip "Rolle '$5' existiert"; return; fi
  req "$1" "$2" POST "/admin/realms/$3/clients/$4/roles" "$(jq -nc --arg n "$5" '{name:$n}')"
  [ "$RC" = "201" ] || die "Rolle '$5' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Rolle '$5' angelegt"
}

assign_optional_scope() { # base token realm clientUuid scopeId scopeName
  req "$1" "$2" PUT "/admin/realms/$3/clients/$4/optional-client-scopes/$5"
  case "$RC" in
    204) ok "Scope '$6' als Optional zugewiesen" ;;
    409) skip "Scope '$6' bereits zugewiesen" ;;
    *)   die "Scope '$6' zuweisen fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
}

ensure_hardcoded_claim_mapper() { # base token realm scopeId claimName claimValue
  req "$1" "$2" GET "/admin/realms/$3/client-scopes/$4/protocol-mappers/models"
  if jq -e --arg n "$5" 'any(.protocolMapper == "oidc-hardcoded-claim-mapper"
        and .config["claim.name"] == $n)' <"$BODY" >/dev/null; then
    skip "Hardcoded-Claim-Mapper '$5' vorhanden"; return
  fi
  req "$1" "$2" POST "/admin/realms/$3/client-scopes/$4/protocol-mappers/models" \
    "$(jq -nc --arg n "$5" --arg v "$6" '{
      name:$n, protocol:"openid-connect", protocolMapper:"oidc-hardcoded-claim-mapper",
      config:{"claim.name":$n,"claim.value":$v,"jsonType.label":"String",
              "access.token.claim":"true","id.token.claim":"false",
              "introspection.token.claim":"true"}}')"
  [ "$RC" = "201" ] || die "Hardcoded-Claim-Mapper '$5' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Hardcoded-Claim-Mapper '$5=$6' angelegt"
}

assign_default_scope() { # base token realm clientUuid scopeId scopeName
  req "$1" "$2" PUT "/admin/realms/$3/clients/$4/default-client-scopes/$5"
  case "$RC" in
    204) ok "Scope '$6' als Default zugewiesen" ;;
    409) skip "Scope '$6' bereits zugewiesen" ;;
    *)   die "Scope '$6' zuweisen fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
}

set_role_scope_mappings() { # base token realm scopeId clientUuid label
  req "$1" "$2" GET "/admin/realms/$3/clients/$5/roles"
  local ROLE_JSON; ROLE_JSON=$(cat "$BODY")
  req "$1" "$2" POST "/admin/realms/$3/client-scopes/$4/scope-mappings/clients/$5" "$ROLE_JSON"
  case "$RC" in
    204|409) ok "Role Scope Mappings gesetzt ($6)" ;;
    *) die "Role Scope Mappings fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
}

assign_client_roles_to_user() { # base token realm userId clientUuid label
  req "$1" "$2" GET "/admin/realms/$3/clients/$5/roles"
  local ROLE_JSON; ROLE_JSON=$(cat "$BODY")
  req "$1" "$2" POST "/admin/realms/$3/users/$4/role-mappings/clients/$5" "$ROLE_JSON"
  case "$RC" in
    204|409) ok "Rollen von '$6' zugewiesen" ;;
    *) die "Rollenzuweisung '$6' fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
}

ensure_user() { # base token realm username -> echo userId
  req "$1" "$2" GET "/admin/realms/$3/users?username=$(jq -rn --arg s "$4" '$s|@uri')&exact=true"
  local id; id=$(jq -r '.[0].id // empty' <"$BODY")
  local missing; missing=$(jq -r '.[0] | select(.email == null or .firstName == null or .lastName == null) | "ja"' <"$BODY")

  # email, firstName und lastName sind Pflicht - nicht wegen requiredActions,
  # sondern wegen des deklarativen User Profile: fehlt eines davon, loest
  # Keycloak beim Login dynamisch VERIFY_PROFILE aus und der Password Grant
  # scheitert mit 'Account is not fully set up', obwohl requiredActions leer ist.
  # Im Server-Log steht dann error="resolve_required_actions".
  local profile; profile=$(jq -nc --arg u "$4" '{
    email:($u + "@example.invalid"), firstName:"Lab", lastName:$u}')

  if [ -n "$id" ]; then
    if [ "$missing" = "ja" ]; then
      req "$1" "$2" PUT "/admin/realms/$3/users/$id" "$profile"
      [ "$RC" = "204" ] || die "User '$4' vervollstaendigen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
      ok "User '$4' um die Profilfelder ergaenzt" >&2
    else
      skip "User '$4' existiert: $id" >&2
    fi
    echo "$id"; return
  fi

  # requiredActions leer: offene Actions lassen den Grant spaeter ebenfalls mit
  # 'Account is not fully set up' scheitern.
  req "$1" "$2" POST "/admin/realms/$3/users" "$(jq -nc --arg u "$4" --argjson p "$profile" '
    $p + {username:$u, enabled:true, emailVerified:true, requiredActions:[]}')"
  [ "$RC" = "201" ] || die "User '$4' anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  req "$1" "$2" GET "/admin/realms/$3/users?username=$(jq -rn --arg s "$4" '$s|@uri')&exact=true"
  id=$(jq -r '.[0].id // empty' <"$BODY")
  ok "User '$4' angelegt: $id" >&2
  echo "$id"
}

ensure_password() { # base token realm userId password
  req "$1" "$2" PUT "/admin/realms/$3/users/$4/reset-password" "$(jq -nc --arg p "$5" '{
    type:"password", value:$p, temporary:false}')"
  # temporary:false ist Pflicht - bei true haengt Keycloak die Required Action
  # UPDATE_PASSWORD an den User, und der Passwort-Grant scheitert mit
  # 'Account is not fully set up'.
  [ "$RC" = "204" ] || die "Passwort setzen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Passwort gesetzt"
}

# =============================================================================
# Frontend-Realm
# =============================================================================
step "Frontend-Realm '$FE_REALM'"
ensure_realm "$FE" "$FE_TOK" "$FE_REALM"

# Client, dessen Client-ID die Issuer-URL des Backends IST: die aud landet im
# Token als Client-ID eines existierenden Clients (ob per Audience-Mapper oder,
# wie hier, per AudienceResolveProtocolMapper), und aud muss laut RFC 7523 der
# Issuer des empfangenden Servers sein. Daher dieser Name.
AUD_JSON=$(jq -nc --arg id "$BE_ISSUER" --arg sec "$SEC_AUDIENCE" '{
  clientId:$id, name:"backend", enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  serviceAccountsEnabled:false, implicitFlowEnabled:false}')
AUD_UUID=$(ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$BE_ISSUER" "$AUD_JSON")

# Rolle 'selfservice' gated den externen Exchange - derselbe Mechanismus, den
# domain-5678/domain-1234 unten schon fuer token1 nutzen: der eingebaute
# AudienceResolveProtocolMapper (im Client Scope 'roles', s. gateway) traegt
# jeden Client in die aud, an dem der User eine GESCOPTE Rolle hat. Vorher
# erzwang ein fest verdrahteter oidc-audience-mapper auf 'access-backend' die
# aud bedingungslos, also konnte jeder User den externen Exchange durchfuehren.
ensure_client_role "$FE" "$FE_TOK" "$FE_REALM" "$AUD_UUID" "selfservice"

ACCESS_SCOPE_ID=$(ensure_scope "$FE" "$FE_TOK" "$FE_REALM" "$ACCESS_SCOPE")
set_role_scope_mappings "$FE" "$FE_TOK" "$FE_REALM" "$ACCESS_SCOPE_ID" "$AUD_UUID" "selfservice"
ensure_requested_tenant_mapper "$FE" "$FE_TOK" "$FE_REALM" "$ACCESS_SCOPE_ID"

# --- Interner Token Exchange: Gateway-Kette -----------------------------------
# Zweiter, in sich geschlossener Exchange innerhalb des Frontend-Realms: ein
# Self-Service-Portal tauscht sein Token gegen ein auf eine Ziel-Domain
# zugeschnittenes Token, das ein Gateway ausstellt.
FE_DOMAIN_UUIDS=""
for entry in "${FE_DOMAINS[@]}"; do
  DOM="${entry%%:*}"
  ROLES="${entry#*:}"

  step "Ziel-Domain '$DOM'"

  DOM_JSON=$(jq -nc --arg id "$DOM" '{
    clientId:$id, enabled:true, protocol:"openid-connect",
    publicClient:false,
    standardFlowEnabled:false, directAccessGrantsEnabled:false,
    implicitFlowEnabled:false, serviceAccountsEnabled:false}')
  DOM_UUID=$(ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$DOM" "$DOM_JSON")

  IFS=',' read -ra ROLE_LIST <<<"$ROLES"
  for r in "${ROLE_LIST[@]}"; do
    ensure_client_role "$FE" "$FE_TOK" "$FE_REALM" "$DOM_UUID" "$r"
  done

  DOM_SCOPE_ID=$(ensure_scope "$FE" "$FE_TOK" "$FE_REALM" "$DOM")
  set_role_scope_mappings "$FE" "$FE_TOK" "$FE_REALM" "$DOM_SCOPE_ID" "$DOM_UUID" "$ROLES"
  ensure_hardcoded_claim_mapper "$FE" "$FE_TOK" "$FE_REALM" "$DOM_SCOPE_ID" "domain" "$DOM"
  # Kein Audience-Mapper hier: aud entsteht ueber den eingebauten
  # AudienceResolveProtocolMapper aus dem Client Scope 'roles', der jeden
  # Client in die aud schreibt, in dem der User aufgeloeste Rollen hat. Der
  # audience-Parameter des Exchange filtert diese Menge nur
  # (TokenManager.restrictRequestedAudience), er fuegt nichts hinzu. Deshalb
  # sind die Rollen tragend, und ein eigener Audience-Mapper ist ueberfluessig.

  FE_DOMAIN_UUIDS="$FE_DOMAIN_UUIDS $DOM:$DOM_SCOPE_ID:$DOM_UUID"
done

step "Gateway-Client '$GATEWAY'"
GATEWAY_JSON=$(jq -nc --arg id "$GATEWAY" --arg sec "$SEC_GATEWAY" '{
  clientId:$id, enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  implicitFlowEnabled:false, serviceAccountsEnabled:false,
  fullScopeAllowed:false,
  attributes:{"standard.token.exchange.enabled":"true"}}')
GATEWAY_UUID=$(ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$GATEWAY" "$GATEWAY_JSON")
# fullScopeAllowed:false wirkt hier anders als beim Backend-Requester. Solange
# der Aufrufer audience mitschickt, filtert restrictRequestedAudience ohnehin
# auf die angeforderte Domain. Der Schalter greift genau dann, wenn audience
# weggelassen wird - dann laeuft der Filter nicht, und mit On truege das Token
# jede Client-Rolle des Users.

for entry in $FE_DOMAIN_UUIDS; do
  DOM="${entry%%:*}"; rest="${entry#*:}"; SID="${rest%%:*}"
  # Optional statt Default: bei Default resolvten immer beide Domains, aud
  # truege beide, und die Zuschneidung haenge allein am audience-Parameter.
  # So haengt sie sichtbar am angeforderten scope=.
  assign_optional_scope "$FE" "$FE_TOK" "$FE_REALM" "$GATEWAY_UUID" "$SID" "$DOM"
done

# access-backend als Optional: gateway ist jetzt auch Requester des externen
# Exchange zum Backend (Schritt 02), nicht nur des internen zur Ziel-Domain.
assign_optional_scope "$FE" "$FE_TOK" "$FE_REALM" "$GATEWAY_UUID" "$ACCESS_SCOPE_ID" "$ACCESS_SCOPE"

step "Service-Scopes am Gateway (Buchungs-Markierung)"
# Reine Marker-Scopes ohne Role Scope Mappings: sie tragen selbst keine Berechtigung,
# sondern werden vom Frontend/BFF anhand der Buchung (docs/buchungen.csv) gezielt beim
# externen Exchange (Schritt 02) angefordert und landen unveraendert im scope-Claim von
# token2. Das Backend liest sie dort wieder aus (Booking-Restriction-Mapper) - der
# einzige Zweck ist der Transport der Buchung, keine eigene Rolle.
for entry in "${SERVICES[@]}"; do
  SVC="${entry%%:*}"
  SVC_MARK_SCOPE="$SERVICE_SCOPE_PREFIX$SVC"
  SVC_MARK_SCOPE_ID=$(ensure_scope "$FE" "$FE_TOK" "$FE_REALM" "$SVC_MARK_SCOPE")
  assign_optional_scope "$FE" "$FE_TOK" "$FE_REALM" "$GATEWAY_UUID" "$SVC_MARK_SCOPE_ID" "$SVC_MARK_SCOPE"
done

step "SP-Client '$SP_CLIENT'"
SP_JSON=$(jq -nc --arg id "$SP_CLIENT" --arg sec "$SEC_SP" '{
  clientId:$id, enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:true,
  implicitFlowEnabled:false, serviceAccountsEnabled:false,
  fullScopeAllowed:false}')
SP_UUID=$(ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$SP_CLIENT" "$SP_JSON")

# Reihenfolge: der Gateway-Client muss existieren, bevor dieser Mapper seine
# clientId referenzieren kann.
SP_SCOPE_ID=$(ensure_scope "$FE" "$FE_TOK" "$FE_REALM" "$SP_SCOPE")
ensure_audience_mapper "$FE" "$FE_TOK" "$FE_REALM" "$SP_SCOPE_ID" "$GATEWAY"
# Expliziter Audience-Mapper noetig, weil gateway keine Rollen hat und der
# Rollen-Weg (AudienceResolveProtocolMapper) fuer ihn deshalb nicht
# funktioniert. Ohne aud: gateway im SP-Token antwortet der Exchange mit
# access_denied: Client is not within the token audience.
assign_default_scope "$FE" "$FE_TOK" "$FE_REALM" "$SP_UUID" "$SP_SCOPE_ID" "$SP_SCOPE"
# Default statt Optional: aud: gateway ist eine Eigenschaft jedes SP-Tokens,
# sonst muesste der Passwort-Grant scope=to-gateway mitschicken.

step "Lab-User '$LAB_USER'"
LAB_USER_ID=$(ensure_user "$FE" "$FE_TOK" "$FE_REALM" "$LAB_USER")
ensure_password "$FE" "$FE_TOK" "$FE_REALM" "$LAB_USER_ID" "$LAB_PASS"

# Hier - und nur hier - entscheidet sich, was im getauschten Token an Rollen
# ankommt. Aus dem Subject-Token kommen keine Berechtigungen.
for entry in $FE_DOMAIN_UUIDS; do
  DOM="${entry%%:*}"; rest="${entry#*:}"; DOM_UUID="${rest#*:}"
  assign_client_roles_to_user "$FE" "$FE_TOK" "$FE_REALM" "$LAB_USER_ID" "$DOM_UUID" "$DOM"
done

# selfservice am Audience-Ziel-Client: ohne sie resolvt der externe Exchange
# keine Backend-aud fuer diesen User, s. Kommentar am Rollen-Anlegen oben.
assign_client_roles_to_user "$FE" "$FE_TOK" "$FE_REALM" "$LAB_USER_ID" "$AUD_UUID" "selfservice"

# =============================================================================
# Backend-Realm
# =============================================================================
step "Backend-Realm '$BE_REALM'"
ensure_realm "$BE" "$BE_TOK" "$BE_REALM"

# --- Identity Provider -------------------------------------------------------
IDP_JSON=$(jq -nc \
  --arg alias "$IDP_ALIAS" --arg iss "$FE_ISSUER" --arg jwks "$FE_JWKS" \
  --arg cid "$BE_ISSUER" --arg sec "$SEC_AUDIENCE" '{
  alias:$alias, providerId:"oidc", enabled:true,
  config:{
    issuer:$iss,
    authorizationUrl:($iss + "/protocol/openid-connect/auth"),
    tokenUrl:($iss + "/protocol/openid-connect/token"),
    useJwksUrl:"true", jwksUrl:$jwks, validateSignature:"true",
    clientId:$cid, clientSecret:$sec, clientAuthMethod:"client_secret_post",
    jwtAuthorizationGrantEnabled:"true",
    jwtAuthorizationGrantAssertionReuseAllowed:"false",
    jwtAuthorizationGrantMaxAllowedAssertionExpiration:"600"
  }}')
req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/identity-provider/instances/$IDP_ALIAS"
if [ "$RC" = "200" ]; then
  req "$BE" "$BE_TOK" PUT "/admin/realms/$BE_REALM/identity-provider/instances/$IDP_ALIAS" "$IDP_JSON"
  [ "$RC" = "204" ] || die "IdP aktualisieren fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  skip "Identity Provider '$IDP_ALIAS' aktualisiert"
else
  req "$BE" "$BE_TOK" POST "/admin/realms/$BE_REALM/identity-provider/instances" "$IDP_JSON"
  [ "$RC" = "201" ] || die "IdP anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  ok "Identity Provider '$IDP_ALIAS' angelegt"
fi

# --- Ziel-Dienste ------------------------------------------------------------
SCOPE_IDS=""
for entry in "${SERVICES[@]}"; do
  SVC="${entry%%:*}"
  ROLES="${entry#*:}"

  step "Ziel-Dienst '$SVC'"

  # Reiner Resource Server: keine Service Accounts. Als Ziel braucht er keine
  # eigene Identitaet, und der Name service-account-<client> bliebe frei.
  SVC_JSON=$(jq -nc --arg id "$SVC" '{
    clientId:$id, enabled:true, protocol:"openid-connect",
    publicClient:false,
    standardFlowEnabled:false, directAccessGrantsEnabled:false,
    implicitFlowEnabled:false, serviceAccountsEnabled:false}')
  SVC_UUID=$(ensure_client "$BE" "$BE_TOK" "$BE_REALM" "$SVC" "$SVC_JSON")

  IFS=',' read -ra ROLE_LIST <<<"$ROLES"
  for r in "${ROLE_LIST[@]}"; do
    ensure_client_role "$BE" "$BE_TOK" "$BE_REALM" "$SVC_UUID" "$r"
  done

  # Der Client Scope traegt beides: den Audience-Mapper (setzt aud) und die Role
  # Scope Mappings (entscheiden, welche Rollen ueberhaupt ins Token duerfen).
  SVC_SCOPE_ID=$(ensure_scope "$BE" "$BE_TOK" "$BE_REALM" "$SVC")
  ensure_audience_mapper "$BE" "$BE_TOK" "$BE_REALM" "$SVC_SCOPE_ID" "$SVC"

  req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/clients/$SVC_UUID/roles"
  ROLE_JSON=$(cat "$BODY")
  req "$BE" "$BE_TOK" POST \
    "/admin/realms/$BE_REALM/client-scopes/$SVC_SCOPE_ID/scope-mappings/clients/$SVC_UUID" \
    "$ROLE_JSON"
  case "$RC" in
    204|409) ok "Role Scope Mappings gesetzt ($ROLES)" ;;
    *) die "Role Scope Mappings fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac

  SCOPE_IDS="$SCOPE_IDS $SVC:$SVC_SCOPE_ID:$SVC_UUID"
done

# --- Requester-Client --------------------------------------------------------
step "Requester-Client '$BE_REQUESTER' im Backend"

# fullScopeAllowed:false ist entscheidend. Auf true (Keycloak-Default) landen ALLE
# Rollen des Users im Token, unabhaengig vom angeforderten Scope - die Zuschneidung
# ueber scope= waere wirkungslos und beide Dienste bekaemen dieselben Rechte.
BE_DOMAIN_JSON=$(jq -nc --arg id "$BE_REQUESTER" --arg sec "$SEC_BE_REQUESTER" --arg idp "$IDP_ALIAS" '{
  clientId:$id, enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  implicitFlowEnabled:false, serviceAccountsEnabled:false,
  fullScopeAllowed:false,
  attributes:{
    "oauth2.jwt.authorization.grant.enabled":"true",
    "oauth2.jwt.authorization.grant.idp":$idp}}')
BE_DOMAIN_UUID=$(ensure_client "$BE" "$BE_TOK" "$BE_REALM" "$BE_REQUESTER" "$BE_DOMAIN_JSON")

for entry in $SCOPE_IDS; do
  SVC="${entry%%:*}"; rest="${entry#*:}"; SID="${rest%%:*}"
  assign_optional_scope "$BE" "$BE_TOK" "$BE_REALM" "$BE_DOMAIN_UUID" "$SID" "$SVC"
done

# Mapper 2 als Default-Scope am Backend-Requester: verengt token3 auf die im
# scope-Claim der Assertion gebuchten Dienste. Default (nicht optional), damit er bei
# JEDEM jwt-bearer-Grant greift - auch fail-closed, wenn gar kein Dienst-Scope aktiv ist.
BR_SCOPE_ID=$(ensure_scope "$BE" "$BE_TOK" "$BE_REALM" "booking-restriction")
ensure_booking_restriction_mapper "$BE" "$BE_TOK" "$BE_REALM" "$BR_SCOPE_ID"
assign_default_scope "$BE" "$BE_TOK" "$BE_REALM" "$BE_DOMAIN_UUID" "$BR_SCOPE_ID" "booking-restriction"

# --- Ziel-User ---------------------------------------------------------------
step "Ziel-User '$TARGET_USER'"

req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/users?username=$(jq -rn --arg s "$TARGET_USER" '$s|@uri')&exact=true"
BE_USER_ID=$(jq -r '.[0].id // empty' <"$BODY")
BE_USER_SVC=$(jq -r '.[0].serviceAccountClientLink // empty' <"$BODY")

[ -z "$BE_USER_SVC" ] || die "'$TARGET_USER' ist der Service Account von '$BE_USER_SVC' - anderen Namen waehlen (TARGET_USER=...)"

if [ -n "$BE_USER_ID" ]; then
  skip "User existiert: $BE_USER_ID"
else
  # requiredActions leer: offene Actions lassen den Grant spaeter mit
  # 'Account is not fully set up' scheitern.
  req "$BE" "$BE_TOK" POST "/admin/realms/$BE_REALM/users" "$(jq -nc --arg u "$TARGET_USER" '{
    username:$u, enabled:true, emailVerified:true, requiredActions:[]}')"
  [ "$RC" = "201" ] || die "User anlegen fehlgeschlagen (HTTP $RC): $(cat "$BODY")"
  req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/users?username=$(jq -rn --arg s "$TARGET_USER" '$s|@uri')&exact=true"
  BE_USER_ID=$(jq -r '.[0].id // empty' <"$BODY")
  ok "User angelegt: $BE_USER_ID"
fi

# Federated Identity: bindet den Backend-User an den sub des Frontend-lab-user.
# Ohne diesen Eintrag antwortet der Grant mit 'User not found' - er provisioniert nicht.
req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity"
LINKED=$(jq -r --arg i "$IDP_ALIAS" '.[] | select(.identityProvider == $i) | .userId' <"$BODY")
if [ "$LINKED" = "$LAB_USER_ID" ]; then
  skip "bereits verknuepft mit $LAB_USER_ID"
else
  [ -z "$LINKED" ] || req "$BE" "$BE_TOK" DELETE "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity/$IDP_ALIAS"
  req "$BE" "$BE_TOK" POST "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity/$IDP_ALIAS" \
    "$(jq -nc --arg i "$IDP_ALIAS" --arg u "$LAB_USER_ID" --arg n "$TARGET_USER" \
       '{identityProvider:$i, userId:$u, userName:$n}')"
  case "$RC" in
    201|204) ok "verknuepft mit Frontend-sub $LAB_USER_ID" ;;
    *) die "Verknuepfung fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
fi

# Direkte Dienst-Rollen am Ziel-User: das Backend kennt keine Mandanten mehr, nur noch
# "hat dieser User ueberhaupt Rollen fuer diesen Dienst". Welcher Mandant welchen Dienst
# gebucht hat, weiss allein das Frontend/BFF (docs/buchungen.csv) und wird ueber die
# service:*-Scopes im scope-Claim der Assertion transportiert; Mapper 2
# (oidc-booking-restriction-mapper) erzwingt das beim Bau von token3.
for entry in $SCOPE_IDS; do
  SVC="${entry%%:*}"; rest="${entry#*:}"; SVC_UUID="${rest#*:}"
  assign_client_roles_to_user "$BE" "$BE_TOK" "$BE_REALM" "$BE_USER_ID" "$SVC_UUID" "$SVC"
done

# =============================================================================
step "Fertig - die Kette zum Ausprobieren"
cat <<EOF

  FE=$FE
  BE=$BE

  token_sp=\$(curl -s -X POST "\$FE/realms/$FE_REALM/protocol/openid-connect/token" \\
    -d grant_type=password \\
    -d username=$LAB_USER -d password=$LAB_PASS \\
    -d client_id=$SP_CLIENT -d client_secret=$SEC_SP | jq -r .access_token)

  token1=\$(curl -s -X POST "\$FE/realms/$FE_REALM/protocol/openid-connect/token" \\
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \\
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \\
    -d subject_token="\$token_sp" \\
    -d audience=$DOMAIN -d scope=$DOMAIN \\
    -d client_id=$GATEWAY -d client_secret=$SEC_GATEWAY | jq -r .access_token)

  # scope traegt hier die Buchung: das Frontend/BFF liest sie aus der CSV
  # (docs/buchungen.csv) und fordert nur die dort gebuchten service:*-Scopes an.
  token2=\$(curl -s -X POST "\$FE/realms/$FE_REALM/protocol/openid-connect/token" \\
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \\
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \\
    -d subject_token="\$token1" \\
    -d scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}e-rechnung" \\
    -d audience=$BE_ISSUER \\
    -d client_id=$GATEWAY -d client_secret=$SEC_GATEWAY | jq -r .access_token)

  token3=\$(curl -s -X POST "\$BE/realms/$BE_REALM/protocol/openid-connect/token" \\
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \\
    -d assertion="\$token2" \\
    -d scope=e-rechnung \\
    -d client_id=$BE_REQUESTER -d client_secret=$SEC_BE_REQUESTER | jq -r .access_token)

  Fuer den zweiten Dienst token2 neu holen (Assertions gelten genau einmal), dabei
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}fahrtkostenerstattung" setzen und in
  token3 ebenfalls scope=fahrtkostenerstattung.

  Fehlt der passende service:*-Scope in token2 (z.B. nur e-rechnung gebucht, aber
  scope=fahrtkostenerstattung in token3 angefordert), leert der
  Booking-Restriction-Mapper resource_access (fail-closed).

  Zweite Ziel-Domain statt domain-5678: im ersten Schritt audience=domain-1234
  -d scope=domain-1234 setzen - token1 gilt dann fuer domain-1234, token_sp
  muss dafuer nicht neu geholt werden (normales Bearer-Token, kein Einmal-Ticket).

  Pruefen:  ./check-setup.sh

EOF
