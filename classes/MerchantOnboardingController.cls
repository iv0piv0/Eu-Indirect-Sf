public with sharing class MerchantOnboardingController {
    public String caseId { get; set; }
    public String errorMessage { get; set; }
    public Boolean isSandbox { get; set; }
    public Boolean isProduction { get; set; }
    
    
    
    public MerchantOnboardingController(ApexPages.StandardController stdController) {
        caseId = stdController.getId();
        
    }
    public PageReference createSandbox() {
        return createMerchant(false, false); // isProd = false
    }
    
    public PageReference createProduction() {
        return createMerchant(true, false); // isProd = true
    }
    
    public PageReference createPayfacSandbox() {
        return createMerchant(false, true); // isProd = false, isPayFac = true
    }
    
    public PageReference createPayfacProduction() {
        return createMerchant(true, true); // isProd = true, isPayFac = true
    }
    
    public PageReference createMerchant(Boolean isProd, Boolean isPayFac) {
        System.debug('===> Inside createMerchant, isProd: ' + isProd);
        System.debug('caseId: '+caseId);
        if (String.isBlank(caseId)) {
            errorMessage = 'Case ID is missing.';
            return null;
        }
        Case cas = fetchCase(caseId);
        
        List<String> missingFields = validateRequiredFields(cas, isPayFac);
        
        if (!missingFields.isEmpty()) {
            errorMessage = 'Please review:\n' + String.join(missingFields, '\n');
            System.debug('errorMessage :'+errorMessage);
            return null;
        }
        
        
        sendMerchantRequest(caseId, isProd, isPayFac);
        return new PageReference('/' + caseId).setRedirect(true);
    }
    
    @InvocableMethod(label='Create Merchant Flow' description='Creates Merchant from Flow')
    public static List<ResponseWrapper> createMerchantFromFlow(List<RequestWrapper> requests) {
        List<ResponseWrapper> responses = new List<ResponseWrapper>();
        
        for (RequestWrapper request : requests) {
            ResponseWrapper response = new ResponseWrapper();
            
            Case cas = fetchCase(request.caseId);
            List<String> missingFields = validateRequiredFields(cas, request.isPayFac);
            
            if (!missingFields.isEmpty()) {
                response.missingFields = missingFields; // Adding missing fields to the response
            } else {
                Boolean payFac = request.isPayFac != null && request.isPayFac;
                sendMerchantRequest(request.caseId, request.isProd, payFac);
            }
            
            responses.add(response);
        }
        
        return responses;
    }
    
    public  class RequestWrapper {
        @InvocableVariable(required=true)
        public String caseId;
        
        @InvocableVariable
        public Boolean isProd;

        @InvocableVariable
        public Boolean isPayFac;
    }
    
    public  class ResponseWrapper {
        
        
        @InvocableVariable
        public List<String> missingFields; // New: Returns list of missing fields
    }
    
    // Wave 1 fix (gap #2): removed @future from this 2-arg overload — calling
    // an @future from inside another @future throws System.AsyncException, which
    // marked Compliance 'Failed NCP' even when NCP succeeded. This is now a thin
    // synchronous wrapper that delegates to the 3-arg @future. All callers
    // (createMerchant page action, createMerchantFromFlow invocable) are sync,
    // so the @future is still kicked off exactly once per request.
    public static void sendMerchantRequest(String caseId, Boolean isProd) {
        sendMerchantRequest(caseId, isProd, false); // ברירת מחדל – לא PayFac
    }
    
    @future(callout=true)
    public static void sendMerchantRequest(String caseId, Boolean isProd, Boolean isPayFac) {
        System.debug('===> Inside sendMerchantRequest, caseId: ' + caseId);
        
        try {
            Case cas = fetchCase(caseId);
            Id complianceId = cas.Company_Profile__c;
            Boolean euIndirect = complianceId != null && cas.Company_Profile__r != null
                && cas.Company_Profile__r.EU_Indirect_Orchestration__c == true;

            // NOTE — Salesforce forbids HTTP callouts AFTER any DML in the same
            // transaction, even inside @future. The router
            // (IndirectBoardingRouter.tryTrackNcp) already sets
            // Technical_Onboarding_Status__c = 'In Progress' in its own
            // transaction BEFORE invoking this @future, and that update is
            // committed by the time we get here. Re-writing it here would
            // dirty the transaction and force the OAuth callout to throw
            // System.CalloutException: "You have uncommitted work pending".
            // So for the EU indirect path we deliberately do NO DML between
            // here and the token / merchant callouts. All DML happens AFTER
            // the responses come back.

            ExpressConfig__c config = [
                SELECT MO_SB_endpoint__c, MO_prod_endpoint__c, 
                       MO_SB_token_endpoint__c, MO_prod_token_endpoint__c, Exception_email__c,
                       MO_SB_secret__c, MO_prod_secret__c 
                FROM ExpressConfig__c 
                LIMIT 1
            ];
            
            List<Website__c> websiteRecords = [
                SELECT Name 
                FROM Website__c  
                WHERE Compliance__c = :cas.Company_Profile__c 
                ORDER BY Primary_URL__c DESC, CreatedDate ASC 
                LIMIT 1
            ];
            
            String endpoint = isProd ? config.MO_prod_endpoint__c : config.MO_SB_endpoint__c;
            String tokenEndpoint = isProd ? config.MO_prod_token_endpoint__c : config.MO_SB_token_endpoint__c;
            String clientSecret = isProd ? config.MO_prod_secret__c : config.MO_SB_secret__c;
            
            System.debug('endpoint: ' + endpoint);
            System.debug('tokenEndpoint: ' + tokenEndpoint);
            System.debug('clientSecret: ' + clientSecret);
            
            TokenResult tokenResult = getAccessTokenWithDetails(tokenEndpoint, clientSecret);
            String accessToken = tokenResult.accessToken;
            System.debug('accessToken: ' + accessToken);

            if (String.isBlank(accessToken)) {
                if (euIndirect) {
                    // Build a Description__c that names the exact reason — the
                    // upstream HTTP code / response body / CalloutException —
                    // and pass the upstream Status_Code__c (or 401 fallback)
                    // so the Execution_Log__c list view pivots on the real value.
                    String reason = tokenResult.errorMessage != null
                        ? tokenResult.errorMessage
                        : 'OAuth token request failed (no further detail available)';
                    String detail = 'Track F: OAuth token request failed.\n'
                        + 'Reason: ' + reason + '\n'
                        + 'Token endpoint: ' + tokenEndpoint + '\n'
                        + 'isProd flag: ' + isProd;
                    String responsePayload = null;
                    if (String.isNotBlank(tokenResult.body)) {
                        responsePayload = tokenResult.body.length() > 4000
                            ? tokenResult.body.substring(0, 4000)
                            : tokenResult.body;
                    }
                    Integer effectiveCode = (tokenResult.statusCode != null && tokenResult.statusCode > 0)
                        ? tokenResult.statusCode
                        : 401;
                    BoardingErrorLogService.log(
                        BoardingErrorLogService.Level.ERROR,
                        'MerchantOnboardingController',
                        'sendMerchantRequest',
                        complianceId,
                        cas.Company_Profile__r.Nuvei_Connect_Application_ID__c,
                        'Track F: Technical Onboarding (NCP)',
                        detail,
                        null,
                        responsePayload,
                        effectiveCode
                    );
                    bumpTrackFRetryCount(complianceId);
                    update new Compliance__c(
                        Id = complianceId,
                        Technical_Onboarding_Status__c = 'Failed NCP'
                    );
                }
                return;
            }
            
            MerchantPayload payload = new MerchantPayload(cas, isProd, isPayFac);
            String payloadJson = JSON.serialize(payload, true);
            
            Map<String, Object> payloadMap = (Map<String, Object>) JSON.deserializeUntyped(payloadJson);
            System.debug('payload: ' + JSON.serializePretty(payloadMap));
            
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
            
            System.debug('=== Request Sent ===');
            System.debug('Request URL: ' + req.getEndpoint());
            System.debug('Request Method: ' + req.getMethod());
            System.debug('Request Headers: ' + req.getHeader('Content-Type'));
            System.debug('Request Body: ' + req.getBody());
            System.debug('===================');
            
            System.debug('=== Response Received ===');
            System.debug('Response Status Code: ' + res.getStatusCode());
            System.debug('Response Body: ' + res.getBody());
            
            // Wave 1 fix (gap #1): accept any 2xx as success. Prod NCP returns
            // HTTP 200 (not just 202/207), which previously made the success
            // path never fire and left Technical_Onboarding_Status__c stuck
            // at 'In Progress' even when the merchant was created in NCP.
            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                System.debug('Response Status is successful, calling handleResponse()...');
                handleResponse(res.getBody(), cas, isProd);
                if (euIndirect) {
                    update new Compliance__c(
                        Id = complianceId,
                        Technical_Onboarding_Status__c = 'Completed'
                    );
                }
            } else {
                System.debug('Response Status is not successful, saving response to Case...');
                
                
                if (cas.Company_Profile__c != null) {
                    try {
                        Compliance__c profile = [
                            SELECT Id, Configuration_Issue_Details__c
                            FROM Compliance__c
                            WHERE Id = :cas.Company_Profile__c
                            LIMIT 1 
                        ];
                        profile.Configuration_Issue_Details__c = 'MerchantOnboarding response log:\n' + res.getBody();
                        update profile;
                    } catch (DmlException e) {
                        System.debug('Failed to update Compliance__c: ' + e.getMessage());
                    }
                }
                if (euIndirect) {
                    // Echo the upstream HTTP code (Status_Code__c) so reports/list views
                    // can pivot on the real response — not a generic 500.
                    BoardingErrorLogService.log(
                        BoardingErrorLogService.Level.ERROR,
                        'MerchantOnboardingController',
                        'sendMerchantRequest',
                        complianceId,
                        cas.Company_Profile__r.Nuvei_Connect_Application_ID__c,
                        'Track F: Technical Onboarding (NCP)',
                        'Track F: NCP API returned HTTP ' + res.getStatusCode(),
                        null,
                        req.getBody(),
                        res.getStatusCode()
                    );
                    bumpTrackFRetryCount(complianceId);
                    update new Compliance__c(
                        Id = complianceId,
                        Technical_Onboarding_Status__c = 'Failed NCP'
                    );
                }
                
                sendErrorEmail(config.Exception_email__c, cas, res.getBody());
                
                
            }
            
            cas.Create_Account_Response__c = res.getBody();
            cas.SB_PPP_Password__c = MerchantValidator.genPassword(8);
            
            update cas;
            
        } catch (Exception e) {
            System.debug('General Exception in sendMerchantRequest: ' + e.getMessage());
            try {
                Case casEx = fetchCase(caseId);
                if (casEx.Company_Profile__c != null && casEx.Company_Profile__r.EU_Indirect_Orchestration__c == true) {
                    BoardingErrorLogService.logError(
                        'MerchantOnboardingController',
                        'sendMerchantRequest',
                        casEx.Company_Profile__c,
                        casEx.Company_Profile__r.Nuvei_Connect_Application_ID__c,
                        'Track F: Technical Onboarding (NCP)',
                        'Track F: unexpected exception during NCP call',
                        e,
                        null
                    );
                    bumpTrackFRetryCount(casEx.Company_Profile__c);
                    update new Compliance__c(
                        Id = casEx.Company_Profile__c,
                        Technical_Onboarding_Status__c = 'Failed NCP'
                    );
                }

                casEx.Create_Account_Response__c = e.getMessage();            
                update casEx;
            } catch (Exception ignore) {
                System.debug('sendMerchantRequest | secondary error handling failed');
            }
        }
    }
    
    
    
    public static void sendErrorEmail(String recipientList, Case cas, String body) {
        if (String.isBlank(recipientList)) return;
        
        List<String> recipients = recipientList.split(',');
        
        Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
        email.setToAddresses(recipients);
        email.setSubject('Merchant Onboarding - Error');
        email.setSenderDisplayName('CREATE_GATEWAY_API');
        
        String emailBody = 'Case ID: ' + cas.Id +
            '\nCompany Profile: ' + cas.Company_Profile__c +
            '\n\nResponse Body:\n' + body;
        
        email.setPlainTextBody(emailBody);
        
        if (!Test.isRunningTest()) {
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage> { email });
        }
    }
    
    
    
    
    
    
    public static Case fetchCase(String caseId) {
        System.debug('===> Inside fetchCase, caseId: ' + caseId);
        
        // שליפת המקרה עצמו
        Case cas = [
            SELECT Id, Company_Profile__c, Integration_Channel__c, ContactId, SB_PPP_Username__c, SB_PPP_Password__c, SB_Template__c, Profile__c, Location__c, 
                   Location__r.Name, Location__r.Email_Address__c, Location__r.Street__c, Location__r.City__c, 
                   Location__r.Country__c, Location__r.Postal_Code__c, Location__r.Phone_Number__c,
                   Platform_Integration__c,
                   Contact.FirstName, Contact.LastName, Contact.Email, Contact.Phone
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];
        
        
        
        System.debug('===> Case fetched: ' + cas);
        
        // שליפת ה-Contact
        if (cas.ContactId != null) {
            cas.Contact = [
                SELECT Id, Name, FirstName, LastName, Email, MailingStreet, MailingCity, MailingCountry, MailingPostalCode, Phone
                FROM Contact
                WHERE Id = :cas.ContactId
            ];
            System.debug('===> Contact fetched: ' + cas.Contact);
        }
        
        // שליפת ה-Compliance__c (Company_Profile)
        if (cas.Company_Profile__c != null) {
            cas.Company_Profile__r = [
                SELECT Id, Name, Registered_Country_Code2__c, Registered_Zip_Postal_Code__c, MCC_Code__c, VAT_Number__c, 
                       Registered_Street__c, Registered_City__c, Primary_Contact__r.Phone, MSA_Effective_Date__c, 
                       City_field__c, Merchant_Tier__c, State_USA__c, Registered_Country__c, Primary_Contact__c, 
                       Primary_Contact__r.Id, Primary_Contact__r.Email, Primary_Contact__r.FirstName, 
                       Primary_Contact__r.LastName, Primary_Contact__r.MailingStreet, Primary_Contact__r.MailingCity,
                       Primary_Contact__r.MailingCountry, Primary_Contact__r.MailingPostalCode,
                       Account__r.Id, Account__r.Name,
                       Sales_Rep__c, Sales_Rep__r.FirstName, Sales_Rep__r.LastName, Sales_Rep__r.Email,
                       Account_Manager__c, Account_Manager__r.FirstName, Account_Manager__r.LastName, Account_Manager__r.Email,
                       Account_Operational_Manager_CP__c, Account_Operational_Manager_CP__r.FirstName, 
                       Account_Operational_Manager_CP__r.LastName, Account_Operational_Manager_CP__r.Email,
                       From_Reseller__r.Id, From_Reseller__r.Name, From_Reseller__r.Nuvei_Partner_ID__c, From_Reseller__r.Credentials_URL__c,
                       From_Reseller__r.Overwrite_Financial_Vertical__c,
                       Overwrite_Financial_Vertical__c, Origin_Region__c, Visa_Payfac_ID__c, Mastercard_Payfac_ID__c,
                       Nuvei_Connect_Application_ID__c, EU_Indirect_Orchestration__c
                FROM Compliance__c
                WHERE Id = :cas.Company_Profile__c
            ];
            System.debug('===> Compliance Profile fetched: ' + cas.Company_Profile__r);
        }
        
        return cas;
    }
    
    
    
    
    public static List<String> validateRequiredFields(Case cas, Boolean isPayFac) {
        List<String> missingFields = new List<String>();
        
        if (String.isBlank(cas.SB_Template__c)) missingFields.add('SB Template');
        if (String.isBlank(cas.Company_Profile__c)) missingFields.add('Company profile Name');
        
        
        if (cas.Location__c != null || cas.Company_Profile__c != null) {
            if ( cas.Company_Profile__c != null && String.isBlank(cas.Company_Profile__r.Name)) missingFields.add('company profile Name');
            if ( cas.Location__c != null && String.isBlank(cas.Location__r.Name)) missingFields.add('location Name');
            if (cas.Location__c !=null && String.isBlank(cas.Location__r.Street__c )) missingFields.add('Location Street');
            if (cas.Company_Profile__c !=null && String.isBlank(cas.Company_Profile__r.Registered_Country__c)) missingFields.add('Please review Country Of Incorporation');
            if(String.isBlank(cas.Company_Profile__r.State_USA__c) && (cas.Company_Profile__r.Registered_Country__c =='United States' ||cas.Company_Profile__r.Registered_Country__c =='Canada' || cas.Company_Profile__r.Registered_Country__c =='United Kingdom')) missingFields.add('State/ Country/ Province ');
            if(cas.Company_Profile__c !=null && String.isBlank(cas.Company_Profile__r.Registered_Zip_Postal_Code__c)) missingFields.add('Registered zip postal code');
            if(cas.Location__c !=null && String.isBlank(cas.Location__r.Postal_Code__c)) missingFields.add('Location postal code');
            if(cas.Company_Profile__c !=null && String.isBlank(cas.Company_Profile__r.City_field__c)) missingFields.add('City field');
            if(cas.Location__c !=null && String.isBlank(cas.Location__r.Phone_Number__c)) missingFields.add('Phone Number');
            if (String.isBlank(cas.Company_Profile__r.Registered_Street__c)) missingFields.add('Registered Street');
            if (String.isBlank(cas.Company_Profile__r.Registered_City__c)) missingFields.add('Registered City');
            if(String.isBlank(cas.Company_Profile__r.MCC_Code__c)) missingFields.add('MCC Code');
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.FirstName)) missingFields.add('Primary Contact First Name');
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.LastName)) missingFields.add('Primary Contact Last Name');
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.MailingStreet) && String.isBlank(cas.Company_Profile__r.Registered_Street__c)) {
                missingFields.add('Primary Contact Mailing/registered Street');
            }
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.MailingCity) && String.isBlank(cas.Company_Profile__r.Registered_City__c)) {
                missingFields.add('Primary Contact Mailing/registered City');
            }
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.MailingCountry) && String.isBlank(cas.Company_Profile__r.Registered_Country__c)) {
                missingFields.add('Primary Contact Mailing/registered Country');
            }
            
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.MailingPostalCode) && String.isBlank(cas.Company_Profile__r.Registered_Zip_Postal_Code__c)) {
                missingFields.add('Primary Contact Registered postal code');
            }
            
            
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.Email)) missingFields.add('Primary Contact Email');
            
            if (String.isBlank(cas.Company_Profile__r.Primary_Contact__r.Phone) && String.isBlank(cas.Company_Profile__r.City_field__c)) {
                missingFields.add('Primary Contact City field');
            }
            
            if (isPayFac) {
                
                if (String.isBlank(cas.Company_Profile__r.Visa_Payfac_ID__c)) {
                    missingFields.add('Visa PayFac ID');
                }
                if (String.isBlank(cas.Company_Profile__r.Mastercard_Payfac_ID__c)) {
                    missingFields.add('Mastercard PayFac ID');
                }
                
            }
        }
        
        
        
        if(String.isBlank(cas.SB_PPP_Username__c)) missingFields.add('C-Panel Username');
        if(String.isBlank(cas.Contact.FirstName)) missingFields.add('Contact First Name');
        if(String.isBlank(cas.Contact.LastName)) missingFields.add('Contact Last Name');
        if(String.isBlank(cas.Contact.Email)) missingFields.add('Contact Email');
        
        
        
        
        // if (MerchantValidator.isPaymentProcessingRequired(cas)) {
            //     String stateValue = MerchantValidator.getStateCode(
            //         cas.Company_Profile__r.Registered_Country__c,
            //     cas.Company_Profile__r.State_USA__c
            //         );
            //     if (String.isBlank(stateValue)) {
                //         missingFields.add('State is mandatory when paymentProcessing is required');
            //     }
        // }
        
        return missingFields;
    }
    
    
    // 👇 הוספנו לוגיקה חדשה לשמירת הלוג + שליחת מייל במקרה של שגיאה מה-Response
    public static void handleResponse(String responseBody, Case cas, Boolean isProd) {
        Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
        
        // שמירת הלוג המלא ב-Company_Profile__c
        
        
        // המשך הטיפול הרגיל בתגובה (כפי שכבר קיים)
        Map<String, Object> merchantMap = (Map<String, Object>) response.get('merchant');
        Map<String, Object> merchantIdentifiers = merchantMap != null ? (Map<String, Object>) merchantMap.get('identifiers') : null;
        
        Map<String, Object> paymentProcessing = (Map<String, Object>) response.get('paymentProcessing');
        Map<String, Object> paymentIdentifiers = paymentProcessing != null ? (Map<String, Object>) paymentProcessing.get('identifiers') : null;
        Map<String, Object> paymentCredentials = paymentProcessing != null ? (Map<String, Object>) paymentProcessing.get('credentials') : null;
        
        String merchantName = merchantMap != null && merchantMap.containsKey('name') ? (String) merchantMap.get('name') : null;
        
        if (isProd) {
            GW_Name__c newGW = new GW_Name__c(
                Name = merchantName != null ? merchantName : 'Unknown Merchant ' + System.currentTimeMillis(),
            MultiClient_Name__c = merchantName,
            Client_Name__c = paymentProcessing != null && paymentProcessing.containsKey('name') ? (String) paymentProcessing.get('name') : null,
            MultiClient_ID__c = merchantIdentifiers != null ? String.valueOf(merchantIdentifiers.get('multiClientId')) : null,
            Merchant_ID__c = merchantIdentifiers != null ? String.valueOf(merchantIdentifiers.get('merchantId')) : null,
            Client_ID__c = paymentIdentifiers != null ? String.valueOf(paymentIdentifiers.get('clientId')) : null,
            Merchant_Site_ID__c = paymentIdentifiers != null ? String.valueOf(paymentIdentifiers.get('merchantSiteId')) : null,
            GW_Login_ID__c = paymentCredentials != null ? (String) paymentCredentials.get('clientLogin') : null,
            GW_Password__c = paymentCredentials != null ? (String) paymentCredentials.get('clientPassword') : null,
            Compliance__c = cas.Company_Profile__c
                );
            insert newGW;
            cas.GW_Name__c = newGW.Id;
        } else {
            cas.SB_MultiClient_Name__c = merchantName;
            cas.SB_MultiClient_ID__c = merchantIdentifiers != null ? String.valueOf(merchantIdentifiers.get('multiClientId')) : null;
            cas.SB_Client_Name__c = paymentProcessing != null && paymentProcessing.containsKey('name') ? (String) paymentProcessing.get('name') : null;
            cas.SB_Client_ID__c = paymentIdentifiers != null ? String.valueOf(paymentIdentifiers.get('clientId')) : null;
            cas.SB_GW_Login_ID__c = paymentCredentials != null ? (String) paymentCredentials.get('clientLogin') : null;
            cas.SB_GW_Password__c = paymentCredentials != null ? (String) paymentCredentials.get('clientPassword') : null;
            // Mirror GW on Compliance for FinanceIntegration (expects GW_Names__r) while retaining Case SB fields for legacy UI
            GW_Name__c sbGw = new GW_Name__c(
                Name = merchantName != null ? merchantName : 'Unknown Merchant ' + System.currentTimeMillis(),
                MultiClient_Name__c = merchantName,
                Client_Name__c = paymentProcessing != null && paymentProcessing.containsKey('name')
                    ? (String) paymentProcessing.get('name') : null,
                MultiClient_ID__c = merchantIdentifiers != null ? String.valueOf(merchantIdentifiers.get('multiClientId')) : null,
                Merchant_ID__c = merchantIdentifiers != null ? String.valueOf(merchantIdentifiers.get('merchantId')) : null,
                Client_ID__c = paymentIdentifiers != null ? String.valueOf(paymentIdentifiers.get('clientId')) : null,
                Merchant_Site_ID__c = paymentIdentifiers != null ? String.valueOf(paymentIdentifiers.get('merchantSiteId')) : null,
                GW_Login_ID__c = paymentCredentials != null ? (String) paymentCredentials.get('clientLogin') : null,
                GW_Password__c = paymentCredentials != null ? (String) paymentCredentials.get('clientPassword') : null,
                Compliance__c = cas.Company_Profile__c
            );
            insert sbGw;
            cas.GW_Name__c = sbGw.Id;
        }
        cas.Activation_Link__c = paymentCredentials != null ? (String) paymentCredentials.get('activationLink') : null;
    }
    
    
    
    /**
     * Wraps the OAuth token-exchange outcome so callers can log the REAL reason
     * the token request failed (HTTP 4xx vs 5xx vs CalloutException vs empty
     * access_token) instead of seeing a generic "OAuth token request failed or
     * returned empty token" message. Used by sendMerchantRequest to populate
     * Execution_Log__c.Status_Code__c / Description__c with the upstream truth.
     */
    public class TokenResult {
        public String accessToken;
        public Integer statusCode;
        public String body;
        public String errorMessage;
        public Boolean isSuccess() {
            return String.isNotBlank(accessToken);
        }
    }

    /**
     * Detailed OAuth token-exchange. Always returns a populated TokenResult so
     * the caller can build a precise Execution_Log__c entry. Never throws.
     */
    public static TokenResult getAccessTokenWithDetails(String tokenEndpoint, String clientSecret) {
        TokenResult r = new TokenResult();
        if (String.isBlank(tokenEndpoint)) {
            r.errorMessage = 'Token endpoint is blank — verify ExpressConfig__c.MO_SB_token_endpoint__c / MO_prod_token_endpoint__c';
            return r;
        }
        if (String.isBlank(clientSecret)) {
            r.errorMessage = 'Client secret is blank — verify ExpressConfig__c.MO_SB_secret__c / MO_prod_secret__c';
            return r;
        }
        try {
            HttpRequest tokenRequest = new HttpRequest();
            tokenRequest.setEndpoint(tokenEndpoint);
            tokenRequest.setMethod('POST');
            tokenRequest.setTimeout(60000);
            tokenRequest.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            String requestBody = 'grant_type=client_credentials'
                + '&scope=digital.gateway.boarding.api.scope'
                + '&client_id=processmanager'
                + '&client_secret=' + EncodingUtil.urlEncode(clientSecret, 'UTF-8');
            tokenRequest.setBody(requestBody);

            HttpResponse tokenResponse = new Http().send(tokenRequest);
            r.statusCode = tokenResponse.getStatusCode();
            r.body = tokenResponse.getBody();

            if (r.statusCode == 200) {
                try {
                    Map<String, Object> tokenResponseMap =
                        (Map<String, Object>) JSON.deserializeUntyped(r.body);
                    r.accessToken = (String) tokenResponseMap.get('access_token');
                    if (String.isBlank(r.accessToken)) {
                        r.errorMessage = 'Token endpoint returned HTTP 200 but the JSON body did not contain a non-empty access_token field';
                    }
                } catch (Exception parseEx) {
                    r.errorMessage = 'Token endpoint returned HTTP 200 but the body could not be parsed as JSON: '
                        + parseEx.getTypeName() + ': ' + parseEx.getMessage();
                }
            } else {
                r.errorMessage = 'Token endpoint returned HTTP ' + r.statusCode
                    + ' — verify isProd flag, token endpoint URL, and client secret '
                    + 'are pointing at the same NCP environment.';
            }
        } catch (System.CalloutException ce) {
            r.errorMessage = 'CalloutException reaching token endpoint: ' + ce.getMessage()
                + ' — likely a Remote Site Setting / TLS / DNS issue.';
        } catch (Exception e) {
            r.errorMessage = 'Unexpected ' + e.getTypeName() + ' during token exchange: ' + e.getMessage();
        }
        return r;
    }

    /**
     * Backward-compatible wrapper kept for any non-orchestration caller that
     * just wants the bare token string. New orchestration code paths should
     * use getAccessTokenWithDetails so failures surface in Execution_Log__c.
     */
    public static String getAccessToken(String tokenEndpoint, String clientSecret) {
        return getAccessTokenWithDetails(tokenEndpoint, clientSecret).accessToken;
    }

    /**
     * Increments Compliance__c.Track_F_Retry_Count__c by 1.
     *
     * Used by the failure paths in sendMerchantRequest so the router's Track F
     * circuit breaker (IndirectBoardingRouter.MAX_RETRIES) can stop the auto
     * retry loop. Best-effort — a counter increment must never abort the
     * orchestration's terminal-status write.
     */
    @TestVisible
    private static void bumpTrackFRetryCount(Id complianceId) {
        if (complianceId == null) return;
        try {
            List<Compliance__c> rows = [
                SELECT Track_F_Retry_Count__c
                FROM Compliance__c
                WHERE Id = :complianceId
                LIMIT 1
            ];
            if (rows.isEmpty()) return;
            Decimal current = rows[0].Track_F_Retry_Count__c == null ? 0 : rows[0].Track_F_Retry_Count__c;
            update new Compliance__c(
                Id = complianceId,
                Track_F_Retry_Count__c = current + 1
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'MerchantOnboardingController.bumpTrackFRetryCount | ' + e.getTypeName() + ': ' + e.getMessage());
        }
    }

}
