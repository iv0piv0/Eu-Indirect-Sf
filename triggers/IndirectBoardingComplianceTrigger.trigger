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
 * Wave 3 fix (gap #11): the previous blanket "inAsync" block also suppressed
 * legitimate SUCCESS transitions (Track F → Track G, Track G → Track H) when
 * the previous track's success DML happened inside Queueable / @future. The
 * per-record isOrchestrationSelfFailureTransition guard above is sufficient
 * for failure-loop protection on its own, so the blanket async block is
 * removed. Each per-track circuit breaker (Track_F_Retry_Count__c /
 * Track_G_Retry_Count__c in IndirectBoardingRouter) provides a second layer
 * of defense against runaway retries.
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
        System.enqueueJob(new IndirectBoardingQueueable(complianceId));
    }
}
