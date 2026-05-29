/**
 * EU indirect boarding router — single entry for OCT rerun and async processing.
 * Reads Indirect_Boarding_Track__mdt for enabled tracks and sort order.
 *
 * Retry / circuit-breaker model
 * ─────────────────────────────
 * Track F (NCP) and Track G (Finance) both write their terminal failure status
 * (Failed NCP / Failed) from inside the @future they invoke. That write would
 * normally re-fire the orchestration trigger and create an infinite retry loop
 * (Failed NCP → trigger → router → 'In Progress' → @future → Failed NCP → …).
 *
 * Two layers of defense protect against this:
 *   1) IndirectBoardingComplianceTrigger calls
 *      IndirectBoardingRouter.isOrchestrationSelfFailureTransition(n, o) and
 *      SUPPRESSES the trigger enqueue when the only watched change is the
 *      @future telling us it failed. The auto-loop is broken at the source.
 *   2) tryTrackNcp / tryTrackFinance check Track_F_Retry_Count__c /
 *      Track_G_Retry_Count__c against MAX_RETRIES. Even if anyone bypasses the
 *      trigger guard (e.g. by a different field flipping in the same update),
 *      the router refuses to fire another attempt after MAX_RETRIES.
 *
 * Manual retry — runInvocable — explicitly RESETS both counters to 0 before
 * enqueueing. So OCT pressing "Rerun" always gets a fresh attempt budget.
 * A manual status reset by OCT (e.g. clearing Technical_Onboarding_Status__c)
 * is NOT one of the suppressed transitions and naturally re-fires the router.
 */
