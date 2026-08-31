#!/usr/bin/env bash
#
# Baut die komplette Token-Exchange-Kette in beiden Keycloak-Instanzen auf.
#
#   Frontend-Realm  frontend
#     domain-5678                Service-Account-Client, darf Token Exchange
#     <backend-issuer-url>       Client, der nur als Audience-Ziel existiert
#     access-backend             Client Scope mit Audience-Mapper darauf
#
#   Backend-Realm   Backend-Microservices
#     frontend                   Identity Provider, akzeptiert JWT Authorization Grants
#     e-rechnung                 Ziel-Dienst mit Rollen reader, writer
#     fahrtkostenerstattung      Ziel-Dienst mit Rollen reader, approver
#     e-rechnung / fahrt...      Client Scopes: Audience-Mapper + Role Scope Mappings
#     domain-5678                Requester-Client, loest die Assertion ein
#     frontend-domain-5678       Ziel-User, verknuepft mit dem Frontend-Service-Account
#
# Idempotent: mehrfaches Ausfuehren ist unschaedlich.
#
#   ./setup-realms.sh              fehlende Objekte ergaenzen
#   ./setup-realms.sh --recreate   beide Realms vorher loeschen und neu aufbauen

set -uo pipefail

# --- Konfiguration -----------------------------------------------------------
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

FE_ISSUER="$FE/realms/$FE_REALM"
BE_ISSUER="$BE/realms/$BE_REALM"
# Aus dem Backend-Container heraus zeigt localhost auf das Backend selbst. Fuer den
# JWKS-Abruf braucht es deshalb den Docker-Servicenamen, waehrend der issuer die
# localhost-URL bleiben muss - sie steht so im Token.
FE_JWKS="${FE_JWKS:-http://frontend-keycloak:8080/realms/$FE_REALM/protocol/openid-connect/certs}"

# Feste Lab-Secrets. Bewusst nicht generiert, damit die Bruno-Environment ohne
# Abtippen laeuft. Fuer ein Testlabor in Ordnung, fuer sonst nichts.
SEC_AUDIENCE="${SEC_AUDIENCE:-lab-backend-audience-secret}"
SEC_FE_DOMAIN="${SEC_FE_DOMAIN:-lab-frontend-domain-5678-secret}"
SEC_BE_DOMAIN="${SEC_BE_DOMAIN:-lab-backend-domain-5678-secret}"

# Ziel-Dienste:  name:rolle,rolle
SERVICES=(
  "e-rechnung:reader,writer"
  "fahrtkostenerstattung:reader,approver"
)

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

# =============================================================================
# Frontend-Realm
# =============================================================================
step "Frontend-Realm '$FE_REALM'"
ensure_realm "$FE" "$FE_TOK" "$FE_REALM"

# Client, dessen Client-ID die Issuer-URL des Backends IST. Der Audience-Mapper
# kann nur die ID eines existierenden Clients in aud schreiben, und aud muss laut
# RFC 7523 der Issuer des empfangenden Servers sein. Daher dieser Name.
AUD_JSON=$(jq -nc --arg id "$BE_ISSUER" --arg sec "$SEC_AUDIENCE" '{
  clientId:$id, name:"backend", enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  serviceAccountsEnabled:false, implicitFlowEnabled:false}')
ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$BE_ISSUER" "$AUD_JSON" >/dev/null

ACCESS_SCOPE_ID=$(ensure_scope "$FE" "$FE_TOK" "$FE_REALM" "$ACCESS_SCOPE")
ensure_audience_mapper "$FE" "$FE_TOK" "$FE_REALM" "$ACCESS_SCOPE_ID" "$BE_ISSUER"

# Der Service-Account-Client. standard.token.exchange.enabled ist das Flag, ohne
# das Schritt 2 mit unauthorized_client antwortet.
FE_DOMAIN_JSON=$(jq -nc --arg id "$DOMAIN" --arg sec "$SEC_FE_DOMAIN" '{
  clientId:$id, enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  implicitFlowEnabled:false, serviceAccountsEnabled:true,
  attributes:{"standard.token.exchange.enabled":"true"}}')
FE_DOMAIN_UUID=$(ensure_client "$FE" "$FE_TOK" "$FE_REALM" "$DOMAIN" "$FE_DOMAIN_JSON")

assign_optional_scope "$FE" "$FE_TOK" "$FE_REALM" "$FE_DOMAIN_UUID" "$ACCESS_SCOPE_ID" "$ACCESS_SCOPE"

req "$FE" "$FE_TOK" GET "/admin/realms/$FE_REALM/clients/$FE_DOMAIN_UUID/service-account-user"
FE_SA_SUB=$(jq -r '.id // empty' <"$BODY")
[ -n "$FE_SA_SUB" ] || die "kein Service-Account-User an '$DOMAIN' - ist serviceAccountsEnabled gesetzt?"
ok "Service-Account-User: $FE_SA_SUB"

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
step "Requester-Client '$DOMAIN' im Backend"

