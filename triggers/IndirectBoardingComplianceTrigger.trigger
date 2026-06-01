/**
 * EU Indirect Merchant Boarding — after-update entry point.
 *
 * Enqueues the IndirectBoardingQueueable when a watched orchestration field
 * changes on an EU-indirect Compliance__c. Skips the enqueue when the change
 * is the orchestration ITSELF writing a terminal failure status from inside
 * the @future it just invoked — that case would otherwise create an infinite
 * retry loop (Failed NCP → trigger → router → In Progress → @future → Failed NCP).
 *
 * See IndirectBoardingRouter.isOrchestrationSelfFailureTransition for the
 * exact transitions that are suppressed and why.
 */
trigger IndirectBoardingComplianceTrigger on Compliance__c (after update) {
    Set<Id> toRun = new Set<Id>();
    for (Compliance__c n : Trigger.new) {
        if (n.EU_Indirect_Orchestration__c != true) {
            continue;
        }
        Compliance__c o = Trigger.oldMap.get(n.Id);

        // Defense layer 1 of 2 against the @future re-trigger loop.
        // Layer 2 (the per-track retry counter circuit breaker) lives in
        // IndirectBoardingRouter.tryTrackNcp / tryTrackFinance.
        if (IndirectBoardingRouter.isOrchestrationSelfFailureTransition(n, o)) {
            continue;
        }

        if (IndirectBoardingRouter.anyOrchestrationFieldChanged(n, o)) {
            toRun.add(n.Id);
        }
    }
        // Wave 1 fix (gap #3): skip enqueue when we're already in an async
    // context. From @future / Queueable / Batch, Salesforce allows only ONE
    // System.enqueueJob per transaction. If the orchestration's @future
    // updated this Compliance to a terminal status, the field-update DML
    // re-fires this trigger inside that same async transaction — and the
    // @future itself (or a sibling DML it triggered) may have already
    // enqueued one queueable. Suppressing the second enqueue prevents
    // "Too many queueable jobs added to the queue: 2" without losing the
    // orchestration semantics, because the transition that mattered has
    // already been written by the code that initiated the async work.
    Boolean inAsync = System.isFuture() || System.isQueueable() || System.isBatch();
    if (inAsync) {
        for (Id complianceId : toRun) {
            System.debug(LoggingLevel.INFO,
                'IndirectBoardingComplianceTrigger | suppressing enqueue for ' + complianceId
                + ' — already in async context (future=' + System.isFuture()
                + ', queueable=' + System.isQueueable()
                + ', batch=' + System.isBatch() + ')');
        }
        return;
    }
    for (Id complianceId : toRun) {
        System.enqueueJob(new IndirectBoardingQueueable(complianceId));
    }
}
