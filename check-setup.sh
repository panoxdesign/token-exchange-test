#!/usr/bin/env bash
#
# Prueft die von setup-realms.sh erzeugte Konfiguration gegen die Admin-API.
# Aendert nichts - reine Diagnose. Exit-Code 1, wenn etwas fehlt.
#
# Deckt beide Stufen der Kette ab: den internen Exchange innerhalb des
# Frontend-Realms ueber ein Gateway (Abschnitt 1b) und den cross-realm Exchange
# (Frontend -> Backend, Abschnitte 0/1/2).
#
#   ./check-setup.sh
#   DOMAIN=domain-1234 ./check-setup.sh

set -uo pipefail

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
# Ziel-Dienste:  name:rolle,rolle  (muss zu setup-realms.sh passen) - die Rollen sind hier
# zugleich die erwarteten DIREKTEN Rollen des Backend-Ziel-Users (keine Mandanten-Gruppen
# mehr, s. docs/buchungen.csv).
SERVICES=(
  "e-rechnung:reader,writer"
  "fahrtkostenerstattung:reader,approver"
)
SERVICE_SCOPE_PREFIX="${SERVICE_SCOPE_PREFIX:-service:}"

GATEWAY="${GATEWAY:-gateway}"
SP_CLIENT="${SP_CLIENT:-self-service-portal}"
SP_SCOPE="${SP_SCOPE:-to-gateway}"
LAB_USER="${LAB_USER:-lab-user}"
FE_DOMAINS=(domain-5678 domain-1234)
# Erwartete lab-user-Rollen je Domain (muss zu setup-realms.sh LAB_USER_DOMAIN_ROLES passen) -
# bewusst asymmetrisch: nur domain-5678 traegt selfservice, das ist der Kern des externen Gates.
LAB_USER_DOMAIN_ROLES=(
  "domain-5678:admin,selfservice"
  "domain-1234:admin"
)

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

# Default-Rollen eines Realms - inhaltlich identisch fuer Frontend und Backend,
# deshalb eine Funktion statt zweimal desselben Blocks (accessor: "fa" oder "ba").
default_role_check() { # accessor title [zusatz]
  # Der dritte Parameter ist optional: nur die Gateway-Kette schneidet ueber
  # audience= zu, die Backend-Kette loest ihre Assertion ohne diesen Parameter ein.
  local accessor="$1" title="$2" zusatz="${3:-}"
  head_ "$title"
  local dr co rn
  dr=$($accessor "" | jq -r '.defaultRole.id // empty')
  if [ -z "$dr" ]; then
    warn "nicht ermittelbar"
    return
  fi
  co=$($accessor "/roles-by-id/$dr/composites")
  rn=$(jq -r '[.[] | select(.clientRole==false) | .name] | join(", ")' <<<"${co:-[]}")
  echo "  Realm-Rollen : ${rn:-<keine>}"
  if [ "$(jq '[.[] | select(.clientRole==true)] | length' <<<"${co:-[]}")" -gt 0 ]; then
    echo "  Client-Rollen:"
    jq -r '.[] | select(.clientRole==true) | .containerId + "|" + .name' <<<"$co" \
    | while IFS='|' read -r cid rn2; do
        cn=$($accessor "/clients/$cid" | jq -r '.clientId // empty')
        echo "                 ${cn:-$cid}: $rn2"
      done
    warn "Client-Rollen in den Default-Rollen landen bei JEDEM User - haeufigste Erklaerung fuer unerwartete Eintraege in resource_access.${zusatz:+ $zusatz}"
  else
    echo "  Client-Rollen: <keine>"
  fi
}

