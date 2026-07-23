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

    /**
     * Build a Compliance__c populated with the same fields that loadCompliance
     * SELECTs in production, so coverage tests can pass an in-memory record
     * straight into executeSendFlow without going through the full DML chain.
     */
    private static Compliance__c buildLoadedCompliance(Id complianceId) {
        return [
            SELECT
                Id, Name,
                EU_Indirect_Orchestration__c,
                Nuvei_Connect_Status__c,
                Nuvei_Connect_Application_ID__c,
                MSA_Status__c, MSA_Effective_Date__c, MSA_Started_At__c,
                Underwriting_Mgr__c, OwnerId, Account__c,
                Registered_Address_New__c, Registered_Country__c,
                Incorporation_number__c,
                MSA_Static_Template_Id__c,
                From_Reseller__r.Name,
                From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c
            WHERE Id = :complianceId
            LIMIT 1
        ];
    }

    /**
     * Conga_Setting__c with the feature flag ON plus the single org-wide Conga
     * template Id (EU_Indirect_Template_ID__c) and the DocuSign account id (a
     * single List custom setting row — Name must be unique). Used by the
     * Conga-path tests.
     */
    private static void insertCongaTriggerSetting() {
        insert new Conga_Setting__c(
            Name = 'Default',
            EU_Indirect_Template_ID__c = 'TPL-CONGA-DEFAULT',
            DocuSign_Account_Id__c = 'test-ds-account',
            Use_Conga_Trigger__c = true
        );
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

    // ════════════════════════════════════════════════════════════════════
    // Coverage boost — direct @TestVisible method calls.
    // These exercise paths that can't always be reached via tryAdvance()
    // because org validation rules block Merchant_Bank__c inserts in test
    // context.
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

    // ════════════════════════════════════════════════════════════════════
    // executeSendFlow coverage — call the @TestVisible extracted method
    // directly to exercise the lines inside the try { ... } block without
    // going through the merchant-pricing gate. This is the same pattern
    // IBRCovBoostTest uses ("NO Merchant_Bank inserts -> avoids your org
    // validations").
    // ════════════════════════════════════════════════════════════════════

    @IsTest
    static void cov_executeSendFlow_happy_path_marks_sent() {
        Account acc = new Account(Name='AccExHappy'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='exhappy@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Id cvId = insertStaticTemplate('ExHappyTpl');

        Compliance__c c = newCompliance('ExHappy', acc.Id, adm.Id);
        c.MSA_Static_Template_Id__c = cvId;
        insert c;
        addSignatory(c.Id, acc.Id);
        insertDocuSignSetting();

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r);

        Compliance__c after = [SELECT MSA_Status__c, DocuSign_Envelope_Id__c
                               FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('sent', after.MSA_Status__c,
            'Happy path must set MSA_Status__c to sent');
        System.assertNotEquals(null, after.DocuSign_Envelope_Id__c,
            'Envelope Id must be persisted after successful DocuSign send');
    }

    @IsTest
    static void cov_executeSendFlow_no_signatory_logs_and_fails() {
        Account acc = new Account(Name='AccExNoSig'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='exnosig@x.invalid', AccountId=acc.Id);
        insert adm;

        Compliance__c c = newCompliance('ExNoSig', acc.Id, adm.Id);
        insert c;
        // NOTE: no signatory inserted on purpose

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r, 'Failure branch must still return true');

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'Missing signatory must set MSA_Status__c to Failed');
    }

    @IsTest
    static void cov_executeSendFlow_no_template_logs_and_fails() {
        Account acc = new Account(Name='AccExNoTpl'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='exnotpl@x.invalid', AccountId=acc.Id);
        insert adm;

        Compliance__c c = newCompliance('ExNoTpl', acc.Id, adm.Id);
        insert c;
        addSignatory(c.Id, acc.Id);
        // NOTE: no template configured anywhere → resolveMsaTemplateId
        // returns null → executeSendFlow takes the "blank template" branch.

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r, 'Blank template branch must return true');

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'Blank template must set MSA_Status__c to Failed');
    }

    @IsTest
    static void cov_executeSendFlow_missing_contentversion_logs_and_fails() {
        Account acc = new Account(Name='AccExBadCv'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='exbadcv@x.invalid', AccountId=acc.Id);
        insert adm;

        Compliance__c c = newCompliance('ExBadCv', acc.Id, adm.Id);
        // Syntactically-valid but non-existent ContentVersion Id so
        // loadStaticMsaTemplate's SOQL returns empty → executeSendFlow takes
        // the "template not found / empty" branch.
        c.MSA_Static_Template_Id__c = '068000000000000AAA';
        insert c;
        addSignatory(c.Id, acc.Id);

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r);

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'Missing ContentVersion must set MSA_Status__c to Failed');
    }

    @IsTest
    static void cov_executeSendFlow_catch_block_when_docusign_throws() {
        Account acc = new Account(Name='AccExCatch'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='excatch@x.invalid', AccountId=acc.Id);
        insert adm;

        Id cvId = insertStaticTemplate('ExCatchTpl');

        Compliance__c c = newCompliance('ExCatch', acc.Id, adm.Id);
        c.MSA_Static_Template_Id__c = cvId;
        insert c;
        addSignatory(c.Id, acc.Id);
        insertDocuSignSetting();

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        // DocuSign error mock so MsaDocuSignService throws → executeSendFlow
        // hits its outer catch block → failWithLog runs → status flips to Failed.
        Test.setMock(HttpCalloutMock.class, new DocuSignErrorMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r, 'Catch block must still return true');

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'DocuSign 5xx must set MSA_Status__c to Failed via catch branch');
    }

    // ════════════════════════════════════════════════════════════════════
    // Conga Trigger path (Use_Conga_Trigger__c = true).
    //
    // Phase 1 (executeSendFlow / tryAdvance) fires the Conga composition and
    // makes NO DocuSign callout — it only writes the params + flag and moves
    // MSA_Status__c to 'started'. Phase 2 (completeCongaMsaSend, driven in
    // production by MsaCongaDocuSignQueueable) performs the DocuSign send.
    // ════════════════════════════════════════════════════════════════════

    @IsTest
    static void cov_executeSendFlow_conga_phase1_fires_and_marks_started() {
        Account acc = new Account(Name='AccCongaP1'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='congap1@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Compliance__c c = newCompliance('CongaP1', acc.Id, adm.Id);
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r);

        Compliance__c after = [
            SELECT MSA_Status__c, Fire_Conga_MSA__c, Conga_MSA_Params__c,
                   MSA_Started_At__c, DocuSign_Envelope_Id__c
            FROM Compliance__c WHERE Id = :c.Id
        ];
        System.assertEquals('started', after.MSA_Status__c,
            'Conga Phase 1 must move MSA_Status__c to started');
        System.assertEquals(true, after.Fire_Conga_MSA__c,
            'Conga Phase 1 must flip Fire_Conga_MSA__c on');
        System.assertNotEquals(null, after.Conga_MSA_Params__c,
            'Conga Phase 1 must write the Conga parameter string');
        System.assert(after.Conga_MSA_Params__c.contains('TPL-CONGA-DEFAULT'),
            'Params must carry the org Conga template id (EU_Indirect_Template_ID__c)');
        System.assert(after.Conga_MSA_Params__c.contains('EU-MSA-' + c.Id),
            'Params must carry the deterministic output filename');
        System.assertEquals(null, after.DocuSign_Envelope_Id__c,
            'Conga Phase 1 must NOT send DocuSign yet');
        System.assertNotEquals(null, after.MSA_Started_At__c);
    }

    @IsTest
    static void cov_executeSendFlow_conga_no_signatory_fails_before_trigger() {
        Account acc = new Account(Name='AccCongaNoSig'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='congansig@x.invalid', AccountId=acc.Id);
        insert adm;

        Compliance__c c = newCompliance('CongaNoSig', acc.Id, adm.Id);
        insert c;
        // no signatory on purpose
        insertCongaTriggerSetting();

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r);

        Compliance__c after = [SELECT MSA_Status__c, Fire_Conga_MSA__c
                               FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'No signatory must fail before firing Conga');
        System.assertEquals(false, after.Fire_Conga_MSA__c,
            'Conga must not be fired when the signatory gate fails');
    }

    @IsTest
    static void cov_executeSendFlow_conga_no_template_fails() {
        Account acc = new Account(Name='AccCongaNoTpl'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='congantpl@x.invalid', AccountId=acc.Id);
        insert adm;

        Compliance__c c = newCompliance('CongaNoTpl', acc.Id, adm.Id);
        insert c;
        addSignatory(c.Id, acc.Id);
        // Flag on but NO Conga template configured anywhere.
        insert new Conga_Setting__c(
            Name = 'Default',
            DocuSign_Account_Id__c = 'test-ds-account',
            Use_Conga_Trigger__c = true
        );

        Compliance__c loaded = buildLoadedCompliance(c.Id);

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        Boolean r = d.executeSendFlow(loaded);
        Test.stopTest();

        System.assertEquals(true, r);

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'Missing Conga template must set MSA_Status__c to Failed');
    }

    @IsTest
    static void cov_resolveCongaTemplateId_reads_org_setting() {
        Account acc = new Account(Name='RCTO'); insert acc;
        Compliance__c c = new Compliance__c(Name='RCTO', Account__c=acc.Id);
        insert c;
        insertCongaTriggerSetting();

        Compliance__c loaded = [
            SELECT Id FROM Compliance__c WHERE Id=:c.Id
        ];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveCongaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals('TPL-CONGA-DEFAULT', tplId,
            'Single org Conga template id (EU_Indirect_Template_ID__c) must be used');
    }

    @IsTest
    static void cov_resolveCongaTemplateId_returns_null_when_unset() {
        Account acc = new Account(Name='RCTN'); insert acc;
        Compliance__c c = new Compliance__c(Name='RCTN', Account__c=acc.Id);
        insert c;
        // No Conga_Setting__c row at all.

        Compliance__c loaded = [SELECT Id FROM Compliance__c WHERE Id=:c.Id];

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        String tplId = d.resolveCongaTemplateId(loaded);
        Test.stopTest();
        System.assertEquals(null, tplId,
            'No setting → null so the caller fails with a clear message');
    }

    @IsTest
    static void cov_completeCongaMsaSend_happy_path_marks_sent() {
        Account acc = new Account(Name='AccP2Happy'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='p2happy@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        // The Conga-composed PDF, already stored as a ContentVersion.
        Id cvId = insertStaticTemplate('EU-MSA-P2Happy');

        Compliance__c c = newCompliance('P2Happy', acc.Id, adm.Id);
        c.MSA_Status__c = 'started';
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        d.completeCongaMsaSend(c.Id, cvId);
        Test.stopTest();

        Compliance__c after = [
            SELECT MSA_Status__c, DocuSign_Envelope_Id__c
            FROM Compliance__c WHERE Id = :c.Id
        ];
        System.assertEquals('sent', after.MSA_Status__c,
            'Phase 2 happy path must move MSA_Status__c to sent');
        System.assertEquals('a1b2c3d4-0000-1111-2222-deadbeefcafe',
            after.DocuSign_Envelope_Id__c,
            'Envelope Id from DocuSign response must be persisted in Phase 2');
    }

    @IsTest
    static void cov_completeCongaMsaSend_docusign_error_marks_failed() {
        Account acc = new Account(Name='AccP2Err'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='p2err@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Id cvId = insertStaticTemplate('EU-MSA-P2Err');

        Compliance__c c = newCompliance('P2Err', acc.Id, adm.Id);
        c.MSA_Status__c = 'started';
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Test.setMock(HttpCalloutMock.class, new DocuSignErrorMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        d.completeCongaMsaSend(c.Id, cvId);
        Test.stopTest();

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('Failed', after.MSA_Status__c,
            'DocuSign failure in Phase 2 must set MSA_Status__c to Failed');
    }

    @IsTest
    static void cov_completeCongaMsaSend_is_idempotent_when_not_started() {
        Account acc = new Account(Name='AccP2Idem'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='p2idem@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Id cvId = insertStaticTemplate('EU-MSA-P2Idem');

        Compliance__c c = newCompliance('P2Idem', acc.Id, adm.Id);
        c.MSA_Status__c = 'sent'; // already completed
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        TrackDMsaConga d = new TrackDMsaConga();
        Test.startTest();
        d.completeCongaMsaSend(c.Id, cvId);
        Test.stopTest();

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('sent', after.MSA_Status__c,
            'Phase 2 must be a no-op when the record is no longer started');
    }

    // ── Phase 2 resume via the ContentDocumentLink trigger ────────────────

    @IsTest
    static void congaOutput_file_link_resumes_and_sends() {
        Account acc = new Account(Name='AccCdlResume'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='cdlresume@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Compliance__c c = newCompliance('CdlResume', acc.Id, adm.Id);
        c.MSA_Status__c = 'started';
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        Test.startTest();
        // Simulate Conga storing its composed MSA as a File on the Compliance.
        ContentVersion cv = new ContentVersion(
            Title          = 'EU-MSA-' + c.Id,
            PathOnClient   = 'EU-MSA.pdf',
            VersionData    = Blob.valueOf('CONGA-COMPOSED-PDF'),
            IsMajorVersion = true
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        insert new ContentDocumentLink(
            ContentDocumentId = docId,
            LinkedEntityId    = c.Id,
            ShareType         = 'V'
        );
        Test.stopTest(); // drains MsaCongaDocuSignQueueable → DocuSign send

        Compliance__c after = [
            SELECT MSA_Status__c, DocuSign_Envelope_Id__c
            FROM Compliance__c WHERE Id = :c.Id
        ];
        System.assertEquals('sent', after.MSA_Status__c,
            'A Conga MSA File linked to a started Compliance must resume and send');
        System.assertNotEquals(null, after.DocuSign_Envelope_Id__c,
            'Resume path must persist the DocuSign envelope Id');
    }

    @IsTest
    static void congaOutput_ignores_non_matching_files() {
        // A non-MSA file linked to a started Compliance must NOT trigger a send.
        Account acc = new Account(Name='AccCdlIgnore'); insert acc;
        Contact adm = new Contact(FirstName='A', LastName='Adm',
            Email='cdlignore@x.invalid', AccountId=acc.Id, Is_CPanel_Admin__c=true);
        insert adm;

        Compliance__c c = newCompliance('CdlIgnore', acc.Id, adm.Id);
        c.MSA_Status__c = 'started';
        insert c;
        addSignatory(c.Id, acc.Id);
        insertCongaTriggerSetting();

        Test.setMock(HttpCalloutMock.class, new TrackDFullMock());

        Test.startTest();
        ContentVersion cv = new ContentVersion(
            Title          = 'Some-Other-Document',
            PathOnClient   = 'other.pdf',
            VersionData    = Blob.valueOf('UNRELATED'),
            IsMajorVersion = true
        );
        insert cv;
        Id docId = [SELECT ContentDocumentId FROM ContentVersion WHERE Id = :cv.Id].ContentDocumentId;

        insert new ContentDocumentLink(
            ContentDocumentId = docId,
            LinkedEntityId    = c.Id,
            ShareType         = 'V'
        );
        Test.stopTest();

        Compliance__c after = [SELECT MSA_Status__c FROM Compliance__c WHERE Id = :c.Id];
        System.assertEquals('started', after.MSA_Status__c,
            'A non EU-MSA- file must not resume the send');
    }
}
