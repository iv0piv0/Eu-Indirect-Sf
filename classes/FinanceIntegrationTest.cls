@isTest
private class FinanceIntegrationTest {

    @testSetup
    static void setup() {
        // ═══════════════════════════════════════════════════
        // 1. FinanceIntegration_Setting__c — CRITICAL
        //    Without this, getSett() throws "List has no rows"
        // ═══════════════════════════════════════════════════
        FinanceIntegration_Setting__c sett = new FinanceIntegration_Setting__c(
            Name        = 'Default',
            endpoint__c = 'https://test.finance.endpoint.com/api',
            secret__c   = 'test-secret-key-abc123'
        );
        insert sett;

        // ═══════════════════════════════════════════════════
        // 2. Countries__c — List Custom Setting
        //    Used by GenerateTree for ISO3 mapping and
        //    getCountryCode for Country_Code__c lookup
        // ═══════════════════════════════════════════════════
        insert new List<Countries__c>{
            new Countries__c(Name = 'United Kingdom', Country_Name__c = 'United Kingdom', ISO_3__c = 'GBR', Country_Code__c = 826),
            new Countries__c(Name = 'Germany',        Country_Name__c = 'Germany',        ISO_3__c = 'DEU', Country_Code__c = 276),
            new Countries__c(Name = 'United States',  Country_Name__c = 'United States',  ISO_3__c = 'USA', Country_Code__c = 840)
        };

        // ═══════════════════════════════════════════════════
        // 3. Account + Compliance__c — core test data
        // ═══════════════════════════════════════════════════
        Account acc = new Account(Name = 'FinTest Corp');
        insert acc;

        Compliance__c comp = new Compliance__c(
            Name                        = 'FinTest Compliance',
            Account__c                  = acc.Id,
            EU_Indirect_Orchestration__c = true,
            Managing_Company__c         = 'Safecharge Limited',
            Fees_Currency__c            = 'EUR',
            VAT_Number__c               = 'DE123456789',
            Registered_Country__c       = 'United Kingdom',
            Registered_Street__c        = '1 Test St',
            Registered_City__c          = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            Remittance_Cycle__c         = 'Monthly'
        );
        insert comp;

        // Non-EU compliance for alternate path testing
        Compliance__c compNonEU = new Compliance__c(
            Name                        = 'FinTest NonEU',
            Account__c                  = acc.Id,
            EU_Indirect_Orchestration__c = false,
            Managing_Company__c         = 'SCD',
            Fees_Currency__c            = 'EUR',
            VAT_Number__c               = 'US999',
            Registered_Country__c       = 'United States',
            Registered_Street__c        = '2 Test Ave',
            Registered_City__c          = 'New York',
            Registered_Zip_Postal_Code__c = '10001',
            Remittance_Cycle__c         = 'Weekly with 1 week delay'
        );
        insert compNonEU;
    }

    // ═══════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════

    private static Compliance__c getEUComp() {
        return [SELECT Id FROM Compliance__c WHERE Name = 'FinTest Compliance' LIMIT 1];
    }

    private static Compliance__c getNonEUComp() {
        return [SELECT Id FROM Compliance__c WHERE Name = 'FinTest NonEU' LIMIT 1];
    }

    // ═══════════════════════════════════════════════════
    // Core flow tests
    // ═══════════════════════════════════════════════════