# Vier-Flags-Pruefung fuer Review L1: neben dem einen vorgesehenen Grant duerfen keine weiteren
# Grants aktiv sein, sonst koennte ein Aufrufer ueber diesen weiteren Grant einen selbstgebauten
# subject_token/assertion-Parameter mitschicken (die Mapper pruefen zwar grant_type und - bei
# RTM/Gate - die Signatur, aber der Grant-Kontext soll erst gar nicht offenstehen). Fuer beide
# Realms nutzbar, deshalb eine Funktion statt zweimal desselben Blocks.
no_other_grants() { # clientJson label
  local clientJson="$1" label="$2" sf da im sa aktiv=""
  sf=$(jq -r '.standardFlowEnabled' <<<"$clientJson")
  da=$(jq -r '.directAccessGrantsEnabled' <<<"$clientJson")
  im=$(jq -r '.implicitFlowEnabled' <<<"$clientJson")
  sa=$(jq -r '.serviceAccountsEnabled' <<<"$clientJson")
  [ "$sf" = "true" ] && aktiv="$aktiv standardFlowEnabled"
  [ "$da" = "true" ] && aktiv="$aktiv directAccessGrantsEnabled"
  [ "$im" = "true" ] && aktiv="$aktiv implicitFlowEnabled"
  [ "$sa" = "true" ] && aktiv="$aktiv serviceAccountsEnabled"
  if [ -z "$aktiv" ]; then
    ok "keine weiteren Grants aktiv ($label)"
  else
    bad "weitere Grants aktiv:$aktiv" \
        "ueber einen weiteren Grant koennte ein Aufrufer einen selbstgebauten subject_token- bzw. assertion-Parameter mitschicken (Review L1)"
  fi
}

# Client-IDs (zeilenweise), an die scopeName als Default- oder Optional-Client-Scope haengt.
# accessor ist "fa" oder "ba". Fuer beide Realms nutzbar, deshalb eine Funktion statt zweimal
# desselben Blocks.
clients_with_scope() { # accessor scopeName
  local accessor="$1" scopeName="$2" id cid
  $accessor "/clients?max=200" | jq -r '.[] | .id + "|" + .clientId' \
  | while IFS='|' read -r id cid; do
      if $accessor "/clients/$id/default-client-scopes" | jq -e --arg n "$scopeName" 'any(.name==$n)' >/dev/null \
         || $accessor "/clients/$id/optional-client-scopes" | jq -e --arg n "$scopeName" 'any(.name==$n)' >/dev/null; then
        echo "$cid"
      fi
    done
}

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

AUDC=$(fa "/clients?clientId=$(uri "$BE_ISSUER")" | jq '.[0] // empty')
if [ -z "$AUDC" ]; then
  bad "Audience-Client '$BE_ISSUER' fehlt" "Client-ID ist die Issuer-URL des Backends"
else
  ok "Audience-Client '$BE_ISSUER' vorhanden"
fi

SC=$(fa "/client-scopes" | jq --arg n "$ACCESS_SCOPE" '.[] | select(.name==$n)')
if [ -n "$SC" ]; then
  ok "Client Scope '$ACCESS_SCOPE' vorhanden"
  jq -e '.protocolMappers // [] | any(.protocolMapper=="oidc-requested-tenant-mapper")' <<<"$SC" >/dev/null \
    && ok "RTM-Mapper (oidc-requested-tenant-mapper) vorhanden" \
    || bad "RTM-Mapper fehlt" "ohne ihn bekommt token2 keinen tenant-Claim"
  jq -e --arg a "$BE_ISSUER" '.protocolMappers // [] | any(.protocolMapper=="oidc-selfservice-exchange-gate"
      and .config["included.client.audience"]==$a)' <<<"$SC" >/dev/null \
    && ok "Selfservice-Exchange-Gate-Mapper zeigt auf '$BE_ISSUER'" \
    || bad "Selfservice-Exchange-Gate-Mapper fehlt oder zeigt auf falsche Audience" \
           "ohne ihn resolvt der externe Exchange keine Backend-aud - unabhaengig von statischen Rollen, der Mapper liest den AKTIVEN Mandanten aus token1"
else
  bad "Client Scope '$ACCESS_SCOPE' fehlt"
fi

# Konfigurationsdrift zu L1: der Scope traegt RTM- und Gate-Mapper und darf deshalb nur an den
# Exchange-Requester haengen.
TREFFER=$(clients_with_scope fa "$ACCESS_SCOPE")
if [ -z "$TREFFER" ]; then
  bad "Scope '$ACCESS_SCOPE' an keinem Client zugewiesen"
elif [ "$TREFFER" = "$GATEWAY" ]; then
  ok "Scope '$ACCESS_SCOPE' haengt an genau einem Client: '$GATEWAY'"
