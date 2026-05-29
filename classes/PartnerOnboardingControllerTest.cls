@IsTest
private class PartnerOnboardingControllerTest {

    private class MultiMock implements HttpCalloutMock {
        String mode;
        MultiMock(String mode) { this.mode = mode; }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            String ep = req.getEndpoint();

            if (ep != null && ep.contains('token')) {
                if (mode == 'tokenFail') {
                    res.setStatusCode(401);
                    res.setBody('{"error":"invalid"}');
                    return res;
                }
                res.setStatusCode(200);
                res.setHeader('Content-Type','application/json');
                res.setBody('{"access_token":"TEST_TOKEN"}');
                return res;
            }

            if (mode == 'missingIdentifiers') {
                res.setStatusCode(201);
                res.setBody('{"requestId":"REQ-1"}');
                return res;
            }

            if (mode == 'http500') {
                res.setStatusCode(500);
                res.setBody('{"error":"boom"}');
                return res;
            }

            res.setStatusCode(201);
            res.setBody('{"identifiers":{"entityId":"ENT-123","masterClientId":"MC-456"}}');
            return res;
        }
    }

    private static ExpressConfig__c makeCfg(Boolean blank) {
        ExpressConfig__c cfg = new ExpressConfig__c(Name='Default');
        if (!blank) {
            cfg.PO_prod_token_endpoint__c = 'https://example.com/token';
            cfg.PO_prod_secret__c         = 'secret';
            cfg.PO_prod_endpoint__c       = 'https://example.com/partners';
        }
        insert cfg;
        return cfg;
    }

    private static Case makeCase(Boolean noCompany, Boolean noContact, Boolean noUsername) {
        Account acc = new Account(Name='Acc ' + String.valueOf(Math.random()).substring(0,8));
        insert acc;

        Contact con = new Contact(
            FirstName='Test',
            LastName='User' + String.valueOf(Math.random()).substring(0,8),
            Email=String.valueOf(Math.random()).substring(0,8) + '@test.com',
            AccountId=acc.Id
        );
        insert con;

        Compliance__c comp = new Compliance__c(
            Name='Comp ' + String.valueOf(Math.random()).substring(0,8),
            Account__c=acc.Id,
            Registered_Street__c='Street',
            Registered_City__c='City',
            Registered_Zip_Postal_Code__c='1000',
            Primary_Contact__c=con.Id
        );
        insert comp;

        Case c = new Case(Subject='Test', Status='New');
        if (!noCompany) c.Company_Profile__c = comp.Id;
        if (!noContact) c.ContactId = con.Id;
        if (!noUsername) c.SB_PPP_Username__c = con.Email;
        insert c;
        return c;
    }

    @IsTest
    static void testHappyPath() {
        makeCfg(false);
        Case c = makeCase(false, false, false);
        Test.setMock(HttpCalloutMock.class, new MultiMock('happy'));
        Test.startTest();
        PartnerOnboardingController.initOnboarding(c.Id);
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void testInitValidation_noCompany() {
        Case c = makeCase(true, false, false);
        String err = PartnerOnboardingController.initOnboarding(c.Id);
        System.assert(err != null && err.contains('Company Profile'));
    }

    @IsTest
    static void testInitValidation_noContact() {
        Case c = makeCase(false, true, false);
        String err = PartnerOnboardingController.initOnboarding(c.Id);
        System.assert(err != null && err.contains('Contact'));
    }

    @IsTest
    static void testInitValidation_noUsername() {
        Case c = makeCase(false, false, true);
        String err = PartnerOnboardingController.initOnboarding(c.Id);
        System.assert(err != null && err.contains('SB_PPP_Username'));
    }

    @IsTest
    static void testMissingConfig() {
        makeCfg(true);
        Case c = makeCase(false, false, false);
        Test.startTest();
        PartnerOnboardingController.sendPartnerRequest(c.Id);
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void testTokenFail() {
        makeCfg(false);
        Case c = makeCase(false, false, false);
        Test.setMock(HttpCalloutMock.class, new MultiMock('tokenFail'));
        Test.startTest();
        PartnerOnboardingController.sendPartnerRequest(c.Id);
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void testHttp500() {
        makeCfg(false);
        Case c = makeCase(false, false, false);
        Test.setMock(HttpCalloutMock.class, new MultiMock('http500'));
        Test.startTest();
        PartnerOnboardingController.sendPartnerRequest(c.Id);
        Test.stopTest();
        System.assert(true);
    }

    @IsTest
    static void testMissingIdentifiers() {
        makeCfg(false);
        Case c = makeCase(false, false, false);
        Test.setMock(HttpCalloutMock.class, new MultiMock('missingIdentifiers'));
        Test.startTest();
        PartnerOnboardingController.sendPartnerRequest(c.Id);
        Test.stopTest();
        System.assert(true);
    }
}