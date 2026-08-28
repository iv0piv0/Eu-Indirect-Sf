/**
 * Async worker for NuveiConnectWebhookHandler.
 *
 * Runs the full processWebhook flow in a separate transaction so the
 * REST endpoint can ACK NC within their 10s SLA regardless of how long
 * the Compliance/Contact/Opp/Bank cascade takes.
 *
 * Failures are logged to Execution_Log__c — no exception is rethrown
 * because the caller (REST endpoint) has already ACKed NC and there is
 * no path back to retry via NC.
 */
public without sharing class NuveiConnectWebhookQueueable implements Queueable {
    private final String rawBody;
    private final Id inboundLogId;

    public NuveiConnectWebhookQueueable(String rawBody, Id inboundLogId) {
        this.rawBody      = rawBody;
        this.inboundLogId = inboundLogId;
    }

    public void execute(QueueableContext ctx) {
        String appId;
        try {
            Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(rawBody);
            String appDataStr = (String) envelope.get('applicationData');
            Map<String, Object> appData = (Map<String, Object>) JSON.deserializeUntyped(appDataStr);
            appData.put('applicationId', envelope.get('applicationId'));
            appData.put('applicationStatus', envelope.get('applicationStatus'));
            appId = (String) envelope.get('applicationId');

            NuveiConnectWebhookHandler.NuveiConnectRequest ncReq =
                (NuveiConnectWebhookHandler.NuveiConnectRequest) JSON.deserialize(
                    JSON.serialize(appData),
                    NuveiConnectWebhookHandler.NuveiConnectRequest.class
                );

            NuveiConnectWebhookHandler.WebhookResult r =
                NuveiConnectWebhookHandler.processWebhook(ncReq);

            insert new Execution_Log__c(
                Class_Name__c  = 'NuveiConnectWebhookQueueable',
                Method_Name__c = 'execute',
                Type__c        = r.success ? 'Info' : 'Error',
                Note__c        = 'Async processing result for ' + appId + ': ' + r.message
            );
        } catch (Exception e) {
            try {
                insert new Execution_Log__c(
                    Class_Name__c  = 'NuveiConnectWebhookQueueable',
                    Method_Name__c = 'execute',
                    Type__c        = 'Error',
                    Note__c        = 'Async processing FAILED for ' + appId
                                    + ': ' + e.getMessage(),
                    Payload__c     = e.getStackTraceString()
                );
            } catch (Exception ignore) { /* nothing more we can do */ }
        }
    }
}
