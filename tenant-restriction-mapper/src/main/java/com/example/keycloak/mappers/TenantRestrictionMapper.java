package com.example.keycloak.mappers;

import org.keycloak.jose.jws.JWSInput;
import org.keycloak.jose.jws.JWSInputException;
import org.keycloak.models.ClientModel;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.GroupModel;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.RealmModel;
import org.keycloak.models.RoleModel;
import org.keycloak.models.UserModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.JsonWebToken;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.stream.Collectors;

/**
 * Verengt resource_access im Access Token (token3, Domain B) auf die Rollen der
 * Mandanten-Gruppe, deren Name mit dem "tenant"-Claim aus der Token-Exchange-
 * Assertion uebereinstimmt. Fail-closed: fehlt Claim, Assertion oder
 * Gruppenmitgliedschaft, wird resource_access komplett geleert.
 *
 * Wirkt nur auf das Access Token - kein IDTokenMapper noetig.
 */
public class TenantRestrictionMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper {

    public static final String PROVIDER_ID = "oidc-tenant-restriction-mapper";
    private static final String CLAIM_NAME = "tenant";
    private static final String ASSERTION_PARAM = "assertion";

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getDisplayType() {
        return "Tenant Restriction Mapper";
    }

    @Override
    public String getHelpText() {
        return "Verengt resource_access auf die Rollen der bestaetigten Mandanten-Gruppe "
                + "(aus dem tenant-Claim der Token-Exchange-Assertion). Fail-closed ohne Treffer.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return Collections.emptyList();
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    // Muss nach den Rollen-Mappern laufen (Prioritaet 40), sonst ist
    // resource_access beim Aufruf dieses Mappers noch leer und es gibt nichts
    // zu verengen. Default-Prioritaet 0 waere zu frueh.
    @Override
    public int getPriority() {
        return 100;
    }

    // Wie bei Mapper 1: die Basisklasse ruft setClaim/die Transformation nur bei
    // gesetztem Config-Flag access.token.claim auf. Dieser Mapper bietet keine
    // Config-Properties an, deshalb direkt transformAccessToken ueberschreiben.
    @Override
    public AccessToken transformAccessToken(AccessToken token, ProtocolMapperModel mappingModel,
            KeycloakSession session, UserSessionModel userSession, ClientSessionContext clientSessionCtx) {

        String tenant = leseTenantAusAssertion(session);

        UserModel user = userSession.getUser();
        GroupModel confirmed = (tenant == null) ? null
                : user.getGroupsStream().filter(g -> tenant.equals(g.getName())).findFirst().orElse(null);

        RealmModel realm = session.getContext().getRealm();

        // Kopie der Eintraege, um beim Entfernen keine ConcurrentModificationException
        // auf der Live-Map von token.getResourceAccess() zu riskieren.
        List<Map.Entry<String, AccessToken.Access>> entries =
                new ArrayList<>(token.getResourceAccess().entrySet());

        for (Map.Entry<String, AccessToken.Access> entry : entries) {
            String clientId = entry.getKey();
            AccessToken.Access access = entry.getValue();
            ClientModel client = realm.getClientByClientId(clientId);

            // Nur Schnittmenge, nie hinzufuegen: ist keine Gruppe bestaetigt oder der
            // Client unbekannt, ist erlaubt leer -> der Eintrag wird komplett geleert
            // (fail-closed, ohne Sonderfall).
            Set<String> erlaubt = (confirmed == null || client == null)
                    ? Collections.emptySet()
                    : confirmed.getClientRoleMappingsStream(client)
                            .map(RoleModel::getName)
                            .collect(Collectors.toSet());

            if (access.getRoles() != null) {
                access.getRoles().retainAll(erlaubt);
            }
            if (access.getRoles() == null || access.getRoles().isEmpty()) {
                token.getResourceAccess().remove(clientId);
            }
        }

        if (confirmed != null) {
            token.getOtherClaims().put(CLAIM_NAME, tenant);
        }

        return token;
    }

    // Bruecke A: liest die Assertion direkt aus den Form-Parametern des Requests
    // (dieselbe Quelle, aus der auch der jwt-bearer-Grant sie liest) und dekodiert
    // sie wie der Grant selbst. Keine erneute Signaturpruefung noetig, der Grant
    // hat die Assertion vor dem Token-Bau schon validiert.
    private String leseTenantAusAssertion(KeycloakSession session) {
        if (session.getContext() == null || session.getContext().getHttpRequest() == null) {
            return null;
        }

        var formParams = session.getContext().getHttpRequest().getDecodedFormParameters();
        if (formParams == null) {
            return null;
        }

        String assertion = formParams.getFirst(ASSERTION_PARAM);
        if (assertion == null) {
            return null;
        }

        try {
            JWSInput jws = new JWSInput(assertion);
            JsonWebToken jwt = jws.readJsonContent(JsonWebToken.class);
            Object t = jwt.getOtherClaims().get(CLAIM_NAME);
            return (t == null) ? null : t.toString();
        } catch (JWSInputException e) {
            return null;
        }
    }
}
