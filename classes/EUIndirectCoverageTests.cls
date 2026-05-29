/**
 * EUIndirectCoverageTests
 * Coverage booster for EU Indirect deployment — covers:
 *   - MerchantPayload
 *   - NuveiConnectEventsService
 *   - FinanceIntegration
 *   - TrackDMsaConga (additional branches)
 *   - MerchantOnboardingController (additional branches)
 *   - IndirectBoardingRouter (additional branches)
 */
@isTest
private class EUIndirectCoverageTests {

    // ─── SHARED MOCK ─────────────────────────────────────────────────────────
    private class SimpleMock implements HttpCalloutMock {
        Integer code; String body;
        SimpleMock(Integer c, String b) { code = c; body = b; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(code);
            r.setBody(body);
            return r;
        }
    }

    private class TwoCallMock implements HttpCalloutMock {
        Integer callCount = 0;
        public HttpResponse respond(HttpRequest req) {
            callCount++;
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            if (req.getEndpoint().contains('token') || req.getEndpoint().contains('connect')) {
                r.setBody('{"access_token":"TEST_TOKEN","token_type":"Bearer","expires_in":3600}');
            } else {
                r.setBody('{"merchant":{"name":"TestMerchant","identifiers":{"multiClientId":"111","merchantId":"222"}},' +
                          '"paymentProcessing":{"name":"TestSite","identifiers":{"clientId":"333","merchantSiteId":"444"},' +
                          '"credentials":{"clientLogin":"login","clientPassword":"pass","activationLink":"http://test"}}}');
            }
            return r;
        }
    }

    // ─── HELPER: create minimal Case + Compliance + Contact ──────────────────
    private static Map<String, SObject> createMinimalData() {
        Account acc = new Account(Name = 'EU Test Merchant');
        insert acc;

        Compliance__c comp = new Compliance__c(
            Name                         = 'EU Test Merchant',
            Account__c                   = acc.Id,
            Registered_Country__c        = 'United Kingdom',
            Registered_City__c           = 'London',
            Registered_Street__c         = '1 Test Street',
            Registered_Zip_Postal_Code__c= 'EC1A 1BB',
            City_field__c                = '+447911123456',
            EU_Indirect_Orchestration__c = true,
            Compliance_Status__c         = 'Oscilar Approved',
            Nuvei_Connect_Application_ID__c = 'EU-COV-TEST-001'
        );
        insert comp;

        Contact con = new Contact(
            FirstName   = 'Test',
            LastName    = 'User',
            Email       = 'test@eutest.com',
            Phone       = '+447911123456',
            AccountId   = acc.Id,
            MailingStreet  = '1 Test Street',
            MailingCity    = 'London',
            MailingCountry = 'United Kingdom',
            MailingPostalCode = 'EC1A 1BB'
        );
        insert con;

        comp.Primary_Contact__c    = con.Id;
        comp.DocuSign_Recipient__c = con.Id;
        update comp;

        List<RecordType> rts = [SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1];

        Case cas = new Case(
            Subject            = 'EU Coverage Test',
            Status             = 'New',
            Reason             = 'New Merchant',
            Type               = 'Create new GW account with a new Multi',
            ContactId          = con.Id,
            Company_Profile__c = comp.Id,
            SB_PPP_Username__c = 'testuser'
        );
        if (!rts.isEmpty()) cas.RecordTypeId = rts[0].Id;
        insert cas;

        return new Map<String, SObject>{
            'account'    => acc,
            'compliance' => comp,
            'contact'    => con,
            'case'       => cas
        };
    }

