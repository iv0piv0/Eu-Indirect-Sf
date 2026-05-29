@isTest
public class TestMerchantOnboardingController {
  
  @testSetup
  static void setup() {
    // Creating test data - Contact
    Contact testContact = new Contact(
      FirstName = 'John',
      LastName = 'Doe',
      Email = 'johndoe@example.com',
      MailingStreet = '456 Broadway',
      MailingCity = 'New York',
      MailingCountry = 'United States',
      MailingPostalCode = '10002',
      Phone = '212-555-6789'
    );
    insert testContact;

    // Creating test data - Compliance
    Compliance__c compliance = new Compliance__c(
      Name = 'Test Company',
      Registered_Country__c = 'United States',
      Registered_Street__c = '123 Main St',
      Registered_City__c = 'New York',
      Registered_Zip_Postal_Code__c = '10001',
      VAT_Number__c = '123456789',
      City_field__c = '212-555-1234',
      MSA_Effective_Date__c = Date.today(),
      State_USA__c = 'Nevada',
      Primary_Contact__c = testContact.Id,
      Visa_Payfac_ID__c = 'VISA123',
      Mastercard_Payfac_ID__c = 'MC123'
    );
    insert compliance;

    // Creating test data - Case
    Case testCase = new Case(
      Company_Profile__c = compliance.Id,
      ContactId = testContact.Id,
      SB_PPP_Username__c = 'testUser',
      SB_PPP_Password__c = 'password123',
      SB_Template__c = 'Ecommerce'
    );
    insert testCase;

    // Creating test data - ExpressConfig
    ExpressConfig__c configTest = new ExpressConfig__c(
      Name= 'testconfig',
      MO_SB_endpoint__c='https://www.test.me',  
      MO_prod_endpoint__c= 'https://www.testProd.me',
      MO_SB_token_endpoint__c='https://www.token.me', 
      MO_prod_token_endpoint__c='https://www.tokenProd.me',
      MO_SB_secret__c='test12314', 
      MO_prod_secret__c='test1234'
    );
    insert configTest;
  }

