#!/usr/bin/env bash
#
# Verhaltens-Regressionstest der Token-Exchange-Kette (Review-Punkt L6, siehe
# docs/Review-Ansatz-Sicherheit.md Abschnitt L6). check-setup.sh prueft Konfiguration,
# test-chain.sh prueft VERHALTEN: laeuft die komplette Kette gegen die laufenden
# Instanzen durch und assertet Claims und Fehlercodes. Rein lesend gegen die Realms
# (nur Token-Endpoints, keine Admin-API noetig).
#
# Voraussetzung: Stack laeuft (docker compose up -d), ./setup-realms.sh --recreate
# und ./check-setup.sh sind gruen.
#
#   ./test-chain.sh
#
# Hinweis: jedes token2 gilt als Assertion genau EINMAL (Token Reuse Detection) -
# deshalb wird es pro Fall, der eine Einloesung braucht, neu geholt.

set -uo pipefail

FE="${FE:-http://localhost:8080}"
BE="${BE:-http://localhost:8181}"
FE_REALM="${FE_REALM:-frontend}"
BE_REALM="${BE_REALM:-Backend-Microservices}"
GATEWAY="${GATEWAY:-gateway}"
SP_CLIENT="${SP_CLIENT:-self-service-portal}"
LAB_USER="${LAB_USER:-lab-user}"
LAB_PASS="${LAB_PASS:-lab-user}"
BE_REQUESTER="${BE_REQUESTER:-backend-requester}"
ACCESS_SCOPE="${ACCESS_SCOPE:-access-backend}"
SERVICE_SCOPE_PREFIX="${SERVICE_SCOPE_PREFIX:-service:}"
SEC_GATEWAY="${SEC_GATEWAY:-lab-frontend-gateway-secret}"
SEC_SP="${SEC_SP:-lab-frontend-sp-secret}"
SEC_BE_REQUESTER="${SEC_BE_REQUESTER:-lab-backend-requester-secret}"
DOMAIN_OK="${DOMAIN_OK:-domain-5678}"
DOMAIN_NOSS="${DOMAIN_NOSS:-domain-1234}"
SVC_A="${SVC_A:-e-rechnung}"
SVC_B="${SVC_B:-fahrtkostenerstattung}"

BE_ISSUER="$BE/realms/$BE_REALM"

command -v jq >/dev/null || { echo "FEHLER: jq wird gebraucht (brew install jq)" >&2; exit 1; }

# --- Ausgabe -------------------------------------------------------------
FAILED=0
CASE_FAILED=0
CASES_TOTAL=0
CASES_FAILED=0
ok()   { printf '  \033[32mOK\033[0m    %s\n' "$1"; }
bad()  { printf '  \033[31mFEHLT\033[0m %s\n' "$1"
         [ -n "${2:-}" ] && printf '        -> %s\n' "$2"
         FAILED=$((FAILED+1)); CASE_FAILED=1; }
head_(){ printf '\n\033[1m%s\033[0m\n' "$1"; }
# Faelle T1-T12 zaehlen fuer die Abschlusszeile - die Erreichbarkeitspruefung (0.) ist
# kein "Fall" im Sinne der Aufgabenstellung, sondern eine Vorbedingung.
case_start() { head_ "$1"; CASES_TOTAL=$((CASES_TOTAL+1)); CASE_FAILED=0; }
case_end() { [ "$CASE_FAILED" -eq 0 ] || CASES_FAILED=$((CASES_FAILED+1)); }

# --- Helfer ----------------------------------------------------------------
tok() { # base realm args...
  local base="$1" realm="$2"; shift 2
  local -a args=()
  for a in "$@"; do args+=(-d "$a"); done
  curl -s -X POST "$base/realms/$realm/protocol/openid-connect/token" "${args[@]}"
}

