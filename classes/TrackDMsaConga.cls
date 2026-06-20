/**
 * Track D — EU Indirect MSA send, fully server-side (static PDF + DocuSign).
 *
 * Flow (spec §6):
 *   tryAdvance()
 *     ├─ eligibility gate     (APPROVED + Configuration Case + status rerunnable)
 *     ├─ pricing gate (§18)   → no Merchant_Bank__c pricing yet ⇒ stay Pending, return false
 *     ├─ signatory (§17)      → resolve R1 from Compliance_Contact__c (Director__c=true);
 *     │                         hard-fail (Failed + Execution_Log) if none — NO silent fallback
 *     ├─ Step 1: template     → load static MSA PDF from a ContentVersion (no callout)
 *     ├─ Step 2: DocuSign      → MsaDocuSignService.sendMsaEnvelope (eSignature REST);
 *     │                         all merchant fields injected as LOCKED prefill text tabs
 *     └─ Step 3: persist       → DocuSign_Envelope_Id__c + MSA_Status__c = 'sent'
 *   On any error: MSA_Status__c = 'Failed' + Execution_Log__c row.
 *
 * Static PDF approach (replaces Conga):
 *   The MSA is a pre-styled PDF (pricing tables baked in) stored as a Salesforce
 *   File. Track D resolves which ContentVersion to load:
 *     1. Compliance__c.MSA_Static_Template_Id__c (merchant — from NC payload)
 *     2. From_Reseller__r.MSA_Static_Template_Id__c (partner profile default)
 *     3. Conga_Setting__c.MSA_Template_Id__c (org-wide fallback)
 *   DocuSign overlays dynamic fields as locked prefill tabs. No Conga callout.
 *
 * Callout ordering:
 *   The template load is a SOQL read (not a callout). The only callout is the
 *   DocuSign send, performed after all gate checks; the status/envelope write
 *   happens only after it returns. (Same "no DML before callout" rule as Track F.)
 *
 * Status values are the Compliance__c.MSA_Status__c picklist API names — note
 * 'started'/'sent'/'signed' are lowercase. Track D writes 'sent' after a
 * successful DocuSign send; DocuSignStatusToMsa later advances 'sent' →
 * 'Counter Signed' from the dsfs webhook, which gates Track F.
 *
 * Testability:
 *   The body of tryAdvance()'s try { ... } block is extracted into the
 *   @TestVisible executeSendFlow(Compliance__c) method so coverage tests
 *   can exercise it directly without going through the merchant-pricing
 *   gate. The pricing gate is impossible to satisfy in test context due
 *   to the org's Industry / SC Acquirer validation cascade — see
 *   IBRCovBoostTest's header comment for the established workaround.
 */
public with sharing class TrackDMsaConga implements IMsaTrack {

    public class TrackDException extends Exception {}

    @TestVisible private static final String TRACK_LABEL = 'Track D: MSA Generation (Static PDF + DocuSign)';

    // MSA_Status__c picklist API names (note the lowercase 'sent' — the picklist
    // value is lowercase and DocuSignStatusToMsa maps the dsfs webhook to it).
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
     * Returns: always true once invoked — either success (status='sent') or
     * a logged failure (status='Failed'). Mirrors the original try { ... }
     * block's return semantics exactly.
     */
    @TestVisible
    private Boolean executeSendFlow(Compliance__c c) {
        try {
            // §17 — resolve R1 (authorized signatory). Hard-fail on none.
            Id signerContactId = resolveAuthorizedSignatory(c.Id);
            if (signerContactId == null) {
                failWithLog(c,
                    'No authorized signatory found on Compliance — no Compliance_Contact__c row '
                    + 'with Director__c=true. Populate Authorized_Signature__c on the relevant '
                    + 'Contact(s) if needed.', null);
                return true;
            }

            String templateId = resolveMsaTemplateId(c);
            if (String.isBlank(templateId)) {
                failWithLog(c,
                    'No MSA PDF template configured — set MSA_Static_Template_Id__c on the '
                    + 'merchant or partner profile, or Conga_Setting__c.MSA_Template_Id__c '
                    + 'as org default', null);
                return true;
            }

            // Step 1 — load the static MSA PDF template (SOQL, no callout)
            Blob pdf = loadStaticMsaTemplate(templateId);
            if (pdf == null || pdf.size() == 0) {
                failWithLog(c,
                    'Static MSA PDF template not found or empty for ContentVersion Id ' + templateId, null);
                return true;
            }

            // cPanel admin (Appendix B) — same resolution pattern as Track F.
            // Absence is non-fatal: the merge data falls back to blanks.
            Id cPanelContactId = resolveCPanelAdmin(c.Account__c);

            // Step 2 — DocuSign send via eSignature REST API (the only callout)
            String envelopeId = MsaDocuSignService.sendMsaEnvelope(c, pdf, signerContactId, cPanelContactId);

            // Step 3 — persist success (DML only after both callouts)
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
            return true;

        } catch (Exception e) {
            failWithLog(c, 'Track D send failed: ' + e.getMessage(), e);
            return true;
        }
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

    // ─── Step 1: static MSA PDF template ─────────────────────────────────────

    /**
     * Load the static MSA PDF from its ContentVersion. The pricing tables and
     * legal boilerplate are baked into this artwork; DocuSign overlays the
     * dynamic merchant fields as locked prefill tabs. Returns null when the
     * ContentVersion is missing or has no data so the caller can fail clearly.
     */
    @TestVisible
    private Blob loadStaticMsaTemplate(String templateId) {
        List<ContentVersion> versions = [
            SELECT VersionData
            FROM ContentVersion
            WHERE Id = :templateId
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
            MSA_Started_At__c = c.MSA_Started_At__c == null ? DateTime.now() : c.MSA_Started_At__c
        );
    }
}
