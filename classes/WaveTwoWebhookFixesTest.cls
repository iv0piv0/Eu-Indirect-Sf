/**
 * Wave 2 — P1 fixes regression tests for NuveiConnectWebhookHandler.
 * Covers gaps #6, #7, #8, #9, #10, #11, #16.
 *
 * Builds an in-memory NuveiConnectRequest and calls processWebhook directly,
 * avoiding the @RestResource entry point. Existing NuveiConnectWebhookHandlerTest
 * continues to cover the full HTTP-shaped path.
 */
@isTest
private class WaveTwoWebhookFixesTest {

    private static NuveiConnectWebhookHandler.NuveiConnectRequest buildReq(String appId) {
        NuveiConnectWebhookHandler.NuveiConnectRequest r =
            new NuveiConnectWebhookHandler.NuveiConnectRequest();
        r.applicationId = appId;
        r.applicationStatus = 'SUBMITTED';

        NuveiConnectWebhookHandler.BusinessInformationWrapper bi =
            new NuveiConnectWebhookHandler.BusinessInformationWrapper();
        bi.legalName = 'Wave2 Test Merchant LLC With A Long Name';
        bi.businessRegistrationNumber = 'REG-W2-001';
        bi.websiteUrl = 'https://wave2.example.com';
        bi.businessType = 'LIMITED_COMPANY';
        bi.merchantCategoryCode = '5411';
        NuveiConnectWebhookHandler.ContactInfoWrapper ci =
            new NuveiConnectWebhookHandler.ContactInfoWrapper();
        ci.firstName = 'Wave2';
        ci.lastName = 'Tester';
        ci.businessEmail = 'wave2.tester@example.com';
        ci.contactNumber = '+447911000000';
        bi.contactInformation = ci;

        NuveiConnectWebhookHandler.AddressWrapper addr =
            new NuveiConnectWebhookHandler.AddressWrapper();
        addr.addressType = 'BUSINESS_ADDRESS';
        addr.country = 'GB';
        addr.city = 'London';
        addr.addressLine1 = '1 Wave2 Street';
        addr.postalCode = 'EC1A 1BB';
        bi.addresses = new List<NuveiConnectWebhookHandler.AddressWrapper>{ addr };
        r.businessInformation = bi;

        NuveiConnectWebhookHandler.AdditionalInfoWrapper ai =
            new NuveiConnectWebhookHandler.AdditionalInfoWrapper();
        ai.portalAdminFirstName = 'Cpanel';
        ai.portalAdminLastName = 'Admin';
        ai.portalAdminEmail = 'cpanel.admin@example.com';
        ai.portalAdminContactNumber = '+447911000001';
        r.additionalInformation = ai;

        NuveiConnectWebhookHandler.BankingInfoWrapper bank =
            new NuveiConnectWebhookHandler.BankingInfoWrapper();
        bank.bankCountry = 'GB';
        bank.accountHolderName = 'Wave2 Holder';
        bank.accountCurrency = 'GBP';
        bank.iban = 'GB29NWBK60161331926819';
        bank.swiftCode = 'NWBKGB2L';
        r.bankingInformation = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>{ bank };

        return r;
    }

    @isTest
    static void gap6_cityField_populated_from_contactNumber() {
        NuveiConnectWebhookHandler.processWebhook(buildReq('W2-APP-006'));
        Compliance__c c = [SELECT City_field__c FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-006' LIMIT 1];
        System.assertEquals('+447911000000', c.City_field__c);
    }

    @isTest
    static void gap7_primaryContact_populated() {
        NuveiConnectWebhookHandler.processWebhook(buildReq('W2-APP-007'));
        Compliance__c c = [SELECT Primary_Contact__c, Primary_Contact__r.Email FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-007' LIMIT 1];
        System.assertNotEquals(null, c.Primary_Contact__c);
        System.assertEquals('wave2.tester@example.com', c.Primary_Contact__r.Email);
    }

    @isTest
    static void gap8_descriptor_seeded_from_legalName() {
        NuveiConnectWebhookHandler.processWebhook(buildReq('W2-APP-008'));
        Compliance__c c = [SELECT Descriptor__c FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-008' LIMIT 1];
        System.assertNotEquals(null, c.Descriptor__c);
        System.assert(c.Descriptor__c.length() <= 22, 'Descriptor must be <= 22 chars');
    }

    @isTest
    static void gap9_descriptorType_defaults_to_Static() {
        NuveiConnectWebhookHandler.processWebhook(buildReq('W2-APP-009'));
        Compliance__c c = [SELECT Descriptor_Type__c FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-009' LIMIT 1];
        System.assertEquals('Static', c.Descriptor_Type__c);
    }

    @isTest
    static void gap16_bankingDetails_beneficiaryCountry_mapped() {
        NuveiConnectWebhookHandler.processWebhook(buildReq('W2-APP-016'));
        Compliance__c c = [SELECT Id FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-016' LIMIT 1];
        Banking_Details__c bd = [SELECT Beneficiary_Country__c FROM Banking_Details__c
            WHERE Compliance__c = :c.Id LIMIT 1];
        System.assertEquals('United Kingdom', bd.Beneficiary_Country__c);
    }

    @isTest
    static void gap10_and_11_configurationCase_fallbacks() {
        // Need ExpressConfig with blank SB_Template__c
        delete [SELECT Id FROM ExpressConfig__c];
        insert new ExpressConfig__c(Name='Default'); // SB_Template__c left blank

        NuveiConnectWebhookHandler.NuveiConnectRequest r = buildReq('W2-APP-010');
        // First create the Compliance, then send APPROVED to trigger Case creation
        NuveiConnectWebhookHandler.processWebhook(r);
        r.applicationStatus = 'APPROVED';
        NuveiConnectWebhookHandler.processWebhook(r);

        Compliance__c c = [SELECT Id, Account__c FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'W2-APP-010' LIMIT 1];
        List<Case> cases = [SELECT SB_Template__c, Contact_Information__c, Profile__c FROM Case
            WHERE Company_Profile__c = :c.Id LIMIT 1];
        System.assertEquals(1, cases.size(), 'Configuration Case should be created on APPROVED');
                // gap #10
        System.assertEquals('Ecommerce', cases[0].SB_Template__c);
        // gap #11
        System.assertEquals('cpanel.admin@example.com', cases[0].Contact_Information__c);
        // NEW — guard against re-adding the hardcoded Profile__c line
        System.assertEquals(null, cases[0].Profile__c,
            'Profile__c must NOT be hardcoded — it is now sourced from ExpressConfig.SB_Template__c via fallback');
    }
}
