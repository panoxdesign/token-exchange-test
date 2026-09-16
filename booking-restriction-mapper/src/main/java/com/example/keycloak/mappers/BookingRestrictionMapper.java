package com.example.keycloak.mappers;

import org.keycloak.jose.jws.JWSInput;
import org.keycloak.jose.jws.JWSInputException;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.JsonWebToken;

import java.util.ArrayList;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Set;

/**
 * Verengt resource_access im Access Token (token3, Domain B) auf die Dienste, die laut
 * scope-Claim der Token-Exchange-Assertion gebucht sind (Praefix "service:"). Fail-closed:
 * jeder Eintrag in resource_access, dessen Client nicht unter den gebuchten Diensten ist,
 * wird komplett entfernt.
 *
 * Wirkt nur auf das Access Token - kein IDTokenMapper noetig.
 */
public class BookingRestrictionMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper {

    public static final String PROVIDER_ID = "oidc-booking-restriction-mapper";
    private static final String SCOPE_CLAIM = "scope";
    private static final String SERVICE_PREFIX = "service:";
    private static final String ASSERTION_PARAM = "assertion";

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getDisplayType() {
        return "Booking Restriction Mapper";
    }

    @Override
    public String getHelpText() {
        return "Verengt resource_access auf die im scope-Claim der Token-Exchange-Assertion "
                + "gebuchten Dienste (Praefix 'service:'). Fail-closed ohne Treffer.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return Collections.emptyList();
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    // Muss nach den Rollen-Mappern laufen (Prioritaet 40), sonst ist resource_access beim
    // Aufruf dieses Mappers noch leer und es gibt nichts zu verengen. Default-Prioritaet 0
    // waere zu frueh.
    @Override
    public int getPriority() {
        return 100;
    }

    // Wie bei den anderen beiden Mappern: die Basisklasse ruft setClaim/die Transformation
    // nur bei gesetztem Config-Flag access.token.claim auf. Dieser Mapper bietet keine
    // Config-Properties an, deshalb direkt transformAccessToken ueberschreiben.
    @Override
    public AccessToken transformAccessToken(AccessToken token, ProtocolMapperModel mappingModel,
            KeycloakSession session, UserSessionModel userSession, ClientSessionContext clientSessionCtx) {

        if (token.getResourceAccess() == null) {
            return token;
        }

        Set<String> gebuchteDienste = leseGebuchteDiensteAusAssertion(session);

        // Kopie der Keys, um beim Entfernen keine ConcurrentModificationException auf der
        // Live-Map von token.getResourceAccess() zu riskieren.
        List<String> clientIds = new ArrayList<>(token.getResourceAccess().keySet());
        for (String clientId : clientIds) {
            if (!gebuchteDienste.contains(clientId)) {
                token.getResourceAccess().remove(clientId);
            }
        }

        return token;
    }

    // Bruecke A: liest die Assertion direkt aus den Form-Parametern des Requests (dieselbe
    // Quelle, aus der auch der jwt-bearer-Grant sie liest) und dekodiert sie wie der Grant
    // selbst. Keine erneute Signaturpruefung noetig, der Grant hat die Assertion vor dem
    // Token-Bau schon validiert.
    //
    // Dekodiert wird als JsonWebToken, nicht als AccessToken: "scope" ist dort kein
    // deklariertes Feld (das liegt nur in AccessToken), sondern landet ueber @JsonAnySetter
    // in otherClaims - genau wie "tenant"/"domain" bei den anderen beiden Mappern.
    private Set<String> leseGebuchteDiensteAusAssertion(KeycloakSession session) {
        if (session.getContext() == null || session.getContext().getHttpRequest() == null) {
            return Collections.emptySet();
        }

        var formParams = session.getContext().getHttpRequest().getDecodedFormParameters();
        if (formParams == null) {
            return Collections.emptySet();
        }

        String assertion = formParams.getFirst(ASSERTION_PARAM);
        if (assertion == null) {
            return Collections.emptySet();
        }

        String scope;
        try {
            JWSInput jws = new JWSInput(assertion);
            JsonWebToken jwt = jws.readJsonContent(JsonWebToken.class);
            Object s = jwt.getOtherClaims().get(SCOPE_CLAIM);
            scope = (s == null) ? null : s.toString();
        } catch (JWSInputException e) {
            return Collections.emptySet();
        }

        if (scope == null || scope.isBlank()) {
            return Collections.emptySet();
        }

        Set<String> gebucht = new HashSet<>();
        for (String eintrag : scope.split("\\s+")) {
            if (eintrag.startsWith(SERVICE_PREFIX)) {
                gebucht.add(eintrag.substring(SERVICE_PREFIX.length()));
            }
        }
        return gebucht;
    }
}
