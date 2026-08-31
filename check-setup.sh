#!/usr/bin/env bash
#
# Prueft die von setup-realms.sh erzeugte Konfiguration gegen die Admin-API.
# Aendert nichts - reine Diagnose. Exit-Code 1, wenn etwas fehlt.
#
#   ./check-setup.sh
#   DOMAIN=domain-1234 ./check-setup.sh

set -uo pipefail

FE="${FE:-http://localhost:8080}"
BE="${BE:-http://localhost:8081}"
FE_REALM="${FE_REALM:-frontend}"
BE_REALM="${BE_REALM:-Backend-Microservices}"
ADMIN_USER="${ADMIN_USER:-admin}"
ADMIN_PASS="${ADMIN_PASS:-admin}"

DOMAIN="${DOMAIN:-domain-5678}"
IDP_ALIAS="${IDP_ALIAS:-frontend}"
ACCESS_SCOPE="${ACCESS_SCOPE:-access-backend}"
TARGET_USER="${TARGET_USER:-frontend-$DOMAIN}"
SERVICES=(e-rechnung fahrtkostenerstattung)

FE_ISSUER="$FE/realms/$FE_REALM"
BE_ISSUER="$BE/realms/$BE_REALM"

FAILED=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFEHLT\033[0m %s\n' "$1"
         [ -n "${2:-}" ] && printf '        -> %s\n' "$2"; FAILED=$((FAILED+1)); }
