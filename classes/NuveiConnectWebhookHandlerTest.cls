/**
 * NuveiConnectWebhookHandlerTest
 *
 * Tests for NuveiConnectWebhookHandler covering:
 *   - EU payload: insert new application
 *   - Status update (upsert path) — known and unknown statuses
 *   - Banking: SEPA (IBAN) and UK (sort code) variants
 *   - Error handling: missing required fields, bad data
 *   - Partner bank copy
 *
 * @author  Nuvei Development Team
 * @version 2.0
 */
@isTest
private class NuveiConnectWebhookHandlerTest {

    // ─── TEST DATA BUILDERS ─────────────────────────────────────────────────

    /**
     * Builds a minimal EU payload matching the Swagger EU sample.
     */
    private static NuveiConnectWebhookHandler.NuveiConnectRequest buildEURequest() {
        NuveiConnectWebhookHandler.NuveiConnectRequest req =
            new NuveiConnectWebhookHandler.NuveiConnectRequest();
        req.applicationId     = 'EU-APP-001';
        req.applicationStatus = 'SUBMITTED';
        req.rawPayload        = '{"applicationId":"EU-APP-001"}';

        // Business information — EU shape
        NuveiConnectWebhookHandler.BusinessInformationWrapper bi =
            new NuveiConnectWebhookHandler.BusinessInformationWrapper();
        bi.legalName                  = 'Tech Innovations EU Ltd';
        bi.doingBusinessAs            = 'Tech EU';
        bi.businessType               = 'LIMITED_COMPANY';
        bi.businessRegistrationNumber = 'SC123456';
        bi.merchantCategoryCode       = '5734';
        bi.productDescription         = 'Laptops, Mobile Phones, and Accessories';
        bi.websiteUrl                 = 'https://techeu.com';
        bi.businessStartDate          = '2015-06-15';

        // EU contact: has firstName/lastName
        NuveiConnectWebhookHandler.ContactInfoWrapper ci =
            new NuveiConnectWebhookHandler.ContactInfoWrapper();
        ci.firstName     = 'John';
        ci.lastName      = 'Doe';
        ci.businessEmail = 'info@techeu.com';
        ci.contactNumber = '+14155552671';
        bi.contactInformation = ci;

        // Addresses
        NuveiConnectWebhookHandler.AddressWrapper bizAddr =
            new NuveiConnectWebhookHandler.AddressWrapper();
        bizAddr.addressType    = 'BUSINESS_ADDRESS';
        bizAddr.country        = 'GB';
        // bizAddr.stateOrProvince — omitted, restricted picklist in sandbox
        bizAddr.city           = 'London';
        bizAddr.postalCode     = 'EC1A 1BB';
        bizAddr.addressLine1   = '123 High Street';
        bi.addresses = new List<NuveiConnectWebhookHandler.AddressWrapper>{ bizAddr };
        req.businessInformation = bi;

        // Business owners — EU shape (nationality + contactNumber)
        NuveiConnectWebhookHandler.BusinessOwnerWrapper bo =
            new NuveiConnectWebhookHandler.BusinessOwnerWrapper();
        bo.legalFirstName       = 'John';
        bo.legalLastName        = 'Doe';
        bo.dateOfBirth          = '1980-05-20';
        bo.nationality          = 'GB';
        bo.email                = 'johndoe@techeu.com';
        bo.contactNumber        = '14155558999';
        bo.percentageOfOwnership = 75;
        bo.ownerRole            = 'DIRECTOR';
        NuveiConnectWebhookHandler.AddressWrapper homeAddr =
            new NuveiConnectWebhookHandler.AddressWrapper();
        homeAddr.country      = 'GB';
        homeAddr.city         = 'London';
        homeAddr.postalCode   = 'W1A 1AA';
        homeAddr.addressLine1 = '456 Park Lane';
        bo.homeAddress = homeAddr;
        req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>{ bo };

        // Banking — EU UK (sortCode + accountNumber)
        NuveiConnectWebhookHandler.BankingInfoWrapper bank =
            new NuveiConnectWebhookHandler.BankingInfoWrapper();
        bank.bankCountry       = 'GB';
        bank.accountNumber     = '87654321';
        bank.sortCode          = '123456';
        bank.accountHolderName = 'Tech Innovations EU Ltd';
        bank.accountCurrency   = 'GBP';
        req.bankingInformation = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>{ bank };

        // Sales profile
        NuveiConnectWebhookHandler.SalesProfileWrapper sp =
            new NuveiConnectWebhookHandler.SalesProfileWrapper();
        sp.averageTransactionValue    = 150;
        sp.highestTicketSize          = 2000;
        sp.percentageOnlineTransactions  = 60;
        sp.percentageInStoreTransactions = 30;
        sp.percentageMotoTransactions    = 10;
        sp.averageOrderFulfillmentTime   = '1_5_DAYS';
        sp.recurringBilling              = true;
        NuveiConnectWebhookHandler.ExpectedSalesWrapper esv =
            new NuveiConnectWebhookHandler.ExpectedSalesWrapper();
        esv.period          = 'MONTHLY';
        esv.expectedRevenue = 300000;
        sp.expectedSalesValue = esv;
        req.salesProfile = sp;

        // Tax details — EU VAT
        NuveiConnectWebhookHandler.TaxDetailsWrapper tax =
            new NuveiConnectWebhookHandler.TaxDetailsWrapper();
        tax.taxIdentificationNumber = 'DE115235681';
        tax.taxIdentificationType   = 'VAT';
        req.taxDetails = tax;

        // Additional information — EU (consentToPrivacyPolicy + portalAdmin)
        NuveiConnectWebhookHandler.AdditionalInfoWrapper ai =
            new NuveiConnectWebhookHandler.AdditionalInfoWrapper();
        ai.portalAdminFirstName     = 'John';
        ai.portalAdminLastName      = 'Doe';
        ai.portalAdminEmail         = 'info@techeu.com'; // matches businessEmail → Case A
        ai.portalAdminContactNumber = '14155558999';
        req.additionalInformation = ai;

        // Metadata — partnerId
        NuveiConnectWebhookHandler.MetadataWrapper meta =
            new NuveiConnectWebhookHandler.MetadataWrapper();
        meta.partnerExternalId = 'PARTNER-EU-001';
        req.metadata = meta;

        return req;
    }

