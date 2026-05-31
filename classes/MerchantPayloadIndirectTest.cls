@IsTest
private class MerchantPayloadIndirectTest {

    @IsTest
    static void payload_omits_optional_partner_fields_when_blank() {
        Account acc = new Account(Name = 'PayAcc');
        insert acc;
        Contact con = new Contact(
            FirstName = 'P', LastName = 'C',
            Email = 'pc@test.invalid', AccountId = acc.Id,
            MailingStreet = '1 St', MailingCity = 'London',
            MailingCountry = 'United Kingdom', MailingPostalCode = 'E1 1AA',
            Phone = '+44123456789'
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'PayCo', Account__c = acc.Id, Primary_Contact__c = con.Id,
            Registered_Country__c = 'United Kingdom', Registered_Street__c = '1 St',
            Registered_City__c = 'London', Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB999', City_field__c = '+44123456789',
            MSA_Effective_Date__c = Date.today(), State_USA__c = null
        );
        insert comp;
        Case cas = new Case(
            Company_Profile__c = comp.Id, ContactId = con.Id,
            SB_PPP_Username__c = 'u@test.invalid', SB_Template__c = 'Ecommerce',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
        insert cas;
        cas = MerchantOnboardingController.fetchCase(cas.Id);

        MerchantPayload p = new MerchantPayload(cas, false, false);
        String jsonStr = JSON.serialize(p, true);
        System.assert(!jsonStr.containsIgnoreCase('"parentEntityId"'),
            'parentEntityId should be omitted when blank: ' + jsonStr);
        System.assert(!jsonStr.containsIgnoreCase('"credentialsUrl"'),
            'credentialsUrl should be omitted when blank');
        System.assert(jsonStr.contains('"profile"'), jsonStr);
    }

    /**
     * Regression guard — NCP merchants schema defines User with
     * additionalProperties: false. Sending phoneNumber on the user object
     * causes HTTP 422. This test fails if anyone re-adds it.
     */
    @IsTest
    static void payload_user_must_not_contain_phoneNumber() {
        Account acc = new Account(Name = 'PayAccUser');
        insert acc;
        Contact con = new Contact(
            FirstName = 'P', LastName = 'C', Email = 'pc@test.invalid',
            AccountId = acc.Id, Phone = '+44123456789'
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'PayCoUser', Account__c = acc.Id, Primary_Contact__c = con.Id,
            Registered_Country__c = 'United Kingdom', Registered_Street__c = '1 St',
            Registered_City__c = 'London', Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB999U', City_field__c = '+44123456789'
        );
        insert comp;
        Case cas = new Case(
            Company_Profile__c = comp.Id, ContactId = con.Id,
            SB_PPP_Username__c = 'u@test.invalid', SB_Template__c = 'Ecommerce',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
        insert cas;
        cas = MerchantOnboardingController.fetchCase(cas.Id);

        MerchantPayload p = new MerchantPayload(cas, true, false);
        String jsonStr = JSON.serialize(p, true);

        System.assert(jsonStr.contains('"phoneNumber"'),
            'Merchant-level phoneNumber is required by NCP and must be serialized');

        Object parsed = JSON.deserializeUntyped(jsonStr);
        Map<String, Object> root = (Map<String, Object>) parsed;
        List<Object> users = (List<Object>) root.get('users');
        System.assertNotEquals(null, users, 'users array must be present');
        System.assert(!users.isEmpty(), 'users array must not be empty');
        Map<String, Object> user0 = (Map<String, Object>) users[0];
        System.assert(!user0.containsKey('phoneNumber'),
            'User object MUST NOT contain phoneNumber — NCP schema rejects it.');
    }

    @IsTest
    static void payload_payfac_branch_adds_visa_mastercard_methods() {
        Account acc = new Account(Name = 'PfAcc');
        insert acc;
        Contact con = new Contact(
            FirstName = 'PF', LastName = 'User', Email = 'pf@test.invalid',
            AccountId = acc.Id, Phone = '+44111'
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'PfCo', Account__c = acc.Id, Primary_Contact__c = con.Id,
            Registered_Country__c = 'United Kingdom', Registered_Street__c = '1 St',
            Registered_City__c = 'London', Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123P', City_field__c = '+44111'
        );
        insert comp;
        Case cas = new Case(
            Company_Profile__c = comp.Id, ContactId = con.Id,
            SB_PPP_Username__c = 'pf@test.invalid', SB_Template__c = 'Ecommerce',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
        insert cas;
        cas = MerchantOnboardingController.fetchCase(cas.Id);

        MerchantPayload p = new MerchantPayload(cas, true, true); // isPayFac = true
        String jsonStr = JSON.serialize(p, true);
        System.assert(jsonStr.contains('Visa'), 'PayFac branch must include Visa');
        System.assert(jsonStr.contains('MasterCard'), 'PayFac branch must include MasterCard');
    }

    @IsTest
    static void payload_address_truncates_long_street_into_line2_line3() {
        String longStreet = 'aaaaaaaaaabbbbbbbbbbccccccccccddddddddddeeeeeeeeeeffffffffffgggggggggghhhhhhhhhhiiiiiiiiii';
        Account acc = new Account(Name = 'AddrAcc');
        insert acc;
        Contact con = new Contact(
            FirstName = 'A', LastName = 'B', Email = 'a@test.invalid',
            AccountId = acc.Id, Phone = '+44333'
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'AddrCo', Account__c = acc.Id, Primary_Contact__c = con.Id,
            Registered_Country__c = 'United Kingdom', Registered_Street__c = longStreet,
            Registered_City__c = 'London', Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB333A', City_field__c = '+44333'
        );
        insert comp;
        Case cas = new Case(
            Company_Profile__c = comp.Id, ContactId = con.Id,
            SB_PPP_Username__c = 'a@test.invalid', SB_Template__c = 'Ecommerce',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
        insert cas;
        cas = MerchantOnboardingController.fetchCase(cas.Id);

        MerchantPayload p = new MerchantPayload(cas, true, false);
        String jsonStr = JSON.serialize(p, true);
        System.assert(jsonStr.contains('"line1"'), 'line1 expected');
        System.assert(jsonStr.contains('"line2"'), 'line2 expected for >30 char street');
        System.assert(jsonStr.contains('"line3"'), 'line3 expected for >60 char street');
    }

    @IsTest
    static void payload_origin_region_and_vertical_enum_mappings() {
        Map<String, String> verticals = new Map<String, String>{
            'Cryptocurrency' => '1',
            'Marketplace'    => '2',
            'Social Gaming'  => '3'
        };
        List<String> regions = new List<String>{ 'NA', 'EMEA', 'LATAM', 'APAC' };

        Account acc = new Account(Name = 'EnumAcc');
        insert acc;
        Contact con = new Contact(
            FirstName = 'E', LastName = 'F', Email = 'ef@test.invalid',
            AccountId = acc.Id, Phone = '+44555'
        );
        insert con;

        Long ts = DateTime.now().getTime();
        Integer i = 0;
        for (String vert : verticals.keySet()) {
            String region = regions[Math.mod(i, regions.size())];
            i++;
            String uniq = String.valueOf(ts) + 'E' + i;

            Compliance__c comp = new Compliance__c(
                Name = 'EnumCo' + uniq,
                Account__c = acc.Id, Primary_Contact__c = con.Id,
                Registered_Country__c = 'United Kingdom', Registered_Street__c = '1 St',
                Registered_City__c = 'London', Registered_Zip_Postal_Code__c = 'E1 1AA',
                VAT_Number__c = 'GB' + uniq,
                City_field__c = '+44555',
                Overwrite_Financial_Vertical__c = vert,
                Origin_Region__c = region
            );
            insert comp;
            Case cas = new Case(
                Company_Profile__c = comp.Id, ContactId = con.Id,
                SB_PPP_Username__c = 'ef' + uniq + '@test.invalid',
                SB_Template__c = 'Ecommerce',
                Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
            );
            insert cas;
            cas = MerchantOnboardingController.fetchCase(cas.Id);

            MerchantPayload p = new MerchantPayload(cas, true, false);
            String jsonStr = JSON.serialize(p, true);
            System.assert(jsonStr.contains('industryIndication'));
            System.assert(jsonStr.contains('businessOriginRegion'));
        }
    }
}
