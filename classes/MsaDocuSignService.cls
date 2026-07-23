/**
 * MsaDocuSignService — server-side DocuSign envelope send for Track D (EU indirect MSA).
 *
 * This is the single seam for the DocuSign dependency, isolated on purpose so
 * the rest of the orchestration never references it directly.
 *
 * Send mechanism: DocuSign eSignature REST API via the 'DocuSign_eSign' Named
 * Credential + External Credential (JWT Bearer). The org has neither the legacy
 * dsfs.DocuSignAPI toolkit nor the dfsle Apex Toolkit, so we call the REST API
 * directly. The EC injects the OAuth bearer automatically; the static MSA PDF is
 * sent inline as base64, so there is no ContentVersion DML before the callout.
 *
 * Static PDF + prefill tabs:
 *   The PDF is a pre-styled artifact (pricing tables baked in) loaded by Track D.
 *   Every dynamic merchant field — company details, c-panel admin, signer name
 *   and title — is rendered by DocuSign as a LOCKED, read-only prefill text tab
 *   anchored to placeholder text in the PDF. Nothing in the document is editable
 *   by the signer; only the signature and date are captured.
 *
 * Responsibilities:
 *   - Resolve the R1 / R2 / R3 recipients with dynamic routing numbering
 *     (spec §8): R1 = merchant authorized signatory (Signer), R2 = Nuvei
 *     underwriting manager (Signer / counter-sign, only if present), R3 / R2 =
 *     record owner (Carbon Copy). When the underwriter is absent the owner
 *     collapses into the R2 slot.
 *   - Build the locked prefill text tabs from Salesforce merge data.
 *   - Send the static PDF as a DocuSign envelope (status=sent).
 *   - Return the DocuSign envelope id so Track D can persist it.
 *
 * Subject contract:
 *   The envelope Subject MUST be exactly "MSA for {Compliance.Name}". The
 *   DocuSignStatusToMsa trigger parses this prefix to map the post-send
 *   dsfs__DocuSign_Status__c webhook back to the right Compliance record. Do
 *   not change the subject format without updating DocuSignStatusToMsa.
 *
 * Recipient identity (spec bug #4):
 *   R2 and R3 are Salesforce Users — we send their User.Email / name, never a
 *   User Id, as the DocuSign recipient identifier.
 *
 * Signer name immutability:
 *   The signer's name is injected as a LOCKED prefill text tab (\n1\), NOT a
 *   DocuSign auto Name tab. This survives "Change Signer" reassignment — only the
 *   signature transfers, the printed authorized-signatory name stays fixed.
 *
 * Anchor placement:
 *   R1 (merchant) signs at \s1\ / dates at \d1\; R2 (Nuvei counter-signer) at
 *   \s3\ / \d3\, matching the static template. Field anchors are the {{...}}
 *   placeholders in the PDF. All anchor constants below are the single tuning
 *   point if the template artwork changes.
 *
 * Test strategy:
 *   The REST send is a standard HTTP callout, intercepted by HttpCalloutMock in
 *   tests — recipient resolution, merge-data resolution AND envelope JSON build
 *   are covered.
 */