public with sharing class IndirectBoardingRouter {

    /**
     * Maximum number of automatic re-attempts allowed for Track F / Track G
     * before the router stops auto-retrying. Manual rerun via runInvocable
     * resets the counters and resumes attempts from 0.
     */
    @TestVisible private static final Decimal MAX_RETRIES = 3;

    public class Request {
        @InvocableVariable(required=true label='Compliance Id')
        public Id complianceId;
    }

    @InvocableMethod(
        label='EU Indirect Boarding Router'
        description='Advances EU indirect onboarding tracks (D–H). Safe to rerun; idempotent per track. Resets per-track retry counters before re-enqueueing.'
    )
    public static void runInvocable(List<Request> requests) {
        if (requests == null || requests.isEmpty()) {
            return;
        }
        Set<Id> ids = new Set<Id>();
        for (Request r : requests) {
            if (r != null && r.complianceId != null) {
                ids.add(r.complianceId);
            }
        }
        if (ids.isEmpty()) {
            return;
        }
        // Reset retry counters so the circuit breaker does not block legitimate
        // OCT-initiated retries (e.g. after fixing the root cause of a failure).
        List<Compliance__c> resets = new List<Compliance__c>();
        for (Id id : ids) {
            resets.add(new Compliance__c(
                Id = id,
                Track_F_Retry_Count__c = 0,
                Track_G_Retry_Count__c = 0
            ));
        }
        try {
            update resets;
        } catch (Exception e) {
            // Never block a manual rerun on a counter reset failure.
            System.debug(LoggingLevel.WARN,
                'IndirectBoardingRouter.runInvocable | counter reset failed | ' + e.getMessage());
        }
        for (Id complianceId : ids) {
            System.enqueueJob(new IndirectBoardingQueueable(complianceId));
        }
    }

    public static Boolean anyOrchestrationFieldChanged(Compliance__c n, Compliance__c o) {
        if (o == null) {
            return true;
        }
        return n.MSA_Status__c != o.MSA_Status__c
            || n.PCI_Status__c != o.PCI_Status__c
            || n.Technical_Onboarding_Status__c != o.Technical_Onboarding_Status__c
            || n.Finance_admin_status__c != o.Finance_admin_status__c
            || n.Nuvei_Connect_Status__c != o.Nuvei_Connect_Status__c
            || n.EU_Indirect_Orchestration__c != o.EU_Indirect_Orchestration__c;
    }

    /**
     * Returns true when the only watched-field change in this update is the
     * orchestration itself writing a terminal failure (the @future signalling
     * "I failed"). The trigger uses this to suppress the auto re-enqueue that
     * would otherwise create an infinite Track F / Track G retry loop.
     *
     * Suppressed transitions:
     *   Technical_Onboarding_Status__c: 'In Progress' → 'Failed NCP'
     *   Finance_admin_status__c       : 'In Progress' → 'Failed'
     *   MSA_Status__c                 : any           → 'Failed'
     *
     * Suppression only applies when NO OTHER watched field changed in the same
     * update — so an explicit OCT change (e.g. flipping PCI to Compliant in
     * the same edit) still re-fires the router as expected.
     */
    public static Boolean isOrchestrationSelfFailureTransition(Compliance__c n, Compliance__c o) {
        if (o == null) {
            return false;
        }
        if (n.Technical_Onboarding_Status__c == 'Failed NCP'
            && o.Technical_Onboarding_Status__c == 'In Progress') {
            return !otherOrchestrationFieldChanged(n, o, 'Technical_Onboarding_Status__c');
        }
        if (n.Finance_admin_status__c == 'Failed'
            && o.Finance_admin_status__c == 'In Progress') {
            return !otherOrchestrationFieldChanged(n, o, 'Finance_admin_status__c');
        }
        if (n.MSA_Status__c == 'Failed' && o.MSA_Status__c != 'Failed') {
            return !otherOrchestrationFieldChanged(n, o, 'MSA_Status__c');
        }
        return false;
    }

    private static Boolean otherOrchestrationFieldChanged(Compliance__c n, Compliance__c o, String except) {
        if (except != 'MSA_Status__c' && n.MSA_Status__c != o.MSA_Status__c) return true;
        if (n.PCI_Status__c != o.PCI_Status__c) return true;
        if (except != 'Technical_Onboarding_Status__c'
            && n.Technical_Onboarding_Status__c != o.Technical_Onboarding_Status__c) return true;
        if (except != 'Finance_admin_status__c'
            && n.Finance_admin_status__c != o.Finance_admin_status__c) return true;
        if (n.Nuvei_Connect_Status__c != o.Nuvei_Connect_Status__c) return true;
        if (n.EU_Indirect_Orchestration__c != o.EU_Indirect_Orchestration__c) return true;
        return false;
    }

    public static void processCompliance(Id complianceId) {
        if (complianceId == null) {
            return;
        }
        List<Compliance__c> lockRow = [
            SELECT Id
            FROM Compliance__c
            WHERE Id = :complianceId
            FOR UPDATE
        ];
        if (lockRow.isEmpty()) {
            return;
        }
        List<Indirect_Boarding_Track__mdt> defs = [
            SELECT Track_Code__c, Sort_Order__c, Is_Enabled__c
            FROM Indirect_Boarding_Track__mdt
            WHERE Is_Enabled__c = true
            ORDER BY Sort_Order__c NULLS LAST, DeveloperName
        ];
        Compliance__c c = loadCompliance(complianceId);
        if (c == null || c.EU_Indirect_Orchestration__c != true) {
            return;
        }
        if (isPciBlocking(c)) {
            return;
        }
        for (Indirect_Boarding_Track__mdt def : defs) {
            String code = def.Track_Code__c;
            if (code == 'MSA') {
                if (tryTrackMsa(complianceId)) {
                    return;
                }
            } else if (code == 'NCP') {
                if (tryTrackNcp(c)) {
                    return;
                }
            } else if (code == 'FINANCE_ADMIN') {
                if (tryTrackFinance(c)) {
                    return;
                }
            } else if (code == 'NC_NOTIFY') {
                if (tryTrackNcNotify(c)) {
                    return;
                }
            }
        }
    }

    private static Compliance__c loadCompliance(Id complianceId) {
        List<Compliance__c> rows = [
            SELECT
                Id,
                Name,
                EU_Indirect_Orchestration__c,
                Nuvei_Connect_Status__c,
                Nuvei_Connect_Application_ID__c,
                Compliance_Status__c,
                MSA_Status__c,
                PCI_Status__c,
                Technical_Onboarding_Status__c,
                Finance_admin_status__c,
                Track_F_Retry_Count__c,
                Track_G_Retry_Count__c,
                Fees_Currency__c,
                Account__c,
                (SELECT Id, MultiClient_ID__c, Client_ID__c FROM GW_Names__r LIMIT 1)
            FROM Compliance__c
            WHERE Id = :complianceId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    @TestVisible private static Boolean isPciBlocking(Compliance__c c) {
        if (c.PCI_Status__c == 'Non-Compliant') {
            BoardingErrorLogService.logError(
                'IndirectBoardingRouter',
                'isPciBlocking',
                c.Id,
                c.Nuvei_Connect_Application_ID__c,
                'PCI Gate',
                'PCI_Status__c is Non-Compliant — orchestration will not proceed to NCP',
                null,
                null
            );
            return true;
        }
        return false;
    }

    private static Boolean tryTrackMsa(Id complianceId) {
        IMsaTrack msa = new TrackDMsaConga();
        return msa.tryAdvance(complianceId);
    }

    @TestVisible private static Boolean tryTrackNcp(Compliance__c c) {
        if (c.MSA_Status__c != 'Counter Signed') {
            return false;
        }
        if (!(c.PCI_Status__c == 'Compliant' || c.PCI_Status__c == 'Compliant Offline')) {
            return false;
        }
        String tos = c.Technical_Onboarding_Status__c;
        if (tos == 'Completed') {
            return false;
        }
        if (tos == 'In Progress') {
            return false;
        }
        // Circuit breaker — stop auto-retrying once MAX_RETRIES attempts have been
        // logged by MerchantOnboardingController.sendMerchantRequest. OCT can resume
        // via the EU Indirect Boarding Router invocable, which resets the counter.
        Decimal fRetries = c.Track_F_Retry_Count__c == null ? 0 : c.Track_F_Retry_Count__c;
        if (fRetries >= MAX_RETRIES) {
            BoardingErrorLogService.logWarning(
                'IndirectBoardingRouter',
                'tryTrackNcp',
                c.Id,
                c.Nuvei_Connect_Application_ID__c,
                'Track F: Technical Onboarding (NCP)',
                'Track F circuit breaker open after ' + fRetries.intValue()
                    + ' failed attempts. Auto-retry suspended. Resolve the upstream error '
                    + 'and rerun via "EU Indirect Boarding Router" invocable to reset.',
                null
            );
            // Allow downstream Track H to notify MERCHANT_PENDING by falling through.
            return false;
        }
        List<Case> cfgCases = [
            SELECT Id
            FROM Case
            WHERE Company_Profile__c = :c.Id
            AND RecordType.DeveloperName = 'Configuration'
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        if (cfgCases.isEmpty()) {
            return false;
        }
        if (c.Account__c == null) {
            return false;
        }
        List<Contact> cPanel = [
            SELECT Id
            FROM Contact
            WHERE AccountId = :c.Account__c
            AND Is_CPanel_Admin__c = true
            LIMIT 1
        ];
        if (cPanel.isEmpty()) {
            BoardingErrorLogService.logError(
                'IndirectBoardingRouter',
                'tryTrackNcp',
                c.Id,
                c.Nuvei_Connect_Application_ID__c,
                'Track F: Technical Onboarding (NCP)',
                'Track F: no Contact with Is_CPanel_Admin__c for merchant account',
                null,
                null
            );
            return false;
        }
        List<Compliance__c> ncpLock = [
            SELECT Technical_Onboarding_Status__c
            FROM Compliance__c
            WHERE Id = :c.Id
            FOR UPDATE
        ];
        String curTos = ncpLock[0].Technical_Onboarding_Status__c;
        if (curTos == 'Completed' || curTos == 'In Progress') {
            return false;
        }
        update new Compliance__c(Id = c.Id, Technical_Onboarding_Status__c = 'In Progress');

        Boolean isProd = false;
        List<NC_Connect_Setting__c> ncCfg = [SELECT Is_Production__c FROM NC_Connect_Setting__c LIMIT 1];
        if (!ncCfg.isEmpty() && ncCfg[0].Is_Production__c == true) {
            isProd = true;
        }
        MerchantOnboardingController.sendMerchantRequest(cfgCases[0].Id, isProd, false);
        return true;
    }

   @TestVisible private static Boolean tryTrackFinance(Compliance__c c) {
        if (c.Technical_Onboarding_Status__c != 'Completed') {
            return false;
        }
        if (c.GW_Names__r.isEmpty()) {
            return false;
        }
        GW_Name__c gw = c.GW_Names__r[0];
        if (String.isBlank(gw.MultiClient_ID__c) || String.isBlank(gw.Client_ID__c)) {
            return false;
        }
        List<Banking_Details__c> banks = [
            SELECT Id
            FROM Banking_Details__c
            WHERE Compliance__c = :c.Id
            AND UW_Approval__c = 'Verified'
            LIMIT 1
        ];
        if (banks.isEmpty()) {
            return false;
        }
        List<Merchant_Bank__c> mb = [
            SELECT Id
            FROM Merchant_Bank__c
            WHERE Compliance__c = :c.Id
            AND bankId__c != null
            LIMIT 1
        ];
        if (mb.isEmpty()) {
            return false;
        }
        if (String.isBlank(c.Fees_Currency__c)) {
            return false;
        }
        String fas = c.Finance_admin_status__c;
        if (fas == 'Completed') {
            return false;
        }
        if (fas == 'In Progress') {
            return false;
        }
        // Circuit breaker — stop auto-retrying once MAX_RETRIES attempts have been
        // logged by FinanceIntegration.futureFinanceIntegration. Reset via the
        // EU Indirect Boarding Router invocable.
        Decimal gRetries = c.Track_G_Retry_Count__c == null ? 0 : c.Track_G_Retry_Count__c;
        if (gRetries >= MAX_RETRIES) {
            BoardingErrorLogService.logWarning(
                'IndirectBoardingRouter',
                'tryTrackFinance',
                c.Id,
                c.Nuvei_Connect_Application_ID__c,
                'Track G: Finance Admin',
                'Track G circuit breaker open after ' + gRetries.intValue()
                    + ' failed attempts. Auto-retry suspended. Resolve the upstream error '
                    + 'and rerun via "EU Indirect Boarding Router" invocable to reset.',
                null
            );
            return false;
        }
        List<Compliance__c> finLock = [
            SELECT Finance_admin_status__c
            FROM Compliance__c
            WHERE Id = :c.Id
            FOR UPDATE
        ];
        String curFin = finLock[0].Finance_admin_status__c;
        if (curFin == 'Completed' || curFin == 'In Progress') {
            return false;
        }
        update new Compliance__c(Id = c.Id, Finance_admin_status__c = 'In Progress');
        FinanceIntegration.futureFinanceIntegration(c.Id);
        return true;
    }

    @TestVisible private static Boolean tryTrackNcNotify(Compliance__c c) {
        if (c.Finance_admin_status__c != 'Completed') {
            if (c.Technical_Onboarding_Status__c == 'Failed NCP'
                || c.Finance_admin_status__c == 'Failed') {
                if (c.Nuvei_Connect_Status__c != 'MERCHANT_PENDING') {
                    NuveiConnectEventsService.postApplicationEvent(c.Id, 'MERCHANT_PENDING');
                }
                return true;
            }
            return false;
        }
        if (c.Nuvei_Connect_Status__c == 'MERCHANT_ACTIVATED') {
            return false;
        }
        NuveiConnectEventsService.postApplicationEvent(c.Id, 'MERCHANT_ACTIVATED');
        return true;
    }
}