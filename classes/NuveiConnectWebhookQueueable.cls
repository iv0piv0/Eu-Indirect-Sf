/**
 * Async worker for NuveiConnectWebhookHandler.
 *
 * Runs the full processWebhook flow in a separate transaction so the
 * REST endpoint can ACK NC within their 10s SLA regardless of how long
 * the Compliance/Contact/Opp/Bank cascade takes.
 *
 * Failures are logged to Execution_Log__c AND System.debug (so they
 * appear in ApexLog even if the log-insert itself fails under the
 * Site Guest User context).
 */
public without sharing class NuveiConnectWebhookQueueable implements Queueable {
    private final String rawBody;
    private final Id inboundLogId;

    public NuveiConnectWebhookQueueable(String rawBody, Id inboundLogId) {
        this.rawBody      = rawBody;
        this.inboundLogId = inboundLogId;
    }

    public void execute(QueueableContext ctx) {
        String jobId     = (ctx == null ? 'null' : String.valueOf(ctx.getJobId()));
        String diagPfx   = 'NC-Queueable[' + jobId + ']';
        String appId;

        System.debug(LoggingLevel.INFO, diagPfx + ' START | user=' + UserInfo.getUserName()
            + ' | userId=' + UserInfo.getUserId());

        try {
            Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            String appDataStr = (String) envelope.get('applicationData');
            Map<String, Object> appData = (Map<String, Object>) JSON.deserializeUntyped(appDataStr);
            appData.put('applicationId', envelope.get('applicationId'));
            appData.put('applicationStatus', envelope.get('applicationStatus'));
            appId = (String) envelope.get('applicationId');

            System.debug(LoggingLevel.INFO, diagPfx + ' parsed envelope | appId=' + appId
                + ' | status=' + envelope.get('applicationStatus'));

            NuveiConnectWebhookHandler.NuveiConnectRequest ncReq =
                (NuveiConnectWebhookHandler.NuveiConnectRequest) JSON.deserialize(
                    JSON.serialize(appData),
                    NuveiConnectWebhookHandler.NuveiConnectRequest.class
                );

            System.debug(LoggingLevel.INFO, diagPfx + ' calling processWebhook...');

            NuveiConnectWebhookHandler.WebhookResult r =
                NuveiConnectWebhookHandler.processWebhook(ncReq);

            System.debug(LoggingLevel.INFO, diagPfx + ' processWebhook returned | success='
                + r.success + ' | message=' + r.message);

            try {
                insert new Execution_Log__c(
                    Class_Name__c  = 'NuveiConnectWebhookQueueable',
                    Method_Name__c = 'execute',
                    Type__c        = r.success ? 'Info' : 'Error',
                    Note__c        = 'Async processing result for ' + appId + ': ' + r.message
                );
            } catch (Exception logEx) {
                System.debug(LoggingLevel.WARN, diagPfx + ' could NOT write success log: '
                    + logEx.getTypeName() + ': ' + logEx.getMessage());
            }

            System.debug(LoggingLevel.INFO, diagPfx + ' END OK');

        } catch (Exception e) {
            // ALWAYS emit to System.debug so it shows in ApexLog even if DML fails
            System.debug(LoggingLevel.ERROR,
                diagPfx + ' FAILED for appId=' + appId
                + ' | ' + e.getTypeName() + ': ' + e.getMessage()
                + '\n' + e.getStackTraceString());

            // Best-effort persist
            try {
                insert new Execution_Log__c(
                    Class_Name__c  = 'NuveiConnectWebhookQueueable',
                    Method_Name__c = 'execute',
                    Type__c        = 'Error',
                    Note__c        = 'Async processing FAILED for ' + appId
                                    + ': ' + e.getTypeName() + ': ' + e.getMessage(),
                    Payload__c     = e.getStackTraceString()
                );
            } catch (Exception ignore) {
                System.debug(LoggingLevel.WARN, diagPfx + ' could NOT write error log: '
                    + ignore.getMessage());
            }
            // NOT rethrowing — NC already got 200; nothing to gain from failing the job
        }
    }
}