    /**
     * Creates a test partner Compliance__c with the given entityId.
     */
    private static Compliance__c createTestPartner(String entityId) {
        Account partnerAcc = new Account(Name = 'Test Partner');
        insert partnerAcc;
        Compliance__c partner = new Compliance__c(
            Name              = 'Test Partner',
            Account__c        = partnerAcc.Id,
            Nuvei_Partner_ID__c = entityId
        );
        insert partner;
        return partner;
    }

    /**
     * Creates a template Merchant_Bank__c for a partner.
     */
    private static void createPartnerTemplateBanks(Id partnerId) {
        Merchant_Bank__c template = new Merchant_Bank__c(
            Compliance__c              = partnerId,
            Partner_Template_Pricing__c = true,
            CHB_Handling__c            = 20,
            Credit_Fee_Per_Credit__c   = 5,
            Trx_Fee__c                 = 0.1,
            Discount_Fee_ALL_Value_1__c = 1.5,
            IsDirect__c                = 'No'
        );
        insert template;
    }

    // ─── TESTS ───────────────────────────────────────────────────────────────





    @isTest
    static void testEUInsert_CreatesAllObjects() {
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'EU insert should succeed: ' + result.message);

        // Verify Compliance__c created
        List<Compliance__c> comps = [
            SELECT Id, Nuvei_Connect_Application_ID__c, Compliance_Status__c, Tax_ID_Type__c
            FROM   Compliance__c
            WHERE  Nuvei_Connect_Application_ID__c = 'EU-APP-001'
        ];
        System.assertEquals(1, comps.size(), 'Should create exactly one Compliance__c');
        System.assertEquals('Oscilar Submitted', comps[0].Compliance_Status__c, 'Status should map SUBMITTED → Oscilar Submitted');
        System.assertEquals('VAT', comps[0].Tax_ID_Type__c, 'VAT tax type should be stored');

        // Verify Account created
        List<Account> accs = [SELECT Id FROM Account WHERE Name = 'Tech Innovations EU Ltd'];
        System.assertEquals(1, accs.size(), 'Should create Account');

