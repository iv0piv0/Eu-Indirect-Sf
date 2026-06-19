@IsTest
private class TrackDMsaCongaTest {

    // ── Mocks ────────────────────────────────────────────────────────────
    //
    // The new TrackDMsaConga makes ZERO Conga callouts — the MSA PDF is
    // loaded from a ContentVersion via SOQL. The only HTTP callout is the
    // DocuSign envelope send performed by MsaDocuSignService. These mocks
    // therefore only need to answer DocuSign requests.
    //
    // We keep TrackDFullMock named the same way for readability with the
    // historical tests; "Full" now means "everything DocuSign needs to
    // succeed", not "everything Conga + DocuSign needs to succeed".

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

    private static void insertDocuSignSetting() {
        // Conga_Setting__c is retained as the DocuSign account-id holder
        // (DocuSign_Account_Id__c). The Conga-specific session fields are
        // no longer read by TrackDMsaConga but are harmless to populate.
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

    /**
     * Insert a small ContentVersion that represents the static MSA PDF.
     * Returns the ContentVersion Id so the test can wire it onto the
     * Compliance / Conga_Setting__c template-id fields.
     */
    private static Id insertStaticTemplate(String title) {
        ContentVersion cv = new ContentVersion(
            Title           = title,
            PathOnClient    = title + '.pdf',
            VersionData     = Blob.valueOf('FAKE-PDF-' + title),
            IsMajorVersion  = true
        );
        insert cv;
        // Re-query to get the Id that the SOQL in TrackDMsaConga will use.
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

        insertDocuSignSetting();
        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r,
            'No signatory must hard-fail (return true) and not call DocuSign');
    }

    @IsTest
    static void tryAdvance_fails_when_template_missing() {
        // No Conga_Setting__c row and no MSA_Static_Template_Id__c on the
        // Compliance / partner → resolveMsaTemplateId returns null → failure.
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
    static void tryAdvance_fails_when_template_id_set_but_contentversion_missing() {
        // MSA_Static_Template_Id__c references a non-existent ContentVersion
        // → loadStaticMsaTemplate returns null → failWithLog branch.
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
        ];
        if (rts.isEmpty()) return;
        Account acc = new Account(Name='AccTplEmpty'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='te@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;
        Compliance__c c = newCompliance('TplEmpty', acc.Id, adm.Id);
        // Bogus ContentVersion Id — looks valid but no matching row.
        c.MSA_Static_Template_Id__c = '068000000000000AAA';
        insert c;
        insertConfigCase(c.Id, acc.Id, adm.Id);
        addSignatory(c.Id, acc.Id);
        if (!addMerchantPricing(c.Id)) return;
        insertDocuSignSetting();

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r,
            'Missing ContentVersion must hard-fail without calling DocuSign');
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
        insertDocuSignSetting();

        Test.setMock(HttpCalloutMock.class, new DocuSignErrorMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r,
            'DocuSign 5xx must be caught and converted to a Failed status');

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id=:c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'DocuSign failure must flip MSA_Status__c to Failed');
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
        insertDocuSignSetting();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.tryAdvance(c.Id);
        Test.stopTest();
        System.assertEquals(true, r);

        Compliance__c after = [
            SELECT MSA_Status__c, DocuSign_Envelope_Id__c, MSA_Started_At__c, MSA_Effective_Date__c
            FROM Compliance__c WHERE Id=:c.Id
        ];
        System.assertEquals('sent', after.MSA_Status__c,
            'Happy path must flip MSA_Status__c to sent');
        System.assertEquals('a1b2c3d4-0000-1111-2222-deadbeefcafe',
            after.DocuSign_Envelope_Id__c,
            'envelopeId from DocuSign response must be persisted');
        System.assertNotEquals(null, after.MSA_Started_At__c);
        System.assertNotEquals(null, after.MSA_Effective_Date__c);
    }

    @IsTest
    static void failWithLog_does_not_log_twice_on_rerun() {
        // No signatory + no template → tryAdvance hits failWithLog on every
        // invocation. Calling tryAdvance twice must produce only one
        // Execution_Log__c row because failWithLog's dedup guard fires once
        // status is already 'Failed'.
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
        insertDocuSignSetting();

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        d.tryAdvance(c.Id);
        d.tryAdvance(c.Id);
        Test.stopTest();

        Integer logged = [
            SELECT COUNT() FROM Execution_Log__c
            WHERE Related_Record_Id__c = :String.valueOf(c.Id)
              AND Type__c = 'Error'
        ];
        System.assert(logged <= 1,
            'Dedup branch must keep error-log row count at 0 or 1, got ' + logged);
    }

    // ══════════════════════════════════════════════════════════════════════
    // Coverage boost — direct @TestVisible method calls.
    // These exercise paths that can't always be reached via tryAdvance()
    // because org validation rules block Merchant_Bank__c inserts in test
    // context.
    // ══════════════════════════════════════════════════════════════════════

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
        // Org default is set; merchant override must win.
        insertDocuSignSetting();

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals('TPL-MERCHANT', tplId,
            'Merchant template id must take precedence');
    }

    @IsTest
    static void cov_resolveMsaTemplateId_falls_back_to_org_default() {
        Account acc = new Account(Name='RMT-O'); insert acc;
        Compliance__c c = new Compliance__c(Name='RMT-O', Account__c=acc.Id);
        insert c;
        insertDocuSignSetting();

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals('TPL-ORG-DEFAULT', tplId,
            'Org default from Conga_Setting__c.MSA_Template_Id__c must be used');
    }

    @IsTest
    static void cov_resolveMsaTemplateId_returns_null_when_nothing_configured() {
        Account acc = new Account(Name='RMT-N'); insert acc;
        Compliance__c c = new Compliance__c(Name='RMT-N', Account__c=acc.Id);
        insert c;
        // No Conga_Setting__c row, no merchant/partner override.

        Compliance__c loaded = [
            SELECT MSA_Static_Template_Id__c, From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveMsaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals(null, tplId,
            'Nothing configured → null so caller can fail with a clear message');
    }

    @IsTest
    static void cov_loadStaticMsaTemplate_returns_blob_when_present() {
        Id cvId = insertStaticTemplate('LoadCov');

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Blob pdf = d.loadStaticMsaTemplate(cvId);
        Test.stopTest();
        System.assertNotEquals(null, pdf, 'PDF blob must load');
        System.assert(pdf.size() > 0, 'PDF blob must not be empty');
    }

    @IsTest
    static void cov_loadStaticMsaTemplate_returns_null_when_missing() {
        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Blob pdf = d.loadStaticMsaTemplate('068000000000000AAA');
        Test.stopTest();
        System.assertEquals(null, pdf,
            'Missing ContentVersion must return null so caller fails clearly');
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
        System.assertEquals(adm.Id, r,
            'Flagged c-Panel admin Contact must be returned');
    }
}