else
  bad "Scope '$ACCESS_SCOPE' haengt an: $(tr '\n' ' ' <<<"$TREFFER")" \
      "Gate-/RTM-Mapper liefen dann in einem fremden Grant-Kontext - der Mapper prueft zwar grant_type und Signatur, aber der Scope gehoert trotzdem nur an den Exchange-Requester (Review L1)"
fi

C=$(fa "/clients?clientId=$(uri "$DOMAIN")" | jq '.[0] // empty')
if [ -z "$C" ]; then
  bad "Client '$DOMAIN' fehlt im Realm '$FE_REALM'"
else
  ok "Client '$DOMAIN' vorhanden"
  U=$(jq -r '.id' <<<"$C")
  [ "$(jq -r '.publicClient' <<<"$C")" = "false" ] && ok "confidential" \
    || bad "Client ist public"
  [ "$(jq -r '.serviceAccountsEnabled' <<<"$C")" = "false" ] \
    && ok "Service accounts Off (reine Ziel-Domain)" \
    || bad "Service accounts On" "domain-5678 soll keinen eigenen Service Account mehr haben"
  [ "$(jq -r '.attributes["standard.token.exchange.enabled"] // "false"' <<<"$C")" = "false" ] \
    && ok "Standard token exchange Off" \
    || bad "Standard token exchange On" "domain-5678 soll keinen Exchange mehr selbst anstossen"
  if fa "/clients/$U/optional-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null \
     || fa "/clients/$U/default-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null; then
    warn "Scope '$ACCESS_SCOPE' ist '$DOMAIN' weiterhin zugewiesen - Altlast aus der Zeit, als die Domain den externen Exchange selbst ausloeste"
  else
    ok "Scope '$ACCESS_SCOPE' nicht zugewiesen"
  fi
fi

