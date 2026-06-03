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
 *
 * Wave 3 fix (gap #11): replaced blanket "inAsync" block with a budget-aware
 * guard. The blanket block previously suppressed legitimate SUCCESS transitions
 * (Track F → Track G, Track G → Track H) when the previous track's success DML
 * happened inside Queueable / @future. The new guard skips enqueue ONLY when
 * the current transaction has no queueable budget remaining (which is the
 * actual cause of "Too many queueable jobs added to the queue: 2"). In sync
 * context the budget is 50 so the guard is a no-op; in Queueable/@future
 * context the budget is 1 so it correctly prevents the second enqueue while
 * still allowing the first (which is the chained successor track).
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

    for (Id complianceId : toRun) {
        // Wave 3 fix (gap #11): skip when no queueable budget remains.
        // Sync context: limit is 50 — guard is effectively a no-op.
        // Queueable/@future context: limit is 1 — allow exactly one chained
        //   successor (which is what auto-advances Track F→G→H), prevent any
        //   further enqueue from the same transaction.
        Integer remaining = Limits.getLimitQueueableJobs() - Limits.getQueueableJobs();
        if (remaining < 1) {
            System.debug(LoggingLevel.INFO,
                'IndirectBoardingComplianceTrigger | queueable budget exhausted ('
                + Limits.getQueueableJobs() + '/' + Limits.getLimitQueueableJobs()
                + ') — skipping enqueue for ' + complianceId);
            continue;
        }
        System.enqueueJob(new IndirectBoardingQueueable(complianceId));
    }
}
