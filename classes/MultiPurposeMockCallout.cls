@isTest
public class MultiPurposeMockCallout implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();

        if (req.getEndpoint() != null && req.getEndpoint().contains('token')) {
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"access_token": "mockAccessToken"}');
        } else if (req.getEndpoint() != null && req.getEndpoint().contains('/events/')) {
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{}');
        } else {
            res.setStatusCode(202);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"merchant":{"name":"Mock","identifiers":{"merchantId":"123","multiClientId":"321"}},'
                + '"paymentProcessing":{"name":"MockPP","identifiers":{"clientId":"111","merchantSiteId":"222"},'
                + '"credentials":{"clientLogin":"mockLogin","clientPassword":"mockPass","activationLink":"https://mock-activate.com"}}}');
        }

        return res;
    }
}