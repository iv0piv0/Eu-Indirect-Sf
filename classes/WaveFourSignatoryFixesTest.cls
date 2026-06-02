@isTest
private class WaveFourSignatoryFixesTest {

    /**
     * Builds a minimal NC request with 3 business owners, one flagged as
     * the authorized signatory, and a portal admin whose email matches one
     * of the owners (to verify the cPanel-merge branch).
     */
    private static NuveiConnectWebhookHandler.NuveiConnectRequest buildReq(String appId) {
        NuveiConnectWebhookHandler.NuveiConnectRequest r = new NuveiConnectWebhookHandler.NuveiConnectRequest();
        r.applicationId = appId;
        r.applicationStatus = 'SUBMITTED';

        NuveiConnectWebhookHandler.BusinessInformationWrapper bi =
            new NuveiConnectWebhookHandler.BusinessInformationWrapper();
        bi.legalName = 'Wave4 Co';
        bi.businessType = 'LIMITED_COMPANY';
        bi.merchantCategoryCode = '5734';
        bi.websiteUrl = 'https://w4.example';
        bi.businessRegistrationNumber = 'W4-001';

        NuveiConnectWebhookHandler.AddressWrapper addr =
            new NuveiConnectWebhookHandler.AddressWrapper();
        addr.addressType = 'BUSINESS_ADDRESS';
        addr.country = 'GB';
        addr.city = 'London';
        addr.postalCode = 'EC1A 1BB';
        addr.addressLine1 = '1 St';
        bi.addresses = new List<NuveiConnectWebhookHandler.AddressWrapper>{ addr };

        NuveiConnectWebhookHandler.ContactInfoWrapper ci =
            new NuveiConnectWebhookHandler.ContactInfoWrapper();
        ci.firstName = 'Primary';
        ci.lastName = 'Contact';
        ci.businessEmail = 'primary@w4.example';
        ci.contactNumber = '+44111';
        bi.contactInformation = ci;
        r.businessInformation = bi;

        // Three owners — owner B is signatory and also matches portal admin email
        NuveiConnectWebhookHandler.BusinessOwnerWrapper a =
            new NuveiConnectWebhookHandler.BusinessOwnerWrapper();
        a.legalFirstName = 'Alice';   a.legalLastName = 'Aaa';
        a.email = 'alice@w4.example'; a.contactNumber = '+44222';
        a.percentageOfOwnership = 25; a.isAuthorizedSignatory = false;

        NuveiConnectWebhookHandler.BusinessOwnerWrapper b =
            new NuveiConnectWebhookHandler.BusinessOwnerWrapper();
        b.legalFirstName = 'Bob';   b.legalLastName = 'Bbb';
        b.email = 'admin@w4.example'; b.contactNumber = '+44333';
        b.percentageOfOwnership = 50; b.isAuthorizedSignatory = true;

        NuveiConnectWebhookHandler.BusinessOwnerWrapper c =
            new NuveiConnectWebhookHandler.BusinessOwnerWrapper();
        c.legalFirstName = 'Carol'; c.legalLastName = 'Ccc';
        c.email = 'carol@w4.example'; c.contactNumber = '+44444';
        c.percentageOfOwnership = 25; c.isAuthorizedSignatory = false;

        r.businessOwnerInformation = new List<NuveiConnectWebhookHandler.BusinessOwnerWrapper>{ a, b, c };

        NuveiConnectWebhookHandler.AdditionalInfoWrapper ai =
            new NuveiConnectWebhookHandler.AdditionalInfoWrapper();
        ai.portalAdminFirstName = 'Bob';
        ai.portalAdminLastName  = 'Bbb';
        ai.portalAdminEmail     = 'admin@w4.example'; // matches owner B
        ai.portalAdminContactNumber = '+44333';
        r.additionalInformation = ai;

        return r;
    }