  public class CreateMerchantCalloutMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
      HttpResponse res = new HttpResponse();
      res.setStatusCode(202);
      res.setBody('{"access_token":"testAccessToken"}');
      return res;
    }
  }

  @isTest
  static void testControllerConstructor() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];
    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);
  }

  @isTest
  static void testCreateSandbox() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);

    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    controller.createSandbox();
    Test.stopTest();
  }

  @isTest
  static void testCreateSandboxPayFac() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    Test.startTest();
    controller.createPayfacSandbox();
    MerchantOnboardingController.sendMerchantRequest(testCase.Id, true, true);

    Test.stopTest();
  }
  @isTest
  static void testCreateProdPayFac() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    Test.startTest();
    controller.createPayfacProduction();
    MerchantOnboardingController.sendMerchantRequest(testCase.Id, true, true);

    Test.stopTest();
  }



  @isTest
  static void testCreateProduction() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);

    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    controller.createProduction();
    Test.stopTest();
  }

  @isTest
  static void testCreateMerchantWithMissingCaseId() {
    ApexPages.StandardController stdController = new ApexPages.StandardController(new Case());
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);
    controller.caseId = null;

    Test.startTest();
    controller.createSandbox();
    Test.stopTest();
  }

  @isTest
  static void testCreateMerchantWithMissingFields() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];

    // Simulate missing fields by setting them to null
    testCase.SB_PPP_Username__c = null;
    testCase.SB_PPP_Password__c = null;
    testCase.SB_Template__c = null;
    testCase.Company_Profile__r.Registered_Street__c = null;
    testCase.Company_Profile__r.Registered_City__c = null;
    testCase.Company_Profile__r.Registered_Country__c = null;
    testCase.Company_Profile__r.Registered_Zip_Postal_Code__c = null;
    testCase.Company_Profile__r.City_field__c = null;
    testCase.Company_Profile__r.Primary_Contact__r.FirstName = null;
    testCase.Company_Profile__r.Primary_Contact__r.LastName = null;
    testCase.Company_Profile__r.Primary_Contact__r.Email = null;
    testCase.Company_Profile__r.Primary_Contact__r.Phone = null;

    update testCase;

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);

    Test.startTest();
    controller.createSandbox();
    Test.stopTest();
  }

  @isTest
  static void testSendMerchantRequest() {
    Case testCase = [
        SELECT Id, Company_Profile__c, Company_Profile__r.Name, Company_Profile__r.Registered_Street__c, 
        Company_Profile__r.Registered_City__c, Company_Profile__r.Registered_Country__c, 
        Company_Profile__r.Registered_Zip_Postal_Code__c, Company_Profile__r.City_field__c, 
        Company_Profile__r.MCC_Code__c, Company_Profile__r.Primary_Contact__r.FirstName, 
        Company_Profile__r.Primary_Contact__r.LastName, Company_Profile__r.Primary_Contact__r.Email, 
        Company_Profile__r.Primary_Contact__r.Phone 
        FROM Case LIMIT 1
    ];
    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    MerchantOnboardingController.sendMerchantRequest(testCase.Id, true, true);
    Test.stopTest();
  }

  @isTest
  static void testGetAccessToken() {
    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    String accessToken = MerchantOnboardingController.getAccessToken('https://www.token.me', 'test12314');
    Test.stopTest();
  }
  @isTest
  static void testCreateMerchantFlow() {
    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());

    List<MerchantOnboardingController.RequestWrapper> requests = new List<MerchantOnboardingController.RequestWrapper>();
    MerchantOnboardingController.RequestWrapper request = new MerchantOnboardingController.RequestWrapper();
    request.caseId = [SELECT Id FROM Case LIMIT 1].Id;
    request.isProd = false;
    request.isPayfac = false;
    requests.add(request);

    List<MerchantOnboardingController.ResponseWrapper> responses = MerchantOnboardingController.createMerchantFromFlow(requests);

    Test.stopTest();
  }

  @isTest
  static void testCreateMerchantWithCompleteData() {
    Case testCase = [SELECT Id FROM Case LIMIT 1];

    ApexPages.StandardController stdController = new ApexPages.StandardController(testCase);
    MerchantOnboardingController controller = new MerchantOnboardingController(stdController);

    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());
    controller.createSandbox();
    Test.stopTest();
  }

  @isTest
  static void testCreateMerchantFromFlowWithProd() {
    Test.startTest();
        Test.setMock(HttpCalloutMock.class, new MultiPurposeMockCallout());

    List<MerchantOnboardingController.RequestWrapper> requests = new List<MerchantOnboardingController.RequestWrapper>();
    MerchantOnboardingController.RequestWrapper request = new MerchantOnboardingController.RequestWrapper();
    request.caseId = [SELECT Id FROM Case LIMIT 1].Id;
    request.isProd = true;
    request.isPayfac = true;
    requests.add(request);

    List<MerchantOnboardingController.ResponseWrapper> responses = MerchantOnboardingController.createMerchantFromFlow(requests);

    Test.stopTest();
  }

  @isTest
  static void testHandleResponse_Prod() {
      Case testCase = [SELECT Id, Company_Profile__c FROM Case LIMIT 1];
      String responseBody = '{"merchant":{"identifiers":{"merchantId":12345,"multiClientId":54321},"name":"MyProdMerchant"},'
          + '"paymentProcessing":{"identifiers":{"clientId":111,"merchantSiteId":222},"credentials":{"clientLogin":"login123","clientPassword":"pass123","activationLink":"https://activate.com"}}}';
      
      Test.startTest();
      MerchantOnboardingController.handleResponse(responseBody, testCase, true); // isProd = true
      Test.stopTest();
  
      // Validate the GW_Name__c record was created
      GW_Name__c gw = [SELECT Id, Name, Client_ID__c, Merchant_ID__c, GW_Login_ID__c FROM GW_Name__c WHERE Compliance__c = :testCase.Company_Profile__c LIMIT 1];
      System.assertEquals('MyProdMerchant', gw.Name);
      System.assertEquals('12345', gw.Merchant_ID__c);
      System.assertEquals('login123', gw.GW_Login_ID__c);
  }
  @isTest