    @isTest
    static void testFutureFinance_EUIndirect_Success() {
        Compliance__c comp = getEUComp();

        Test.startTest();
        FinanceIntegration.futureFinanceIntegration(comp.Id);
        Test.stopTest();

        comp = [SELECT Finance_admin_status__c, Finance_Log__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals('Completed', comp.Finance_admin_status__c,
            'EU indirect success path should set Finance_admin_status__c to Completed');
        System.assertNotEquals(null, comp.Finance_Log__c,
            'Finance_Log__c should be populated with the JSON payload');
    }

    @isTest
    static void testFutureFinance_NonEUIndirect() {
        Compliance__c comp = getNonEUComp();

        Test.startTest();
        FinanceIntegration.futureFinanceIntegration(comp.Id);
        Test.stopTest();

        comp = [SELECT Finance_admin_status__c, Finance_Log__c FROM Compliance__c WHERE Id = :comp.Id];
        // Non-EU path does NOT set Finance_admin_status__c
        System.assertEquals(null, comp.Finance_admin_status__c,
            'Non-EU path should not set Finance_admin_status__c');
        System.assertNotEquals(null, comp.Finance_Log__c,
            'Finance_Log__c should still be populated');
    }

    @isTest
    static void testInvocableFinanceIntegration() {
        Compliance__c comp = getEUComp();

        FinanceIntegration.Param p = new FinanceIntegration.Param();
        p.compid = comp.Id;

        Test.startTest();
        FinanceIntegration.invocableFinanceIntegration(new List<FinanceIntegration.Param>{ p });
        Test.stopTest();

        comp = [SELECT Finance_admin_status__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals('Completed', comp.Finance_admin_status__c);
    }

    // ═══════════════════════════════════════════════════
    // VF Controller
    // ═══════════════════════════════════════════════════

    @isTest
    static void testVFController() {
        Compliance__c comp = getEUComp();

        PageReference pg = new PageReference('/apex/FinanceIntegration');
        pg.getParameters().put('id', comp.Id);
        Test.setCurrentPage(pg);

        ApexPages.StandardController std = new ApexPages.StandardController(comp);
        FinanceIntegration ctrl = new FinanceIntegration(std);

        System.assertEquals(comp.Id, ctrl.curid, 'Controller should read id from page params');

        // Also test act() via VF path
        Test.startTest();
        PageReference result = ctrl.act();
        Test.stopTest();

        System.assertNotEquals(null, result, 'act() should return a PageReference');
    }

    // ═══════════════════════════════════════════════════
    // bumpTrackGRetryCount
    // ═══════════════════════════════════════════════════

    @isTest
    static void testBumpTrackGRetryCount_Normal() {
        Compliance__c comp = getEUComp();

        Test.startTest();
        FinanceIntegration.bumpTrackGRetryCount(comp.Id);
        Test.stopTest();

        comp = [SELECT Track_G_Retry_Count__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals(1, comp.Track_G_Retry_Count__c,
            'Retry count should be incremented from null/0 to 1');
    }

    @isTest
    static void testBumpTrackGRetryCount_BlankId() {
        // Should exit gracefully — no exception
        Test.startTest();
        FinanceIntegration.bumpTrackGRetryCount('');
        FinanceIntegration.bumpTrackGRetryCount(null);
        Test.stopTest();
    }

    // ═══════════════════════════════════════════════════
    // Utility methods
    // ═══════════════════════════════════════════════════

    @isTest
    static void testGetPayPer_AllValues() {
        System.assertEquals(0,  FinanceIntegration.getPayPer('No Payout'));
        System.assertEquals(1,  FinanceIntegration.getPayPer('Weekly with 1 week delay'));
        System.assertEquals(2,  FinanceIntegration.getPayPer('Monday Two Week delay'));
        System.assertEquals(3,  FinanceIntegration.getPayPer('Twice a week with 1 week delay'));
        System.assertEquals(4,  FinanceIntegration.getPayPer('Monday Three Week delay'));
        System.assertEquals(5,  FinanceIntegration.getPayPer('Within 3 business days'));
        System.assertEquals(6,  FinanceIntegration.getPayPer('Daily \u2013 4 days delay'));
        System.assertEquals(7,  FinanceIntegration.getPayPer('Daily \u2013 1 day delay'));
        System.assertEquals(8,  FinanceIntegration.getPayPer('Daily \u2013 2 days delay'));
        System.assertEquals(9,  FinanceIntegration.getPayPer('Monthly'));
        System.assertEquals(10, FinanceIntegration.getPayPer('Weekly with 3 business days delay'));
        System.assertEquals(null, FinanceIntegration.getPayPer('Unknown Value'));
    }

    @isTest
    static void testGenChecksum() {
        String result = FinanceIntegration.genChecksum('secret', '123', 'fffff');
        System.assertNotEquals(null, result, 'Checksum should not be null');
        System.assertEquals(64, result.length(), 'SHA-256 hex should be 64 chars');
    }

    @isTest
    static void testNl_NullAndNonNull() {
        System.assertEquals(null, FinanceIntegration.nl(null));
        System.assertEquals(null, FinanceIntegration.nl(''));
        System.assertEquals(42,   FinanceIntegration.nl(42));
        System.assertEquals(123,  FinanceIntegration.nl('123'));
    }

    @isTest
    static void testGetCountryCode_ExistingAndMissing() {
        // 'United Kingdom' was inserted in @testSetup with Country_Code__c = 826
        String ukCode = FinanceIntegration.getCountryCode('United Kingdom');
        System.assertEquals('826', ukCode, 'Should return country code for existing country');

        // Non-existent country
        String noCode = FinanceIntegration.getCountryCode('Narnia');
        System.assertEquals(null, noCode, 'Should return null for non-existent country');
    }

    @isTest
    static void testGenerateJson() {
        Compliance__c comp = getEUComp();
        FinanceIntegration_Setting__c sett = FinanceIntegration.getSett();

        Test.startTest();
        String jsonResult = FinanceIntegration.GenerateJson(comp.Id, sett);
        Test.stopTest();

        System.assertNotEquals(null, jsonResult, 'JSON should not be null');
        System.assert(jsonResult.contains('multiClientId'), 'JSON should contain FinanceRoot fields');
    }

    @isTest
    static void testGenerateTree_WithNullSett() {
        // When sett is null, GenerateTree calls getSett() internally
        Compliance__c comp = getEUComp();

        Test.startTest();
        FinanceIntegration.FinanceRoot fr = FinanceIntegration.GenerateTree(comp.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, fr, 'FinanceRoot should not be null');
    }

    @isTest
    static void testGenerateTree_NoComplianceFound() {
        // Use a fake (valid format) Id that won't match any record
        Id fakeId = Compliance__c.SObjectType.getDescribe().getKeyPrefix() + '000000000001';
        FinanceIntegration_Setting__c sett = FinanceIntegration.getSett();

        Test.startTest();
        FinanceIntegration.FinanceRoot fr = FinanceIntegration.GenerateTree(fakeId, sett);
        Test.stopTest();

        // Should return empty root (no compliance found branch)
        System.assertNotEquals(null, fr);
    }

    @isTest
    static void testSendJson() {
        Compliance__c comp = getEUComp();

        Test.startTest();
        String result = FinanceIntegration.SendJson(comp.Id);
        Test.stopTest();

        System.assertNotEquals(null, result, 'SendJson should return finance log');
    }

    @isTest
    static void testGetSett() {
        Test.startTest();
        FinanceIntegration_Setting__c sett = FinanceIntegration.getSett();
        Test.stopTest();

        System.assertNotEquals(null, sett);
        System.assertEquals('https://test.finance.endpoint.com/api', sett.endpoint__c);
        System.assertEquals('test-secret-key-abc123', sett.secret__c);
    }

    // ═══════════════════════════════════════════════════
    // Managing Company switch coverage
    // ═══════════════════════════════════════════════════

    @isTest
    static void testGenerateTree_DifferentManagingCompany() {
        // Non-EU comp has Managing_Company__c = 'SCD'
        Compliance__c comp = getNonEUComp();
        FinanceIntegration_Setting__c sett = FinanceIntegration.getSett();

        Test.startTest();
        FinanceIntegration.FinanceRoot fr = FinanceIntegration.GenerateTree(comp.Id, sett);
        Test.stopTest();

        System.assertNotEquals(null, fr);
        System.assertEquals('3', fr.clientGeneralInfo.managingCompanyId,
            'SCD should map to managingCompanyId 3');
    }

    // ═══════════════════════════════════════════════════
    // Default constructor
    // ═══════════════════════════════════════════════════

    @isTest
    static void testDefaultConstructor() {
        FinanceIntegration fi = new FinanceIntegration();
        System.assertNotEquals(null, fi);
    }
}