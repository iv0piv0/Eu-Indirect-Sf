/**
 * Centralised execution / error log service for the EU Indirect Merchant
 * Boarding orchestration (AB-22478).
 *
 * Persists every track event to Execution_Log__c — the org-wide convention
 * already used by 14+ classes (OnBoardingController, ApiUtils, CaseHandler,
 * InitiateMerchantController, OmniChannelController, FeedCommentHandler,
 * MonthlyExecutionLogCleanup, CaseChangeEventHandler, CaseSLAController,
 * sendEmailUtils, CasePriorityForOmniScheduler, LightningLogHourlyExporter, …).
 *
 * Design choices (locked with the requester):
 *   - Insert-only / append log (NOT upsert one-row-per-merchant). Matches every
 *     other Execution_Log__c writer in the org and gives Ops a real audit trail.
 *     MonthlyExecutionLogCleanup already prunes old rows on schedule.
 *   - Caller passes its class + method name (Class_Name__c / Method_Name__c) —
 *     same convention all other writers follow. Track label goes to Note__c
 *     so a list view can group by track.
 *   - Four log levels exposed: ERROR / WARNING / INFO / SUCCESS — matches the
 *     restricted picklist on Execution_Log__c.Type__c.
 *   - All original Execution_Log__c semantics preserved:
 *         Error_Message__c    → Description__c   (human message)
 *         Error_Log__c        → Description__c   (exception type + message)
 *         NC_Application_ID__c→ Description__c   (NC App ID line)
 *         Stack_Trace__c      → Path__c          (full apex stack)
 *         Webhook_Payload__c  → Payload__c       (request body / payload)
 *         Track__c            → Note__c          (track label)
 *         Compliance__c       → Related_Record_Id__c (string Id, no lookup)
 *         Occurred_At__c      → CreatedDate (system)
 *
 * The service is fail-safe: any DML failure inside is caught and logged to
 * the system debug log, never thrown back at the calling track. A logging
 * failure must never abort an orchestration step.
 */