static void testHandleResponse_Sandbox() {
    Case testCase = [SELECT Id, Company_Profile__c, SB_MultiClient_Name__c, Create_Account_Response__c FROM Case LIMIT 1];
    String responseBody = '{"merchant":{"identifiers":{"merchantId":99999,"multiClientId":88888},"name":"MySandboxMerchant"},'
        + '"paymentProcessing":{"identifiers":{"clientId":777,"merchantSiteId":666},"credentials":{"clientLogin":"sandboxLogin","clientPassword":"sandboxPass","activationLink":"https://sandbox.com"}}}';

    Test.startTest();
    MerchantOnboardingController.handleResponse(responseBody, testCase, false); // isProd = false
    Test.stopTest();

    Case updated = [SELECT SB_MultiClient_Name__c, SB_Client_ID__c, SB_GW_Login_ID__c, Activation_Link__c FROM Case WHERE Id = :testCase.Id];
}
  public class EmptyTokenCalloutMock implements HttpCalloutMock {
    public HTTPResponse respond(HTTPRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setBody('{}'); // intentionally no access_token
        return res;
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // NEW TESTS — coverage for uncovered branches
  // ═══════════════════════════════════════════════════════════════════════

  // ── Additional mocks ───────────────────────────────────────────────────

  private class TokenFailMock implements HttpCalloutMock {
      public HttpResponse respond(HttpRequest req) {
          HttpResponse res = new HttpResponse();
          res.setStatusCode(401);
          res.setBody('{"error":"unauthorized"}');
          return res;
      }
  }

  private class TokenSuccessMock implements HttpCalloutMock {
      public HttpResponse respond(HttpRequest req) {
          HttpResponse res = new HttpResponse();
          res.setStatusCode(200);
          res.setBody('{"access_token":"tok123"}');
          return res;
      }
  }

  // ── getAccessTokenWithDetails — all branches ───────────────────────────

  @isTest
  static void testGetAccessTokenWithDetails_BlankEndpoint() {
      MerchantOnboardingController.TokenResult r =
          MerchantOnboardingController.getAccessTokenWithDetails('', 'someSecret');
      System.assertEquals(null, r.accessToken);
      System.assert(r.errorMessage.contains('Token endpoint is blank'));
      System.assertEquals(false, r.isSuccess());
  }

  @isTest
  static void testGetAccessTokenWithDetails_BlankSecret() {
      MerchantOnboardingController.TokenResult r =
          MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', '');
      System.assertEquals(null, r.accessToken);
      System.assert(r.errorMessage.contains('Client secret is blank'));
      System.assertEquals(false, r.isSuccess());
  }

  @isTest
  static void testGetAccessTokenWithDetails_Non200Response() {
      Test.setMock(HttpCalloutMock.class, new TokenFailMock());
      Test.startTest();
      MerchantOnboardingController.TokenResult r =
          MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', 'secret');
      Test.stopTest();
      System.assertEquals(401, r.statusCode);
      System.assert(r.errorMessage.contains('returned HTTP 401'));
      System.assertEquals(false, r.isSuccess());
  }

  @isTest
  static void testGetAccessTokenWithDetails_EmptyAccessToken() {
      Test.setMock(HttpCalloutMock.class, new EmptyTokenCalloutMock());
      Test.startTest();
      MerchantOnboardingController.TokenResult r =
          MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', 'secret');
      Test.stopTest();
      System.assertEquals(200, r.statusCode);
      System.assert(r.errorMessage.contains('did not contain'));
      System.assertEquals(false, r.isSuccess());
  }

  @isTest
  static void testGetAccessTokenWithDetails_Success() {
      Test.setMock(HttpCalloutMock.class, new TokenSuccessMock());
      Test.startTest();
      MerchantOnboardingController.TokenResult r =
          MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', 'secret');
      Test.stopTest();
      System.assertEquals('tok123', r.accessToken);
      System.assertEquals(200, r.statusCode);
      System.assertEquals(true, r.isSuccess());
  }

  // ── TokenResult.isSuccess ──────────────────────────────────────────────

  @isTest
  static void testTokenResult_isSuccess() {
      MerchantOnboardingController.TokenResult r = new MerchantOnboardingController.TokenResult();
      System.assertEquals(false, r.isSuccess(), 'Empty token should not be success');

      r.accessToken = 'tok123';
      System.assertEquals(true, r.isSuccess(), 'Non-blank token should be success');

      r.accessToken = '';
      System.assertEquals(false, r.isSuccess(), 'Blank token should not be success');
  }

  // ── bumpTrackFRetryCount ───────────────────────────────────────────────

  @isTest
  static void testBumpTrackFRetryCount_Normal() {
      Compliance__c comp = [SELECT Id FROM Compliance__c LIMIT 1];

      Test.startTest();
      MerchantOnboardingController.bumpTrackFRetryCount(comp.Id);
      Test.stopTest();

      comp = [SELECT Track_F_Retry_Count__c FROM Compliance__c WHERE Id = :comp.Id];
      System.assertEquals(1, comp.Track_F_Retry_Count__c,
          'Retry count should increment from null/0 to 1');
  }

  @isTest
  static void testBumpTrackFRetryCount_NullId() {
      Test.startTest();
      MerchantOnboardingController.bumpTrackFRetryCount(null);
      Test.stopTest();
      // Should exit gracefully — no exception
  }

  // ── sendErrorEmail ─────────────────────────────────────────────────────

  @isTest
  static void testSendErrorEmail_BlankRecipient() {
      Case testCase = [SELECT Id, Company_Profile__c FROM Case LIMIT 1];

      Test.startTest();
      MerchantOnboardingController.sendErrorEmail('', testCase, 'error body');
      MerchantOnboardingController.sendErrorEmail(null, testCase, 'error body');
      Test.stopTest();
      // Should exit gracefully
  }

  @isTest
  static void testSendErrorEmail_WithRecipient() {
      Case testCase = [SELECT Id, Company_Profile__c FROM Case LIMIT 1];

      Test.startTest();
      MerchantOnboardingController.sendErrorEmail('test@test.com', testCase, 'error body');
      Test.stopTest();
      // Test.isRunningTest prevents actual send
  }

  // ── sendMerchantRequest overload (2-param) ─────────────────────────────


  // ── createMerchantFromFlow with missing fields ─────────────────────────

  @isTest
  static void testCreateMerchantFromFlow_MissingFields() {
      Case testCase = [SELECT Id FROM Case LIMIT 1];
      testCase.SB_Template__c = null;
      update testCase;

      List<MerchantOnboardingController.RequestWrapper> requests = new List<MerchantOnboardingController.RequestWrapper>();
      MerchantOnboardingController.RequestWrapper request = new MerchantOnboardingController.RequestWrapper();
      request.caseId = testCase.Id;
      request.isProd = false;
      request.isPayfac = false;
      requests.add(request);

      Test.startTest();
      List<MerchantOnboardingController.ResponseWrapper> responses =
          MerchantOnboardingController.createMerchantFromFlow(requests);
      Test.stopTest();

      System.assertNotEquals(null, responses[0].missingFields,
          'Should return missing fields when SB_Template is blank');
      System.assert(responses[0].missingFields.size() > 0);
  }
  private class TokenBadJsonMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(200);
        res.setBody('NOT_JSON');
        return res;
    }
}

@isTest
static void testGetAccessTokenWithDetails_BadJsonBody() {
    Test.setMock(HttpCalloutMock.class, new TokenBadJsonMock());
    Test.startTest();
    MerchantOnboardingController.TokenResult r =
        MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', 'secret');
    Test.stopTest();
    System.assertEquals(null, r.accessToken);
    System.assert(r.errorMessage != null && r.errorMessage.contains('could not be parsed'));
}

private class TokenThrowsMock implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest req) {
        throw new System.CalloutException('simulated');
    }
}

@isTest
static void testGetAccessTokenWithDetails_CalloutException() {
    Test.setMock(HttpCalloutMock.class, new TokenThrowsMock());
    Test.startTest();
    MerchantOnboardingController.TokenResult r =
        MerchantOnboardingController.getAccessTokenWithDetails('https://token.endpoint.com', 'secret');
    Test.stopTest();
    System.assertEquals(null, r.accessToken);
    System.assert(r.errorMessage != null && r.errorMessage.contains('CalloutException'));
}
}