payload() { # jwt
  local p
  p=$(cut -d. -f2 <<<"$1" | tr '_-' '/+')
  local mod=$(( ${#p} % 4 ))
  [ "$mod" -eq 2 ] && p="${p}=="
  [ "$mod" -eq 3 ] && p="${p}="
  base64 -d <<<"$p" 2>/dev/null || base64 -D <<<"$p" 2>/dev/null
}

exp_eq() { # label actual expected
  if [ "$2" = "$3" ]; then ok "$1"
  else bad "$1: '$2', erwartet '$3'"; fi
}

exp_contains() { # label haystack needle
  case "$2" in
    *"$3"*) ok "$1" ;;
    *) bad "$1: '$2' enthaelt nicht '$3'" ;;
  esac
}

exp_err() { # body erwarteterError erwarteterTextteil
  local err desc
  err=$(jq -r '.error // empty' <<<"$1")
  desc=$(jq -r '.error_description // empty' <<<"$1")
  exp_eq "error == $2" "$err" "$2"
  exp_contains "error_description enthaelt '$3'" "$desc" "$3"
}

exp_no_token() { # body
  local at
  at=$(jq -r '.access_token // empty' <<<"$1")
  [ -z "$at" ] && ok "kein access_token" || bad "access_token unerwartet vorhanden"
}

# --- 0. Erreichbarkeit -------------------------------------------------------
head_ "0. Erreichbarkeit"
FE_ISS=$(curl -sf "$FE/realms/$FE_REALM/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty')
[ -n "$FE_ISS" ] && ok "Frontend-Realm '$FE_REALM' erreichbar: $FE_ISS" \
  || bad "Frontend-Realm '$FE_REALM' unter $FE nicht erreichbar"
BE_ISS=$(curl -sf "$BE_ISSUER/.well-known/openid-configuration" 2>/dev/null | jq -r '.issuer // empty')
[ -n "$BE_ISS" ] && ok "Backend-Realm '$BE_REALM' erreichbar: $BE_ISS" \
  || bad "Backend-Realm '$BE_REALM' unter $BE nicht erreichbar"
case_end
if [ -z "$FE_ISS" ] || [ -z "$BE_ISS" ]; then
  echo
  echo "Ohne erreichbare Realms kein sinnvoller Testlauf. docker compose up -d / ./setup-realms.sh --recreate pruefen."
  exit 1
fi

# --- Grund-Requests, wiederverwendbare Tokens --------------------------------
token_sp=$(tok "$FE" "$FE_REALM" grant_type=password username="$LAB_USER" password="$LAB_PASS" \
  client_id="$SP_CLIENT" client_secret="$SEC_SP" | jq -r '.access_token // empty')

token1=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token_sp" \
  audience="$DOMAIN_OK" scope="$DOMAIN_OK" client_id="$GATEWAY" client_secret="$SEC_GATEWAY" \
  | jq -r '.access_token // empty')

# --- T1 Positivkette ---------------------------------------------------------
case_start "T1 Positivkette 04 -> 05(DOMAIN_OK) -> 02(service:$SVC_A) -> 03($SVC_A)"
p1=$(payload "$token1")
exp_eq "token1.domain == $DOMAIN_OK" "$(jq -r '.domain // empty' <<<"$p1")" "$DOMAIN_OK"
AUD1=$(jq -c '[.aud]|flatten' <<<"$p1")
jq -e --arg d "$DOMAIN_OK" 'index($d) != null' <<<"$AUD1" >/dev/null \
  && ok "token1.aud enthaelt $DOMAIN_OK" || bad "token1.aud ($AUD1) enthaelt nicht $DOMAIN_OK"
jq -e --arg d "$DOMAIN_OK" '.resource_access[$d].roles // [] | index("selfservice") != null' <<<"$p1" >/dev/null \
  && ok "token1.resource_access[$DOMAIN_OK].roles enthaelt selfservice" \
  || bad "token1.resource_access[$DOMAIN_OK].roles enthaelt selfservice nicht"

token2=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_A}" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
p2=$(payload "$token2")
exp_eq "token2.aud == BE_ISSUER" "$(jq -r '.aud // empty' <<<"$p2")" "$BE_ISSUER"
exp_eq "token2.tenant == $DOMAIN_OK" "$(jq -r '.tenant // empty' <<<"$p2")" "$DOMAIN_OK"
exp_contains "token2.scope enthaelt service:$SVC_A" "$(jq -r '.scope // empty' <<<"$p2")" "${SERVICE_SCOPE_PREFIX}${SVC_A}"
[ -n "$(jq -r '.jti // empty' <<<"$p2")" ] && ok "token2.jti gesetzt" || bad "token2.jti fehlt"

token3=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2" scope="$SVC_A" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER" \
  | jq -r '.access_token // empty')
