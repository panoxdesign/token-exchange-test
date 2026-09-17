package com.example.keycloak.mappers;

import org.keycloak.OAuth2Constants;
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
 * wird komplett entfernt. Schreibt zusaetzlich den tenant-Claim aus der Assertion nach token3
 * (mandantenbindend: die Backend-Dienste trennen ihre Daten danach, der Mapper selbst wertet
 * ihn nicht aus) - aber nur, wenn nach dem Verengen mindestens ein Dienst uebrig
 * bleibt (sonst fail-closed auch beim tenant-Claim).
 *
 * Wirkt nur auf das Access Token - kein IDTokenMapper noetig.
 */
public class BookingRestrictionMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper {

    public static final String PROVIDER_ID = "oidc-booking-restriction-mapper";
    private static final String SCOPE_CLAIM = "scope";
    private static final String TENANT_CLAIM = "tenant";
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

        AssertionDaten assertionDaten = leseAssertionDaten(session);

        // Kopie der Keys, um beim Entfernen keine ConcurrentModificationException auf der
        // Live-Map von token.getResourceAccess() zu riskieren.
        List<String> clientIds = new ArrayList<>(token.getResourceAccess().keySet());
        for (String clientId : clientIds) {
            if (!assertionDaten.gebuchteDienste().contains(clientId)) {
                token.getResourceAccess().remove(clientId);
            }
        }

        // tenant nur setzen, wenn nach dem Verengen ueberhaupt ein Dienst
        // uebrig bleibt - sonst waere token3 "ohne Rollen, aber mit tenant" ein Widerspruch
        // zum Fail-closed-Verhalten.
        if (assertionDaten.tenant() != null && !token.getResourceAccess().isEmpty()) {
            token.getOtherClaims().put(TENANT_CLAIM, assertionDaten.tenant());
        }

        return token;
    }

    // Haelt beide aus der Assertion gelesenen Werte, da sie aus derselben Dekodierung stammen.
    private record AssertionDaten(Set<String> gebuchteDienste, String tenant) {
    }

    // Bruecke A: liest die Assertion direkt aus den Form-Parametern des Requests (dieselbe
    // Quelle, aus der auch der jwt-bearer-Grant sie liest) und dekodiert sie wie der Grant
    // selbst. Neu: grant_type muss jwt-bearer sein, sonst koennte ein fremder Grant einen
    // selbstgebauten assertion-Parameter unterschieben. Die JWSInput-Dekodierung ohne erneute
    // Signaturpruefung bleibt aber bewusst bestehen (anders als bei RTM/Gate): die Assertion
    // stammt vom fremden Frontend-Realm, dessen Schluessel der Backend-Realm nicht lokal hat -
    // session.tokens().decode(...) kann hier nicht pruefen. Der jwt-bearer-Grant hat die
    // Signatur ueber den IdP-JWKS bereits vor dem Token-Bau geprueft.
    //
    // Dekodiert wird als JsonWebToken, nicht als AccessToken: "scope" ist dort kein
    // deklariertes Feld (das liegt nur in AccessToken), sondern landet ueber @JsonAnySetter
    // in otherClaims - genau wie "tenant"/"domain" bei den anderen beiden Mappern.
    private AssertionDaten leseAssertionDaten(KeycloakSession session) {
        if (session.getContext() == null || session.getContext().getHttpRequest() == null) {
            return new AssertionDaten(Collections.emptySet(), null);
        }

        var formParams = session.getContext().getHttpRequest().getDecodedFormParameters();
        if (formParams == null) {
            return new AssertionDaten(Collections.emptySet(), null);
        }

        if (!OAuth2Constants.JWT_AUTHORIZATION_GRANT.equals(formParams.getFirst(OAuth2Constants.GRANT_TYPE))) {
            return new AssertionDaten(Collections.emptySet(), null);
        }

        String assertion = formParams.getFirst(ASSERTION_PARAM);
        if (assertion == null) {
            return new AssertionDaten(Collections.emptySet(), null);
        }

        String scope;
        String tenant;
        try {
            JWSInput jws = new JWSInput(assertion);
            JsonWebToken jwt = jws.readJsonContent(JsonWebToken.class);
            Object s = jwt.getOtherClaims().get(SCOPE_CLAIM);
            scope = (s == null) ? null : s.toString();
            Object t = jwt.getOtherClaims().get(TENANT_CLAIM);
            tenant = (t == null) ? null : t.toString();
        } catch (JWSInputException e) {
            return new AssertionDaten(Collections.emptySet(), null);
        }

        if (scope == null || scope.isBlank()) {
            return new AssertionDaten(Collections.emptySet(), tenant);
        }

        Set<String> gebucht = new HashSet<>();
        for (String eintrag : scope.split("\\s+")) {
            if (eintrag.startsWith(SERVICE_PREFIX)) {
                gebucht.add(eintrag.substring(SERVICE_PREFIX.length()));
            }
        }
        return new AssertionDaten(gebucht, tenant);
    }
}
