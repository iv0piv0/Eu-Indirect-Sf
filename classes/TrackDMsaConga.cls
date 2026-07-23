/**
 * Track D — EU Indirect MSA generation + DocuSign send, fully server-side.
 *
 * Two interchangeable PDF sources, selected by the feature flag
 * Conga_Setting__c.Use_Conga_Trigger__c (default off):
 *
 *   OFF — Static PDF (synchronous, single transaction)
 *     tryAdvance() loads a pre-styled MSA PDF from a ContentVersion (SOQL,
 *     no callout) and sends it straight to DocuSign in the same transaction.
 *
 *   ON  — Conga Trigger (headless, asynchronous, two-phase)
 *     Conga Trigger composes a per-merchant, properly styled MSA in its own
 *     background job and stores the result as a Salesforce File on the
 *     Compliance record. Because nothing comes back to Apex in-transaction,
 *     the send is split:
 *       Phase 1 (this class, tryAdvance): resolve the Conga template, write
 *         the Conga parameters, flip Fire_Conga_MSA__c, set MSA_Status__c =
 *         'started', and return. No callout here.
 *       Phase 2 (ContentDocumentLinkTriggerHandler → MsaCongaDocuSignQueueable
 *         → completeCongaMsaSend): when Conga's output File lands on the
 *         Compliance, load the composed PDF and run the same DocuSign send +
 *         persist as the static path.
 *
 * Flow (both paths):
 *   tryAdvance()
 *     ├─ eligibility gate     (APPROVED + Configuration Case + status rerunnable)
 *     ├─ pricing gate (§18)   → no Merchant_Bank__c pricing yet ⇒ stay Pending, return false
 *     ├─ signatory (§17)      → resolve R1 from Compliance_Contact__c (Director__c=true);
 *     │                         hard-fail (Failed + Execution_Log) if none — NO silent fallback
 *     ├─ Step 1: template     → static: load ContentVersion PDF | conga: fire Conga Trigger
 *     ├─ Step 2: DocuSign      → MsaDocuSignService.sendMsaEnvelope (eSignature REST)
 *     └─ Step 3: persist       → DocuSign_Envelope_Id__c + MSA_Status__c = 'sent'
 *   On any error: MSA_Status__c = 'Failed' + Execution_Log__c row.
 *
 * Template resolution:
 *   Static : Compliance MSA_Static_Template_Id__c → partner → Conga_Setting__c.MSA_Template_Id__c
 *   Conga  : single org template — Conga_Setting__c.EU_Indirect_Template_ID__c. Conga merges
 *            all merchant data itself off the Compliance record, so there is no per-merchant
 *            Conga template.
 *
 * Callout ordering:
 *   No DML precedes a callout in any transaction. Static path: SOQL load then
 *   DocuSign send then persist. Conga Phase 1: DML only (no callout; the Conga
 *   managed trigger owns its async callout). Conga Phase 2 (queueable): SOQL
 *   load then DocuSign send then persist.
 *
 * Status values are the Compliance__c.MSA_Status__c picklist API names — note
 * 'started'/'sent'/'signed' are lowercase. 'started' is only ever set by the
 * Conga path and is the discriminator Phase 2 keys off. DocuSignStatusToMsa
 * later advances 'sent' → 'Counter Signed' from the dsfs webhook, gating Track F.
 */