p3=$(payload "$token3")
exp_eq "token3.iss == BE_ISSUER" "$(jq -r '.iss // empty' <<<"$p3")" "$BE_ISSUER"
exp_eq "token3.aud == $SVC_A" "$(jq -r '.aud // empty' <<<"$p3")" "$SVC_A"
RAKEYS=$(jq -c '.resource_access // {} | keys' <<<"$p3")
[ "$RAKEYS" = "[\"$SVC_A\"]" ] && ok "token3.resource_access hat genau den Key $SVC_A" \
  || bad "token3.resource_access-Keys sind $RAKEYS, erwartet [\"$SVC_A\"]"
RAROLES=$(jq -c --arg s "$SVC_A" '.resource_access[$s].roles // [] | sort' <<<"$p3")
exp_eq "token3.resource_access[$SVC_A].roles sortiert" "$RAROLES" '["reader","writer"]'
exp_eq "token3.tenant == $DOMAIN_OK" "$(jq -r '.tenant // empty' <<<"$p3")" "$DOMAIN_OK"
case_end

# --- T2 Zweiter Dienst --------------------------------------------------------
case_start "T2 Zweiter Dienst: service:$SVC_B -> 03($SVC_B)"
token2b=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_B}" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
token3b=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2b" scope="$SVC_B" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER" \
  | jq -r '.access_token // empty')
p3b=$(payload "$token3b")
RAROLESB=$(jq -c --arg s "$SVC_B" '.resource_access[$s].roles // [] | sort' <<<"$p3b")
exp_eq "token3.resource_access[$SVC_B].roles sortiert" "$RAROLESB" '["approver","reader"]'
exp_eq "token3.tenant == $DOMAIN_OK" "$(jq -r '.tenant // empty' <<<"$p3b")" "$DOMAIN_OK"
case_end

# --- T3 Fail-closed Fall C ----------------------------------------------------
case_start "T3 Fail-closed (Fall C): token2 bucht $SVC_A, 03 fordert $SVC_B"
token2c=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_A}" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
token3c=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2c" scope="$SVC_B" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER" \
  | jq -r '.access_token // empty')
p3c=$(payload "$token3c")
exp_eq "token3.resource_access == {}" "$(jq -c '.resource_access // {}' <<<"$p3c")" '{}'
[ "$(jq -r 'has("tenant")' <<<"$p3c")" = "false" ] && ok "token3 hat keinen tenant-Claim" \
  || bad "token3 hat unerwartet einen tenant-Claim"
case_end

# --- T4 Fail-closed Fall D ----------------------------------------------------
case_start "T4 Fail-closed (Fall D): token2 nur ACCESS_SCOPE, 03 fordert $SVC_A"
token2d=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
token3d=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2d" scope="$SVC_A" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER" \
  | jq -r '.access_token // empty')
p3d=$(payload "$token3d")
exp_eq "token3.resource_access == {}" "$(jq -c '.resource_access // {}' <<<"$p3d")" '{}'
[ "$(jq -r 'has("tenant")' <<<"$p3d")" = "false" ] && ok "token3 hat keinen tenant-Claim" \
  || bad "token3 hat unerwartet einen tenant-Claim"
case_end

