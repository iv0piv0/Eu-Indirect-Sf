@IsTest
private class MerchantPayloadIndirectTest {
    @IsTest
    static void payload_omits_optional_partner_fields_when_blank() {
        Account acc = new Account(Name = 'PayAcc');
        insert acc;
        Contact con = new Contact(
            FirstName = 'P',
            LastName = 'C',
            Email = 'pc@test.invalid',
            AccountId = acc.Id,
            MailingStreet = '1 St',
            MailingCity = 'London',
            MailingCountry = 'United Kingdom',
            MailingPostalCode = 'E1 1AA',
            Phone = '+44123456789'
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'PayCo',
            Account__c = acc.Id,
            Primary_Contact__c = con.Id,
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB999',
            City_field__c = '+44123456789',
            MSA_Effective_Date__c = Date.today(),
            State_USA__c = null
        );
        insert comp;
        Case cas = new Case(
            Company_Profile__c = comp.Id,
            ContactId = con.Id,
            SB_PPP_Username__c = 'u@test.invalid',
            SB_Template__c = 'Ecommerce',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
        insert cas;
        cas = MerchantOnboardingController.fetchCase(cas.Id);
        MerchantPayload p = new MerchantPayload(cas, false, false);
        String json = JSON.serialize(p, true);
        System.assert(
            !json.containsIgnoreCase('"parentEntityId"'),
            'parentEntityId should be omitted when blank: ' + json
        );
        System.assert(
            !json.containsIgnoreCase('"credentialsUrl"'),
            'credentialsUrl should be omitted when blank'
        );
        System.assert(json.contains('"profile"'), json);
    }
}