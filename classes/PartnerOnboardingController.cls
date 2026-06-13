/**
 * PartnerOnboardingController
 *
 * Handles partner onboarding to NCP via the selfconfiguration API.
 * Triggered by the "Onboard Partner" button on a Configuration Case
 * linked to a partner Compliance__c record.
 *
 * Flow:
 *   1. Reads partner data from Case + linked Compliance__c
 *   2. Builds NCP partner payload
 *   3. Authenticates via OAuth2 client_credentials (ExpressConfig__c)
 *   4. POSTs to partner onboarding endpoint
 *   5. On success: writes entityId → Nuvei_Partner_ID__c
 *                             masterClientId → MasterClient_ID__c on Compliance__c
 *   6. Writes full response (success or error) to Case.Logs__c
 *   7. Writes errors to Execution_Log__c (NuveiConnect record type)
 *
 * Phase 1 hardcoded values (to be driven by Custom Object in Phase 2):
 *   - features.enableWhiteLabel = false
 *   - profile = 'Partner onboarding'
 *   - users[0].adminOfAdmins = true
 *   - users[0].roles = ['management']
 *
 * @author  Nuvei Development Team
 * @version 1.0
 */
public with sharing class PartnerOnboardingController {

    public String caseId       { get; set; }
    public String errorMessage { get; set; }

    private static final Id RT_EL_NC = RecordTypeHelper.getRecordTypeIdByName(
        'Execution_Log__c', 'NuveiConnect'
    );

    // ─── VISUALFORCE CONTROLLER ──────────────────────────────────────────────
    public PartnerOnboardingController(ApexPages.StandardController stdController) {
        caseId = stdController.getId();
    }

    public PageReference onboardPartner() {
        if (String.isBlank(caseId)) {
            errorMessage = 'Case ID is missing.';
            return null;
        }
        sendPartnerRequest(caseId);
        return new PageReference('/' + caseId).setRedirect(true);
    }

    // ─── INVOCABLE (for Flow if needed in future) ────────────────────────────
    @InvocableMethod(label='Onboard Partner' description='Onboards a partner to NCP via selfconfiguration API')
    public static List<ResponseWrapper> onboardPartnerFromFlow(List<RequestWrapper> requests) {
        List<ResponseWrapper> responses = new List<ResponseWrapper>();
        for (RequestWrapper req : requests) {
            ResponseWrapper resp = new ResponseWrapper();
            try {
                sendPartnerRequest(req.caseId);
                resp.success = true;
            } catch (Exception e) {
                resp.success = false;
                resp.errorMessage = e.getMessage();
            }
            responses.add(resp);
        }
        return responses;
    }

    public class RequestWrapper {
        @InvocableVariable(required=true)
        public String caseId;
    }

    public class ResponseWrapper {
        @InvocableVariable
        public Boolean success;
        @InvocableVariable
        public String errorMessage;
    }

    // ─── AURA / LWC ENTRY POINT ─────────────────────────────────────────────
    // Called by the LWC quick action button. Validates the case then kicks
    // off the @future callout. Returns any validation error to the UI.
    @AuraEnabled
    public static String initOnboarding(String caseId) {
        try {
            if (String.isBlank(caseId)) return 'Case ID is missing.';

            Case cas = [
                SELECT Id, Company_Profile__c, ContactId,
                       SB_PPP_Username__c
                FROM   Case WHERE Id = :caseId LIMIT 1
            ];

            if (String.isBlank(cas.Company_Profile__c))
                return 'This case has no linked Company Profile — cannot onboard.';
            if (String.isBlank(cas.ContactId))
                return 'This case has no Contact — cPanel admin user cannot be built.';
            if (String.isBlank(cas.SB_PPP_Username__c))
                return 'SB_PPP_Username__c is blank — ensure the case workflow has run.';

            // Kick off async callout
            sendPartnerRequest(caseId);
            return null; // null = no error
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    // ─── MAIN ASYNC METHOD ───────────────────────────────────────────────────
    @future(callout=true)
    public static void sendPartnerRequest(String caseId) {
        System.debug('PartnerOnboarding | sendPartnerRequest | caseId=' + caseId);

        Case cas;
        ExpressConfig__c config;

        try {
            cas    = fetchCase(caseId);
            config = fetchConfig();
        } catch (Exception e) {
            logError('Failed to fetch Case or ExpressConfig__c', e, caseId, null);
            return;
        }

        try {
            // ── Auth ──────────────────────────────────────────────────────────
            String tokenEndpoint = config.PO_prod_token_endpoint__c;
            String clientSecret  = config.PO_prod_secret__c;
            String endpoint      = config.PO_prod_endpoint__c;

            if (String.isBlank(tokenEndpoint) || String.isBlank(clientSecret) || String.isBlank(endpoint)) {
                String msg = 'PartnerOnboarding | Missing ExpressConfig__c values — check PO_prod_endpoint__c, PO_prod_secret__c, PO_prod_token_endpoint__c';
                appendCaseLog(cas, msg);
                logError(msg, null, caseId, cas.Company_Profile__c);
                return;
            }

            String accessToken = getAccessToken(tokenEndpoint, clientSecret);
            if (String.isBlank(accessToken)) {
                String msg = 'PartnerOnboarding | Failed to obtain access token from ' + tokenEndpoint;
                appendCaseLog(cas, msg);
                logError(msg, null, caseId, cas.Company_Profile__c);
                return;
            }

            // ── Build payload ─────────────────────────────────────────────────
            PartnerPayload payload = new PartnerPayload(cas);
            String payloadJson    = JSON.serialize(payload, true);

            System.debug('PartnerOnboarding | payload=' + JSON.serializePretty(
                (Map<String, Object>) JSON.deserializeUntyped(payloadJson)
            ));

            // ── HTTP call ─────────────────────────────────────────────────────
            HttpRequest req = new HttpRequest();
            req.setEndpoint(endpoint);
            req.setTimeout(120000);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/json');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setHeader('Idempotency-Key', String.valueOf(System.currentTimeMillis()));
            req.setBody(payloadJson);

            Http http = new Http();
            HttpResponse res = http.send(req);

            System.debug('PartnerOnboarding | responseCode=' + res.getStatusCode());
            System.debug('PartnerOnboarding | responseBody=' + res.getBody());

            // ── Handle response ───────────────────────────────────────────────
            if (res.getStatusCode() == 200 || res.getStatusCode() == 201 || res.getStatusCode() == 202) {
                handleSuccess(res.getBody(), cas);
            } else {
                String msg = 'PartnerOnboarding | HTTP ' + res.getStatusCode() + ' | ' + res.getBody();
                appendCaseLog(cas, 'ERROR: ' + msg);
                logError(msg, null, caseId, cas.Company_Profile__c);
            }

        } catch (Exception e) {
            String msg = 'PartnerOnboarding | Unexpected error: ' + e.getMessage();
            if (cas != null) appendCaseLog(cas, 'ERROR: ' + msg + '\n' + e.getStackTraceString());
            logError(msg, e, caseId, cas?.Company_Profile__c);
        }
    }

    // ─── SUCCESS HANDLER ─────────────────────────────────────────────────────
    private static void handleSuccess(String responseBody, Case cas) {
        try {
            Map<String, Object> response =
                (Map<String, Object>) JSON.deserializeUntyped(responseBody);

            Map<String, Object> identifiers =
                (Map<String, Object>) response.get('identifiers');

            if (identifiers == null) {
                appendCaseLog(cas, 'WARNING: Response missing identifiers block.\n' + responseBody);
                return;
            }

            String entityId       = (String)  identifiers.get('entityId');
            Object masterClientId = identifiers.get('masterClientId');

            // ── Update Compliance__c ──────────────────────────────────────────
            if (String.isNotBlank(cas.Company_Profile__c)) {
                Compliance__c comp = new Compliance__c(Id = cas.Company_Profile__c);

                if (String.isNotBlank(entityId)) {
                    comp.Nuvei_Partner_ID__c = entityId;
                }
                if (masterClientId != null) {
                    comp.MasterClient_ID__c = String.valueOf(masterClientId);
                }
                update comp;
                System.debug('PartnerOnboarding | Compliance__c updated | entityId=' + entityId
                    + ' masterClientId=' + masterClientId);
            }

            // ── Update Case ───────────────────────────────────────────────────
            String successLog =
                'Partner onboarding SUCCESS\n'
                + 'Timestamp: '     + DateTime.now().format('yyyy-MM-dd HH:mm:ss') + '\n'
                + 'Entity ID: '     + (String.isNotBlank(entityId) ? entityId : 'not returned') + '\n'
                + 'Master Client ID: ' + (masterClientId != null ? String.valueOf(masterClientId) : 'not returned') + '\n'
                + 'Full response:\n' + responseBody;

            appendCaseLog(cas, successLog);

            // Update case status to Configuration Completed
            cas.Status = 'Configuration Completed';
            update cas;

        } catch (Exception e) {
            appendCaseLog(cas, 'ERROR processing success response: ' + e.getMessage() + '\n' + responseBody);
            logError('handleSuccess failed', e, cas.Id, cas.Company_Profile__c);
        }
    }

    // ─── CASE FETCHER ────────────────────────────────────────────────────────
    private static Case fetchCase(String caseId) {
        Case cas = [
            SELECT Id, Status, Logs__c, Company_Profile__c,
                   SB_PPP_Username__c, SB_PPP_Password__c,
                   ContactId,
                   Contact.FirstName, Contact.LastName, Contact.Email, Contact.Phone,
                   Company_Profile__r.Name,
                   Company_Profile__r.Registered_Street__c,
                   Company_Profile__r.Registered_City__c,
                   Company_Profile__r.Registered_Country_Code2__c,
                   Company_Profile__r.Registered_Zip_Postal_Code__c,
                   Company_Profile__r.Nuvei_Partner_ID__c,
                   Company_Profile__r.MasterClient_ID__c,
                   Company_Profile__r.Primary_Contact__c,
                   Company_Profile__r.Primary_Contact__r.Email,
                   Company_Profile__r.Primary_Contact__r.Phone
            FROM   Case
            WHERE  Id = :caseId
            LIMIT  1
        ];

        // Fetch contact separately if not inline
        if (cas.ContactId != null && cas.Contact == null) {
            cas.Contact = [
                SELECT Id, FirstName, LastName, Email, Phone
                FROM   Contact
                WHERE  Id = :cas.ContactId
                LIMIT  1
            ];
        }

        return cas;
    }

    // ─── CONFIG FETCHER ──────────────────────────────────────────────────────
    private static ExpressConfig__c fetchConfig() {
        return [
            SELECT PO_prod_endpoint__c, PO_prod_token_endpoint__c, PO_prod_secret__c,
                   PO_SB_endpoint__c,   PO_SB_token_endpoint__c,   PO_SB_secret__c,
                   Exception_email__c
            FROM   ExpressConfig__c
            LIMIT  1
        ];
    }

    // ─── CASE LOG HELPER ─────────────────────────────────────────────────────
    private static void appendCaseLog(Case cas, String message) {
        try {
            String separator = '\n─────────────────────────────────────────\n';
            String existing  = String.isBlank(cas.Logs__c) ? '' : cas.Logs__c + separator;
            cas.Logs__c      = existing + message;
            update cas;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'PartnerOnboarding | appendCaseLog failed: ' + e.getMessage());
        }
    }

    // ─── ERROR LOGGER ────────────────────────────────────────────────────────
    private static void logError(String message, Exception e, String caseId, String complianceId) {
        System.debug(LoggingLevel.ERROR, 'PartnerOnboarding ERROR | ' + message
            + (e != null ? ' | ' + e.getMessage() : ''));
        try {
            Execution_Log__c el = new Execution_Log__c(
                RecordTypeId      = RT_EL_NC,
                Class_Name__c     = 'PartnerOnboardingController',
                Initiated_By__c   = UserInfo.getUserId(),
                Method_Name__c    = 'sendPartnerRequest',
                Description__c    = message,
                Path__c           = e != null ? e.getStackTraceString() : '',
                Related_Record_Id__c = String.isNotBlank(complianceId) ? complianceId : caseId,
                Status_Code__c    = 400,
                Type__c           = 'Error'
            );
            WithoutSharingUtils.insertRecord(el);
        } catch (Exception logEx) {
            System.debug(LoggingLevel.ERROR,
                'PartnerOnboarding | Failed to write Execution_Log__c: ' + logEx.getMessage());
        }
    }

    // ─── OAUTH TOKEN ─────────────────────────────────────────────────────────
    private static String getAccessToken(String tokenEndpoint, String clientSecret) {
        try {
            HttpRequest tokenReq = new HttpRequest();
            tokenReq.setEndpoint(tokenEndpoint);
            tokenReq.setMethod('POST');
            tokenReq.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            tokenReq.setBody(
                'grant_type=client_credentials'
                + '&scope=digital.gateway.boarding.api.scope'
                + '&client_id=processmanager'
                + '&client_secret=' + clientSecret
            );

            HttpResponse tokenRes = new Http().send(tokenReq);
            System.debug('PartnerOnboarding | tokenStatus=' + tokenRes.getStatusCode());

            if (tokenRes.getStatusCode() == 200) {
                Map<String, Object> tokenMap =
                    (Map<String, Object>) JSON.deserializeUntyped(tokenRes.getBody());
                return (String) tokenMap.get('access_token');
            }
            System.debug(LoggingLevel.ERROR,
                'PartnerOnboarding | Token request failed: ' + tokenRes.getStatusCode()
                + ' ' + tokenRes.getBody());
            return null;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'PartnerOnboarding | getAccessToken exception: ' + e.getMessage());
            return null;
        }
    }

    // ─── PAYLOAD INNER CLASS ─────────────────────────────────────────────────
    /**
     * NCP partner onboarding request payload.
     * Built from the Configuration Case and linked Compliance__c.
     */
    public class PartnerPayload {

        public String         username;
        public String         profile;
        public String         name;
        public AddressBlock   address;
        public IdentifiersBlock identifiers;
        public List<UserBlock> users;
        public List<FeaturesBlock> features;
        public List<ContactBlock> contacts;

        public PartnerPayload(Case cas) {
            this.username = UserInfo.getUserName();
            this.profile  = 'Partner onboarding';
            this.name     = cas.Company_Profile__r.Name;

            // ── Address from Compliance__c registered address ─────────────────
            this.address = new AddressBlock();
            this.address.line1      = cas.Company_Profile__r.Registered_Street__c;
            this.address.city       = cas.Company_Profile__r.Registered_City__c;
            this.address.country    = cas.Company_Profile__r.Registered_Country_Code2__c;
            this.address.postalCode = cas.Company_Profile__r.Registered_Zip_Postal_Code__c;
            this.address.state      = cas.Company_Profile__r.Registered_Country_Code2__c; // fallback

            // ── Identifiers — EU Indirect Salesforce ID (Company Profile SFID) ─
            this.identifiers = new IdentifiersBlock();
            this.identifiers.euIndirectSalesforceId = cas.Company_Profile__c;

            // ── cPanel admin user from Case Contact ───────────────────────────
            UserBlock adminUser   = new UserBlock();
            adminUser.username     = cas.SB_PPP_Username__c;
            adminUser.email        = cas.Contact?.Email;
            adminUser.password     = MerchantValidator.genPassword(8);
            adminUser.adminOfAdmins = true;
            adminUser.roles        = new List<String>{ 'management' };

            NameBlock nm           = new NameBlock();
            nm.first               = cas.Contact?.FirstName;
            nm.last                = cas.Contact?.LastName;
            adminUser.name         = nm;

            // Store generated password on Case for reference
            cas.SB_PPP_Password__c = adminUser.password;

            this.users    = new List<UserBlock>{ adminUser };

            // ── Features — Phase 1: WhiteLabel disabled ───────────────────────
            // Phase 2: drive from partner settings Custom Object
            FeaturesPropertiesBlock props = new FeaturesPropertiesBlock();
            props.enableWhiteLabel        = false;
            props.BypassCWOS              = 0;
            props.BypassExcessiveCredits  = 0;
            props.BypassExcessiveTrans    = 0;
            props.BypassForcePost         = 0;

            FeaturesBlock featureItem = new FeaturesBlock();
            featureItem.name         = 'WhiteLabel';
            featureItem.properties   = props;
            this.features            = new List<FeaturesBlock>{ featureItem };

            // ── Primary contact from Compliance__c ────────────────────────────
            ContactBlock primaryContact = new ContactBlock();
            primaryContact.email = cas.Company_Profile__r.Primary_Contact__r?.Email;
            primaryContact.phone = cas.Company_Profile__r.Primary_Contact__r?.Phone;
            primaryContact.type  = 'primary';

            this.contacts = new List<ContactBlock>{ primaryContact };
        }
    }

    public class AddressBlock {
        public String line1;
        public String city;
        public String state;
        public String country;
        public String postalCode;
    }

    public class IdentifiersBlock {
        public String euIndirectSalesforceId;
    }

    public class UserBlock {
        public String        username;
        public NameBlock     name;
        public String        email;
        public List<String>  roles;
        public Boolean       adminOfAdmins;
        public String        password;
    }

    public class NameBlock {
        public String first;
        public String last;
    }

    public class FeaturesBlock {
        public String             name;
        public FeaturesPropertiesBlock properties;
    }

    public class FeaturesPropertiesBlock {
        public Boolean enableWhiteLabel;
        public Integer BypassCWOS;
        public Integer BypassExcessiveCredits;
        public Integer BypassExcessiveTrans;
        public Integer BypassForcePost;
    }

    public class ContactBlock {
        public String email;
        public String phone;
        public String type;
    }
}
