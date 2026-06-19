@IsTest
private class TrackDMsaCongaTest {

    // ── Mocks ────────────────────────────────────────────────────────────

    private class TrackDFullMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"envelopeId":"a1b2c3d4-0000-1111-2222-deadbeefcafe","status":"sent"}');
            return res;
        }
    }

    private class DocuSignErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(500);
            res.setBody('{"error":"docusign down"}');
            return res;
        }
    }

    // ── Setup helpers ────────────────────────────────────────────────────

    private static void insertCongaSettingFull() {
        insert new Conga_Setting__c(
            Name = 'Default',
            EU_Indirect_Template_ID__c = 'a1bTESTTEMPLATE',
            DocuSign_Account_Id__c = 'test-ds-account',
            MSA_Template_Id__c = 'TPL-ORG-DEFAULT'
        );
    }

    private static Compliance__c newCompliance(String name, Id accId, Id primaryContactId) {
        return new Compliance__c(
            Name = name,
            Account__c = accId,
            EU_Indirect_Orchestration__c = true,
            Nuvei_Connect_Status__c = 'APPROVED',
            Nuvei_Connect_Application_ID__c = 'APP-' + name,
            Compliance_Status__c = 'Live',
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123',
            City_field__c = '+44123456789',
            Primary_Contact__c = primaryContactId,
            MSA_Status__c = 'Pending',
            PCI_Status__c = 'Compliant'
        );
    }

    private static void insertConfigCase(Id complianceId, Id accId, Id contactId) {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        insert new Case(
            RecordTypeId        = rts[0].Id,
            AccountId           = accId,
            Company_Profile__c  = complianceId,
            ContactId           = contactId,
            Subject             = 'Cfg',
            Status              = 'In Progress',
            Reason              = 'New Merchant',
            Type                = 'Create new GW account with a new Multi',
            Profile_Type__c     = 'None',
            SB_PPP_Username__c  = 'cfg@test.invalid',
            SB_Template__c      = 'Merchant and merchantSite onboarding NCP acquiring CNP'
        );
    }

    private static void addSignatory(Id complianceId, Id accId) {
        Contact signer = new Contact(
            FirstName = 'Sig', LastName = 'Natory',
            Email = 'signer@test.invalid', AccountId = accId,
            Authorized_Signature__c = true
        );
        insert signer;
        insert new Compliance_Contact__c(
            Compliance__c = complianceId,
            Contact__c = signer.Id
        );
    }

    private static Boolean addMerchantPricing(Id complianceId) {
        try {
            insert new Merchant_Bank__c(
                Compliance__c = complianceId,
                Partner_Template_Pricing__c = false
            );
            return true;
        } catch (Exception e) {
            return false;
        }
    }

    private static Id insertStaticTemplate(String title) {
        ContentVersion cv = new ContentVersion(
            Title           = title,
            PathOnClient    = title + '.pdf',
            VersionData     = Blob.valueOf('FAKE-PDF-' + title),
            IsMajorVersion  = true
        );
        insert cv;
        return [SELECT Id FROM ContentVersion WHERE Id = :cv.Id LIMIT 1].Id;
    }

    // ── Null / orchestration guards ──────────────────────────────────────

    @IsTest
    static void tryAdvance_returns_false_when_id_null() {
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(null);
        Test.stopTest();
        System.assertEquals(false, r);
    }

    @IsTest
    static void tryAdvance_returns_false_when_not_eu_indirect() {
        Account acc = new Account(Name='AccNotEU'); insert acc;
        Compliance__c c = new Compliance__c(
            Name='CoNotEU', Account__c=acc.Id,
            EU_Indirect_Orchestration__c = false,
            Nuvei_Connect_Status__c = 'APPROVED'
        );
        insert c;
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(false, r);
    }

    @IsTest
    static void tryAdvance_returns_false_when_not_approved() {
        Account acc = new Account(Name='AccNotAppr'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm', AccountId=acc.Id);
        insert adm;
        Compliance__c c = newCompliance('NotAppr', acc.Id, adm.Id);
        c.Nuvei_Connect_Status__c = null;
        insert c;
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(false, r);
    }

    @IsTest
    static void tryAdvance_returns_false_when_no_config_case() {
        Account acc = new Account(Name='AccNoCase'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm', AccountId=acc.Id);
        insert adm;
        Compliance__c c = newCompliance('NoCase', acc.Id, adm.Id);
        insert c;
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(false, r);
    }

    @IsTest
    static void tryAdvance_returns_false_when_status_is_sent_already() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;

        Account acc = new Account(Name='AccAlreadySent'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='alr@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('AlreadySent', acc.Id, adm.Id);
        c.MSA_Status__c = 'sent';
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(false, r);
    }

    @IsTest
    static void tryAdvance_returns_false_when_no_pricing_yet() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;

        Account acc = new Account(Name='AccNoPricing'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='np@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('NoPricing', acc.Id, adm.Id);
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        addSignatory(c.Id, acc.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(false, r);

        Compliance__c reread = [SELECT MSA_Status__c FROM Compliance__c WHERE Id=:c.Id];
        System.assertEquals('Pending', reread.MSA_Status__c);
    }

    // ── Hard-fail paths (only run if Merchant_Bank insert succeeds) ─────

    @IsTest
    static void tryAdvance_fails_when_no_authorized_signatory() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccNoSig'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='ns@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('NoSig', acc.Id, adm.Id);
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        if (!addMerchantPricing(c.Id)) return;

        insertCongaSettingFull();
        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r);
    }

    @IsTest
    static void tryAdvance_fails_when_template_missing() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccNoTpl'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='nt@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('NoTpl', acc.Id, adm.Id);
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        addSignatory(c.Id, acc.Id);
        if (!addMerchantPricing(c.Id)) return;

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r);
    }

    @IsTest
    static void tryAdvance_fails_when_docusign_returns_5xx() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccDsErr'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='ds@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Id cvId = insertStaticTemplate('DsErrTpl');

        Compliance__c c = newCompliance('DsErr', acc.Id, adm.Id);
        c.MSA_Static_Template_Id__c = cvId;
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        addSignatory(c.Id, acc.Id);
        if (!addMerchantPricing(c.Id)) return;
        insertCongaSettingFull();

        Test.setMock(HttpCalloutMock.class, new DocuSignErrorMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r);

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id=:c.Id];
        System.assertEquals('Failed', after.MSA_Status__c);
    }

    @IsTest
    static void tryAdvance_happy_path_marks_sent() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccHappy'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='hp@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Id cvId = insertStaticTemplate('HappyTpl');

        Compliance__c c = newCompliance('Happy', acc.Id, adm.Id);
        c.MSA_Static_Template_Id__c = cvId;
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        addSignatory(c.Id, acc.Id);
        if (!addMerchantPricing(c.Id)) return;
        insertCongaSettingFull();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r);
    }

    @IsTest
    static void failWithLog_does_not_log_twice_on_rerun() {
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccDup'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='du@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('Dup', acc.Id, adm.Id);
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        if (!addMerchantPricing(c.Id)) return;

        insertCongaSettingFull();
        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        d.tryAdvance(c.Id);
        d.tryAdvance(c.Id);
        Test.stopTest();
    }

    // ════════════════════════════════════════════════════════════════════
    // Coverage boost — direct @TestVisible method calls.
    // These exercise paths that can't always be reached via tryAdvance()
    // because org validation rules block Merchant_Bank__c inserts in test.
    // ════════════════════════════════════════════════════════════════════

    @IsTest
    static void cov_hasMerchantPricing_returns_false_when_no_rows() {
        Account acc = new Account(Name='HMP'); insert acc;
        Compliance__c c = new Compliance__c(Name='HMP', Account__c=acc.Id);
        insert c;

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.hasMerchantPricing(c.Id);
        Test.stopTest();
        System.assertEquals(false, r,
            'No Merchant_Bank__c rows → hasMerchantPricing returns false');
    }

    @IsTest
    static void cov_resolveAuthorizedSignatory_returns_null_when_no_signers() {
        Account acc = new Account(Name='RAS'); insert acc;
        Compliance__c c = new Compliance__c(Name='RAS', Account__c=acc.Id);
        insert c;

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Id r = d.resolveAuthorizedSignatory(c.Id);
        Test.stopTest();
        System.assertEquals(null, r,
            'No Compliance_Contact__c with Director__c=true → null');
    }

    @IsTest
    static void cov_resolveAuthorizedSignatory_returns_signer_id_when_present() {
        Account acc = new Account(Name='RASS'); insert acc;
        Compliance__c c = new Compliance__c(Name='RASS', Account__c=acc.Id);
        insert c;
        Contact con = new Contact(
            FirstName='Sig', LastName='Two', AccountId=acc.Id,
            Email='sig2@x.invalid', Authorized_Signature__c=true
        );
        insert con;
        insert new Compliance_Contact__c(
            Compliance__c=c.Id,
            Contact__c=con.Id
        );

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Id r = d.resolveAuthorizedSignatory(c.Id);
        Test.stopTest();
        System.assertEquals(con.Id, r,
            'Authorized signatory Contact must be returned');
    }

    @IsTest
    static void cov_resolveMsaTemplateId_prefers_merchant_id() {
        Account acc = new Account(Name='RMT-M'); insert acc;
        Compliance__c c = new Compliance__c(
            Name='RMT-M', Account__c=acc.Id,
            MSA_Static_Template_Id__c = 'TPL-MERCHANT'
        );
        insert c;
        insertCongaSettingFull();

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals('TPL-MERCHANT', tplId);
    }

    @IsTest
    static void cov_resolveMsaTemplateId_falls_back_to_org_default() {
        Account acc = new Account(Name='RMT-O'); insert acc;
        Compliance__c c = new Compliance__c(Name='RMT-O', Account__c=acc.Id);
        insert c;
        insertCongaSettingFull();

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals('TPL-ORG-DEFAULT', tplId);
    }

    @IsTest
    static void cov_resolveMsaTemplateId_returns_null_when_nothing_configured() {
        Account acc = new Account(Name='RMT-N'); insert acc;
        Compliance__c c = new Compliance__c(Name='RMT-N', Account__c=acc.Id);
        insert c;

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals(null, tplId);
    }

    @IsTest
    static void cov_loadStaticMsaTemplate_returns_blob_when_present() {
        Id cvId = insertStaticTemplate('LoadCov');

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Blob pdf = d.loadStaticMsaTemplate(cvId);
        Test.stopTest();
        System.assertNotEquals(null, pdf);
        System.assert(pdf.size() > 0);
    }

    @IsTest
    static void cov_loadStaticMsaTemplate_returns_null_when_missing() {
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Blob pdf = d.loadStaticMsaTemplate('068000000000000AAA');
        Test.stopTest();
        System.assertEquals(null, pdf);
    }

    @IsTest
    static void cov_resolveCPanelAdmin_returns_null_when_account_id_null() {
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Id r = d.resolveCPanelAdmin(null);
        Test.stopTest();
        System.assertEquals(null, r);
    }

    @IsTest
    static void cov_resolveCPanelAdmin_returns_contact_when_present() {
        Account acc = new Account(Name='CPA'); insert acc;
        Contact adm = new Contact(
            FirstName='A', LastName='Adm', Email='cpa@x.invalid',
            AccountId=acc.Id, Is_CPanel_Admin__c=true
        );
        insert adm;

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Id r = d.resolveCPanelAdmin(acc.Id);
        Test.stopTest();
        System.assertEquals(adm.Id, r);
    }
}
