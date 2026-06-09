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

    // ── Input validation ─────────────────────────────────────────────────

    @IsTest
    static void send_throws_when_compliance_null() {
        Boolean caught = false;
        try {
            MsaDocuSignService.sendMsaEnvelope(null, Blob.valueOf('PDF'), UserInfo.getUserId());
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
            MsaDocuSignService.sendMsaEnvelope(c, null, ct.Id);
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
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf(''), ct.Id);
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
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), null);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
        }
        System.assert(caught, 'null r1 must throw');
    }

    // ── Recipient resolution ─────────────────────────────────────────────

    @IsTest
    static void resolveRecipients_returns_r1_signer() {
        Account acc = new Account(Name='AccResolve'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1resolve@x.invalid');
        Compliance__c c = minimalCompliance(acc, 'Resolve');

        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1.Id);

        System.assert(!rs.isEmpty(), 'Should return at least R1');
        System.assertEquals('Signer', rs[0].type, 'R1 must be Signer');
        System.assertEquals('r1resolve@x.invalid', rs[0].email);
        System.assertEquals(1, rs[0].recipientId, 'R1 recipientId must be 1');
        System.assertEquals(1, rs[0].routingOrder, 'R1 routingOrder must be 1');
    }

    @IsTest
    static void resolveRecipients_throws_when_r1_email_blank() {
        Account acc = new Account(Name='AccBlankEmail'); insert acc;
        // Contact with no email
        Contact r1 = new Contact(FirstName='R', LastName='One', AccountId=acc.Id);
        insert r1;
        Compliance__c c = minimalCompliance(acc, 'BlankEmail');

        Boolean caught = false;
        try {
            MsaDocuSignService.resolveRecipients(c, r1.Id);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().toLowerCase().contains('email'),
                'Exception message must mention email');
        }
        System.assert(caught, 'blank R1 email must throw');
    }

    @IsTest
    static void resolveRecipients_with_underwriter() {
        // Find any other active user to act as the underwriter; skip if org has
        // only the running user (rare but possible in scratch orgs).
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

        List<MsaDocuSignService.EnvelopeRecipient> rs =
            MsaDocuSignService.resolveRecipients(c, r1.Id);
        System.assert(rs.size() >= 2,
            'Should resolve R1 + underwriter (and possibly owner CC)');
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
            c, Blob.valueOf('PDF-CONTENT'), r1.Id
        );
        Test.stopTest();

        System.assertEquals('a1b2c3d4-0000-1111-2222-deadbeefcafe', envId,
            'envelope id from response body must be returned');
    }

    @IsTest
    static void send_throws_when_account_id_missing() {
        Account acc = new Account(Name='AccNoAcctId'); insert acc;
        Contact r1 = contactWithEmail(acc.Id, 'r1noacct@x.invalid');
        // No Conga_Setting__c row on purpose
        Compliance__c c = minimalCompliance(acc, 'NoAcctId');

        Test.setMock(HttpCalloutMock.class, new DocuSignSuccessMock());
        Boolean caught = false;
        Test.startTest();
        try {
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id);
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
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id);
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
            MsaDocuSignService.sendMsaEnvelope(c, Blob.valueOf('PDF'), r1.Id);
        } catch (MsaDocuSignService.DocuSignSendException e) {
            caught = true;
            System.assert(e.getMessage().toLowerCase().contains('envelopeid'),
                'Exception must mention missing envelopeId');
        }
        Test.stopTest();
        System.assert(caught, 'Response missing envelopeId must throw');
    }
}
