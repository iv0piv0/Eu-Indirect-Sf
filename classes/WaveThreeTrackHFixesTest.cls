@isTest
private class WaveThreeTrackHFixesTest {

    private static String lastBody;

    @isTest
    static void trackH_payload_includes_full_application_data() {
        Account acc = new Account(Name = 'TrackH Acc', Phone = '+44111', Website = 'https://h.example');
        insert acc;
        Contact con = new Contact(
            FirstName = 'Track', LastName = 'H',
            Email = 'trackh@example.com', Phone = '+44111',
            AccountId = acc.Id
        );
        insert con;
        Compliance__c comp = new Compliance__c(
            Name = 'TrackH Co',
            Account__c = acc.Id,
            Primary_Contact__c = con.Id,
            Nuvei_Connect_Application_ID__c = 'NC-TRACKH-001',
            Nuvei_Partner_ID__c = 'PARTNER-UUID-X',
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 Test St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'EC1A 1BB',
            City_field__c = '+447911000000',
            Company_Type__c = 'Limited',
            Manual_MCC_Code__c = '5734',
            Url__c = 'https://h.example',
            VAT_Number__c = 'GB123456789',
            Tax_ID_Type__c = 'VAT'
        );
        insert comp;

        // Application_Form must exist BEFORE director (director has required lookup to it)
        Application_Form__c af = new Application_Form__c(
            Company_Profile__c = comp.Id,
            Average_transaction_value__c = 100,
            Maximum_Ticket_Value_1__c = 500,
            E_comm__c = 100,
            Expected_Monthly_Volume__c = 10000,
            Processing_Currencies_New__c = 'GBP',
            Target_Market__c = 'United Kingdom'
        );
        insert af;

        insert new Banking_Details__c(
            Compliance__c = comp.Id,
            Account_Holder_Name__c = 'TrackH Co',
            Beneficiary_Country__c = 'United Kingdom',
            Target_Currency__c = 'GBP',
            IBAN__c = 'GB29NWBK60161331926819',
            swift_code__c = 'NWBKGB2L'
        );

        insert new Directors_or_Ultimate_Beneficial_Owner__c(
            Company_Profile__c = comp.Id,
            Application_Form__c = af.Id,
            First_Name__c = 'John',
            Last_Name__c = 'Doe',
            Email__c = 'jd@example.com',
            Phone__c = '+44222',
            Country__c = 'United Kingdom'
        );

        Test.setMock(HttpCalloutMock.class, new TrackHMock());
        Test.startTest();
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_ACTIVATED');
        Test.stopTest();

        Compliance__c after = [SELECT Nuvei_Connect_Status__c, Compliance_Status__c
            FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals('MERCHANT_ACTIVATED', after.Nuvei_Connect_Status__c);
        System.assertEquals('Live', after.Compliance_Status__c);

        System.assert(lastBody.contains('"applicationId":"NC-TRACKH-001"'), 'applicationId missing from payload');
        System.assert(lastBody.contains('"legalName":"TrackH Co"'), 'legalName missing');
        System.assert(lastBody.contains('"businessType":"LIMITED_COMPANY"'), 'businessType not reverse-mapped');
        System.assert(lastBody.contains('"country":"GB"'), 'country not reverse-mapped to ISO');
        System.assert(lastBody.contains('"iban":"GB29NWBK60161331926819"'), 'banking iban missing');
        System.assert(lastBody.contains('"merchant_activated"'), 'outputs.decisions[].status not lowercased');
        System.assert(lastBody.contains('"name":"pre_onboarding_dev"'), 'input.name should be pre_onboarding_dev');
        System.assert(lastBody.contains('"partnerId":"PARTNER-UUID-X"'), 'metadata.partnerId missing');
    }

    public class TrackHMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            lastBody = req.getBody();
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setBody('{"ok":true}');
            return res;
        }
    }
}