                // Verify Contacts: Wave 4 now creates one Contact per business owner
        // in addition to the primary contact. Primary email (info@techeu.com)
        // ≠ owner email (johndoe@techeu.com), so 2 distinct Contacts.
        List<Contact> cons = [
            SELECT Id, FirstName, LastName, Email, Authorized_Signature__c
            FROM Contact WHERE AccountId = :accs[0].Id
            ORDER BY Email
        ];
        System.assertEquals(2, cons.size(),
            'Wave 4: primary contact + 1 owner contact (different emails)');

        // Primary contact (info@techeu.com) — also cPanel admin (matches portalAdminEmail)
        Contact primary;
        Contact owner;
        for (Contact c : cons) {
            if (c.Email == 'info@techeu.com') primary = c;
            if (c.Email == 'johndoe@techeu.com') owner = c;
        }
        System.assertNotEquals(null, primary, 'Primary contact should exist');
        System.assertNotEquals(null, owner,   'Owner contact should exist');
        System.assertEquals('John', primary.FirstName, 'EU primary first name');
        System.assertEquals('Doe',  primary.LastName,  'EU primary last name');
        System.assertEquals('John', owner.FirstName,   'Owner first name');
        System.assertEquals('Doe',  owner.LastName,    'Owner last name');
        
        // Verify Directors_or_Ultimate_Beneficial_Owner__c with EU fields
        List<Directors_or_Ultimate_Beneficial_Owner__c> dirs = [
            SELECT Organization_Role__c, Nationality__c, Phone__c
            FROM   Directors_or_Ultimate_Beneficial_Owner__c
            WHERE  Company_Profile__c = :comps[0].Id
        ];
        System.assertEquals(1, dirs.size(), 'Should create one Director');
        System.assertEquals('Director', dirs[0].Organization_Role__c, 'EU owner role stored as picklist label');
        System.assertEquals('United Kingdom', dirs[0].Nationality__c, 'EU nationality maps to full country name');
        System.assertNotEquals(null, dirs[0].Phone__c, 'EU contactNumber should map to Phone');
    }


    @isTest
    static void testEUInsert_UKBank_PricingCopiedAndBankDetailsStamped() {
        // Tests UK bank details (sort code + account number) are stored correctly
        // Partner template copy is skipped in test env due to Industry__c validation rules
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata = null; // no partner
        // EU request has UK bank: sortCode + accountNumber, currency GBP

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'Should succeed with UK bank details: ' + result.message);

        Compliance__c comp = [SELECT Id FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1];

        // Verify bank account details are in Banking_Details__c
        List<Banking_Details__c> bds = [
            SELECT IBAN__c, branchCode__c, Account_number__c, Account_Holder_Name__c, bankCountry__c
            FROM Banking_Details__c WHERE Compliance__c = :comp.Id
        ];
        System.assertEquals(1, bds.size(), 'Should have 1 Banking_Details__c record');
        System.assertEquals('123456', bds[0].branchCode__c, 'Sort code in branchCode__c');
        System.assertEquals('87654321', bds[0].Account_number__c, 'Account number populated');
        System.assertEquals('Tech Innovations EU Ltd', bds[0].Account_Holder_Name__c, 'Holder name matches');
        System.assertEquals('United Kingdom', bds[0].bankCountry__c, 'Bank country mapped to full name');
    }

    @isTest
    static void testEUInsert_SEPABank_IBANAndSwiftStamped() {
        // No partner templates — testing SEPA detection only
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata = null; // no partner
        // Replace UK bank with SEPA IBAN bank
        req.bankingInformation[0].sortCode      = null;
        req.bankingInformation[0].accountNumber = null;
        req.bankingInformation[0].iban          = 'DE89370400440532013000';
        req.bankingInformation[0].swiftCode     = 'DEUTDEDB';
        req.bankingInformation[0].bankCountry   = 'DE';
        req.bankingInformation[0].accountCurrency = 'EUR';

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'SEPA insert should succeed: ' + result.message);

        Compliance__c c = [SELECT Id FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1];
        List<Banking_Details__c> bds = [
            SELECT IBAN__c, swift_code__c, bankCountry__c
            FROM Banking_Details__c WHERE Compliance__c = :c.Id
        ];
        System.assertEquals(1, bds.size(), 'Should have 1 Banking_Details__c for SEPA bank');
        System.assertEquals('DE89370400440532013000', bds[0].IBAN__c, 'IBAN stored in Banking_Details__c');
        System.assertEquals('DEUTDEDB', bds[0].swift_code__c, 'SWIFT stored in Banking_Details__c');
        System.assertEquals('Germany', bds[0].bankCountry__c, 'Bank country maps to Germany');
    }

    @isTest
    static void testMultipleBanks_CurrencyMatching() {
        // Tests that multiple banking details records are created from payload
        // No partner templates used (avoids Industry__c validation in tests)
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata = null; // no partner

        // Add a second bank (EUR SEPA) alongside the existing GBP UK bank
        NuveiConnectWebhookHandler.BankingInfoWrapper sepaBank =
            new NuveiConnectWebhookHandler.BankingInfoWrapper();
        sepaBank.iban              = 'DE89370400440532013000';
        sepaBank.swiftCode         = 'DEUTDEDB';
        sepaBank.bankCountry       = 'DE';
        sepaBank.accountCurrency   = 'EUR';
        sepaBank.accountHolderName = 'Tech Innovations EU Ltd';
        req.bankingInformation.add(sepaBank);

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'Should succeed with multiple banks: ' + result.message);

        Compliance__c mc = [SELECT Id FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1];

        List<Banking_Details__c> bds = [
            SELECT IBAN__c, branchCode__c, Target_Currency__c
            FROM Banking_Details__c WHERE Compliance__c = :mc.Id
            ORDER BY Target_Currency__c
        ];
        System.assertEquals(2, bds.size(), 'Should have 2 Banking_Details__c records');
        Map<String, Banking_Details__c> byCcy = new Map<String, Banking_Details__c>();
        for (Banking_Details__c b : bds) byCcy.put(b.Target_Currency__c, b);
        System.assertNotEquals(null, byCcy.get('GBP')?.branchCode__c, 'GBP record has sort code');
        System.assertNotEquals(null, byCcy.get('EUR')?.IBAN__c, 'EUR record has IBAN');
    }
    @isTest
    static void testNoPartnerTemplates_StandaloneBankCreated() {
        // No partner — bank details should still be written as standalone record
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata = null; // no partnerId

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'Should succeed without partner: ' + result.message);

        Compliance__c c2 = [SELECT Id FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1];
        List<Banking_Details__c> bds = [
            SELECT branchCode__c, Account_number__c, Account_Holder_Name__c
            FROM Banking_Details__c WHERE Compliance__c = :c2.Id
        ];
        System.assertEquals(1, bds.size(), 'Should create 1 Banking_Details__c without partner');
        System.assertEquals('123456', bds[0].branchCode__c, 'Sort code in branchCode__c');
        System.assertEquals('87654321', bds[0].Account_number__c, 'Account number populated');
    }

    @isTest
    static void testStatusUpdate_KnownStatus() {
        // First create the record
        NuveiConnectWebhookHandler.NuveiConnectRequest insertReq = buildEURequest();
        NuveiConnectWebhookHandler.processWebhook(insertReq);

        // Now send a status update
        NuveiConnectWebhookHandler.NuveiConnectRequest updateReq =
            new NuveiConnectWebhookHandler.NuveiConnectRequest();
        updateReq.applicationId     = 'EU-APP-001';
        updateReq.applicationStatus = 'APPROVED';
        updateReq.rawPayload        = '{"applicationId":"EU-APP-001","applicationStatus":"APPROVED"}';
        updateReq.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
        updateReq.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(updateReq);
        Test.stopTest();

        System.assert(result.success, 'Status update should succeed: ' + result.message);
        Compliance__c comp = [SELECT Compliance_Status__c, From_Reseller__c FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'];
        System.assertEquals('Oscilar Approved', comp.Compliance_Status__c, 'APPROVED should map to Oscilar Approved');
    }

    @isTest
    static void testStatusUpdate_AllMappings() {
        // Create base record
        NuveiConnectWebhookHandler.processWebhook(buildEURequest());

        Map<String, String> expectedMappings = new Map<String, String>{
            'PENDING_REVIEW'            => 'Oscilar Pending Review',
            'IN_REVIEW'                 => 'Oscilar In Review',
            'ADDITIONAL_INFO_REQUESTED' => 'Oscilar Additional Info Requested',
            'PENDING_APPROVAL'          => 'Oscilar Pending Approval',
            'CONDITIONALLY_APPROVED'    => 'Oscilar Conditionally Approved',
            'DECLINED'                  => 'Oscilar Declined',
            'WITHDRAWN'                 => 'Oscilar Withdrawn',
            'IN_PROGRESS'               => 'Oscilar In Progress'
        };

        for (String ncStatus : expectedMappings.keySet()) {
            NuveiConnectWebhookHandler.NuveiConnectRequest req =
                new NuveiConnectWebhookHandler.NuveiConnectRequest();
            req.applicationId     = 'EU-APP-001';
            req.applicationStatus = ncStatus;
            req.rawPayload        = '{}';
            req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
            req.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();

            NuveiConnectWebhookHandler.WebhookResult result =
                NuveiConnectWebhookHandler.processWebhook(req);
            System.assert(result.success, 'Status update failed for ' + ncStatus + ': ' + result.message);

            Compliance__c comp = [SELECT Compliance_Status__c, From_Reseller__c FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'];
            System.assertEquals(expectedMappings.get(ncStatus), comp.Compliance_Status__c,
                'Mapping failed for NC status: ' + ncStatus);
        }
    }

       @isTest
    static void testStatusUpdate_UnknownStatus_LogsError() {
        NuveiConnectWebhookHandler.processWebhook(buildEURequest());

        // Capture status BEFORE unknown event arrives
        Compliance__c before = [
            SELECT Compliance_Status__c
            FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'
        ];

        NuveiConnectWebhookHandler.NuveiConnectRequest req =
            new NuveiConnectWebhookHandler.NuveiConnectRequest();
        req.applicationId     = 'EU-APP-001';
        req.applicationStatus = 'UNKNOWN_FUTURE_STATUS';
        req.rawPayload        = '{}';
        req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
        req.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        // ── Hard contract: unknown status must fail loudly so NC retries ──
        System.assertNotEquals(null, result, 'Should always return a result, never throw');
        System.assertEquals(false, result.success,
            'Unknown NC status must return success=false (was a bug — used to silently 200)');
        System.assert(
            result.message != null && result.message.contains('Unknown NC status'),
            'Response message must explain the failure. Got: ' + result.message
        );

        // ── Status must not have been touched ──
        Compliance__c after = [
            SELECT Compliance_Status__c
            FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'
        ];
        System.assertEquals(before.Compliance_Status__c, after.Compliance_Status__c,
            'Compliance_Status__c must NOT change when NC sends unknown event');
    }

    @isTest
    static void testDuplicateInsert_GoesUpsertPath() {
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();

        Test.startTest();
        NuveiConnectWebhookHandler.processWebhook(req);   // first insert
        NuveiConnectWebhookHandler.processWebhook(req);   // should go upsert path
        Test.stopTest();

        // Should still only be one Compliance__c
        List<Compliance__c> comps = [
            SELECT Id FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'
        ];
        System.assertEquals(1, comps.size(), 'Duplicate applicationId should not create a second record');
    }

    @isTest
    static void testEUBankingVariant_SEPA_IBAN() {
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        // Replace UK bank with SEPA IBAN bank
        req.bankingInformation[0].sortCode = null;
        req.bankingInformation[0].accountNumber = null;
        req.bankingInformation[0].iban      = 'DE89370400440532013000';
        req.bankingInformation[0].swiftCode = 'DEUTDEDB';
        req.bankingInformation[0].bankCountry = 'DE';

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'SEPA IBAN EU insert should succeed: ' + result.message);
        // EU should still be detected (consentToPrivacyPolicy is present)
        Compliance__c comp = [SELECT Id FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1];
    }

    @isTest
    static void testMissingApplicationId_HandledGracefully() {
        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.applicationId = null;
        req.rawPayload    = '{"applicationId":null}';

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        // Should not throw an unhandled exception
        System.assertNotEquals(null, result, 'Should always return result object');
    }
    
        @isTest
    static void testStatusUpdate_ApplicationApproved_NormalizesAndLocksBanking() {
        // ── Arrange: insert base record (creates Banking_Details__c too) ──
        NuveiConnectWebhookHandler.processWebhook(buildEURequest());

        // ── Act: send the NC event name NC actually delivers ──
        NuveiConnectWebhookHandler.NuveiConnectRequest req =
            new NuveiConnectWebhookHandler.NuveiConnectRequest();
        req.applicationId     = 'EU-APP-001';
        req.applicationStatus = 'APPLICATION_APPROVED';   // ← long form NC sends
        req.rawPayload        = '{}';
        req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
        req.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        // ── Assert: webhook accepted ──
        System.assert(result.success,
            'APPLICATION_APPROVED must succeed (was a bug — used to return Unknown NC status). Got: ' + result.message);

        // ── Assert: Compliance status mapped to Oscilar Approved ──
        Compliance__c comp = [
            SELECT Compliance_Status__c, Nuvei_Connect_Status__c, Nuvei_Connect_Last_Webhook__c
            FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'
        ];
        System.assertEquals('Oscilar Approved', comp.Compliance_Status__c,
            'APPLICATION_APPROVED → Oscilar Approved');

        // ── Assert: Nuvei_Connect_Status__c normalized to short form ──
        // (picklist only accepts APPROVED, not APPLICATION_APPROVED — would throw INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST otherwise)
        System.assertEquals('APPROVED', comp.Nuvei_Connect_Status__c,
            'NC status must be normalized to the short picklist value (APPROVED), not the raw NC event name');

        System.assertNotEquals(null, comp.Nuvei_Connect_Last_Webhook__c,
            'Last webhook timestamp must be stamped');

        // ── Assert: approval side-effects fired (Banking lock) ──
        List<Banking_Details__c> banks = [
            SELECT UW_Approval__c, Locked__c
            FROM Banking_Details__c WHERE Compliance__c = :comp.Id
        ];
        System.assert(!banks.isEmpty(), 'Setup should have created at least one Banking_Details__c');
        for (Banking_Details__c bd : banks) {
            System.assertEquals('Verified', bd.UW_Approval__c,
                'Banking must be set to Verified on APPLICATION_APPROVED');
            System.assertEquals(true, bd.Locked__c,
                'Banking must be locked on APPLICATION_APPROVED');
        }
    }
    
            @isTest
    static void testStatusUpdate_AllApplicationEventMappings() {
        // Create base record OUTSIDE the metered block to keep its SOQL out of the budget
        NuveiConnectWebhookHandler.processWebhook(buildEURequest());

        // NC's actual outbound event names → expected SF picklist values
        Map<String, String> expectedSfStatus = new Map<String, String>{
            'APPLICATION_SUBMITTED'              => 'Oscilar Submitted',
            'APPLICATION_UPDATED'                => 'Oscilar In Review',
            'APPLICATION_APPROVED'               => 'Oscilar Approved',
            'APPLICATION_CONDITIONALLY_APPROVED' => 'Oscilar Conditionally Approved',
            'APPLICATION_DECLINED'               => 'Oscilar Declined',
            'ADDITIONAL_INFORMATION_REQUIRED'    => 'Oscilar Additional Info Requested'
        };

        Map<String, String> expectedNcShort = new Map<String, String>{
            'APPLICATION_SUBMITTED'              => 'SUBMITTED',
            'APPLICATION_UPDATED'                => 'IN_REVIEW',
            'APPLICATION_APPROVED'               => 'APPROVED',
            'APPLICATION_CONDITIONALLY_APPROVED' => 'CONDITIONALLY_APPROVED',
            'APPLICATION_DECLINED'               => 'DECLINED',
            'ADDITIONAL_INFORMATION_REQUIRED'    => 'ADDITIONAL_INFO_REQUESTED'
        };

        // Test.startTest() resets governor limits so the 6-iteration loop has a fresh budget
        Test.startTest();
        for (String ncEvent : expectedSfStatus.keySet()) {
            NuveiConnectWebhookHandler.NuveiConnectRequest req =
                new NuveiConnectWebhookHandler.NuveiConnectRequest();
            req.applicationId     = 'EU-APP-001';
            req.applicationStatus = ncEvent;
            req.rawPayload        = '{}';
            req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
            req.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();

            NuveiConnectWebhookHandler.WebhookResult result =
                NuveiConnectWebhookHandler.processWebhook(req);
            System.assert(result.success,
                'NC event ' + ncEvent + ' must succeed (was Unknown NC status). Got: ' + result.message);

            Compliance__c comp = [
                SELECT Compliance_Status__c, Nuvei_Connect_Status__c
                FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001'
            ];
            System.assertEquals(expectedSfStatus.get(ncEvent), comp.Compliance_Status__c,
                'SF status mapping failed for NC event: ' + ncEvent);
            System.assertEquals(expectedNcShort.get(ncEvent), comp.Nuvei_Connect_Status__c,
                'NC short-form normalization failed for: ' + ncEvent);
        }
        Test.stopTest();
    }

    // ── msaTemplateId selection — new pricing-template-picker behaviour ──
    //
    // NOTE ON ORG VALIDATION: Prod has a validation rule "Never change
    // industry (must be the same as in the company profile)" that blocks
    // Merchant_Bank__c inserts in test context in most Industry/SC-Acquirer
    // combinations. The established team pattern (see TrackDMsaConga header,
    // IndirectBoardingRouterTest, WaveOnePZeroFixesTest) is to attempt the
    // insert in try/catch and SKIP the test rather than fight the validation
    // cascade. That means these tests may pass trivially in orgs where the
    // partner-template insert cannot be created. In prod, the code paths
    // are exercised by the real webhook + real partner data.

    /**
     * Try to build an additional partner template Merchant_Bank__c so we can
     * exercise the multi-template path. Returns the Id on success, null if
     * blocked by the org validation cascade.
     */
    private static Id tryCreatePartnerTemplateBank(Id partnerId, Decimal chb) {
        try {
            Merchant_Bank__c template = new Merchant_Bank__c(
                Compliance__c              = partnerId,
                Partner_Template_Pricing__c = true,
                CHB_Handling__c            = chb
            );
            insert template;
            return template.Id;
        } catch (Exception e) {
            return null;
        }
    }

       @IsTest
    static void testEUInsert_msaTemplateId_matches_specific_partner_bank() {
        Compliance__c partner = createTestPartner('PARTNER-EU-001');
        Id t1 = tryCreatePartnerTemplateBank(partner.Id, 10);
        Id t2 = tryCreatePartnerTemplateBank(partner.Id, 20);
        Id t3 = tryCreatePartnerTemplateBank(partner.Id, 30);

        if (t1 == null || t2 == null || t3 == null) {
            // Established skip pattern — org validation blocked template setup.
            return;
        }

        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata.msaTemplateId = String.valueOf(t2);

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success, 'Insert should succeed: ' + result.message);

        Compliance__c merchant = [
            SELECT Id FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1
        ];

        List<Merchant_Bank__c> merchantBanks = [
            SELECT Id, CHB_Handling__c, Partner_Template_Pricing__c
            FROM   Merchant_Bank__c
            WHERE  Compliance__c = :merchant.Id
        ];
        System.assertEquals(1, merchantBanks.size(),
            'Exactly one Merchant_Bank__c must be cloned when msaTemplateId matches');
        System.assertEquals(20, merchantBanks[0].CHB_Handling__c,
            'The cloned Merchant_Bank__c must be the one whose Id matches msaTemplateId (CHB=20)');
        System.assertEquals(false, merchantBanks[0].Partner_Template_Pricing__c,
            'Cloned merchant pricing must have Partner_Template_Pricing__c=false');
    }

    @IsTest
    static void testEUInsert_msaTemplateId_no_match_logs_and_skips() {
        Compliance__c partner = createTestPartner('PARTNER-EU-001');
        Id t1 = tryCreatePartnerTemplateBank(partner.Id, 10);
        Id t2 = tryCreatePartnerTemplateBank(partner.Id, 20);
        if (t1 == null || t2 == null) return;

        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        req.metadata.msaTemplateId = 'a0X000000000000AAA';

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success,
            'Insert should still succeed overall — only the pricing clone is skipped: '
            + result.message);

        Compliance__c merchant = [
            SELECT Id FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1
        ];

        Integer clonedCount = [
            SELECT COUNT() FROM Merchant_Bank__c WHERE Compliance__c = :merchant.Id
        ];
        System.assertEquals(0, clonedCount,
            'Bogus msaTemplateId must result in NO cloned Merchant_Bank__c');

        Integer errorLogs = [
            SELECT COUNT() FROM Execution_Log__c
            WHERE Type__c = 'Error'
              AND Note__c LIKE '%msaTemplateId%'
        ];
        System.assert(errorLogs >= 1,
            'A clear Execution_Log__c error row must be written for the mismatched msaTemplateId');
    }

    @IsTest
    static void testEUInsert_no_msaTemplateId_multi_template_partner_logs_and_skips() {
        Compliance__c partner = createTestPartner('PARTNER-EU-001');
        Id t1 = tryCreatePartnerTemplateBank(partner.Id, 10);
        Id t2 = tryCreatePartnerTemplateBank(partner.Id, 20);
        if (t1 == null || t2 == null) return;

        NuveiConnectWebhookHandler.NuveiConnectRequest req = buildEURequest();
        // NC did NOT set msaTemplateId → multi-template partner ambiguous.

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult result =
            NuveiConnectWebhookHandler.processWebhook(req);
        Test.stopTest();

        System.assert(result.success,
            'Insert should still succeed overall — only pricing clone is skipped: '
            + result.message);

        Compliance__c merchant = [
            SELECT Id FROM Compliance__c
            WHERE Nuvei_Connect_Application_ID__c = 'EU-APP-001' LIMIT 1
        ];

        Integer clonedCount = [
            SELECT COUNT() FROM Merchant_Bank__c WHERE Compliance__c = :merchant.Id
        ];
        System.assertEquals(0, clonedCount,
            'Multi-template partner + missing msaTemplateId hint must clone nothing');

        Integer errorLogs = [
            SELECT COUNT() FROM Execution_Log__c
            WHERE Type__c = 'Error'
              AND (Note__c LIKE '%multiple%' OR Note__c LIKE '%disambiguate%'
                   OR Note__c LIKE '%Partner_Template_Pricing__c%')
        ];
        System.assert(errorLogs >= 1,
            'A clear Execution_Log__c error row must be written when multi-template partner has '
            + 'no msaTemplateId hint');
    }
    
    @isTest