public with sharing class BoardingErrorLogService {

    // ── Public log levels (1:1 with Execution_Log__c.Type__c picklist) ────
    //
    // NOTE: Apex requires the fully-qualified name (BoardingErrorLogService.Level.X)
    // anywhere inside this class — referencing a bare enum constant like
    // `Level.ERROR` from within the enclosing class triggers the well-known
    // "Static field cannot be referenced from a non static context" compile
    // error. Every internal callsite below uses the fully-qualified form.
    public enum Level { ERROR, WARNING, INFO, SUCCESS }

    // Default REST-style status codes per level. Callers can override via
    // the full log(...) overload when they have an actual HTTP code.
    @TestVisible private static final Integer DEFAULT_ERROR_CODE   = 500;
    @TestVisible private static final Integer DEFAULT_WARNING_CODE = 409;
    @TestVisible private static final Integer DEFAULT_INFO_CODE    = 204;
    @TestVisible private static final Integer DEFAULT_SUCCESS_CODE = 200;

    // Description__c is LongText 131072. We cap each contribution defensively
    // so a single oversized payload can never blow the field limit.
    @TestVisible private static final Integer LONG_TEXT_CAP = 131072;

    /**
     * Execution_Log__c Record Type the orchestration writes to.
     *
     * All EU Indirect Boarding events must land under the NuveiConnect RT
     * (per org standard — picklist values for Type__c are tied to that RT).
     * Resolved once per Apex execution and cached. If the RT is missing in
     * the target org (e.g. a scratch org without the package), we fall back
     * to no RecordTypeId — the logger must never abort the orchestration.
     */
    @TestVisible private static final String EXECUTION_LOG_RT_NAME = 'NuveiConnect';
    private static Id cachedRecordTypeId;
    private static Boolean rtLookupAttempted = false;

    @TestVisible
    private static Id getExecutionLogRecordTypeId() {
        if (rtLookupAttempted) {
            return cachedRecordTypeId;
        }
        rtLookupAttempted = true;
        try {
            Schema.DescribeSObjectResult d = Execution_Log__c.SObjectType.getDescribe();
            Map<String, Schema.RecordTypeInfo> byDevName = d.getRecordTypeInfosByDeveloperName();
            Schema.RecordTypeInfo info = byDevName.get(EXECUTION_LOG_RT_NAME);
            if (info != null && info.isAvailable()) {
                cachedRecordTypeId = info.getRecordTypeId();
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'BoardingErrorLogService | RT lookup failed | ' + e.getTypeName() + ': ' + e.getMessage());
        }
        return cachedRecordTypeId;
    }

    // ── Public convenience entry points ───────────────────────────────────

    /**
     * Log an error from an orchestration track.
     *
     * @param callerClass        Apex class name initiating the log (e.g. 'TrackDMsaConga').
     * @param callerMethod       Apex method initiating the log (e.g. 'tryAdvance').
     * @param complianceId       Compliance__c Id this error relates to (mandatory).
     * @param nuveiApplicationId NC application Id (Compliance__c.Nuvei_Connect_Application_ID__c).
     * @param trackLabel         Human-readable track name (e.g. 'Track F: Technical Onboarding (NCP)').
     * @param humanMessage       Operator-facing summary (e.g. 'NCP API returned HTTP 500').
     * @param ex                 Optional Exception (its type, message and stack trace are captured).
     * @param requestPayload     Optional request body / payload that produced the failure.
     */
    public static void logError(
        String callerClass,
        String callerMethod,
        Id complianceId,
        String nuveiApplicationId,
        String trackLabel,
        String humanMessage,
        Exception ex,
        String requestPayload
    ) {
        log(BoardingErrorLogService.Level.ERROR, callerClass, callerMethod, complianceId,
            nuveiApplicationId, trackLabel, humanMessage, ex, requestPayload, null);
    }

    /**
     * Log a warning (non-blocking issue worth investigating).
     */
    public static void logWarning(
        String callerClass,
        String callerMethod,
        Id complianceId,
        String nuveiApplicationId,
        String trackLabel,
        String humanMessage,
        String requestPayload
    ) {
        log(BoardingErrorLogService.Level.WARNING, callerClass, callerMethod, complianceId,
            nuveiApplicationId, trackLabel, humanMessage, null, requestPayload, null);
    }

    /**
     * Log an informational event (e.g. "Track F skipped — gate not met").
     */
    public static void logInfo(
        String callerClass,
        String callerMethod,
        Id complianceId,
        String nuveiApplicationId,
        String trackLabel,
        String humanMessage
    ) {
        log(BoardingErrorLogService.Level.INFO, callerClass, callerMethod, complianceId,
            nuveiApplicationId, trackLabel, humanMessage, null, null, null);
    }

    /**
     * Log a success event (e.g. "Track G: Finance Admin completed").
     */
    public static void logSuccess(
        String callerClass,
        String callerMethod,
        Id complianceId,
        String nuveiApplicationId,
        String trackLabel,
        String humanMessage
    ) {
        log(BoardingErrorLogService.Level.SUCCESS, callerClass, callerMethod, complianceId,
            nuveiApplicationId, trackLabel, humanMessage, null, null, null);
    }

    // ── Full entry point — used internally and by callers that need to set
    //    the actual REST status code (e.g. echo the upstream HTTP code). ──

    public static void log(
        Level level,
        String callerClass,
        String callerMethod,
        Id complianceId,
        String nuveiApplicationId,
        String trackLabel,
        String humanMessage,
        Exception ex,
        String requestPayload,
        Integer statusCode
    ) {
        if (complianceId == null) {
            // Spec: errors must always be tied to a Compliance__c. Refuse silently
            // rather than throw — logging failures must not abort orchestration.
            return;
        }
        if (level == null) {
            level = BoardingErrorLogService.Level.ERROR;
        }

        try {
            Execution_Log__c row = new Execution_Log__c();
            Id rtId = getExecutionLogRecordTypeId();
            if (rtId != null) {
                row.RecordTypeId = rtId;
            }
            row.Class_Name__c = truncate(callerClass, 255);
            row.Method_Name__c = truncate(callerMethod, 255);
            row.Note__c = truncate(trackLabel, 255);
            row.Initiated_By__c = UserInfo.getUserId();
            row.Related_Record_Id__c = String.valueOf(complianceId);
            row.Type__c = toPicklist(level);
            row.Status_Code__c = statusCode != null ? statusCode : defaultStatusCode(level);
            row.Description__c = buildDescription(humanMessage, nuveiApplicationId, ex);
            if (ex != null) {
                String stack = ex.getStackTraceString();
                if (stack != null) {
                    row.Path__c = stack.length() > LONG_TEXT_CAP
                        ? stack.substring(0, LONG_TEXT_CAP)
                        : stack;
                }
            }
            if (requestPayload != null) {
                row.Payload__c = requestPayload.length() > LONG_TEXT_CAP
                    ? requestPayload.substring(0, LONG_TEXT_CAP)
                    : requestPayload;
            }
            insert row;
        } catch (Exception e) {
            // Last-ditch: never throw from the logger.
            System.debug(LoggingLevel.ERROR,
                'BoardingErrorLogService | insert failed | ' + e.getTypeName() + ': ' + e.getMessage());
        }
    }

    // ── Helpers ───────────────────────────────────────────────────────────

    /**
     * Compose the Description__c body so we never lose the three pieces of
     * context that used to live in dedicated Execution_Log__c fields:
     *   Error_Message__c, Error_Log__c, NC_Application_ID__c.
     */
    @TestVisible
    private static String buildDescription(String humanMessage, String nuveiApplicationId, Exception ex) {
        List<String> parts = new List<String>();
        if (String.isNotBlank(humanMessage)) {
            parts.add(humanMessage);
        }
        if (String.isNotBlank(nuveiApplicationId)) {
            parts.add('NC Application Id: ' + nuveiApplicationId);
        }
        if (ex != null) {
            String t = ex.getTypeName();
            String m = ex.getMessage();
            parts.add('Exception: ' + (t == null ? '' : t) + (m == null ? '' : (': ' + m)));
        }
        if (parts.isEmpty()) {
            return null;
        }
        String joined = String.join(parts, '\n');
        return joined.length() > LONG_TEXT_CAP ? joined.substring(0, LONG_TEXT_CAP) : joined;
    }

    @TestVisible
    private static String toPicklist(Level level) {
        if (level == BoardingErrorLogService.Level.ERROR)   return 'Error';
        if (level == BoardingErrorLogService.Level.WARNING) return 'Warning';
        if (level == BoardingErrorLogService.Level.INFO)    return 'Info';
        if (level == BoardingErrorLogService.Level.SUCCESS) return 'Success';
        return 'Error';
    }

    @TestVisible
    private static Integer defaultStatusCode(Level level) {
        if (level == BoardingErrorLogService.Level.ERROR)   return DEFAULT_ERROR_CODE;
        if (level == BoardingErrorLogService.Level.WARNING) return DEFAULT_WARNING_CODE;
        if (level == BoardingErrorLogService.Level.INFO)    return DEFAULT_INFO_CODE;
        if (level == BoardingErrorLogService.Level.SUCCESS) return DEFAULT_SUCCESS_CODE;
        return DEFAULT_ERROR_CODE;
    }

    private static String truncate(String s, Integer max) {
        if (s == null) return null;
        return s.length() > max ? s.substring(0, max) : s;
    }
}