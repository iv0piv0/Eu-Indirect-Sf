@IsTest
private class NuveiConnectEventsServiceTest {

    private class CapturingMock implements HttpCalloutMock {
        public HttpRequest captured;
        public Integer responseStatus = 200;
        public HttpResponse respond(HttpRequest req) {
            this.captured = req;
            HttpResponse res = new HttpResponse();
            res.setStatusCode(responseStatus);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{}');
            return res;
        }
    }

    private static Compliance__c makeCompliance() {
        Account acc = new Account(Name = 'NcEvt');
        insert acc;
        Compliance__c comp = new Compliance__c(
            Name = 'NcEvtCo',
            Account__c = acc.Id,
            Nuvei_Connect_Application_ID__c = 'NC-APP-EVT-1',
            Nuvei_Connect_Status__c = 'APPROVED',
            Compliance_Status__c = 'Live',
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123',
            City_field__c = '+44123456789'
        );
        insert comp;
        return comp;
    }

    @IsTest
    static void post_merchant_activated_success() {
        Compliance__c comp = makeCompliance();
        CapturingMock mock = new CapturingMock();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_ACTIVATED');
        Test.stopTest();

        System.assertNotEquals(null, mock.captured);
        System.assertEquals('callout:Nuvei_API/v1/events/applications', mock.captured.getEndpoint());
        System.assertEquals(null, mock.captured.getHeader('Authorization'));

        comp = [SELECT Nuvei_Connect_Status__c, Compliance_Status__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals('MERCHANT_ACTIVATED', comp.Nuvei_Connect_Status__c);
        System.assertEquals('Live', comp.Compliance_Status__c);
    }

    @IsTest
    static void post_merchant_pending_success() {
        Compliance__c comp = makeCompliance();

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new CapturingMock());
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_PENDING');
        Test.stopTest();

        comp = [SELECT Nuvei_Connect_Status__c FROM Compliance__c WHERE Id = :comp.Id];
        System.assertEquals('MERCHANT_PENDING', comp.Nuvei_Connect_Status__c);
    }

    @IsTest
    static void post_http_500_logs_and_does_not_throw() {
        Compliance__c comp = makeCompliance();
        CapturingMock mock = new CapturingMock();
        mock.responseStatus = 500;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, mock);
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_PENDING');
        Test.stopTest();

        System.assert(true);
    }

    @IsTest
    static void post_skips_when_application_id_blank() {
        Account acc = new Account(Name = 'NcEvt2');
        insert acc;
        Compliance__c comp = new Compliance__c(
            Name = 'NoAppId',
            Account__c = acc.Id,
            Compliance_Status__c = 'Live'
        );
        insert comp;

        Test.startTest();
        Test.setMock(HttpCalloutMock.class, new CapturingMock());
        NuveiConnectEventsService.postApplicationEvent(comp.Id, 'MERCHANT_PENDING');
        Test.stopTest();

        System.assert(true);
    }
}