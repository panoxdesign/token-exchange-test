package com.example.keycloak.mappers;

import org.keycloak.OAuth2Constants;
import org.keycloak.models.ClientSessionContext;
import org.keycloak.models.KeycloakSession;
import org.keycloak.models.ProtocolMapperModel;
import org.keycloak.models.UserSessionModel;
import org.keycloak.protocol.oidc.mappers.AbstractOIDCProtocolMapper;
import org.keycloak.protocol.oidc.mappers.OIDCAccessTokenMapper;
import org.keycloak.provider.ProviderConfigProperty;
import org.keycloak.representations.AccessToken;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/**
 * Gated den externen Token Exchange (token2 -> token3) auf die Client-Rolle "selfservice" im
 * AKTIVEN Mandanten - nicht auf eine statische Rollenzuweisung an einem Audience-Ziel-Client.
 *
 * Der aktive Mandant steht nur im Inhalt des subject_token (token1): dessen "domain"-Claim plus
 * die darunter aufgeloesten Rollen in resource_access. Der eingebaute
 * AudienceResolveProtocolMapper leitet die aud dagegen aus den STATISCHEN Rollenzuweisungen des
 * Users ab (unabhaengig davon, fuer welche Domain token1 ausgestellt wurde) - er kann den aktiven
 * Mandanten also gar nicht sehen. selfservice@domain-5678 waere darueber immer sichtbar, selbst
 * wenn token1 fuer domain-1234 gilt. Nur das Lesen des subject_token selbst unterscheidet die
 * beiden Faelle, deshalb ein Custom-Mapper statt eines nativen Role-Scope-Mappings.
 *
 * Gate-Punkt bleibt die aud in token2: TokenManager.transformAccessToken laesst zuerst ALLE
 * Protocol-Mapper laufen (dieser hier eingeschlossen), erst danach entfernt
 * restrictRequestedAudience aus der angeforderten Audience alles, was NICHT im Token steht. Setzt
 * dieser Mapper die konfigurierte Audience, bleibt sie erhalten und Schritt 02 liefert token2 -
 * setzt er sie nicht, bleibt aud leer und Schritt 02 scheitert hart mit "invalid_request:
 * Requested audience not available" (kein token2, Schritt 03 ist damit unerreichbar).
 *
 * Fail-closed: fehlt subject_token, ist seine Signatur ungueltig, laeuft kein
 * Token-Exchange-Grant, fehlt domain-Claim, steht domain nicht in der aud von token1, fehlt
 * resource_access des aktiven Mandanten oder die Rolle darin, wird NICHTS hinzugefuegt - lieber
 * ein scheiternder Exchange als eine faelschlich gewaehrte Audience.
 *
 * Nur auf dem Client-Scope "access-backend" registrieren, damit der Mapper ausschliesslich bei
 * diesem einen Exchange-Schritt greift.
 */
public class SelfserviceExchangeGateMapper extends AbstractOIDCProtocolMapper
        implements OIDCAccessTokenMapper {

    public static final String PROVIDER_ID = "oidc-selfservice-exchange-gate";
    private static final String SUBJECT_TOKEN_PARAM = "subject_token";
    private static final String DOMAIN_CLAIM = "domain";

    private static final String CONFIG_AUDIENCE = "included.client.audience";
    private static final String CONFIG_ROLE = "role";
    private static final String DEFAULT_ROLE = "selfservice";

    private static final List<ProviderConfigProperty> CONFIG_PROPERTIES = new ArrayList<>();

    static {
        ProviderConfigProperty audience = new ProviderConfigProperty();
        audience.setName(CONFIG_AUDIENCE);
        audience.setLabel("Audience bei bestandenem Gate");
        audience.setHelpText("Client-ID (Issuer-URL des Backends), die als aud eingetragen wird, "
                + "wenn der aktive Mandant die Rolle traegt.");
        audience.setType(ProviderConfigProperty.STRING_TYPE);
        CONFIG_PROPERTIES.add(audience);

        ProviderConfigProperty role = new ProviderConfigProperty();
        role.setName(CONFIG_ROLE);
        role.setLabel("Rolle im aktiven Mandanten");
        role.setHelpText("Client-Rolle, die in subject_token.resource_access[domain] stehen muss.");
        role.setType(ProviderConfigProperty.STRING_TYPE);
        role.setDefaultValue(DEFAULT_ROLE);
        CONFIG_PROPERTIES.add(role);
    }

    @Override
    public String getDisplayCategory() {
        return TOKEN_MAPPER_CATEGORY;
    }

    @Override
    public String getDisplayType() {
        return "Selfservice Exchange Gate";
    }

    @Override
    public String getHelpText() {
        return "Traegt die konfigurierte Audience nur ein, wenn lab-user die konfigurierte Rolle "
                + "im AKTIVEN Mandanten (subject_token.domain) hat - nicht bei irgendeiner "
                + "statischen Rollenzuweisung an anderer Stelle.";
    }

    @Override
    public List<ProviderConfigProperty> getConfigProperties() {
        return CONFIG_PROPERTIES;
    }

    @Override
    public String getId() {
        return PROVIDER_ID;
    }

    // Wie RTM/Mapper 2: die Basisklasse ruft die Transformation nur bei gesetztem Config-Flag
    // access.token.claim auf. Unsere Config-Properties heissen bewusst included.client.audience/
    // role statt dieses Flags, deshalb transformAccessToken direkt ueberschreiben - sonst liefe
    // der Mapper nie.
    @Override
    public AccessToken transformAccessToken(AccessToken token,
                                             ProtocolMapperModel mappingModel,
                                             KeycloakSession session,
                                             UserSessionModel userSession,
                                             ClientSessionContext clientSessionCtx) {

        String audienceClient = mappingModel.getConfig().get(CONFIG_AUDIENCE);
        if (audienceClient == null || audienceClient.isBlank()) {
            return token;
        }
        String requiredRole = mappingModel.getConfig().getOrDefault(CONFIG_ROLE, DEFAULT_ROLE);

        AccessToken subjectToken = leseSubjectToken(session);
        if (subjectToken == null) {
            return token;
        }

        Object domainClaim = subjectToken.getOtherClaims().get(DOMAIN_CLAIM);
        if (domainClaim == null) {
            return token;
        }
        String domain = domainClaim.toString();

        // domain muss in der aud von token1 stehen - sonst ist bei zwei gleichzeitig
        // angeforderten Domain-Scopes unklar, fuer welche Domain token1 wirklich ausgestellt
        // wurde (siehe Review L4). Fail-closed: ohne Treffer nichts hinzufuegen.
        String[] aud = subjectToken.getAudience();
        if (aud == null || !Arrays.asList(aud).contains(domain)) {
            return token;
        }

        AccessToken.Access acc = subjectToken.getResourceAccess(domain);
        if (acc != null && acc.getRoles() != null && acc.getRoles().contains(requiredRole)) {
            token.addAudience(audienceClient);
        }

        return token;
    }

    // Liest den subject_token direkt aus den Form-Parametern des Requests - aber erst nach
    // Pruefung von Grant-Type und Signatur (siehe Klassen-Javadoc), statt dem Parameter blind
    // zu vertrauen. Dekodiert wird als AccessToken (nicht nur JsonWebToken - resource_access
    // ist nur dort deklariert), dasselbe Muster wie
    // RequestedTenantMapper.leseDomainAusSubjectToken().
    private AccessToken leseSubjectToken(KeycloakSession session) {
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

        return session.tokens().decode(subjectToken, AccessToken.class);
    }
}