# --- T5 Gate-Negativfall -------------------------------------------------------
case_start "T5 Gate-Negativfall: DOMAIN_NOSS ohne selfservice"
token1_noss=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token_sp" \
  audience="$DOMAIN_NOSS" scope="$DOMAIN_NOSS" client_id="$GATEWAY" client_secret="$SEC_GATEWAY" \
  | jq -r '.access_token // empty')
p1n=$(payload "$token1_noss")
[ -n "$token1_noss" ] && ok "token1_noss gueltig" || bad "token1_noss leer"
RAN=$(jq -c --arg d "$DOMAIN_NOSS" '.resource_access[$d].roles // [] | sort' <<<"$p1n")
exp_eq "token1_noss.resource_access[$DOMAIN_NOSS].roles == [\"admin\"]" "$RAN" '["admin"]'
body5=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1_noss" \
  scope="$ACCESS_SCOPE" audience="$BE_ISSUER" client_id="$GATEWAY" client_secret="$SEC_GATEWAY")
exp_no_token "$body5"
exp_err "$body5" "invalid_request" "Requested audience not available"
case_end

# --- T6 requested_tenant-Spoofing --------------------------------------------
case_start "T6 requested_tenant-Spoofing"
token2t=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_A}" audience="$BE_ISSUER" \
  requested_tenant="$DOMAIN_NOSS" client_id="$GATEWAY" client_secret="$SEC_GATEWAY" \
  | jq -r '.access_token // empty')
p2t=$(payload "$token2t")
exp_eq "token2.tenant == $DOMAIN_OK trotz requested_tenant=$DOMAIN_NOSS" "$(jq -r '.tenant // empty' <<<"$p2t")" "$DOMAIN_OK"
case_end

# --- T7 Token-Reuse -----------------------------------------------------------
case_start "T7 Token-Reuse: dasselbe token2 zweimal einloesen"
token2r=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_A}" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
body7a=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2r" scope="$SVC_A" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER")
[ -n "$(jq -r '.access_token // empty' <<<"$body7a")" ] && ok "erster Aufruf liefert access_token" \
  || bad "erster Aufruf liefert keinen access_token"
body7b=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token2r" scope="$SVC_A" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER")
ERR7=$(jq -r '.error // empty' <<<"$body7b")
DESC7=$(jq -r '.error_description // empty' <<<"$body7b" | tr '[:upper:]' '[:lower:]')
exp_eq "zweiter Aufruf error == invalid_grant" "$ERR7" "invalid_grant"
case "$DESC7" in
  *"reuse"*) ok "error_description enthaelt 'reuse' (case-insensitive)" ;;
  *) bad "error_description enthaelt kein 'reuse': '$DESC7'" ;;
esac
case_end

# --- T8 token1 direkt als Assertion -------------------------------------------
case_start "T8 token1 direkt als Assertion in 03"
body8=$(tok "$BE" "$BE_REALM" grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer \
  assertion="$token1" client_id="$BE_REQUESTER" client_secret="$SEC_BE_REQUESTER")
exp_no_token "$body8"
exp_eq "error == invalid_grant" "$(jq -r '.error // empty' <<<"$body8")" "invalid_grant"
case_end

# --- T9 token_sp direkt als subject_token in 02 -------------------------------
case_start "T9 token_sp direkt als subject_token in 02 (05 uebersprungen)"
body9=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token_sp" \
  scope="$ACCESS_SCOPE" audience="$BE_ISSUER" client_id="$GATEWAY" client_secret="$SEC_GATEWAY")
exp_no_token "$body9"
exp_err "$body9" "invalid_request" "Requested audience not available"
case_end