# Vertrauensanker fuer den RTM-Mapper: der Domain-Scope selbst (Name = Domain)
# muss den Hardcoded-Claim-Mapper 'domain=<Name>' tragen, sonst hat token1 gar
# keinen domain-Claim, aus dem der RTM-Mapper 'tenant' ableiten koennte.
DSC=$(fa "/client-scopes" | jq --arg n "$DOMAIN" '.[] | select(.name==$n)')
if [ -n "$DSC" ]; then
  V=$(jq -r --arg n "domain" '.protocolMappers // [] | .[]
      | select(.protocolMapper=="oidc-hardcoded-claim-mapper" and .config["claim.name"]==$n)
      | .config["claim.value"] // empty' <<<"$DSC")
  [ "$V" = "$DOMAIN" ] && ok "Domain-Scope '$DOMAIN' traegt Hardcoded-Claim-Mapper 'domain=$DOMAIN'" \
    || bad "Hardcoded-Claim-Mapper 'domain' auf Scope '$DOMAIN' fehlt oder zeigt auf '${V:-<keiner>}'" \
      "Vertrauensanker fuer den tenant-Claim in token2 - ohne ihn kann der RTM-Mapper nichts ableiten"
else
  bad "Domain-Scope '$DOMAIN' fehlt"
fi

# --- 1b Frontend: interner Token Exchange ueber ein Gateway ------------------
head_ "1b. Frontend-Realm - interner Token Exchange"

GW=$(fa "/clients?clientId=$(uri "$GATEWAY")" | jq '.[0] // empty')
if [ -z "$GW" ]; then
  bad "Client '$GATEWAY' fehlt im Realm '$FE_REALM'"
else
  ok "Client '$GATEWAY' vorhanden"
  GU=$(jq -r '.id' <<<"$GW")
  [ "$(jq -r '.publicClient' <<<"$GW")" = "false" ] && ok "confidential" \
    || bad "Client ist public" "public clients duerfen keinen Token Exchange"
  [ "$(jq -r '.attributes["standard.token.exchange.enabled"] // "false"' <<<"$GW")" = "true" ] \
    && ok "Standard token exchange On" \
    || bad "Standard token exchange Off" "sonst: Standard token exchange is not enabled for the requested client"
  [ "$(jq -r '.fullScopeAllowed' <<<"$GW")" = "false" ] && ok "Full scope allowed Off" \
    || bad "Full scope allowed ist On" \
           "greift, wenn der Aufrufer audience weglaesst - dann traegt das Token jede Client-Rolle des Users"
  no_other_grants "$GW" "nur Token Exchange"
  # Der Weg zur aud fuehrt hier ueber Rollen, nicht ueber einen Audience-Mapper:
  # der Client Scope 'roles' bringt den eingebauten AudienceResolveProtocolMapper mit.
  fa "/clients/$GU/default-client-scopes" | jq -e 'any(.name=="roles")' >/dev/null \
    && ok "Client Scope 'roles' als Default zugewiesen" \
    || bad "Client Scope 'roles' nicht als Default zugewiesen" \
           "darin sitzt der AudienceResolveProtocolMapper, ueber den die aud ueberhaupt entsteht - ohne ihn: Requested audience not available"
  for DM in "${FE_DOMAINS[@]}"; do
    if fa "/clients/$GU/optional-client-scopes" | jq -e --arg n "$DM" 'any(.name==$n)' >/dev/null; then
      ok "Scope '$DM' als Optional zugewiesen"
    elif fa "/clients/$GU/default-client-scopes" | jq -e --arg n "$DM" 'any(.name==$n)' >/dev/null; then
      warn "Scope '$DM' ist Default statt Optional - dann resolvte immer jede Domain, die Zuschneidung haenge dann allein am audience-Parameter statt sichtbar am angeforderten scope="
    else
      bad "Scope '$DM' nicht zugewiesen"
    fi
  done
  if fa "/clients/$GU/optional-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null; then
    ok "Scope '$ACCESS_SCOPE' als Optional zugewiesen"
  elif fa "/clients/$GU/default-client-scopes" | jq -e --arg n "$ACCESS_SCOPE" 'any(.name==$n)' >/dev/null; then
    warn "Scope '$ACCESS_SCOPE' ist Default statt Optional"
  else
    bad "Scope '$ACCESS_SCOPE' nicht zugewiesen" "ohne ihn kann gateway keinen externen Exchange zum Backend anstossen"
  fi
  for entry in "${SERVICES[@]}"; do
    SVC="${entry%%:*}"
    SM="$SERVICE_SCOPE_PREFIX$SVC"
    if fa "/clients/$GU/optional-client-scopes" | jq -e --arg n "$SM" 'any(.name==$n)' >/dev/null; then
      ok "Scope '$SM' als Optional zugewiesen"
    elif fa "/clients/$GU/default-client-scopes" | jq -e --arg n "$SM" 'any(.name==$n)' >/dev/null; then
      warn "Scope '$SM' ist Default statt Optional - dann waere jeder Dienst immer 'gebucht', unabhaengig von der CSV"
    else
      bad "Scope '$SM' nicht zugewiesen" "ohne ihn kann '$GATEWAY' die Buchung dieses Dienstes nicht in token2 transportieren"
    fi
  done
fi

SP=$(fa "/clients?clientId=$(uri "$SP_CLIENT")" | jq '.[0] // empty')
if [ -z "$SP" ]; then
  bad "Client '$SP_CLIENT' fehlt im Realm '$FE_REALM'"
else
  ok "Client '$SP_CLIENT' vorhanden"
  SPU=$(jq -r '.id' <<<"$SP")
  [ "$(jq -r '.publicClient' <<<"$SP")" = "false" ] && ok "confidential" || bad "Client ist public"
  [ "$(jq -r '.directAccessGrantsEnabled' <<<"$SP")" = "true" ] && ok "Direct Access Grants On" \
    || bad "Direct Access Grants Off" "ohne das gibt es kein Token per Passwort-Grant"

  SPSC=$(fa "/client-scopes" | jq --arg n "$SP_SCOPE" '.[] | select(.name==$n)')
  if [ -n "$SPSC" ]; then
    ok "Client Scope '$SP_SCOPE' vorhanden"
    M=$(jq -r '.protocolMappers // [] | .[] | select(.protocolMapper=="oidc-audience-mapper")
        | .config["included.client.audience"] // empty' <<<"$SPSC")
    [ "$M" = "$GATEWAY" ] && ok "Audience-Mapper zeigt auf '$GATEWAY'" \
      || bad "Audience-Mapper zeigt auf '${M:-<keiner>}'" "sonst: access_denied: Client is not within the token audience"
  else
    bad "Client Scope '$SP_SCOPE' fehlt"
  fi

  if fa "/clients/$SPU/default-client-scopes" | jq -e --arg n "$SP_SCOPE" 'any(.name==$n)' >/dev/null; then
    ok "Scope '$SP_SCOPE' als Default zugewiesen"
  else
    bad "Scope '$SP_SCOPE' nicht als Default zugewiesen" \
        "sonst fehlt die aud im SP-Token, solange der Grant scope= nicht selbst mitschickt"
  fi
fi

for DM in "${FE_DOMAINS[@]}"; do
  head_ "1b. Ziel-Domain '$DM'"
  DC=$(fa "/clients?clientId=$(uri "$DM")" | jq '.[0] // empty')
  if [ -z "$DC" ]; then bad "Client '$DM' fehlt im Realm '$FE_REALM'"; continue; fi
  ok "Client '$DM' vorhanden"
  DCU=$(jq -r '.id' <<<"$DC")

  DMR=$(fa "/clients/$DCU/roles" | jq -r 'map(.name)|join(", ")')
  [ -n "$DMR" ] && ok "Rollen: $DMR" \
    || bad "Client '$DM' hat keine Rollen" "ohne Rollen entsteht keine aud - der Exchange endet in: Requested audience not available"

  DSC=$(fa "/client-scopes" | jq --arg n "$DM" '.[] | select(.name==$n)')
  if [ -z "$DSC" ]; then bad "Client Scope '$DM' fehlt"; continue; fi
  ok "Client Scope '$DM' vorhanden"
  DSCID=$(jq -r '.id' <<<"$DSC")

  DSM=$(fa "/client-scopes/$DSCID/scope-mappings/clients/$DCU" | jq -r 'map(.name)|join(", ")')
  [ -n "$DSM" ] && ok "Role Scope Mappings: $DSM" \
    || bad "Scope '$DM' hat keine Role Scope Mappings" "ohne die filtert der Scope keine Rollen"

  HM=$(jq -r --arg n "domain" '.protocolMappers // [] | .[]
      | select(.protocolMapper=="oidc-hardcoded-claim-mapper" and .config["claim.name"]==$n)' <<<"$DSC")
  if [ -z "$HM" ]; then
    bad "Hardcoded-Claim-Mapper fuer 'domain' fehlt" "ohne ihn fehlt der domain-Claim im getauschten Token"
  else
    HV=$(jq -r '.config["claim.value"] // empty' <<<"$HM")
    [ "$HV" = "$DM" ] && ok "Hardcoded-Claim-Mapper: domain=$HV" \
      || bad "Hardcoded-Claim-Mapper traegt domain=${HV:-<leer>}" "erwartet '$DM'"
  fi
done

head_ "1b. Lab-User '$LAB_USER'"
LU=$(fa "/users?username=$(uri "$LAB_USER")&exact=true" | jq '.[0] // empty')
if [ -z "$LU" ]; then
  bad "User '$LAB_USER' fehlt" "./setup-realms.sh ausfuehren"
else
  LUID=$(jq -r '.id' <<<"$LU")
  ok "User vorhanden: $LUID"
  [ "$(jq -r '.enabled' <<<"$LU")" = "true" ] && ok "enabled" || bad "User ist disabled"
  [ "$(jq -r '.requiredActions // [] | length' <<<"$LU")" -eq 0 ] && ok "keine Required Actions" \
    || bad "offene Required Actions" "sonst: Account is not fully set up"
  EM=$(jq -r '.email // empty' <<<"$LU")
  FN=$(jq -r '.firstName // empty' <<<"$LU")
  LN=$(jq -r '.lastName // empty' <<<"$LU")
  if [ -n "$EM" ] && [ -n "$FN" ] && [ -n "$LN" ]; then
    ok "email/firstName/lastName gesetzt"
  else
    bad "email/firstName/lastName unvollstaendig (email='$EM' firstName='$FN' lastName='$LN')" \
        "das deklarative User Profile loest sonst dynamisch VERIFY_PROFILE aus und der Passwort-Grant scheitert ebenfalls mit 'Account is not fully set up', obwohl requiredActions leer ist. Im Server-Log steht dann error=\"resolve_required_actions\""
  fi
  fa "/users/$LUID/credentials" | jq -e 'any(.type=="password")' >/dev/null \
    && ok "Passwort-Credential vorhanden" \
    || bad "kein Passwort-Credential" "ohne Passwort kein Passwort-Grant"
  RM=$(fa "/users/$LUID/role-mappings")
  # Rollen-Matrix statt reiner Existenzpruefung: der externe Exchange soll nur aus domain-5678
  # gelingen, deshalb muss die Zuweisung EXAKT LAB_USER_DOMAIN_ROLES entsprechen, nicht nur
  # "irgendeine Rolle vorhanden".
  for entry in "${LAB_USER_DOMAIN_ROLES[@]}"; do
    DM="${entry%%:*}"; WANT="${entry#*:}"
    RR=$(jq -r --arg c "$DM" '.clientMappings[$c].mappings // [] | map(.name) | sort | join(",")' <<<"${RM:-{\}}")
    WANTS=$(jq -rn --arg s "$WANT" '$s|split(",")|sort|join(",")')
    [ "$RR" = "$WANTS" ] && ok "Rollen auf '$DM': ${RR//,/, }" \
      || bad "Rollen auf '$DM': '${RR:-<keine>}', erwartet '$WANTS'" \
             "dann ist resource_access im Token fuer diesen Mandanten falsch besetzt"
  done
  # Kern des Gates, separat ausgewiesen: jede Domain OHNE selfservice in LAB_USER_DOMAIN_ROLES
  # darf die Rolle auch tatsaechlich nicht tragen - genau die Unterscheidung, die der
  # Selfservice-Exchange-Gate-Mapper anhand des AKTIVEN Mandanten treffen muss.
  for entry in "${LAB_USER_DOMAIN_ROLES[@]}"; do
    DM="${entry%%:*}"; WANT="${entry#*:}"
    case ",$WANT," in *,selfservice,*) continue ;; esac
    jq -e --arg c "$DM" '.clientMappings[$c].mappings // [] | any(.name=="selfservice") | not' \
      <<<"${RM:-{\}}" >/dev/null \
      && ok "KEINE Rolle 'selfservice' auf '$DM' (Kern des externen Gates)" \
      || bad "Rolle 'selfservice' faelschlich auf '$DM'" \
             "der externe Exchange waere aus '$DM' dann faelschlich moeglich"
  done
fi

default_role_check fa "1b. Default-Rollen des Frontend-Realms" \
  "Im getauschten Token verschwinden sie wieder, sobald audience= mitgeschickt wird - restrictRequestedAudience entfernt aus resource_access jeden Client, der nicht in der angeforderten Audience steht."

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

for entry in "${SERVICES[@]}"; do
  SVC="${entry%%:*}"
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
  RSM=$(ba "/client-scopes/$SSID/scope-mappings/clients/$SU" | jq -r 'map(.name)|join(", ")')
  [ -n "$RSM" ] && ok "Role Scope Mappings: $RSM" \
    || bad "Scope '$SVC' hat keine Role Scope Mappings" "ohne die filtert der Scope keine Rollen"
done

head_ "2. Requester-Client '$BE_REQUESTER'"
D=$(ba "/clients?clientId=$(uri "$BE_REQUESTER")" | jq '.[0] // empty')
if [ -z "$D" ]; then
  bad "Client '$BE_REQUESTER' fehlt im Realm '$BE_REALM'"
else
  ok "Client '$BE_REQUESTER' vorhanden"
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
  no_other_grants "$D" "nur JWT Authorization Grant"
  for entry in "${SERVICES[@]}"; do
    SVC="${entry%%:*}"
    ba "/clients/$DU/optional-client-scopes" | jq -e --arg n "$SVC" 'any(.name==$n)' >/dev/null \
      && ok "Scope '$SVC' als Optional zugewiesen" || bad "Scope '$SVC' nicht zugewiesen"
  done
fi

head_ "2. Mapper 2 (booking-restriction) im Backend"
BRSC=$(ba "/client-scopes" | jq --arg n "booking-restriction" '.[] | select(.name==$n)')
if [ -z "$BRSC" ]; then
  bad "Client Scope 'booking-restriction' fehlt" "ohne ihn greift Mapper 2 nicht"
else
  ok "Client Scope 'booking-restriction' vorhanden"
  jq -e '.protocolMappers // [] | any(.protocolMapper=="oidc-booking-restriction-mapper")' <<<"$BRSC" >/dev/null \
    && ok "Booking-Restriction-Mapper (oidc-booking-restriction-mapper) vorhanden" \
    || bad "Booking-Restriction-Mapper fehlt im Scope" "ohne ihn wird token3 nicht auf die gebuchten Dienste verengt"
  if [ -n "${DU:-}" ]; then
    ba "/clients/$DU/default-client-scopes" | jq -e --arg n "booking-restriction" 'any(.name==$n)' >/dev/null \
      && ok "Scope 'booking-restriction' als Default an '$BE_REQUESTER' zugewiesen" \
      || bad "Scope 'booking-restriction' nicht als Default an '$BE_REQUESTER'" "sonst laeuft Mapper 2 nicht beim Bau von token3"
  fi
  # Konfigurationsdrift zu L1: Mapper 2 prueft nur grant_type (keine Signatur, die Assertion
  # stammt vom fremden Frontend-Realm), der Scope darf deshalb nur am Requester haengen.
  BRTREFFER=$(clients_with_scope ba "booking-restriction")
  if [ -z "$BRTREFFER" ]; then
    bad "Scope 'booking-restriction' an keinem Client zugewiesen"
  elif [ "$BRTREFFER" = "$BE_REQUESTER" ]; then
    ok "Scope 'booking-restriction' haengt an genau einem Client: '$BE_REQUESTER'"
  else
    bad "Scope 'booking-restriction' haengt an: $(tr '\n' ' ' <<<"$BRTREFFER")" \
        "Mapper 2 liefe dann in einem fremden Grant-Kontext - der Mapper prueft zwar grant_type, aber der Scope gehoert trotzdem nur an den Requester (Review L1)"
  fi
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
  elif [ "$L" = "${LUID:-}" ]; then ok "verknuepft mit Frontend-lab-user $L"
  else bad "verknuepft mit '$L', Frontend-lab-user ist '${LUID:-unbekannt}'" "./setup-realms.sh erneut ausfuehren"; fi
  RM=$(ba "/users/$TUID/role-mappings")
  # Direkte Rollen statt Mandanten-Gruppen: das Backend kennt keine Mandanten mehr, nur
  # noch "hat der User ueberhaupt Rollen fuer diesen Dienst" - die Buchung je Mandant
  # erzwingt Mapper 2 anhand des scope-Claims der Assertion, nicht diese Rollen selbst.
  for entry in "${SERVICES[@]}"; do
    SVC="${entry%%:*}"; WANT="${entry#*:}"
    HAVE=$(jq -r --arg c "$SVC" '.clientMappings[$c].mappings // [] | map(.name) | sort | join(",")' <<<"${RM:-{\}}")
    WANTS=$(jq -rn --arg s "$WANT" '$s|split(",")|sort|join(",")')
    [ "$HAVE" = "$WANTS" ] && ok "direkte Rollen auf '$SVC': ${HAVE//,/, }" \
      || bad "direkte Rollen auf '$SVC': '${HAVE:-<keine>}', erwartet '$WANTS'" \
             "ohne die direkten Rollen bleibt resource_access leer, egal was gebucht ist"
  done
fi

# --- Default-Rollen ----------------------------------------------------------
default_role_check ba "2. Default-Rollen des Realms (bekommt jeder neue User automatisch)"

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mAlles gruen.\033[0m Weiter mit Teil 3 in SETUP.md oder den Bruno-Requests.\n'
else
  printf '\033[31m%s Punkt(e) offen.\033[0m Siehe die FEHLT-Zeilen oben.\n' "$FAILED"
  exit 1
fi
