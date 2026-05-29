/**
 * Maps dsfs__DocuSign_Status__c envelope events to Compliance__c.MSA_Status__c.
 *
 * Why a small handler:
 *   - Track D (TrackDMsaConga) only initiates the Conga + DocuSign send.
 *   - DocuSign's managed package writes envelope state to dsfs__DocuSign_Status__c
 *     ("Sent", "Delivered", "Completed", "Declined", "Voided").
 *   - This handler keeps the Compliance.MSA_Status__c picklist in sync and the
 *     update auto-fires IndirectBoardingComplianceTrigger -> router -> next gates.
 *
 * Linking model:
 *   - dsfs ships a few envelope linkage variants (parent-id, source-object-id,
 *     a Company lookup, etc.) which differ between orgs and dsfs versions.
 *   - To stay portable AND aligned with the existing JS buttons that set
 *     "DocuSignEmailSubject = MSA for {Compliance Name}" we resolve by parsing
 *     the subject. If the subject does not begin with the well-known prefix
 *     we silently skip (other DocuSign envelopes in the org are unaffected).
 *
 * Status mapping (kept intentionally narrow — Track F gates only on Counter Signed):
 *   Sent / Delivered  -> 'sent'
 *   Completed         -> 'Counter Signed' (envelope completed = all signers signed)
 *   Declined          -> 'declined'
 *   Voided            -> 'Failed'
 *   anything else     -> no change
 *
 * Idempotency:
 *   - Compliance__c.MSA_Status__c is updated only when the new value differs.
 *   - Only Compliance rows with EU_Indirect_Orchestration__c = true are touched.
 */
public with sharing class DocuSignStatusToMsa {

    @TestVisible private static final String SUBJECT_PREFIX = 'MSA for ';

    /**
     * Trigger entry point — handles inserts and status changes.
     */
    public static void handle(List<dsfs__DocuSign_Status__c> newRows,
                              Map<Id, dsfs__DocuSign_Status__c> oldMap) {
        if (newRows == null || newRows.isEmpty()) {
            return;
        }

        // 1) Collect (legalName -> targetStatus) for envelopes whose status changed
        Map<String, String> nameToStatus = new Map<String, String>();
        for (dsfs__DocuSign_Status__c row : newRows) {
            String env = row.dsfs__Envelope_Status__c;
            String oldEnv = oldMap == null ? null : (oldMap.containsKey(row.Id) ? oldMap.get(row.Id).dsfs__Envelope_Status__c : null);
            if (env == oldEnv) {
                continue;
            }
            String mapped = mapStatus(env);
            if (mapped == null) {
                continue;
            }
            String legalName = extractLegalName(row.dsfs__Subject__c);
            if (String.isBlank(legalName)) {
                continue;
            }
            // last writer wins — latest mapped status for the same legalName
            nameToStatus.put(legalName, mapped);
        }
        if (nameToStatus.isEmpty()) {
            return;
        }

        // 2) Look up matching EU indirect Compliance rows
        Set<String> names = nameToStatus.keySet();
        List<Compliance__c> targets = [
            SELECT Id, Name, MSA_Status__c, EU_Indirect_Orchestration__c
            FROM Compliance__c
            WHERE Name IN :names
            AND EU_Indirect_Orchestration__c = true
        ];

        // 3) Build the minimal update set (no-op when status unchanged)
        List<Compliance__c> updates = new List<Compliance__c>();
        for (Compliance__c c : targets) {
            String desired = nameToStatus.get(c.Name);
            if (desired == null) {
                continue;
            }
            if (c.MSA_Status__c == desired) {
                continue;
            }
            updates.add(new Compliance__c(Id = c.Id, MSA_Status__c = desired));
        }
        if (!updates.isEmpty()) {
            update updates;
        }
    }

    /**
     * Pure mapping — exposed for unit tests.
     */
    @TestVisible
    public static String mapStatus(String envelopeStatus) {
        if (String.isBlank(envelopeStatus)) {
            return null;
        }
        String s = envelopeStatus.trim().toLowerCase();
        if (s == 'sent' || s == 'delivered') {
            return 'sent';
        }
        if (s == 'completed') {
            return 'Counter Signed';
        }
        if (s == 'declined') {
            return 'declined';
        }
        if (s == 'voided') {
            return 'Failed';
        }
        return null;
    }

    /**
     * Extract the Compliance Name from a DocuSign subject built by Track D.
     * Subject convention: "MSA for {Compliance.Name}". Returns null if subject
     * does not match the convention (so unrelated DocuSign traffic is ignored).
     */
    @TestVisible
    public static String extractLegalName(String subject) {
        if (String.isBlank(subject)) {
            return null;
        }
        String s = subject.trim();
        if (!s.startsWithIgnoreCase(SUBJECT_PREFIX)) {
            return null;
        }
        return s.substring(SUBJECT_PREFIX.length()).trim();
    }
}