# fullScopeAllowed:false ist entscheidend. Auf true (Keycloak-Default) landen ALLE
# Rollen des Users im Token, unabhaengig vom angeforderten Scope - die Zuschneidung
# ueber scope= waere wirkungslos und beide Dienste bekaemen dieselben Rechte.
BE_DOMAIN_JSON=$(jq -nc --arg id "$DOMAIN" --arg sec "$SEC_BE_DOMAIN" --arg idp "$IDP_ALIAS" '{
  clientId:$id, enabled:true, protocol:"openid-connect",
  publicClient:false, secret:$sec,
  standardFlowEnabled:false, directAccessGrantsEnabled:false,
  implicitFlowEnabled:false, serviceAccountsEnabled:false,
  fullScopeAllowed:false,
  attributes:{
    "oauth2.jwt.authorization.grant.enabled":"true",
    "oauth2.jwt.authorization.grant.idp":$idp}}')
BE_DOMAIN_UUID=$(ensure_client "$BE" "$BE_TOK" "$BE_REALM" "$DOMAIN" "$BE_DOMAIN_JSON")

for entry in $SCOPE_IDS; do
  SVC="${entry%%:*}"; rest="${entry#*:}"; SID="${rest%%:*}"
  assign_optional_scope "$BE" "$BE_TOK" "$BE_REALM" "$BE_DOMAIN_UUID" "$SID" "$SVC"
done

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

# Federated Identity: bindet den Backend-User an den sub des Frontend-Service-Accounts.
# Ohne diesen Eintrag antwortet der Grant mit 'User not found' - er provisioniert nicht.
req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity"
LINKED=$(jq -r --arg i "$IDP_ALIAS" '.[] | select(.identityProvider == $i) | .userId' <"$BODY")
if [ "$LINKED" = "$FE_SA_SUB" ]; then
  skip "bereits verknuepft mit $FE_SA_SUB"
else
  [ -z "$LINKED" ] || req "$BE" "$BE_TOK" DELETE "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity/$IDP_ALIAS"
  req "$BE" "$BE_TOK" POST "/admin/realms/$BE_REALM/users/$BE_USER_ID/federated-identity/$IDP_ALIAS" \
    "$(jq -nc --arg i "$IDP_ALIAS" --arg u "$FE_SA_SUB" --arg n "$TARGET_USER" \
       '{identityProvider:$i, userId:$u, userName:$n}')"
  case "$RC" in
    201|204) ok "verknuepft mit Frontend-sub $FE_SA_SUB" ;;
    *) die "Verknuepfung fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
fi

# Rollen: hier - und nur hier - entscheidet sich, was die Kette im Backend darf.
# Aus dem Frontend kommen keine Berechtigungen, die Assertion transportiert nur Identitaet.
for entry in $SCOPE_IDS; do
  SVC="${entry%%:*}"; rest="${entry#*:}"; SVC_UUID="${rest#*:}"
  req "$BE" "$BE_TOK" GET "/admin/realms/$BE_REALM/clients/$SVC_UUID/roles"
  ROLE_JSON=$(cat "$BODY")
  req "$BE" "$BE_TOK" POST "/admin/realms/$BE_REALM/users/$BE_USER_ID/role-mappings/clients/$SVC_UUID" "$ROLE_JSON"
  case "$RC" in
    204|409) ok "Rollen von '$SVC' zugewiesen" ;;
    *) die "Rollenzuweisung '$SVC' fehlgeschlagen (HTTP $RC): $(cat "$BODY")" ;;
  esac
done

# =============================================================================
step "Fertig - die Kette zum Ausprobieren"
cat <<EOF

  FE=$FE
  BE=$BE

  token1=\$(curl -s -X POST "\$FE/realms/$FE_REALM/protocol/openid-connect/token" \\
    -d grant_type=client_credentials \\
    -d client_id=$DOMAIN -d client_secret=$SEC_FE_DOMAIN | jq -r .access_token)

  token2=\$(curl -s -X POST "\$FE/realms/$FE_REALM/protocol/openid-connect/token" \\
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \\
    -d subject_token_type=urn:ietf:params:oauth:token-type:access_token \\
    -d subject_token="\$token1" \\
    -d scope=$ACCESS_SCOPE \\
    -d audience=$BE_ISSUER \\
    -d client_id=$DOMAIN -d client_secret=$SEC_FE_DOMAIN | jq -r .access_token)

  token3=\$(curl -s -X POST "\$BE/realms/$BE_REALM/protocol/openid-connect/token" \\
    -d grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \\
    -d assertion="\$token2" \\
    -d scope=e-rechnung \\
    -d client_id=$DOMAIN -d client_secret=$SEC_BE_DOMAIN | jq -r .access_token)

  Fuer den zweiten Dienst token2 neu holen (Assertions gelten genau einmal)
  und scope=fahrtkostenerstattung setzen.

  Pruefen:  ./check-setup.sh

EOF
