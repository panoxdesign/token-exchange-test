package com.example.keycloak.mappers;

import org.keycloak.OAuth2Constants;
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

import java.util.Arrays;
import java.util.Collections;
import java.util.List;

/**
 * Leitet den "tenant"-Claim der Token-Exchange-Assertion (token2) aus dem
 * "domain"-Claim des subject_token (token1) ab, statt ihn per Request-Parameter
 * entgegenzunehmen.
 *
 * Der Mapper prueft Signatur und Grant-Kontext selbst - unabhaengig davon,
 * dass der Exchange den subject_token vorher schon validiert. Er tut nur im
 * Token-Exchange-Grant etwas, sonst koennte ein fremder Grant einen
 * selbstgebauten subject_token-Parameter unterschieben. Ausserdem muss
 * "domain" in der aud von token1 stehen: bei zwei gleichzeitig angeforderten
 * Domain-Scopes waere der domain-Claim sonst mehrdeutig.
 *
 * Fail-closed: fehlt der subject_token, ist seine Signatur ungueltig, laeuft
 * kein Token-Exchange-Grant, fehlt "domain" oder steht "domain" nicht in aud,
 * wird "tenant" gar nicht erst gesetzt (Mapper 2 im Backend leert dann
 * resource_access).
 *
 * Nur auf dem Client-Scope "access-backend" registrieren, damit der Mapper
 * ausschliesslich bei diesem einen Exchange-Schritt greift.
 */
public class RequestedTenantMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper, OIDCIDTokenMapper {

    public static final String PROVIDER_ID = "oidc-requested-tenant-mapper";
    private static final String CLAIM_NAME = "tenant";
    private static final String SUBJECT_TOKEN_PARAM = "subject_token";
    private static final String DOMAIN_CLAIM = "domain";

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
        return "Leitet den 'tenant'-Claim der Token-Exchange-Assertion aus dem "
                + "'domain'-Claim des subject_token ab. Nimmt keinen Request-Parameter an.";
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

        String domain = leseDomainAusSubjectToken(keycloakSession);

        if (domain != null && !domain.isBlank()) {
            token.getOtherClaims().put(CLAIM_NAME, domain);
        }
    }

    // Liest den subject_token direkt aus den Form-Parametern des Requests, prueft
    // aber zuerst Grant-Type und Signatur selbst (siehe Klassen-Javadoc), statt
    // dem Parameter blind zu vertrauen. Danach domain gegen aud von token1 pruefen.
    private String leseDomainAusSubjectToken(KeycloakSession session) {
        if (session.getContext() == null || session.getContext().getHttpRequest() == null) {
            return null;
        }

        var formParams = session.getContext().getHttpRequest().getDecodedFormParameters();
        if (formParams == null) {
            return null;
        }

        if (!OAuth2Constants.TOKEN_EXCHANGE_GRANT_TYPE.equals(formParams.getFirst(OAuth2Constants.GRANT_TYPE))) {
            return null;
        }

        String subjectToken = formParams.getFirst(SUBJECT_TOKEN_PARAM);
        if (subjectToken == null) {
            return null;
        }

        AccessToken t = session.tokens().decode(subjectToken, AccessToken.class);
        if (t == null) {
            return null;
        }

        Object d = t.getOtherClaims().get(DOMAIN_CLAIM);
        if (d == null) {
            return null;
        }
        String domain = d.toString();
        if (domain.isBlank()) {
            return null;
        }

        String[] aud = t.getAudience();
        if (aud == null || !Arrays.asList(aud).contains(domain)) {
            return null;
        }

        return domain;
    }
}
