@IsTest
private class MsaEuIndirectPdfControllerTest {

    @TestSetup
    static void setup() {
        Account acc = new Account(Name = 'Test Acc');
        insert acc;

        Compliance__c c = new Compliance__c(
            Name = 'TestMerchant Ltd',
            Account__c = acc.Id,
            MSA_Effective_Date__c = Date.today(),
            Registered_Country__c = 'United Kingdom',
            Incorporation_number__c = '12345678',
            Registered_Address_New__c = '10 Test St, London',
            Remittance_Cycle_MSA_wording__c = 'twice monthly',
            Contract_Term__c = 24,
            Fees_Currency__c = 'EUR',
            GW_Processing_Fee__c = 0.15,
            Wire_Fee__c = 25
        );
        insert c;

        insert new Website__c(Name = 'https://test1.com', Compliance__c = c.Id);
        insert new Website__c(Name = 'https://test2.com', Compliance__c = c.Id);

        insert new Merchant_Bank__c(
            Compliance__c = c.Id,
            Bank_Name_for_Conga__c = 'Test Bank',
            New_MSA_wording__c = 'Test wording',
            Partner_Template_Pricing__c = false,
            Setup_fee_per_bank_Merchant_ID_MID__c = 100,
            Annual_Fee__c = 500,
            Trx_Fee__c = 0.10
        );

        insert new Contact(
            FirstName = 'John', LastName = 'Doe', Title = 'CEO',
            AccountId = acc.Id, Email = 'jdoe@test.com'
        );
    }

    @IsTest
    static void controller_loads_compliance_and_children() {
        Compliance__c c = [SELECT Id FROM Compliance__c LIMIT 1];
        Contact signer = [SELECT Id FROM Contact LIMIT 1];

        Test.startTest();
        PageReference pr = Page.MsaEuIndirectPdf;
        pr.getParameters().put('id', c.Id);
        pr.getParameters().put('signerContactId', signer.Id);
        Test.setCurrentPage(pr);

        MsaEuIndirectPdfController ctrl = new MsaEuIndirectPdfController();
        Test.stopTest();

        System.assertNotEquals(null, ctrl.compliance, 'Compliance must load');
        System.assertEquals('TestMerchant Ltd', ctrl.compliance.Name);
        System.assertEquals(2, ctrl.websites.size(), 'Both websites must load');
        System.assertEquals(1, ctrl.merchantBanks.size(), 'Merchant bank must load');
        System.assertEquals('John Doe', ctrl.signerName);
        System.assertEquals('CEO', ctrl.signerTitle);
        System.assertNotEquals(null, ctrl.todayDate);
    }

    @IsTest
    static void controller_handles_missing_id_gracefully() {
        Test.startTest();
        PageReference pr = Page.MsaEuIndirectPdf;
        Test.setCurrentPage(pr);
        MsaEuIndirectPdfController ctrl = new MsaEuIndirectPdfController();
        Test.stopTest();

        System.assertNotEquals(null, ctrl.compliance, 'Empty compliance must be initialized');
        System.assertEquals(0, ctrl.websites.size());
        System.assertEquals(false, ctrl.hasApplicationForm);
        System.assertEquals(false, ctrl.hasReseller);
    }

    @IsTest
    static void controller_handles_invalid_id_gracefully() {
        Test.startTest();
        PageReference pr = Page.MsaEuIndirectPdf;
        pr.getParameters().put('id', 'not-an-id');
        Test.setCurrentPage(pr);
        MsaEuIndirectPdfController ctrl = new MsaEuIndirectPdfController();
        Test.stopTest();

        System.assertNotEquals(null, ctrl.compliance);
        System.assertEquals(0, ctrl.websites.size());
    }

    @IsTest
    static void formatRemittanceCurrency_replaces_semicolons() {
        Compliance__c c = [SELECT Id FROM Compliance__c LIMIT 1];
        c.Remittance_Currency_Text__c = 'EUR;USD;GBP';
        update c;

        Test.startTest();
        PageReference pr = Page.MsaEuIndirectPdf;
        pr.getParameters().put('id', c.Id);
        Test.setCurrentPage(pr);
        MsaEuIndirectPdfController ctrl = new MsaEuIndirectPdfController();
        Test.stopTest();

        System.assertEquals('EUR, USD, GBP', ctrl.remittanceCurrencyDisplay);
    }

    @IsTest
    static void controller_resolves_signer_with_null_title() {
        Compliance__c c = [SELECT Id FROM Compliance__c LIMIT 1];
        Contact noTitle = new Contact(FirstName = 'Jane', LastName = 'Smith');
        insert noTitle;

        Test.startTest();
        PageReference pr = Page.MsaEuIndirectPdf;
        pr.getParameters().put('id', c.Id);
        pr.getParameters().put('signerContactId', noTitle.Id);
        Test.setCurrentPage(pr);
        MsaEuIndirectPdfController ctrl = new MsaEuIndirectPdfController();
        Test.stopTest();

        System.assertEquals('Jane Smith', ctrl.signerName);
        System.assertEquals('', ctrl.signerTitle);
    }
}