public with sharing class MsaDocuSignService {

    public class DocuSignSendException extends Exception {}

    // Named Credential (developer name) configured in Setup with its External
    // Credential (JWT Bearer) — the EC injects the OAuth bearer on callout.
    @TestVisible private static final String NAMED_CREDENTIAL = 'DocuSign_eSign';

    // DocuSign eSignature REST resource (account id from Conga_Setting__c).
    @TestVisible private static final String ENVELOPES_PATH = '/restapi/v2.1/accounts/{0}/envelopes';

    // signHere / dateSigned / name / title anchor prefixes — the static template
    // contains "\sN\", "\dN\", "\nN\", "\tN\" (N = recipientId).
    @TestVisible private static final String SIGN_ANCHOR_PREFIX = '\\s';
    @TestVisible private static final String DATE_ANCHOR_PREFIX = '\\d';
    @TestVisible private static final String NAME_ANCHOR_PREFIX = '\\n';
    @TestVisible private static final String TITLE_ANCHOR_PREFIX = '\\t';
    @TestVisible private static final String ANCHOR_SUFFIX = '\\';

    // Category A field anchors — placeholder text the static PDF must contain as
    // real, selectable text so DocuSign can locate each locked prefill tab.
    @TestVisible private static final String ANCHOR_COMPANY_NAME   = '{{COMPLIANCE_NAME}}';
    @TestVisible private static final String ANCHOR_REG_ADDRESS    = '{{COMPLIANCE_REGISTERED_ADDRESS_NEW}}';
    @TestVisible private static final String ANCHOR_REG_COUNTRY    = '{{COMPLIANCE_REGISTERED_COUNTRY}}';
    @TestVisible private static final String ANCHOR_INCORPORATION  = '{{COMPLIANCE_INCORPORATION_NUMBER}}';
    @TestVisible private static final String ANCHOR_PARTNER_NAME   = '{{COMPLIANCE_FROM_RESELLER_NAME}}';
    @TestVisible private static final String ANCHOR_CPANEL_FIRST   = '{{Application_Form_Administrator_First_Name}}';
    @TestVisible private static final String ANCHOR_CPANEL_LAST    = '{{Application_Form_Administrator_Last_Name}}';
    @TestVisible private static final String ANCHOR_CPANEL_TITLE   = '{{Application_Form_Administrator_Title_Position}}';
    @TestVisible private static final String ANCHOR_CPANEL_EMAIL   = '{{Application_Form_Administrator_Email_Address}}';
    @TestVisible private static final String ANCHOR_CPANEL_PHONE   = '{{Application_Form_Administrator_Phone}}';

    /**
     * Merge data for the locked prefill tabs — resolved from Compliance, the R1
     * signatory Contact and the c-Panel admin Contact. Plain DTO so the build is
     * fully unit-testable.
     */
    @TestVisible
    public class MsaMergeData {
        public String companyName;
        public String registeredAddress;
        public String registeredCountry;
        public String incorporationNumber;
        public String partnerName;
        public String signerName;
        public String signerTitle;
        public String cPanelFirstName;
        public String cPanelLastName;
        public String cPanelTitle;
        public String cPanelEmail;
        public String cPanelPhone;
    }

    /**
     * Resolved recipient — internal DTO so recipient logic is fully unit-testable
     * without constructing managed-package types.
     */
    @TestVisible
    public class EnvelopeRecipient {
        public String email;
        public String fullName;
        public String type;          // 'Signer' | 'CarbonCopy'
        public String roleName;      // 'Signer 1' | 'Signer 2' | 'CC 1'
        public Integer routingOrder;
        public Integer recipientId;

        public EnvelopeRecipient(String email, String fullName, String type, String roleName,
                          Integer routingOrder, Integer recipientId) {
            this.email = email;
            this.fullName = fullName;
            this.type = type;
            this.roleName = roleName;
            this.routingOrder = routingOrder;
            this.recipientId = recipientId;
        }
    }

    /**
     * Build + send the MSA envelope.
     *
     * @param comp            Compliance row (Name, OwnerId, Underwriting_Mgr__c +
     *                        the merge fields loaded by Track D).
     * @param pdf             Static MSA PDF loaded by Track D.
     * @param r1ContactId     Authorized signatory Contact (resolved by Track D §17).
     * @param cPanelContactId c-Panel admin Contact (Appendix B); may be null.
     * @return DocuSign envelope id.
     * @throws DocuSignSendException on any unrecoverable problem.
     */
    public static String sendMsaEnvelope(Compliance__c comp, Blob pdf, Id r1ContactId, Id cPanelContactId) {
        if (comp == null) {
            throw new DocuSignSendException('Compliance record is null');
        }
        if (pdf == null || pdf.size() == 0) {
            throw new DocuSignSendException('MSA PDF blob is empty — the static MSA template did not load');
        }
        if (r1ContactId == null) {
            throw new DocuSignSendException('No authorized signatory (R1) supplied');
        }

        // R1 Contact is loaded once and reused for both recipient + merge data.
        Contact r1 = loadSignatoryContact(r1ContactId);
        List<EnvelopeRecipient> recipients = resolveRecipients(comp, r1);
        if (recipients.isEmpty()) {
            throw new DocuSignSendException('No resolvable recipients for the MSA envelope');
        }

        MsaMergeData mergeData = resolveMergeData(comp, r1, cPanelContactId);

        String subject = 'MSA for ' + comp.Name;
        return dispatchToDocuSign(subject, pdf, recipients, mergeData);
    }

    // ─── Recipient resolution (fully unit-testable) ───────────────────────────

    private static Contact loadSignatoryContact(Id r1ContactId) {
        Contact r1 = [
            SELECT Id, FirstName, LastName, Email, Title
            FROM Contact
            WHERE Id = :r1ContactId
            LIMIT 1
        ];
        if (String.isBlank(r1.Email)) {
            throw new DocuSignSendException('Authorized signatory Contact has no email — cannot send MSA');
        }
        return r1;
    }

    @TestVisible
    private static List<EnvelopeRecipient> resolveRecipients(Compliance__c comp, Contact r1) {
        List<EnvelopeRecipient> out = new List<EnvelopeRecipient>();
        Set<String> usedEmails = new Set<String>();

        out.add(new EnvelopeRecipient(
            r1.Email, buildName(r1.FirstName, r1.LastName), 'Signer', 'Signer 1', 1, 1
        ));
        usedEmails.add(r1.Email.toLowerCase());

        // Resolve the two Users (underwriter + owner) in a single query
        Map<Id, User> usersById = new Map<Id, User>();
        Set<Id> userIds = new Set<Id>();
        if (comp.Underwriting_Mgr__c != null) {
            userIds.add(comp.Underwriting_Mgr__c);
        }
        if (comp.OwnerId != null) {
            userIds.add(comp.OwnerId);
        }
        if (!userIds.isEmpty()) {
            for (User u : [SELECT Id, Email, FirstName, LastName FROM User WHERE Id IN :userIds]) {
                usersById.put(u.Id, u);
            }
        }

        Integer routingOrder = 2;

        // R2 — Nuvei underwriting manager (counter-signer), only when present.
        // recipientId is fixed at 3 so the signature/date tabs bind to the
        // template's \s3\ / \d3\ anchors (the Nuvei block in the static PDF).
        User underwriter = comp.Underwriting_Mgr__c == null ? null : usersById.get(comp.Underwriting_Mgr__c);
        if (underwriter != null && String.isNotBlank(underwriter.Email)
            && !usedEmails.contains(underwriter.Email.toLowerCase())) {
            out.add(new EnvelopeRecipient(
                underwriter.Email, buildName(underwriter.FirstName, underwriter.LastName),
                'Signer', 'Signer 2', routingOrder, 3
            ));
            usedEmails.add(underwriter.Email.toLowerCase());
            routingOrder++;
        }

        // Record owner as Carbon Copy (no tabs). recipientId 4 keeps it distinct
        // from the two signer slots regardless of whether the underwriter exists.
        User owner = comp.OwnerId == null ? null : usersById.get(comp.OwnerId);
        if (owner != null && String.isNotBlank(owner.Email)
            && !usedEmails.contains(owner.Email.toLowerCase())) {
            out.add(new EnvelopeRecipient(
                owner.Email, buildName(owner.FirstName, owner.LastName),
                'CarbonCopy', 'CC 1', routingOrder, 4
            ));
            usedEmails.add(owner.Email.toLowerCase());
        }

        return out;
    }

    // ─── Merge data resolution (fully unit-testable) ──────────────────────────

    @TestVisible
    private static MsaMergeData resolveMergeData(Compliance__c comp, Contact r1, Id cPanelContactId) {
        MsaMergeData d = new MsaMergeData();
        d.companyName = comp.Name;
        d.registeredAddress = comp.Registered_Address_New__c;
        d.registeredCountry = comp.Registered_Country__c;
        d.incorporationNumber = comp.Incorporation_number__c;
        d.partnerName = comp.From_Reseller__r == null ? null : comp.From_Reseller__r.Name;
        d.signerName = buildName(r1.FirstName, r1.LastName);
        d.signerTitle = r1.Title;

        if (cPanelContactId != null) {
            List<Contact> admins = [
                SELECT FirstName, LastName, Title, Email, Phone
                FROM Contact
                WHERE Id = :cPanelContactId
                LIMIT 1
            ];
            if (!admins.isEmpty()) {
                Contact a = admins[0];
                d.cPanelFirstName = a.FirstName;
                d.cPanelLastName = a.LastName;
                d.cPanelTitle = a.Title;
                d.cPanelEmail = a.Email;
                d.cPanelPhone = a.Phone;
            }
        }
        return d;
    }

    private static String buildName(String first, String last) {
        String f = String.isBlank(first) ? '' : first.trim();
        String l = String.isBlank(last) ? '' : last.trim();
        String full = (f + ' ' + l).trim();
        return String.isBlank(full) ? 'Recipient' : full;
    }

    // ─── DocuSign eSignature REST send ────────────────────────────────────────
    //
    // POST .../envelopes with status=sent (create + send in one call). Auth is
    // handled by the DocuSign_eSign Named Credential / External Credential, which
    // injects the OAuth bearer. The PDF is embedded inline as base64 so there is
    // no DML between the Conga and DocuSign callouts.

    private static String dispatchToDocuSign(String subject, Blob pdf, List<EnvelopeRecipient> recipients, MsaMergeData mergeData) {
        String accountId = readDocuSignAccountId();
        if (String.isBlank(accountId)) {
            throw new DocuSignSendException(
                'DocuSign account id missing — set Conga_Setting__c.DocuSign_Account_Id__c');
        }

        String body = buildEnvelopeJson(subject, pdf, recipients, mergeData);

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + NAMED_CREDENTIAL + String.format(ENVELOPES_PATH, new List<String>{ accountId }));
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Accept', 'application/json');
        req.setTimeout(120000);
        req.setBody(body);

        HttpResponse res = new Http().send(req);
        Integer status = res.getStatusCode();
        if (status < 200 || status >= 300) {
            throw new DocuSignSendException(
                'DocuSign envelope create failed: HTTP ' + status
                + (res.getBody() == null ? '' : ' | ' + res.getBody().abbreviate(500)));
        }

        Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        Object envelopeId = parsed.get('envelopeId');
        if (envelopeId == null || String.isBlank(String.valueOf(envelopeId))) {
            throw new DocuSignSendException('DocuSign returned no envelopeId. Body: '
                + (res.getBody() == null ? '' : res.getBody().abbreviate(500)));
        }
        return String.valueOf(envelopeId);
    }

    /**
     * Build the DocuSign envelope definition. Signers (R1/R2) get anchor-based
     * signHere + dateSigned tabs; the merchant signer (R1, recipientId 1) also
     * gets all the locked prefill text tabs that carry the merge data. Carbon
     * copies (owner) get no tabs.
     */
    @TestVisible
    private static String buildEnvelopeJson(String subject, Blob pdf, List<EnvelopeRecipient> recipients, MsaMergeData mergeData) {
        JSONGenerator gen = JSON.createGenerator(false);
        gen.writeStartObject();
        gen.writeStringField('emailSubject', subject);
        gen.writeStringField('emailBlurb',
            'Please review and sign the Nuvei Merchant Service Agreement (MSA).');
        gen.writeStringField('status', 'sent');

        // documents
        gen.writeFieldName('documents');
        gen.writeStartArray();
        gen.writeStartObject();
        gen.writeStringField('documentId', '1');
        gen.writeStringField('name', 'MSA.pdf');
        gen.writeStringField('fileExtension', 'pdf');
        gen.writeStringField('documentBase64', EncodingUtil.base64Encode(pdf));
        gen.writeEndObject();
        gen.writeEndArray();

        // recipients split into signers / carbonCopies
        List<EnvelopeRecipient> signers = new List<EnvelopeRecipient>();
        List<EnvelopeRecipient> carbonCopies = new List<EnvelopeRecipient>();
        for (EnvelopeRecipient r : recipients) {
            if (r.type == 'CarbonCopy') {
                carbonCopies.add(r);
            } else {
                signers.add(r);
            }
        }

        gen.writeFieldName('recipients');
        gen.writeStartObject();

        gen.writeFieldName('signers');
        gen.writeStartArray();
        for (EnvelopeRecipient r : signers) {
            gen.writeStartObject();
            writeRecipientCore(gen, r);
            writeSignerTabs(gen, r, mergeData);
            gen.writeEndObject();
        }
        gen.writeEndArray();

        gen.writeFieldName('carbonCopies');
        gen.writeStartArray();
        for (EnvelopeRecipient r : carbonCopies) {
            gen.writeStartObject();
            writeRecipientCore(gen, r);
            gen.writeEndObject();
        }
        gen.writeEndArray();

        gen.writeEndObject(); // recipients
        gen.writeEndObject(); // envelope
        return gen.getAsString();
    }

    private static void writeRecipientCore(JSONGenerator gen, EnvelopeRecipient r) {
        gen.writeStringField('recipientId', String.valueOf(r.recipientId));
        gen.writeStringField('routingOrder', String.valueOf(r.routingOrder));
        gen.writeStringField('email', r.email);
        gen.writeStringField('name', r.fullName);
        if (String.isNotBlank(r.roleName)) {
            gen.writeStringField('roleName', r.roleName);
        }
    }

    private static void writeSignerTabs(JSONGenerator gen, EnvelopeRecipient r, MsaMergeData mergeData) {
        String signAnchor = SIGN_ANCHOR_PREFIX + r.recipientId + ANCHOR_SUFFIX;
        String dateAnchor = DATE_ANCHOR_PREFIX + r.recipientId + ANCHOR_SUFFIX;
        gen.writeFieldName('tabs');
        gen.writeStartObject();

        gen.writeFieldName('signHereTabs');
        gen.writeStartArray();
        writeAnchorTab(gen, signAnchor);
        gen.writeEndArray();

        gen.writeFieldName('dateSignedTabs');
        gen.writeStartArray();
        writeAnchorTab(gen, dateAnchor);
        gen.writeEndArray();

        // Only the merchant signer (R1) carries the locked prefill data. The
        // Nuvei counter-signer (R2) just signs; nothing to prefill for them.
        if (r.recipientId == 1) {
            writeMerchantTextTabs(gen, r, mergeData);
        }

        gen.writeEndObject(); // tabs
    }

    /** signHere / dateSigned anchor tab (no value). */
    private static void writeAnchorTab(JSONGenerator gen, String anchorString) {
        gen.writeStartObject();
        gen.writeStringField('anchorString', anchorString);
        gen.writeStringField('anchorUnits', 'pixels');
        gen.writeStringField('anchorXOffset', '0');
        gen.writeStringField('anchorYOffset', '0');
        gen.writeEndObject();
    }

    /**
     * All Category A locked prefill text tabs, attached to the merchant signer.
     * Signer name (\n1\) and title (\t1\) use the recipient-numbered anchors;
     * the company / address / c-panel fields use the {{...}} placeholders.
     */
    private static void writeMerchantTextTabs(JSONGenerator gen, EnvelopeRecipient r, MsaMergeData d) {
        String nameAnchor = NAME_ANCHOR_PREFIX + r.recipientId + ANCHOR_SUFFIX;
        String titleAnchor = TITLE_ANCHOR_PREFIX + r.recipientId + ANCHOR_SUFFIX;

        gen.writeFieldName('textTabs');
        gen.writeStartArray();
        writeLockedTextTab(gen, nameAnchor, d.signerName);
        writeLockedTextTab(gen, titleAnchor, d.signerTitle);
        writeLockedTextTab(gen, ANCHOR_COMPANY_NAME, d.companyName);
        writeLockedTextTab(gen, ANCHOR_REG_ADDRESS, d.registeredAddress);
        writeLockedTextTab(gen, ANCHOR_REG_COUNTRY, d.registeredCountry);
        writeLockedTextTab(gen, ANCHOR_INCORPORATION, d.incorporationNumber);
        writeLockedTextTab(gen, ANCHOR_PARTNER_NAME, d.partnerName);
        writeLockedTextTab(gen, ANCHOR_CPANEL_FIRST, d.cPanelFirstName);
        writeLockedTextTab(gen, ANCHOR_CPANEL_LAST, d.cPanelLastName);
        writeLockedTextTab(gen, ANCHOR_CPANEL_TITLE, d.cPanelTitle);
        writeLockedTextTab(gen, ANCHOR_CPANEL_EMAIL, d.cPanelEmail);
        writeLockedTextTab(gen, ANCHOR_CPANEL_PHONE, d.cPanelPhone);
        gen.writeEndArray();
    }

    /**
     * A single read-only prefill text tab: locked so the signer cannot edit it,
     * not required (blank Salesforce values render as empty rather than blocking
     * the signing ceremony).
     */
    private static void writeLockedTextTab(JSONGenerator gen, String anchorString, String value) {
        gen.writeStartObject();
        gen.writeStringField('anchorString', anchorString);
        gen.writeStringField('anchorUnits', 'pixels');
        gen.writeStringField('anchorXOffset', '0');
        gen.writeStringField('anchorYOffset', '0');
        gen.writeStringField('value', value == null ? '' : value);
        gen.writeBooleanField('locked', true);
        gen.writeBooleanField('required', false);
        gen.writeStringField('font', 'Helvetica');
        gen.writeStringField('fontSize', 'Size10');
        gen.writeEndObject();
    }

    private static String readDocuSignAccountId() {
        List<Conga_Setting__c> rows = [
            SELECT DocuSign_Account_Id__c FROM Conga_Setting__c LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].DocuSign_Account_Id__c;
    }
}