# --- T10 Gefaelschter subject_token -------------------------------------------
case_start "T10 Gefaelschter subject_token (unsigniert)"
now=$(date +%s)
header_b64=$(printf '%s' '{"alg":"none","typ":"JWT"}' | base64 | tr '+/' '-_' | tr -d '=\n')
payload10=$(jq -n --arg iss "$FE/realms/$FE_REALM" --arg azp "$GATEWAY" --arg dom "$DOMAIN_OK" \
  --argjson exp "$((now+300))" --argjson iat "$now" \
  '{iss:$iss, aud:[$azp], azp:$azp, sub:"00000000-0000-0000-0000-000000000000",
    domain:$dom, resource_access:{($dom):{roles:["selfservice"]}}, exp:$exp, iat:$iat, typ:"Bearer"}')
payload10_b64=$(printf '%s' "$payload10" | base64 | tr '+/' '-_' | tr -d '=\n')
forged="${header_b64}.${payload10_b64}."
body10=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$forged" \
  scope="$ACCESS_SCOPE" audience="$BE_ISSUER" client_id="$GATEWAY" client_secret="$SEC_GATEWAY")
exp_no_token "$body10"
[ -n "$(jq -r '.error // empty' <<<"$body10")" ] && ok "error-Feld gesetzt (beliebiger Fehler zulaessig)" \
  || bad "kein error-Feld gesetzt"
# Kommentar: Keycloak weist das vor dem Mapper-Lauf ab; der Fall beweist, dass die Grenze haelt.
case_end

# --- T11 Zwei Domain-Scopes gleichzeitig --------------------------------------
case_start "T11 Zwei Domain-Scopes gleichzeitig"
token1_both=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token_sp" \
  scope="$DOMAIN_OK $DOMAIN_NOSS" audience="$DOMAIN_OK" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY" | jq -r '.access_token // empty')
p1both=$(payload "$token1_both")
AUDBOTH=$(jq -c '[.aud]|flatten' <<<"$p1both")
DOMBOTH=$(jq -r '.domain // empty' <<<"$p1both")
body11=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token1_both" \
  scope="$ACCESS_SCOPE ${SERVICE_SCOPE_PREFIX}${SVC_A}" audience="$BE_ISSUER" \
  client_id="$GATEWAY" client_secret="$SEC_GATEWAY")
AT11=$(jq -r '.access_token // empty' <<<"$body11")
if [ -z "$AT11" ]; then
  ok "Fehler ohne access_token (zulaessiges Ergebnis a)"
else
  TEN11=$(jq -r '.tenant // empty' <<<"$(payload "$AT11")")
  if [ "$TEN11" = "$DOMBOTH" ] && jq -e --arg t "$TEN11" 'index($t) != null' <<<"$AUDBOTH" >/dev/null; then
    ok "token2.tenant ($TEN11) == token1_both.domain und liegt in token1_both.aud (zulaessiges Ergebnis b)"
  else
    bad "token2.tenant ($TEN11) liegt NICHT in token1_both.aud ($AUDBOTH)" "unzulaessig: fremder Mandant durchgereicht"
  fi
fi
case_end

# --- T12 Requester ohne Exchange-Recht ----------------------------------------
case_start "T12 Requester ohne Exchange-Recht ($SP_CLIENT statt $GATEWAY)"
body12=$(tok "$FE" "$FE_REALM" grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
  subject_token_type=urn:ietf:params:oauth:token-type:access_token subject_token="$token_sp" \
  audience="$DOMAIN_OK" scope="$DOMAIN_OK" client_id="$SP_CLIENT" client_secret="$SEC_SP")
exp_err "$body12" "invalid_request" "not enabled"
case_end

echo
if [ "$FAILED" -eq 0 ]; then
  printf '\033[32mAlle %s Faelle bestanden.\033[0m\n' "$CASES_TOTAL"
else
  if [ "$CASES_FAILED" -eq 1 ]; then
    printf '\033[31m1 Fall fehlgeschlagen.\033[0m Siehe die FEHLT-Zeilen oben.\n'
  else
    printf '\033[31m%s Faelle fehlgeschlagen.\033[0m Siehe die FEHLT-Zeilen oben.\n' "$CASES_FAILED"
  fi
  exit 1
fi
