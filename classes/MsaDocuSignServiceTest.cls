@IsTest
private class MsaDocuSignServiceTest {

    // ── Callout mocks ────────────────────────────────────────────────────

    private class DocuSignSuccessMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"envelopeId":"a1b2c3d4-0000-1111-2222-deadbeefcafe","status":"sent"}');
            return res;
        }
    }

    private class DocuSignFailureMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(400);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"errorCode":"INVALID_REQUEST"}');
            return res;
        }
    }

    private class DocuSignMissingEnvelopeIdMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(201);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"status":"sent"}');
            return res;
        }
    }

    // ── Setup helpers ────────────────────────────────────────────────────

    private static Compliance__c minimalCompliance(Account acc, String name) {
        Compliance__c c = new Compliance__c(Name = name, Account__c = acc.Id);
        insert c;
        return c;
    }

    private static Contact contactWithEmail(Id accId, String email) {
        Contact c = new Contact(
            FirstName = 'R', LastName = 'One',
            Email = email, AccountId = accId
        );
        insert c;
        return c;
    }

    private static Contact loadContact(Id contactId) {
        return [
            SELECT Id, FirstName, LastName, Email, Title, Phone
            FROM Contact WHERE Id = :contactId LIMIT 1
        ];
    }

    // ── Input validation ─────────────────────────────────────────────────

    @IsTest
    static void send_throws_when_compliance_null() {
        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(null, Blob.valueOf('PDF'), UserInfo.getUserId(), null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
        }
        System.assert(caught, 'null compliance must throw DocuSignSendException');
    }

    @IsTest
    static void send_throws_when_pdf_null() {
        Account acc = new Account(Name='AccNullPdf'); insert acc;
        Compliance__c c = minimalCompliance(acc, 'NullPdf');
        Contact ct = contactWithEmail(acc.Id, 'r1null@x.invalid');
        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(c, null, ct.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
        }
        System.assert(caught, 'null pdf must throw');
    }

    @IsTest
    static void send_throws_when_pdf_empty() {
        Account acc = new Account(Name='AccEmptyPdf'); insert acc;
        Compliance__c c = minimalCompliance(acc, 'EmptyPdf');
        Contact ct = contactWithEmail(acc.Id, 'r1empty@x.invalid');
        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf(''), ct.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
        }
        System.assert(caught, 'empty pdf must throw');
    }

    @IsTest
    static void send_throws_when_r1_null() {
        Account acc = new Account(Name='AccNullR1'); insert acc;
        Compliance__c c = minimalCompliance(acc, 'NullR1');
        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), null, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
        }
        System.assert(caught, 'null r1 must throw');
    }

    @IsTest
    static void send_throws_when_r1_email_blank() {
        Account acc = new Account(Name='AccBlankEmail'); insert acc;
        Contact r1 = new Contact(FirstName='R', LastName='One', AccountId=acc.Id);
        insert r1;
        Compliance__c c = minimalCompliance(acc, 'BlankEmail');

        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().toLowerCase().contains('email'),
                'Exception message must mention email');
        }
        System.assert(caught, 'blank R1 email must throw');
    }

    // ── Recipient resolution ─────────────────────────────────────────────

    @IsTest
    static void resolveRecipients_returns_r1_signer() {
        Account acc = new Account(Name='AccResolve'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1resolve@x.invalid');
        Compliance__c c = minimalCompliance(acc, 'Resolve');

        Contact r1Loaded = loadContact(r1.Id);

        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1Loaded);

        System.assert(!rs.isEmpty(), 'Should return at least R1');
        System.assertEquals('Signer', rs[0].type, 'R1 must be Signer');
        System.assertEquals('r1resolve@x.invalid', rs[0].email);
        System.assertEquals(1, rs[0].recipientId, 'R1 recipientId must be 1');
        System.assertEquals(1, rs[0].routingOrder, 'R1 routingOrder must be 1');
    }

    @IsTest
    static void resolveRecipients_with_underwriter() {
        List<User> others = [
            SELECT Id, Email FROM User
            WHERE IsActive = true AND Id != :UserInfo.getUserId()
              AND Email != null LIMIT 1
        ];
        if (others.isEmpty()) {
            return;
        }
        Account acc = new Account(Name='AccUw'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1uw@x.invalid');
        Compliance__c c = new Compliance__c(
            Name = 'Uw',
            Account__c = acc.Id,
            Underwriting_Mgr__c = others[0].Id
        );
        insert c;

        Contact r1Loaded = loadContact(r1.Id);

        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1Loaded);
        System.assert(rs.size() >= 2,
            'Should resolve R1 + underwriter (and possibly owner CC)');

        Boolean foundUnderwriter = false;
        for (MsaDocuSignService.EnvelopeRecipient r : rs) {
            if (r.recipientId == 3 && r.type == 'Signer') {
                foundUnderwriter = true;
                break;
            }
        }
        System.assert(foundUnderwriter,
            'Underwriter must occupy recipientId=3');
    }

    @IsTest
    static void resolveRecipients_dedups_when_r1_and_owner_share_email() {
        String myEmail = [SELECT Email FROM User WHERE Id = :UserInfo.getUserId()].Email;
        if (String.isBlank(myEmail)) return;

        Account acc = new Account(Name='AccDedup'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, myEmail.toLowerCase());
        Compliance__c c = minimalCompliance(acc, 'Dedup');

        Contact r1Loaded = loadContact(r1.Id);
        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1Loaded);

        for (MsaDocuSignService.EnvelopeRecipient r : rs) {
            if (r.recipientId == 4) {
                System.assert(false,
                    'Owner CC slot must be empty when owner shares R1 email');
            }
        }
    }

    // ── Merge data resolution ────────────────────────────────────────────

    @IsTest
    static void resolveMergeData_returns_company_fields() {
        Account acc = new Account(Name='AccMerge'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'merge@x.invalid');

        Compliance__c c = new Compliance__c(
            Name = 'MergeCo',
            Account__c = acc.Id,
            Registered_Address_New__c = '1 St, London',
            Registered_Country__c = 'United Kingdom',
            Incorporation_number__c = 'INC-12345'
        );
        insert c;

        Compliance__c loaded = [
            SELECT Id, Name, Registered_Address_New__c, Registered_Country__c,
                   Incorporation_number__c, OwnerId, Underwriting_Mgr__c,
                   From_Reseller__r.Name
            FROM Compliance__c WHERE Id = :c.Id
        ];
        Contact r1Loaded = loadContact(r1.Id);

        MsaDocuSignService.MsaMergeData d =
            MsaDocuSignService.resolveMergeData(loaded, r1Loaded, null);

        System.assertEquals('MergeCo', d.companyName);
        System.assertEquals('1 St, London', d.registeredAddress);
        System.assertEquals('United Kingdom', d.registeredCountry);
        System.assertEquals('INC-12345', d.incorporationNumber);
        System.assertEquals('R One', d.signerName,
            'Signer name must be built from R1 first + last');
    }

    @IsTest
    static void resolveMergeData_loads_cpanel_admin_fields_when_id_provided() {
        Account acc = new Account(Name='AccCPanel'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1cp@x.invalid');
        Contact cpanel = new Contact(
            FirstName = 'CPanel', LastName = 'Admin',
            Title = 'Operations Manager', Email = 'cp@x.invalid',
            Phone = '+44777', AccountId = acc.Id,
            Is_CPanel_Admin__c = true
        );
        insert cpanel;
        Compliance__c c = minimalCompliance(acc, 'CPanelTest');

        Compliance__c loaded = [
            SELECT Id, Name, Registered_Address_New__c, Registered_Country__c,
                   Incorporation_number__c, OwnerId, Underwriting_Mgr__c,
                   From_Reseller__r.Name
            FROM Compliance__c WHERE Id = :c.Id
        ];
        Contact r1Loaded = loadContact(r1.Id);

        MsaDocuSignService.MsaMergeData d =
            MsaDocuSignService.resolveMergeData(loaded, r1Loaded, cpanel.Id);

        System.assertEquals('CPanel', d.cPanelFirstName);
        System.assertEquals('Admin', d.cPanelLastName);
        System.assertEquals('Operations Manager', d.cPanelTitle);
        System.assertEquals('cp@x.invalid', d.cPanelEmail);
        System.assertEquals('+44777', d.cPanelPhone);
    }

    @IsTest
    static void resolveMergeData_leaves_cpanel_blank_when_id_null() {
        Account acc = new Account(Name='AccNoCp'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1nocp@x.invalid');
        Compliance__c c = minimalCompliance(acc, 'NoCp');

        Compliance__c loaded = [
            SELECT Id, Name, Registered_Address_New__c, Registered_Country__c,
                   Incorporation_number__c, OwnerId, Underwriting_Mgr__c,
                   From_Reseller__r.Name
            FROM Compliance__c WHERE Id = :c.Id
        ];
        Contact r1Loaded = loadContact(r1.Id);

        MsaDocuSignService.MsaMergeData d =
            MsaDocuSignService.resolveMergeData(loaded, r1Loaded, null);

        System.assertEquals(null, d.cPanelFirstName);
        System.assertEquals(null, d.cPanelLastName);
        System.assertEquals(null, d.cPanelEmail);
    }

    // ── Envelope JSON build ──────────────────────────────────────────────

    @IsTest
    static void buildEnvelopeJson_emits_signer_with_anchor_tabs() {
        Account acc = new Account(Name='AccJson'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'json@x.invalid');
        Compliance__c c = minimalCompliance(acc, 'Json');

        Contact r1Loaded = loadContact(r1.Id);
        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1Loaded);

        MsaDocuSignService.MsaMergeData mergeData = new MsaDocuSignService.MsaMergeData();
        mergeData.companyName = 'JsonCo';
        mergeData.signerName = 'R One';
        mergeData.signerTitle = 'CEO';

        String body = MsaDocuSignService.buildEnvelopeJson(
            'MSA for JsonCo', Blob.valueOf('PDF-CONTENT'), rs, mergeData
        );

        System.assert(body.contains('"emailSubject":"MSA for JsonCo"'));
        System.assert(body.contains('"status":"sent"'));
        System.assert(body.contains('signHereTabs'));
        System.assert(body.contains('dateSignedTabs'));
        System.assert(body.contains('textTabs'));
        System.assert(body.contains('"locked":true'));
        System.assert(body.contains('{{COMPLIANCE_NAME}}'));
        System.assert(body.contains('JsonCo'));
    }

    // ── Full send happy + error paths ────────────────────────────────────

    @IsTest
    static void send_happy_path_returns_envelopeId() {
        Account acc = new Account(Name='AccHappy'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'happyr1@x.invalid');
        insert new Conga_Setting__c(
            Name = 'Default',
            DocuSign_Account_Id__c = 'test-acct-id'
        );
        Compliance__c c = minimalCompliance(acc, 'Happy');

        Test.setMock(HttpCalloutMock.class, new DocuSignSuccessMock());
        Test.startTest();
        String envId = MsaDocuSignService.sendMsaEnvelope(
            c, Blob.valueOf('PDF-CONTENT'), r1.Id, null
        );
        Test.stopTest();

        System.assertEquals('a1b2c3d4-0000-1111-2222-deadbeefcafe', envId);
    }

    @IsTest
    static void send_happy_path_with_cpanel_admin_id() {
        Account acc = new Account(Name='AccHappyCp'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'happycp@x.invalid');
        Contact cpanel = new Contact(
            FirstName='CP', LastName='Admin', Email='cph@x.invalid',
            AccountId=acc.Id, Is_CPanel_Admin__c=true
        );
        insert cpanel;
        insert new Conga_Setting__c(
            Name = 'Default',
            DocuSign_Account_Id__c = 'test-acct-id'
        );
        Compliance__c c = minimalCompliance(acc, 'HappyCp');

        Test.setMock(HttpCalloutMock.class, new DocuSignSuccessMock());
        Test.startTest();
        String envId = MsaDocuSignService.sendMsaEnvelope(
            c, Blob.valueOf('PDF-CONTENT'), r1.Id, cpanel.Id
        );
        Test.stopTest();

        System.assertEquals('a1b2c3d4-0000-1111-2222-deadbeefcafe', envId);
    }

    @IsTest
    static void send_throws_when_account_id_missing() {
        Account acc = new Account(Name='AccNoAcctId'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1noacct@x.invalid');
        Compliance__c c = minimalCompliance(acc, 'NoAcctId');

        Test.setMock(HttpCalloutMock.class, new DocuSignSuccessMock());
        Boolean caught = false;
        Test.startTest();
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().toLowerCase().contains('account'),
                'Exception must mention missing account id');
        }
        Test.stopTest();
        System.assert(caught, 'missing DocuSign_Account_Id__c must throw');
    }

    @IsTest
    static void send_throws_on_http_failure() {
        Account acc = new Account(Name='AccHttpFail'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1fail@x.invalid');
        insert new Conga_Setting__c(Name='Default', DocuSign_Account_Id__c='test-acct');
        Compliance__c c = minimalCompliance(acc, 'HttpFail');

        Test.setMock(HttpCalloutMock.class, new DocuSignFailureMock());
        Boolean caught = false;
        Test.startTest();
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().contains('400'),
                'Exception must include the HTTP status');
        }
        Test.stopTest();
        System.assert(caught, 'HTTP non-2xx must throw');
    }

    @IsTest
    static void send_throws_when_response_has_no_envelopeId() {
        Account acc = new Account(Name='AccNoEnvId'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1noenvid@x.invalid');
        insert new Conga_Setting__c(Name='Default', DocuSign_Account_Id__c='test-acct');
        Compliance__c c = minimalCompliance(acc, 'NoEnvId');

        Test.setMock(HttpCalloutMock.class, new DocuSignMissingEnvelopeIdMock());
        Boolean caught = false;
        Test.startTest();
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id, null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().toLowerCase().contains('envelopeid'),
                'Exception must mention missing envelopeId');
        }
        Test.stopTest();
        System.assert(caught, 'Response missing envelopeId must throw');
    }
}