warn() { printf '  \033[33mHINWEIS\033[0m %s\n' "$1"; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$1"; }

command -v jq >/dev/null || { echo "FEHLER: jq wird gebraucht (brew install jq)" >&2; exit 1; }

admin_token() {
  curl -sf -X POST "$1/realms/master/protocol/openid-connect/token" \
    -d client_id=admin-cli -d grant_type=password \
    -d "username=$ADMIN_USER" -d "password=$ADMIN_PASS" 2>/dev/null | jq -r '.access_token // empty'
}
uri() { jq -rn --arg s "$1" '$s|@uri'; }

# --- 0 -----------------------------------------------------------------------
head_ "0. Erreichbarkeit und Issuer"
A=$(curl -sf "$FE_ISSUER/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty')
if [ -z "$A" ]; then bad "Frontend-Realm '$FE_REALM' unter $FE nicht erreichbar"
elif [ "$A" = "$FE_ISSUER" ]; then ok "Frontend-Issuer: $A"
else bad "Frontend-Issuer ist '$A', erwartet '$FE_ISSUER'" "KC_HOSTNAME pruefen"; fi

B=$(curl -sf "$BE_ISSUER/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty')
if [ -z "$B" ]; then bad "Backend-Realm '$BE_REALM' unter $BE nicht erreichbar"
elif [ "$B" = "$BE_ISSUER" ]; then ok "Backend-Issuer: $B"
else bad "Backend-Issuer ist '$B', erwartet '$BE_ISSUER'" "KC_HOSTNAME pruefen"; fi

FE_TOK=$(admin_token "$FE"); BE_TOK=$(admin_token "$BE")
[ -n "$FE_TOK" ] || bad "Admin-Login am Frontend fehlgeschlagen"
[ -n "$BE_TOK" ] || bad "Admin-Login am Backend fehlgeschlagen"
{ [ -n "$FE_TOK" ] && [ -n "$BE_TOK" ]; } || { echo; echo "Ohne Admin-Zugang keine weitere Pruefung."; exit 1; }

fa() { curl -sf -H "Authorization: Bearer $FE_TOK" "$FE/admin/realms/$FE_REALM$1" 2>/dev/null; }
ba() { curl -sf -H "Authorization: Bearer $BE_TOK" "$BE/admin/realms/$BE_REALM$1" 2>/dev/null; }

# --- 1 Frontend --------------------------------------------------------------
head_ "1. Frontend-Realm '$FE_REALM'"

if [ "$(fa "/clients?clientId=$(uri "$BE_ISSUER")" | jq 'length')" -gt 0 ] 2>/dev/null; then
  ok "Audience-Client '$BE_ISSUER' vorhanden"
else
  bad "Audience-Client '$BE_ISSUER' fehlt" "Client-ID ist die Issuer-URL des Backends"
fi

SC=$(fa "/client-scopes" | jq --arg n "$ACCESS_SCOPE" '.[] | select(.name==$n)')
if [ -n "$SC" ]; then
  ok "Client Scope '$ACCESS_SCOPE' vorhanden"
  M=$(jq -r '.protocolMappers // [] | .[] | select(.protocolMapper=="oidc-audience-mapper")
      | .config["included.client.audience"] // empty' <<<"$SC")
  [ "$M" = "$BE_ISSUER" ] && ok "Audience-Mapper zeigt auf '$BE_ISSUER'" \
    || bad "Audience-Mapper zeigt auf '${M:-<keiner>}'" "erwartet '$BE_ISSUER'"
else
  bad "Client Scope '$ACCESS_SCOPE' fehlt"
fi

C=$(fa "/clients?clientId=$(uri "$DOMAIN")" | jq '.[0] // empty')
if [ -z "$C" ]; then
  bad "Client '$DOMAIN' fehlt im Realm '$FE_REALM'"
else
  ok "Client '$DOMAIN' vorhanden"
  U=$(jq -r '.id' <<<"$C")
  [ "$(jq -r '.publicClient' <<<"$C")" = "false" ] && ok "confidential" \
    || bad "Client ist public" "public clients duerfen keinen Token Exchange"
  [ "$(jq -r '.serviceAccountsEnabled' <<<"$C")" = "true" ] && ok "Service accounts On" \
    || bad "Service accounts Off" "ohne das gibt es keinen Service-Account-User"
  [ "$(jq -r '.attributes["standard.token.exchange.enabled"] // "false"' <<<"$C")" = "true" ] \
    && ok "Standard token exchange On" \
    || bad "Standard token exchange Off" "sonst: unauthorized_client in Schritt 2"
  if fa "/clients/$U/optional-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null; then
    ok "Scope '$ACCESS_SCOPE' als Optional zugewiesen"
  elif fa "/clients/$U/default-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null; then
    warn "Scope '$ACCESS_SCOPE' ist Default statt Optional - dann traegt schon token1 die Backend-Audience"
  else
    bad "Scope '$ACCESS_SCOPE' nicht zugewiesen"
  fi
  FE_SA_SUB=$(fa "/clients/$U/service-account-user" | jq -r '.id // empty')
  [ -n "$FE_SA_SUB" ] && ok "Service-Account-User: $FE_SA_SUB" || bad "kein Service-Account-User"
fi

# --- 2 Backend ---------------------------------------------------------------
head_ "2. Backend-Realm '$BE_REALM' - Identity Provider"

IDP=$(ba "/identity-provider/instances/$IDP_ALIAS")
if [ -z "$IDP" ]; then
  bad "Identity Provider '$IDP_ALIAS' fehlt"
else
  ok "Identity Provider '$IDP_ALIAS' vorhanden"
  [ "$(jq -r '.enabled' <<<"$IDP")" = "true" ] && ok "enabled" || bad "IdP ist disabled"
  I=$(jq -r '.config.issuer // empty' <<<"$IDP")
  [ "$I" = "$FE_ISSUER" ] && ok "Issuer: $I" \
    || bad "Issuer ist '${I:-<leer>}'" "muss exakt '$FE_ISSUER' sein, sonst: No Identity Provider for provided issuer"
  [ "$(jq -r '.config.jwtAuthorizationGrantEnabled // "false"' <<<"$IDP")" = "true" ] \
    && ok "JWT Authorization Grant On" || bad "JWT Authorization Grant Off"
  J=$(jq -r '.config.jwksUrl // empty' <<<"$IDP")
  if [ -z "$J" ]; then bad "JWKS URL fehlt"
  elif grep -q localhost <<<"$J"; then
    bad "JWKS URL zeigt auf localhost: $J" "aus dem Backend-Container ist das die eigene Instanz"
  else
    ok "JWKS URL: $J"
    if docker compose exec -T backend-keycloak curl -sf "$J" >/dev/null 2>&1; then
      ok "JWKS aus dem Backend-Container erreichbar"
    else
      warn "JWKS aus dem Container nicht pruefbar (im Projektverzeichnis ausfuehren)"
    fi
  fi
  MX=$(jq -r '.config.jwtAuthorizationGrantMaxAllowedAssertionExpiration // "300"' <<<"$IDP")
  LS=$(fa "" | jq -r '.accessTokenLifespan // 300')
  if [ "$MX" -ge "$LS" ] 2>/dev/null; then
    ok "Max assertion expiration ${MX}s >= Frontend-Lifespan ${LS}s"
  else
    bad "Max assertion expiration ${MX}s < Frontend-Lifespan ${LS}s" "die Assertion waere laenger gueltig als erlaubt"
  fi
fi

for SVC in "${SERVICES[@]}"; do
  head_ "2. Ziel-Dienst '$SVC'"
  SC_=$(ba "/clients?clientId=$(uri "$SVC")" | jq '.[0] // empty')
  if [ -z "$SC_" ]; then bad "Client '$SVC' fehlt"; continue; fi
  ok "Client '$SVC' vorhanden"
  SU=$(jq -r '.id' <<<"$SC_")
  R=$(ba "/clients/$SU/roles" | jq -r 'map(.name)|join(", ")')
  [ -n "$R" ] && ok "Rollen: $R" || bad "Client '$SVC' hat keine Rollen"

  SS=$(ba "/client-scopes" | jq --arg n "$SVC" '.[] | select(.name==$n)')
  if [ -z "$SS" ]; then bad "Client Scope '$SVC' fehlt"; continue; fi
  ok "Client Scope '$SVC' vorhanden"
  SSID=$(jq -r '.id' <<<"$SS")
  M=$(jq -r '.protocolMappers // [] | .[] | select(.protocolMapper=="oidc-audience-mapper")
      | .config["included.client.audience"] // empty' <<<"$SS")
  [ "$M" = "$SVC" ] && ok "Audience-Mapper zeigt auf '$SVC'" \
    || bad "Audience-Mapper zeigt auf '${M:-<keiner>}'" "erwartet '$SVC'"
  SM=$(ba "/client-scopes/$SSID/scope-mappings/clients/$SU" | jq -r 'map(.name)|join(", ")')
  [ -n "$SM" ] && ok "Role Scope Mappings: $SM" \
    || bad "Scope '$SVC' hat keine Role Scope Mappings" "ohne die filtert der Scope keine Rollen"
done

head_ "2. Requester-Client '$DOMAIN'"
D=$(ba "/clients?clientId=$(uri "$DOMAIN")" | jq '.[0] // empty')
if [ -z "$D" ]; then
  bad "Client '$DOMAIN' fehlt im Realm '$BE_REALM'"
else
  ok "Client '$DOMAIN' vorhanden"
  DU=$(jq -r '.id' <<<"$D")
  [ "$(jq -r '.publicClient' <<<"$D")" = "false" ] && ok "confidential" || bad "Client ist public"
  [ "$(jq -r '.attributes["oauth2.jwt.authorization.grant.enabled"] // "false"' <<<"$D")" = "true" ] \
    && ok "JWT Authorization Grant On" || bad "JWT Authorization Grant Off"
  AL=$(jq -r '.attributes["oauth2.jwt.authorization.grant.idp"] // empty' <<<"$D")
  grep -q "$IDP_ALIAS" <<<"${AL:-}" && ok "Allowed Identity Providers: $AL" \
    || bad "IdP '$IDP_ALIAS' nicht in der Allow-Liste (aktuell '${AL:-<leer>}')" \
           "sonst: Identity Provider is not allowed for the client"
  # Der entscheidende Schalter fuer die Zuschneidung ueber scope=
  [ "$(jq -r '.fullScopeAllowed' <<<"$D")" = "false" ] && ok "Full scope allowed Off" \
    || bad "Full scope allowed ist On" \
           "dann landen ALLE Rollen des Users im Token, egal welcher Scope angefordert wurde"
  for SVC in "${SERVICES[@]}"; do
    ba "/clients/$DU/optional-client-scopes" | jq -e --arg n "$SVC" 'any(.name==$n)' >/dev/null \
      && ok "Scope '$SVC' als Optional zugewiesen" || bad "Scope '$SVC' nicht zugewiesen"
  done
fi

head_ "2. Ziel-User '$TARGET_USER'"
TU=$(ba "/users?username=$(uri "$TARGET_USER")&exact=true" | jq '.[0] // empty')
if [ -z "$TU" ]; then
  bad "User '$TARGET_USER' fehlt" "./setup-realms.sh ausfuehren"
else
  TUID=$(jq -r '.id' <<<"$TU")
  ok "User vorhanden: $TUID    <- erscheint als sub in token3"
  [ "$(jq -r '.enabled' <<<"$TU")" = "true" ] && ok "enabled" || bad "User ist disabled"
  SVCL=$(jq -r '.serviceAccountClientLink // empty' <<<"$TU")
  [ -z "$SVCL" ] && ok "eigenstaendiger User (kein Service Account)" \
    || bad "User ist der Service Account von '$SVCL'" "das Token erbte dessen Rollen"
  [ "$(jq -r '.requiredActions // [] | length' <<<"$TU")" -eq 0 ] && ok "keine Required Actions" \
    || bad "offene Required Actions" "sonst: Account is not fully set up"
  L=$(ba "/users/$TUID/federated-identity" | jq -r --arg i "$IDP_ALIAS" \
      '.[] | select(.identityProvider==$i) | .userId')
  if [ -z "$L" ]; then bad "keine Federated Identity fuer '$IDP_ALIAS'"
  elif [ "$L" = "${FE_SA_SUB:-}" ]; then ok "verknuepft mit Frontend-sub $L"
  else bad "verknuepft mit '$L', Frontend-sub ist '${FE_SA_SUB:-unbekannt}'" "./setup-realms.sh erneut ausfuehren"; fi
  RM=$(ba "/users/$TUID/role-mappings")
  for SVC in "${SERVICES[@]}"; do
    RR=$(jq -r --arg c "$SVC" '.clientMappings[$c].mappings // [] | map(.name) | join(", ")' <<<"${RM:-{\}}")
    [ -n "$RR" ] && ok "Rollen auf '$SVC': $RR" \
      || bad "keine Rollen auf '$SVC'" "dann ist resource_access im Token leer"
  done
fi

# --- Default-Rollen ----------------------------------------------------------
head_ "2. Default-Rollen des Realms (bekommt jeder neue User automatisch)"
DR=$(ba "" | jq -r '.defaultRole.id // empty')
if [ -z "$DR" ]; then
  warn "nicht ermittelbar"
else
  CO=$(ba "/roles-by-id/$DR/composites")
  RN=$(jq -r '[.[] | select(.clientRole==false) | .name] | join(", ")' <<<"${CO:-[]}")
  echo "  Realm-Rollen : ${RN:-<keine>}"
  if [ "$(jq '[.[] | select(.clientRole==true)] | length' <<<"${CO:-[]}")" -gt 0 ]; then
    echo "  Client-Rollen:"
    jq -r '.[] | select(.clientRole==true) | .containerId + "|" + .name' <<<"$CO" \
    | while IFS='|' read -r cid rn; do
        cn=$(ba "/clients/$cid" | jq -r '.clientId // empty')
        echo "                 ${cn:-$cid}: $rn"
      done
    warn "Client-Rollen in den Default-Rollen landen bei JEDEM User - haeufigste Erklaerung fuer unerwartete Eintraege in resource_access"
  else
    echo "  Client-Rollen: <keine>"
  fi
fi

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mAlles gruen.\033[0m Weiter mit Teil 3 in SETUP.md oder den Bruno-Requests.\n'
else
  printf '\033[31m%s Punkt(e) offen.\033[0m Siehe die FEHLT-Zeilen oben.\n' "$FAILED"
  exit 1
fi