public with sharing class TrackDMsaConga implements IMsaTrack {

    public class TrackDException extends Exception {}

    @TestVisible private static final String TRACK_LABEL = 'Track D: MSA Generation (Conga Trigger / Static PDF + DocuSign)';

    // Deterministic output filename prefix for Conga-composed MSAs. Phase 2
    // detection (ContentDocumentLinkTriggerHandler) matches on this prefix, so
    // the Conga Trigger solution must be configured to name its output the same
    // way (OFN below builds it). Public so the file trigger can reuse it.
    public static final String OUTPUT_FILENAME_PREFIX = 'EU-MSA-';

    // MSA_Status__c picklist API names (note the lowercase 'sent'/'started' —
    // the picklist values are lowercase and DocuSignStatusToMsa maps the dsfs
    // webhook to them).
    @TestVisible private static final String STATUS_STARTED = 'started';
    @TestVisible private static final String STATUS_SENT    = 'sent';
    @TestVisible private static final String STATUS_FAILED  = 'Failed';
    @TestVisible private static final String STATUS_PENDING = 'Pending';


    public Boolean tryAdvance(Id complianceId) {
        if (complianceId == null) {
            return false;
        }

        Compliance__c c = loadCompliance(complianceId);
        if (c == null || c.EU_Indirect_Orchestration__c != true) {
            return false;
        }
        if (!isEligible(c)) {
            return false;
        }

        // §18 — pricing gate. Expected wait state: do NOT fail, just hold.
        if (!hasMerchantPricing(c.Id)) {
            return false;
        }

        return executeSendFlow(c);
    }

    /**
     * Extracted body of the original try { ... } block. @TestVisible so that
     * coverage tests can call this directly with a hand-built Compliance__c,
     * bypassing the merchant-pricing gate (which is impossible to satisfy in
     * test context due to the sandbox's Industry / SC Acquirer validation
     * cascade; see IBRCovBoostTest header comment for the team's established
     * workaround pattern).
     *
     * Callers must:
     *   - Pass a Compliance__c that has already passed loadCompliance()
     *     (i.e. with all SELECT'd fields populated).
     *   - Have already verified eligibility and the pricing gate themselves
     *     (or be in a test context that intentionally bypasses these gates
     *     for coverage purposes).
     *
     * Returns: always true once invoked — either a successful send (status
     * 'sent'), a fired Conga composition (status 'started'), or a logged
     * failure (status 'Failed'). Mirrors the original return semantics.
     */
    @TestVisible
    private Boolean executeSendFlow(Compliance__c c) {
        try {
            // §17 — resolve R1 (authorized signatory). Hard-fail on none, for
            // both paths — never fire Conga / send DocuSign without a signer.
            Id signerContactId = resolveAuthorizedSignatory(c.Id);
            if (signerContactId == null) {
                failWithLog(c,
                    'No authorized signatory found on Compliance — no Compliance_Contact__c row '
                    + 'with Director__c=true. Populate Authorized_Signature__c on the relevant '
                    + 'Contact(s) if needed.', null);
                return true;
            }

            if (useCongaTrigger()) {
                // Conga path, Phase 1 — fire headless composition, then wait
                // for the output File (resumed by Phase 2). No callout here.
                String congaTemplateId = resolveCongaTemplateId(c);
                if (String.isBlank(congaTemplateId)) {
                    failWithLog(c,
                        'No Conga MSA template configured — set '
                        + 'Conga_Setting__c.EU_Indirect_Template_ID__c', null);
                    return true;
                }
                triggerCongaComposition(c, congaTemplateId);
                return true;
            }

            // Static path — load the pre-styled PDF and send synchronously.
            String templateId = resolveMsaTemplateId(c);
            if (String.isBlank(templateId)) {
                failWithLog(c,
                    'No MSA PDF template configured — set MSA_Static_Template_Id__c on the '
                    + 'merchant or partner profile, or Conga_Setting__c.MSA_Template_Id__c '
                    + 'as org default', null);
                return true;
            }

            Blob pdf = loadStaticMsaTemplate(templateId);
            if (pdf == null || pdf.size() == 0) {
                failWithLog(c,
                    'Static MSA PDF template not found or empty for ContentVersion Id ' + templateId, null);
                return true;
            }

            Id cPanelContactId = resolveCPanelAdmin(c.Account__c);
            sendViaDocuSignAndPersist(c, pdf, signerContactId, cPanelContactId);
            return true;

        } catch (Exception e) {
            failWithLog(c, 'Track D send failed: ' + e.getMessage(), e);
            return true;
        }
    }

    /**
     * Phase 2 entry point (called by MsaCongaDocuSignQueueable after Conga
     * stores its output File). Loads the composed PDF from the ContentVersion
     * and runs the same DocuSign send + persist as the static path.
     *
     * Idempotent: only proceeds while MSA_Status__c is still 'started', so a
     * duplicate File link or a re-enqueued job cannot double-send.
     */
    public void completeCongaMsaSend(Id complianceId, Id contentVersionId) {
        if (complianceId == null || contentVersionId == null) {
            return;
        }
        Compliance__c c = loadCompliance(complianceId);
        if (c == null) {
            return;
        }
        // Only the in-flight Conga composition should be completed here.
        if (c.MSA_Status__c != STATUS_STARTED) {
            return;
        }

        try {
            Id signerContactId = resolveAuthorizedSignatory(c.Id);
            if (signerContactId == null) {
                failWithLog(c,
                    'Conga MSA composed but no authorized signatory (Director__c=true) is set — '
                    + 'cannot send for signature.', null);
                return;
            }

            Blob pdf = loadStaticMsaTemplate(contentVersionId);
            if (pdf == null || pdf.size() == 0) {
                failWithLog(c,
                    'Conga MSA output ContentVersion ' + contentVersionId + ' was empty or missing', null);
                return;
            }

            Id cPanelContactId = resolveCPanelAdmin(c.Account__c);
            sendViaDocuSignAndPersist(c, pdf, signerContactId, cPanelContactId);

        } catch (Exception e) {
            failWithLog(c, 'Track D Conga send (Phase 2) failed: ' + e.getMessage(), e);
        }
    }

    // ─── Step 2/3: DocuSign send + persist (shared by both paths) ─────────────

    /**
     * The only callout plus the success write. Extracted so the static path
     * and the Conga Phase 2 queueable share one code path. DML happens only
     * after the DocuSign send returns (no DML before callout).
     */
    @TestVisible
    private void sendViaDocuSignAndPersist(Compliance__c c, Blob pdf, Id signerContactId, Id cPanelContactId) {
        String envelopeId = MsaDocuSignService.sendMsaEnvelope(c, pdf, signerContactId, cPanelContactId);

        Compliance__c upd = new Compliance__c(
            Id = c.Id,
            DocuSign_Envelope_Id__c = envelopeId,
            MSA_Status__c = STATUS_SENT
        );
        if (c.MSA_Started_At__c == null) {
            upd.MSA_Started_At__c = DateTime.now();
        }
        if (c.MSA_Effective_Date__c == null) {
            upd.MSA_Effective_Date__c = Date.today();
        }
        update upd;
    }

    // ─── Step 1 (Conga path): fire headless composition ───────────────────────

    /**
     * Phase 1 of the Conga path — write the Conga Composer parameters and flip
     * the trigger flag the Conga Trigger managed configuration watches, then
     * move MSA_Status__c to 'started'. Conga composes asynchronously and stores
     * the output File; Phase 2 resumes from there.
     *
     * The parameter string injects the dynamic template Id and a deterministic
     * output filename (EU-MSA-<ComplianceId>) so Phase 2 can recognise the
     * resulting File. Email-off and store-as-File behaviour are governed by the
     * Conga Trigger solution configuration (see the post-deploy admin steps).
     */
    @TestVisible
    private void triggerCongaComposition(Compliance__c c, String congaTemplateId) {
        String ofn = OUTPUT_FILENAME_PREFIX + c.Id;
        String params = String.join(new List<String>{
            'TemplateId=' + congaTemplateId,
            'DefaultPDF=1',   // compose a PDF
            'OFN=' + ofn      // output filename → Phase 2 detection prefix
        }, '&');

        Compliance__c upd = new Compliance__c(
            Id = c.Id,
            Conga_MSA_Params__c = params,
            Fire_Conga_MSA__c   = true,
            MSA_Status__c       = STATUS_STARTED
        );
        if (c.MSA_Started_At__c == null) {
            upd.MSA_Started_At__c = DateTime.now();
        }
        update upd;
    }

    private Boolean useCongaTrigger() {
        // Conga_Setting__c is a List custom setting (queried, not getOrgDefaults).
        List<Conga_Setting__c> rows = [
            SELECT Use_Conga_Trigger__c FROM Conga_Setting__c LIMIT 1
        ];
        return !rows.isEmpty() && rows[0].Use_Conga_Trigger__c == true;
    }

    // ─── Loaders / gating ────────────────────────────────────────────────────

    private Compliance__c loadCompliance(Id complianceId) {
        List<Compliance__c> rows = [
            SELECT
                Id,
                Name,
                EU_Indirect_Orchestration__c,
                Nuvei_Connect_Status__c,
                Nuvei_Connect_Application_ID__c,
                MSA_Status__c,
                MSA_Effective_Date__c,
                MSA_Started_At__c,
                Underwriting_Mgr__c,
                OwnerId,
                Account__c,
                Registered_Address_New__c,
                Registered_Country__c,
                Incorporation_number__c,
                MSA_Static_Template_Id__c,
                From_Reseller__r.Name,
                From_Reseller__r.MSA_Static_Template_Id__c
            FROM Compliance__c
            WHERE Id = :complianceId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private Boolean isEligible(Compliance__c c) {
        if (c.Nuvei_Connect_Status__c != 'APPROVED') {
            return false;
        }
        Integer cfgCount = [
            SELECT COUNT()
            FROM Case
            WHERE Company_Profile__c = :c.Id
            AND RecordType.DeveloperName = 'Configuration'
        ];
        if (cfgCount == 0) {
            return false;
        }
        String s = c.MSA_Status__c;
        // Track D fires only when status is unset / Pending / Failed (rerun).
        // 'started' (Conga in flight) and 'sent' are deliberately excluded so
        // the orchestration never re-fires a composition that is already running.
        return String.isBlank(s) || s == STATUS_PENDING || s == STATUS_FAILED;
    }

    /**
     * §18 — at least one merchant-level pricing row must exist. Track D does not
     * care whether it was auto-copied from the partner template or supplied via
     * custom intake — only that a Merchant_Bank__c with Partner_Template_Pricing__c=false
     * exists for this Compliance.
     */
    @TestVisible
    private Boolean hasMerchantPricing(Id complianceId) {
        Integer pricingCount = [
            SELECT COUNT()
            FROM Merchant_Bank__c
            WHERE Compliance__c = :complianceId
            AND Partner_Template_Pricing__c = false
        ];
        return pricingCount > 0;
    }

    /**
     * §17 — R1 = the authorized signatory. Junction rows are populated upstream
     * by the webhook handler; Track D only consumes them. Highest ownership
     * percentage wins when more than one owner is flagged.
     */
    @TestVisible
    private Id resolveAuthorizedSignatory(Id complianceId) {
        List<Compliance_Contact__c> signers = [
            SELECT Contact__c
            FROM Compliance_Contact__c
            WHERE Compliance__c = :complianceId
            AND Director__c = true
            AND Contact__r.Email != null
            ORDER BY If_Owner_Percentage_held__c DESC NULLS LAST
            LIMIT 1
        ];
        return signers.isEmpty() ? null : signers[0].Contact__c;
    }

    /**
     * Resolve the ContentVersion Id for the static MSA PDF:
     *   1. Merchant MSA_Static_Template_Id__c (from NC payload at onboarding)
     *   2. Partner From_Reseller__r.MSA_Static_Template_Id__c
     *   3. Conga_Setting__c.MSA_Template_Id__c (org default)
     */
    @TestVisible
    private String resolveMsaTemplateId(Compliance__c c) {
        if (String.isNotBlank(c.MSA_Static_Template_Id__c)) {
            return c.MSA_Static_Template_Id__c.trim();
        }
        if (c.From_Reseller__r != null
            && String.isNotBlank(c.From_Reseller__r.MSA_Static_Template_Id__c)) {
            return c.From_Reseller__r.MSA_Static_Template_Id__c.trim();
        }
        List<Conga_Setting__c> rows = [
            SELECT MSA_Template_Id__c FROM Conga_Setting__c LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].MSA_Template_Id__c;
    }

    /**
     * Resolve the Conga template Id — a single org-wide template held in
     * Conga_Setting__c.EU_Indirect_Template_ID__c (the field from the original
     * design). Conga merges every merchant field itself off the Compliance
     * record, so no per-merchant / per-partner template is needed.
     */
    @TestVisible
    private String resolveCongaTemplateId(Compliance__c c) {
        List<Conga_Setting__c> rows = [
            SELECT EU_Indirect_Template_ID__c FROM Conga_Setting__c LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].EU_Indirect_Template_ID__c;
    }

    // ─── cPanel admin (Appendix B) ───────────────────────────────────────────

    /**
     * Resolve the c-Panel administrator Contact for the merchant account — the
     * same flag and pattern used by Track F (IndirectBoardingRouter.tryTrackNcp).
     * Returns null when the account is missing or no flagged Contact exists;
     * the merge data then falls back to blanks (signing can still proceed).
     */
    @TestVisible
    private Id resolveCPanelAdmin(Id accountId) {
        if (accountId == null) {
            return null;
        }
        List<Contact> admins = [
            SELECT Id
            FROM Contact
            WHERE AccountId = :accountId
            AND Is_CPanel_Admin__c = true
            LIMIT 1
        ];
        return admins.isEmpty() ? null : admins[0].Id;
    }

    // ─── PDF loader (ContentVersion) ─────────────────────────────────────────

    /**
     * Load a PDF Blob from its ContentVersion. Used for both the static MSA
     * template (flag off) and the Conga-composed output File (flag on, Phase 2).
     * Returns null when the ContentVersion is missing or has no data so the
     * caller can fail clearly.
     */
    @TestVisible
    private Blob loadStaticMsaTemplate(String contentVersionId) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :contentVersionId
            LIMIT 1
        ];
        return versions.isEmpty() ? null : versions[0].VersionData;
    }

    // ─── Failure path ───────────────────────────────────────────────────────

    private void failWithLog(Compliance__c c, String reason, Exception ex) {
        // Track D writing MSA_Status__c='Failed' re-fires the orchestration
        // trigger; guard against logging the same failure twice on the rerun.
        if (c.MSA_Status__c == STATUS_FAILED) {
            Integer existing = [
                SELECT COUNT()
                FROM Execution_Log__c
                WHERE Related_Record_Id__c = :String.valueOf(c.Id)
                  AND Note__c = :TRACK_LABEL
                  AND Type__c = 'Error'
            ];
            if (existing >= 1) {
                return;
            }
        }

        BoardingErrorLogService.log(
            BoardingErrorLogService.Level.ERROR,
            'TrackDMsaConga',
            'tryAdvance',
            c.Id,
            c.Nuvei_Connect_Application_ID__c,
            TRACK_LABEL,
            'Track D: ' + reason,
            ex,
            null,
            412
        );

        update new Compliance__c(
            Id = c.Id,
            MSA_Status__c = STATUS_FAILED,
            // Clear the Conga trigger flag so a later rerun (Failed → true) is a
            // genuine field change that re-fires the Conga Trigger managed config.
            Fire_Conga_MSA__c = false,
            MSA_Started_At__c = c.MSA_Started_At__c == null ? DateTime.now() : c.MSA_Started_At__c
        );
    }
}