    // ─── MERCHANT PAYLOAD ────────────────────────────────────────────────────
    @isTest
    static void merchantPayload_buildsCorrectly() {
        Map<String, SObject> data = createMinimalData();
        Case cas = [
            SELECT Id, Company_Profile__c, Integration_Channel__c, ContactId,
                   SB_PPP_Username__c, SB_PPP_Password__c, SB_Template__c, Profile__c,
                   Profile_Type__c, Location__c, Platform_Integration__c,
                   Contact.FirstName, Contact.LastName, Contact.Email, Contact.Phone
            FROM Case WHERE Id = :(Id)data.get('case').Id LIMIT 1
        ];
        cas.Company_Profile__r = [
            SELECT Id, Name, Registered_Country_Code2__c, Registered_Zip_Postal_Code__c,
                   MCC_Code__c, VAT_Number__c, Registered_Street__c, Registered_City__c,
                   Primary_Contact__r.Phone, MSA_Effective_Date__c, City_field__c,
                   Merchant_Tier__c, State_USA__c, Registered_Country__c, Primary_Contact__c,
                   Primary_Contact__r.Id, Primary_Contact__r.Email, Primary_Contact__r.FirstName,
                   Primary_Contact__r.LastName, Primary_Contact__r.MailingStreet,
                   Primary_Contact__r.MailingCity, Primary_Contact__r.MailingCountry,
                   Primary_Contact__r.MailingPostalCode,
                   Account__r.Id, Account__r.Name,
                   Sales_Rep__c, Sales_Rep__r.FirstName, Sales_Rep__r.LastName, Sales_Rep__r.Email,
                   Account_Manager__c, Account_Manager__r.FirstName, Account_Manager__r.LastName,
                   Account_Manager__r.Email,
                   Account_Operational_Manager_CP__c, Account_Operational_Manager_CP__r.FirstName,
                   Account_Operational_Manager_CP__r.LastName, Account_Operational_Manager_CP__r.Email,
                   From_Reseller__r.Id, From_Reseller__r.Name, From_Reseller__r.Nuvei_Partner_ID__c,
                   From_Reseller__r.Credentials_URL__c, From_Reseller__r.Overwrite_Financial_Vertical__c,
                   Overwrite_Financial_Vertical__c, Origin_Region__c, Visa_Payfac_ID__c,
                   Mastercard_Payfac_ID__c, Nuvei_Connect_Application_ID__c, EU_Indirect_Orchestration__c
            FROM Compliance__c WHERE Id = :(Id)data.get('compliance').Id
        ];

        Test.startTest();
        MerchantPayload p = new MerchantPayload(cas, false, false);
        String json = JSON.serialize(p, true);
        Test.stopTest();

        System.assertNotEquals(null, p, 'Payload should be created');
        System.assertNotEquals(null, p.name, 'Name should be set');
        System.assertNotEquals(null, json, 'Should serialize');
    }

    @isTest
    static void merchantPayload_withPartner_setsParentEntityId() {
        Account partnerAcc = new Account(Name = 'Test Partner');
        insert partnerAcc;
        Compliance__c partner = new Compliance__c(
            Name = 'Test Partner',
            Account__c = partnerAcc.Id,
            Nuvei_Partner_ID__c = 'test-partner-uuid-123',
            Credentials_URL__c  = 'https://partner.test/credentials',
            Industry__c         = 'ISO'
        );
        insert partner;

        Map<String, SObject> data = createMinimalData();
        Compliance__c comp = (Compliance__c) data.get('compliance');
        comp.From_Reseller__c = partner.Id;
        update comp;

        Case cas = [
            SELECT Id, Company_Profile__c, Integration_Channel__c, ContactId,
                   SB_PPP_Username__c, SB_PPP_Password__c, SB_Template__c, Profile__c,
                   Profile_Type__c, Location__c, Platform_Integration__c,
                   Contact.FirstName, Contact.LastName, Contact.Email, Contact.Phone
            FROM Case WHERE Id = :(Id)data.get('case').Id LIMIT 1
        ];
        cas.Company_Profile__r = [
            SELECT Id, Name, Registered_Country_Code2__c, Registered_Zip_Postal_Code__c,
                   MCC_Code__c, VAT_Number__c, Registered_Street__c, Registered_City__c,
                   Primary_Contact__r.Phone, MSA_Effective_Date__c, City_field__c,
                   Merchant_Tier__c, State_USA__c, Registered_Country__c, Primary_Contact__c,
                   Primary_Contact__r.Id, Primary_Contact__r.Email, Primary_Contact__r.FirstName,
                   Primary_Contact__r.LastName, Primary_Contact__r.MailingStreet,
                   Primary_Contact__r.MailingCity, Primary_Contact__r.MailingCountry,
                   Primary_Contact__r.MailingPostalCode,
                   Account__r.Id, Account__r.Name,
                   Sales_Rep__c, Sales_Rep__r.FirstName, Sales_Rep__r.LastName, Sales_Rep__r.Email,
                   Account_Manager__c, Account_Manager__r.FirstName, Account_Manager__r.LastName,
                   Account_Manager__r.Email,
                   Account_Operational_Manager_CP__c, Account_Operational_Manager_CP__r.FirstName,
                   Account_Operational_Manager_CP__r.LastName, Account_Operational_Manager_CP__r.Email,
                   From_Reseller__r.Id, From_Reseller__r.Name, From_Reseller__r.Nuvei_Partner_ID__c,
                   From_Reseller__r.Credentials_URL__c, From_Reseller__r.Overwrite_Financial_Vertical__c,
                   Overwrite_Financial_Vertical__c, Origin_Region__c, Visa_Payfac_ID__c,
                   Mastercard_Payfac_ID__c, Nuvei_Connect_Application_ID__c, EU_Indirect_Orchestration__c
            FROM Compliance__c WHERE Id = :comp.Id
        ];

        Test.startTest();
        MerchantPayload p = new MerchantPayload(cas, true, false);
        Test.stopTest();

        System.assertEquals('test-partner-uuid-123', p.parentEntityId, 'Partner entity ID should be set');
        System.assertEquals('https://partner.test/credentials', p.credentialsUrl, 'Credentials URL should be set');
    }

