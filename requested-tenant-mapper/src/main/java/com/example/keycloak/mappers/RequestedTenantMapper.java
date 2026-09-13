package com.example.keycloak.mappers;

import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.protocol.oidc.mappers.OIDCIDTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;
import org.keycloak.representations.IDToken;

import java.util.Collections;
import java.util.List;

/**
 * Liest den Request-Parameter "requested_tenant" aus dem eingehenden
 * Token-Exchange-Request (Domain A) und schreibt ihn unveraendert als
 * "tenant"-Claim in die ausgestellte JWT-Assertion (token2).
 *
 * WICHTIG: Dieser Mapper VALIDIERT NICHTS. Er transportiert den Wert nur.
 * Nur auf dem Client-Scope "access-domainb" registrieren, damit der Mapper
 * ausschliesslich bei diesem einen Exchange-Schritt greift.
 */
public class RequestedTenantMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper {

    public static final String PROVIDER_ID = "oidc-requested-tenant-mapper";
    private static final String CLAIM_NAME = "tenant";
    private static final String PARAM_NAME = "requested_tenant";

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getDisplayType() {
        return "Requested Tenant Mapper";
    }

    @Override
    public String getHelpText() {
        return "Transportiert den 'requested_tenant' Request-Parameter als "
                + "'tenant'-Claim in die Token-Exchange-Assertion. Keine Validierung hier.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return Collections.emptyList();
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    // AbstractOIDCProtocolMapper.transformAccessToken ruft setClaim nur, wenn das
    // Config-Flag access.token.claim gesetzt ist. Da dieser Mapper bewusst keine
    // Config-Properties anbietet (und die Admin-Console deshalb keinen Schalter
    // zeigt), waere das Flag nie gesetzt und der Claim landete nie in token2.
    // Deshalb hier fest ueberschreiben: greift der Mapper, wird der Claim immer
    // in das Access Token (die Exchange-Assertion) geschrieben.
    @Override
    public AccessToken transformAccessToken(AccessToken token,
                                            ProtocolMapperModel mappingModel,
                                            KeycloakSession session,
                                            UserSessionModel userSession,
                                            ClientSessionContext clientSessionCtx) {
        setClaim(token, mappingModel, userSession, session, clientSessionCtx);
        return token;
    }

    @Override
    protected void setClaim(IDToken token,
                             ProtocolMapperModel mappingModel,
                             UserSessionModel userSession,
                             KeycloakSession keycloakSession,
                             ClientSessionContext clientSessionCtx) {

        if (keycloakSession.getContext() == null
                || keycloakSession.getContext().getHttpRequest() == null) {
            return;
        }

        var formParams = keycloakSession.getContext()
                .getHttpRequest()
                .getDecodedFormParameters();

        if (formParams == null) {
            return;
        }

        String requestedTenant = formParams.getFirst(PARAM_NAME);

        if (requestedTenant != null && !requestedTenant.isBlank()) {
            token.getOtherClaims().put(CLAIM_NAME, requestedTenant);
        }
    }
}
