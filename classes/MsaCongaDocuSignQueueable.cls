/**
 * Track D — Conga path, Phase 2 worker.
 *
 * Enqueued by ContentDocumentLinkTriggerHandler once Conga Trigger stores its
 * composed MSA PDF as a File on a Compliance still in MSA_Status__c = 'started'.
 * Runs in an async context so it can perform the DocuSign callout that Phase 1
 * (inside the synchronous orchestration transaction) could not.
 *
 * Thin by design: all Track D logic — reload, idempotency guard, signatory /
 * cPanel resolution, PDF load, DocuSign send, persist and failure logging —
 * lives in TrackDMsaConga.completeCongaMsaSend so the send path is identical to
 * the static flow.
 */
public with sharing class MsaCongaDocuSignQueueable implements Queueable, Database.AllowsCallouts {

    private final Id complianceId;
    private final Id contentVersionId;

    public MsaCongaDocuSignQueueable(Id complianceId, Id contentVersionId) {
        this.complianceId = complianceId;
        this.contentVersionId = contentVersionId;
    }

    public void execute(QueueableContext ctx) {
        new TrackDMsaConga().completeCongaMsaSend(complianceId, contentVersionId);
    }
}