    @isTest
    static void create_owner_contacts_and_junctions_with_signatory_picked() {
        NuveiConnectWebhookHandler.NuveiConnectRequest r = buildReq('NC-W4-001');

        Test.startTest();
        NuveiConnectWebhookHandler.WebhookResult res = NuveiConnectWebhookHandler.processWebhook(r);
        Test.stopTest();

        System.assertEquals(true, res.success, res.message);

        Compliance__c comp = [
            SELECT Id, Account__c, DocuSign_Recipient__c, DocuSign_Recipient__r.Email,
                   Primary_Contact__c
            FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'NC-W4-001' LIMIT 1
        ];

        // 3 owner contacts + 1 primary contact (different email) = 4 total
        List<Contact> cons = [
            SELECT Id, Email, Authorized_Signature__c, Is_CPanel_Admin__c
            FROM Contact WHERE AccountId = :comp.Account__c
        ];
        Map<String, Contact> byEmail = new Map<String, Contact>();
        for (Contact c : cons) byEmail.put(c.Email.toLowerCase(), c);

        System.assertEquals(4, cons.size(), 'Expect 1 primary + 3 owners (admin merged into owner B)');

        // Bob is signatory + cPanel admin (same Contact, both flags true)
        Contact bob = byEmail.get('admin@w4.example');
        System.assertNotEquals(null, bob, 'Owner B should exist');
        System.assertEquals(true, bob.Authorized_Signature__c, 'Bob should be signatory');
        System.assertEquals(true, bob.Is_CPanel_Admin__c, 'Bob should also be cPanel (merged)');

        // Alice & Carol — not signatory
        System.assertEquals(false, byEmail.get('alice@w4.example').Authorized_Signature__c == true);
        System.assertEquals(false, byEmail.get('carol@w4.example').Authorized_Signature__c == true);

        // DocuSign recipient resolves to Bob (signatory wins over primary contact)
        System.assertEquals('admin@w4.example', comp.DocuSign_Recipient__r.Email,
            'DocuSign_Recipient__c must point to the authorized signatory');

        // Junctions — one per owner (3)
        List<Compliance_Contact__c> juncs = [
            SELECT Id, Contact__c, Contact__r.Email
            FROM Compliance_Contact__c WHERE Compliance__c = :comp.Id
        ];
        System.assertEquals(3, juncs.size(), 'One junction per owner');
    }

    @isTest
    static void no_signatory_falls_back_to_primary_contact() {
        NuveiConnectWebhookHandler.NuveiConnectRequest r = buildReq('NC-W4-002');
        for (NuveiConnectWebhookHandler.BusinessOwnerWrapper bo : r.businessOwnerInformation) {
            bo.isAuthorizedSignatory = false; // none flagged
        }

        Test.startTest();
        NuveiConnectWebhookHandler.processWebhook(r);
        Test.stopTest();

        Compliance__c comp = [
            SELECT DocuSign_Recipient__r.Email
            FROM Compliance__c WHERE Nuvei_Connect_Application_ID__c = 'NC-W4-002' LIMIT 1
        ];
        System.assertEquals('primary@w4.example', comp.DocuSign_Recipient__r.Email,
            'With no signatory, must fall back to primary contact');
    }

    @isTest
    static void backfill_on_status_update_creates_missing_owner_contacts_and_junctions() {
        // Step 1: simulate a pre-Wave-4 record by creating Compliance + Account
        // with only the primary contact, no owner contacts, no junctions.
        Account acc = new Account(Name = 'Wave4 BackfillCo');
        insert acc;
        Contact primary = new Contact(
            FirstName = 'Primary', LastName = 'Contact',
            Email = 'primary@w4.example', AccountId = acc.Id
        );
        insert primary;
        Compliance__c comp = new Compliance__c(
            Name = 'Wave4 BackfillCo',
            Account__c = acc.Id,
            Nuvei_Connect_Application_ID__c = 'NC-W4-BF',
            Nuvei_Connect_Status__c = 'SUBMITTED',
            Compliance_Status__c = 'Oscilar Submitted',
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St', Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'EC1A 1BB',
            City_field__c = '+44111',
            Primary_Contact__c = primary.Id,
            DocuSign_Recipient__c = primary.Id
        );
        insert comp;

        // Step 2: NC re-fires the webhook with full owner info → backfill should populate
        NuveiConnectWebhookHandler.NuveiConnectRequest r = buildReq('NC-W4-BF');
        r.applicationStatus = 'PENDING_REVIEW';

        Test.startTest();
        NuveiConnectWebhookHandler.processWebhook(r);
        Test.stopTest();

        Integer ownerCount = [
            SELECT COUNT() FROM Contact
            WHERE AccountId = :acc.Id AND Email IN ('alice@w4.example','admin@w4.example','carol@w4.example')
        ];
        System.assertEquals(3, ownerCount, 'Backfill must create the 3 missing owner contacts');

        Integer juncCount = [
            SELECT COUNT() FROM Compliance_Contact__c WHERE Compliance__c = :comp.Id
        ];
        System.assertEquals(3, juncCount, 'Backfill must create 3 junction rows');

        Contact bob = [SELECT Authorized_Signature__c, Is_CPanel_Admin__c
                       FROM Contact WHERE Email = 'admin@w4.example' AND AccountId = :acc.Id LIMIT 1];
        System.assertEquals(true, bob.Authorized_Signature__c);
        System.assertEquals(true, bob.Is_CPanel_Admin__c);
    }
}