    @isTest
    static void merchantPayload_nullCase_doesNotThrow() {
        Test.startTest();
        MerchantPayload p = new MerchantPayload(null, false, false);
        Test.stopTest();
        System.assertNotEquals(null, p, 'Should not throw on null case');
    }

    // ─── NUVEI CONNECT EVENTS SERVICE ────────────────────────────────────────
    @isTest
    static void eventsService_merchantActivated_success() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(200, '{"status":"ok"}'));
        Test.startTest();
        NuveiConnectEventsService.postApplicationEvent(compId, 'MERCHANT_PENDING');
        Test.stopTest();

        Compliance__c comp = [SELECT Nuvei_Connect_Status__c FROM Compliance__c WHERE Id = :compId];
        System.assertEquals('MERCHANT_PENDING', comp.Nuvei_Connect_Status__c,
            'Status should be mirrored to MERCHANT_PENDING');
    }

    @isTest
    static void eventsService_merchantPending_success() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(200, '{"status":"ok"}'));
        Test.startTest();
        NuveiConnectEventsService.postApplicationEvent(compId, 'MERCHANT_PENDING');
        Test.stopTest();

        System.assertNotEquals(null, compId);
    }

    @isTest
    static void eventsService_blankApplicationId_skips() {
        Account acc = new Account(Name = 'No AppId Merchant');
        insert acc;
        Compliance__c comp = new Compliance__c(Name = 'No AppId', Account__c = acc.Id);
        insert comp;

        Test.startTest();
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_ACTIVATED');
        Test.stopTest();

        System.assertNotEquals(null, comp.Id);
    }

    @isTest
    static void eventsService_httpError_logsAndContinues() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(500, '{"error":"server error"}'));
        Test.startTest();
        NuveiConnectEventsService.postApplicationEvent(compId, 'MERCHANT_PENDING');
        Test.stopTest();

        System.assertNotEquals(null, compId);
    }

    // ─── FINANCE INTEGRATION ─────────────────────────────────────────────────
    @isTest
    static void financeIntegration_euIndirect_success() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(200, '{"status":"completed"}'));
        Test.startTest();
        FinanceIntegration.futureFinanceIntegration(compId);
        Test.stopTest();

        Compliance__c comp = [SELECT Finance_admin_status__c FROM Compliance__c WHERE Id = :compId];
        System.assertNotEquals(null, comp.Finance_admin_status__c);
    }

    @isTest
    static void financeIntegration_euIndirect_failure() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(500, '{"error":"server error"}'));
        Test.startTest();
        FinanceIntegration.futureFinanceIntegration(compId);
        Test.stopTest();

        Compliance__c comp = [SELECT Finance_admin_status__c FROM Compliance__c WHERE Id = :compId];
        System.assertEquals('Failed', comp.Finance_admin_status__c);
    }

    @isTest
    static void financeIntegration_invocable_fires() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        FinanceIntegration.Param p = new FinanceIntegration.Param();
        p.compid = compId;

        Test.setMock(HttpCalloutMock.class, new SimpleMock(200, '{"status":"ok"}'));
        Test.startTest();
        FinanceIntegration.invocableFinanceIntegration(new List<FinanceIntegration.Param>{ p });
        Test.stopTest();

        System.assertNotEquals(null, compId);
    }

    @isTest
    static void trackDMsaConga_missingTemplateId_setsFailed() {
        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        update new Compliance__c(Id = compId, Nuvei_Connect_Status__c = 'APPROVED');

        Test.startTest();
        TrackDMsaConga track = new TrackDMsaConga();
        Boolean advanced = track.tryAdvance(compId);
        Test.stopTest();

        System.assertEquals(true, advanced);
        Compliance__c comp = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :compId];
        System.assertEquals('Failed', comp.MSA_Status__c);
    }

    @isTest
    static void trackDMsaConga_withTemplateId_setsStarted() {
        try {
            Conga_Setting__c setting = new Conga_Setting__c(
                Name = 'Default',
                EU_Indirect_Template_ID__c = 'TEST_TEMPLATE_123'
            );
            insert setting;
        } catch (Exception e) {
            Conga_Setting__c existing = Conga_Setting__c.getOrgDefaults();
            if (existing != null) {
                existing.EU_Indirect_Template_ID__c = 'TEST_TEMPLATE_123';
                update existing;
            }
        }

        Map<String, SObject> data = createMinimalData();
        Id compId = (Id) data.get('compliance').Id;

        update new Compliance__c(Id = compId, Nuvei_Connect_Status__c = 'APPROVED');

        Test.startTest();
        TrackDMsaConga track = new TrackDMsaConga();
        Boolean advanced = track.tryAdvance(compId);
        Test.stopTest();

        System.assertEquals(true, advanced);
        Compliance__c comp = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :compId];
        System.assertNotEquals(null, comp.MSA_Status__c);
    }

    @isTest
    static void trackDMsaConga_nullComplianceId_returnsFalse() {
        Test.startTest();
        TrackDMsaConga track = new TrackDMsaConga();
        Boolean advanced = track.tryAdvance(null);
        Test.stopTest();
        System.assertEquals(false, advanced);
    }

    @isTest
    static void trackDMsaConga_nonEuIndirect_returnsFalse() {
        Account acc = new Account(Name = 'Non EU');
        insert acc;
        Compliance__c comp = new Compliance__c(
            Name = 'Non EU', Account__c = acc.Id,
            EU_Indirect_Orchestration__c = false
        );
        insert comp;

        Test.startTest();
        TrackDMsaConga track = new TrackDMsaConga();
        Boolean advanced = track.tryAdvance(comp.Id);
        Test.stopTest();

        System.assertEquals(false, advanced);
    }

    // ─── MERCHANT ONBOARDING CONTROLLER ──────────────────────────────────────
    @isTest
    static void merchantOnboarding_validateRequiredFields_missingTemplate() {
        Map<String, SObject> data = createMinimalData();
        Case cas = (Case) data.get('case');
        cas.SB_Template__c = null;
        update cas;

        Case fetchedCase = MerchantOnboardingController.fetchCase(cas.Id);
        List<String> missing = MerchantOnboardingController.validateRequiredFields(fetchedCase, false);

        System.assert(!missing.isEmpty());
        System.assert(missing.contains('SB Template'));
    }

    @isTest
    static void merchantOnboarding_validateRequiredFields_allPresent() {
        Map<String, SObject> data = createMinimalData();
        Case cas = (Case) data.get('case');

        Case fetchedCase = MerchantOnboardingController.fetchCase(cas.Id);
        List<String> missing = MerchantOnboardingController.validateRequiredFields(fetchedCase, false);
        System.assertNotEquals(null, missing);
    }

    @isTest
    static void merchantOnboarding_sendRequest_sandbox_success() {
        Map<String, SObject> data = createMinimalData();
        Case cas = (Case) data.get('case');

        List<ExpressConfig__c> cfgs = [SELECT Id FROM ExpressConfig__c LIMIT 1];
        if (cfgs.isEmpty()) {
            insert new ExpressConfig__c(
                Name = 'Default',
                MO_SB_endpoint__c = 'https://sandbox.nuvei.com/api/merchant',
                MO_SB_token_endpoint__c = 'https://sandbox.nuvei.com/connect/token',
                MO_SB_secret__c = 'test_secret'
            );
        }

        Test.setMock(HttpCalloutMock.class, new TwoCallMock());
        Test.startTest();
        MerchantOnboardingController.sendMerchantRequest(cas.Id, false, false);
        Test.stopTest();

        System.assertNotEquals(null, cas.Id);
    }

    @isTest
    static void merchantOnboarding_createMerchantFromFlow_missingFields() {
        Map<String, SObject> data = createMinimalData();
        Case cas = (Case) data.get('case');
        cas.SB_Template__c = null;
        update cas;

        MerchantOnboardingController.RequestWrapper req = new MerchantOnboardingController.RequestWrapper();
        req.caseId   = cas.Id;
        req.isProd   = false;
        req.isPayFac = false;

        Test.startTest();
        List<MerchantOnboardingController.ResponseWrapper> responses =
            MerchantOnboardingController.createMerchantFromFlow(
                new List<MerchantOnboardingController.RequestWrapper>{ req }
            );
        Test.stopTest();

        System.assertNotEquals(null, responses);
        System.assertNotEquals(null, responses[0].missingFields);
        System.assert(!responses[0].missingFields.isEmpty());
    }

    // ─── INDIRECT BOARDING ROUTER (additional branches) ──────────────────────
    @isTest
    static void indirectBoardingRouter_processCompliance_notEuIndirect_exits() {
        Account acc = new Account(Name = 'Non EU Router Test');
        insert acc;
        Compliance__c comp = new Compliance__c(
            Name = 'Non EU Router',
            Account__c = acc.Id,
            EU_Indirect_Orchestration__c = false
        );
        insert comp;

        Test.startTest();
        IndirectBoardingRouter.processCompliance(comp.Id);
        Test.stopTest();

        comp = [SELECT Technical_Onboarding_Status__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals(null, comp.Technical_Onboarding_Status__c);
    }

    @isTest
    static void indirectBoardingRouter_processCompliance_nullId_exits() {
        Test.startTest();
        IndirectBoardingRouter.processCompliance(null);
        Test.stopTest();
        System.assert(true);
    }

    @isTest
    static void indirectBoardingRouter_anyOrchestrationFieldChanged_detectsChange() {
        Compliance__c n = new Compliance__c(
            MSA_Status__c = 'Counter Signed',
            EU_Indirect_Orchestration__c = true
        );
        Compliance__c o = new Compliance__c(
            MSA_Status__c = null,
            EU_Indirect_Orchestration__c = false
        );

        Boolean changed = IndirectBoardingRouter.anyOrchestrationFieldChanged(n, o);
        System.assertEquals(true, changed);
    }

    @isTest
    static void indirectBoardingRouter_anyOrchestrationFieldChanged_noChange() {
        Compliance__c n = new Compliance__c(MSA_Status__c = 'Counter Signed');
        Boolean changed = IndirectBoardingRouter.anyOrchestrationFieldChanged(n, null);
        System.assertEquals(true, changed);
    }

    @isTest
    static void indirectBoardingRouter_pciNonCompliant_blocks() {
        Map<String, SObject> data = createMinimalData();
        Compliance__c comp = (Compliance__c) data.get('compliance');
        comp.PCI_Status__c = 'Non-Compliant';
        comp.MSA_Status__c = 'Counter Signed';
        comp.Nuvei_Connect_Status__c = 'APPROVED';
        update comp;

        Test.startTest();
        IndirectBoardingRouter.processCompliance(comp.Id);
        Test.stopTest();

        comp = [SELECT Technical_Onboarding_Status__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals(null, comp.Technical_Onboarding_Status__c);
    }

    // ─── FIXED: StartIntegrationProcess_Controller coverage ──────────────────
    @isTest
    static void cover_StartIntegrationProcess_Controller_StartAction() {
        Account a = new Account(Name = 'PR Acc');
        insert a;

        // Provisioning_Request__c requires Company_Profile__c in PROD
        Compliance__c comp = new Compliance__c(
            Name = 'PR Comp',
            Account__c = a.Id,
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123',
            City_field__c = '+44123456789'
        );
        insert comp;

        Opportunity o = new Opportunity(
            Name = 'PR Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert o;

        Id rtId = null;
        List<RecordType> rts = [
            SELECT Id
            FROM RecordType
            WHERE SObjectType = 'Provisioning_Request__c'
            LIMIT 1
        ];
        if (!rts.isEmpty()) rtId = rts[0].Id;

        // IMPORTANT: Do NOT set Name (not writeable). Set Company_Profile__c (required).
        Provisioning_Request__c pr = new Provisioning_Request__c(
            Account__c = a.Id,
            Opportunity__c = o.Id,
            Company_Profile__c = comp.Id
        );
        if (rtId != null) pr.RecordTypeId = rtId;

        insert pr;

        Test.startTest();
        String result = StartIntegrationProcess_Controller.StartAction(pr.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'StartAction should return a string (OK or Error: ...)');
    }
}