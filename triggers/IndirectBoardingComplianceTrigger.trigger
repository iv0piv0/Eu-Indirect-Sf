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
    for (Id complianceId : toRun) {
        System.enqueueJob(new IndirectBoardingQueueable(complianceId));
    }
}