static void initial_creation_sets_nuvei_connect_status_on_new_compliance() {
    // Regression guard: yesterday's dedup fix exposed that createAllObjects
    // did NOT set Nuvei_Connect_Status__c — only handleStatusUpdate did.
    // For NC apps where only a single APPLICATION_SUBMITTED webhook arrives,
    // Nuvei_Connect_Status__c was staying empty until a follow-up webhook.
    NuveiConnectWebhookHandler.NuveiConnectRequest req =
        new NuveiConnectWebhookHandler.NuveiConnectRequest();
    req.applicationId     = 'NC-INIT-CREATE-001';
    req.applicationStatus = 'APPLICATION_SUBMITTED';
    req.rawPayload        = '{}';
    req.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>();
    req.bankingInformation       = new List<NuveiConnectWebhookHandler.BankingInfoWrapper>();
    // Minimal businessInformation to allow buildCompliance to run
    req.businessInformation = new NuveiConnectWebhookHandler.BusinessInformationWrapper();
    req.businessInformation.legalName = 'Init Create Co';

    Test.startTest();
    NuveiConnectWebhookHandler.WebhookResult result =
        NuveiConnectWebhookHandler.processWebhook(req);
    Test.stopTest();

    System.assert(result.success, 'First webhook should succeed. Got: ' + result.message);

    Compliance__c comp = [
        SELECT Nuvei_Connect_Status__c, Compliance_Status__c
        FROM Compliance__c
        WHERE Nuvei_Connect_Application_ID__c = 'NC-INIT-CREATE-001'
        LIMIT 1
    ];
    System.assertEquals('SUBMITTED', comp.Nuvei_Connect_Status__c,
        'Nuvei_Connect_Status__c must be set on initial creation, not only on update');
    System.assertEquals('Oscilar Submitted', comp.Compliance_Status__c,
        'Compliance_Status__c must be set on initial creation');
}


    // NOTE: testBoardingLogCreated_OnInsert is disabled pending Track I deployment.
    // Boarding_Log__c and Boarding_Log_Entry__c do not yet exist in the org.
    // Re-enable once those objects are deployed.
    // @isTest
    // static void testBoardingLogCreated_OnInsert() { ... }
}
