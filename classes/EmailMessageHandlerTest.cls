@isTest
public class EmailMessageHandlerTest {
  private static final Id RT_CASE_CHARGBACK = RecordTypeHelper.getRecordTypeIdByName('Case', 'Chargeback'); // 012Pj0000088kx7IAA
  private static Id RT_CASE_BILLING_DP = RecordTypeHelper.getRecordTypeIdByName('Case', 'Billing_Team_DP'); // 012Pj000006yt4bIAA
  private static Id RT_CASE_PAYAUT_SUPPORT = RecordTypeHelper.getRecordTypeIdByName('Case', 'Payaut_Support'); // 012Pj000007HwjVIAS
  public static Id RT_CASE_PAC = RecordTypeHelper.getRecordTypeIdByName('Case', 'Premium_Accounts_Team');
  public static Id RT_CASE_TS = RecordTypeHelper.getRecordTypeIdByName('Case', 'TechSupport');
  public static Id RT_CASE_PS = RecordTypeHelper.getRecordTypeIdByName('Case', 'PaymentSupport');
  public static Id RT_CASE_APM_IMP = RecordTypeHelper.getRecordTypeIdByName('Case', 'APM_Implementation');
  public static Id RT_CASE_INITIATIVE = RecordTypeHelper.getRecordTypeIdByName('Case', 'Initiative');
  public static Id RT_CASE_GS = RecordTypeHelper.getRecordTypeIdByName('Case', 'Global_Support');
  public static Id RT_CASE_CONFIGURATION = RecordTypeHelper.getRecordTypeIdByName('Case', 'Configuration'); // 0121O000001ZXQOQA4
  public static final Id RT_CASE_IE = RecordTypeHelper.getRecordTypeIdByName('Case', 'Integration_Emails');

  @isTest
  static void testDoNotCleanDuplicateMailToCase() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact1 = new Contact(Email = 'recipient@example.com', LastName = 'test1');

    Contact contact2 = new Contact(Email = 'recipient1@example.com', LastName = 'test2');
    insert new List<Contact>{ contact1, contact2 };

    Case case1 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test Case 1',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case2 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test Case 2',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_TS,
      ContactId = contact2.Id
    );

    insert new List<Case>{ case1, case2 };

    EmailMessage em1 = new EmailMessage(
      ParentId = case1.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em2 = new EmailMessage(
      ParentId = case2.Id,
      FromAddress = 'recipient1@example.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert new List<EmailMessage>{ em1, em2 };
    Test.stopTest();

    // List<CaseComment> comments = [SELECT Id, CommentBody FROM CaseComment WHERE ParentId = :case1.Id];

    // System.assertEquals(1, comments.size());

    List<Case> cases = [SELECT Id, Status FROM Case WHERE Status = 'New' AND Id IN :new List<Id>{ case1.Id, case2.Id }];
    System.assertEquals(2, cases.size());
  }

  @isTest
  static void testCleanDuplicateMailToCase() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact1 = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert new List<Contact>{ contact1 };

    Case case1 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case2 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case3 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    insert new List<Case>{ case1, case2, case3 };

    EmailMessage em1 = new EmailMessage(
      ParentId = case1.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em2 = new EmailMessage(
      ParentId = case2.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em3 = new EmailMessage(
      ParentId = case3.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em1;
    insert em2;
    insert em3;

    Test.stopTest();

    List<CaseComment> comments = [SELECT Id, CommentBody FROM CaseComment];

    System.assertEquals(1, comments.size());

    String expectedComment = 'This case was merged from:';

    System.debug('comments[0].CommentBody' + comments[0].CommentBody);
    System.assertEquals(true, comments[0].CommentBody.contains(expectedComment));

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Status = 'New' AND Id IN :new List<Id>{ case1.Id, case2.Id, case3.Id }
    ];
    System.assertEquals(1, cases.size());
  }

  @isTest
  static void testMergeDuplicateMailToCase() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact1 = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert new List<Contact>{ contact1 };

    Case case1 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case2 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );
    insert new List<Case>{ case1, case2 };

    Case case3 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );
    insert case3;

    EmailMessage em1 = new EmailMessage(
      ParentId = case1.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em2 = new EmailMessage(
      ParentId = case2.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em3 = new EmailMessage(
      ParentId = case3.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier2@example.com>',
      Incoming = true
    );

    insert em1;
    insert em2;
    Test.startTest();
    insert em3;

    Test.stopTest();

    List<CaseComment> comments = [SELECT Id, CommentBody FROM CaseComment];

    System.assertEquals(2, comments.size());

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Status = '*Updated*' AND Id IN :new List<Id>{ case1.Id, case2.Id, case3.Id }
    ];
    System.assertEquals(1, cases.size());
  }

  @isTest
  static void testCleanDuplicateMailToCaseErr() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact1 = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert new List<Contact>{ contact1 };

    Case case1 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case2 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    Case case3 = new Case(
      SuppliedEmail = 'test@example.com',
      Subject = 'Test please ignore - Test8721',
      Origin = 'Email',
      Status = 'New',
      RecordTypeId = RT_CASE_PAC,
      ContactId = contact1.Id
    );

    insert new List<Case>{ case1, case2, case3 };

    EmailMessage em1 = new EmailMessage(
      ParentId = case1.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em2 = new EmailMessage(
      ParentId = case2.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );
    EmailMessage em3 = new EmailMessage(
      ParentId = case3.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test please ignore - Test8721',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    EmailMessageHandler.allRecordsMap = null;

    Test.startTest();
    insert em1;
    insert em2;
    insert em3;

    Test.stopTest();

    List<Execution_Log__c> els = [
      SELECT Id, Class_Name__c, Method_Name__c, Status_Code__c
      FROM Execution_Log__c
      WHERE
        Class_Name__c = 'EmailMessageHandler'
        AND Method_Name__c = 'duplicateEmailToCaseFuture'
        AND Status_Code__c = 400
    ];

    System.assertEquals(3, els.size());
  }

  @isTest
  static void testSendAutoReplyEmailGS() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCase = new Case(
      RecordTypeId = RT_CASE_GS,
      ContactId = contact.Id,
      SuppliedEmail = 'recipient@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'Test1539 Test Case'
    );
    insert testCase;

    EmailMessage em = new EmailMessage(
      ParentId = testCase.Id,
      FromAddress = 'recipient@example.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'enterprise.support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();
  }

  @isTest
  static void testSendAutoReplyEmailBILLING_DP() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCase = new Case(
      RecordTypeId = RT_CASE_BILLING_DP,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'Test1539 Test Case'
    );
    insert testCase;
    EmailMessage em = new EmailMessage(
      ParentId = testCase.Id,
      FromAddress = 'test@test.com',
      CcAddress = 'Billingteam@nuvei.com; fakeEmail@fake.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'Billingteam@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Id = :testCase.Id
    ];
    System.assertEquals('New', cases[0].Status);
  }

  @isTest
  static void testSendAutoReplyEmailPAYAUT_SUPPORT() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact1 = new Contact(Email = 'test@example.com', LastName = 'test1');
    insert contact1;

    Case case1 = new Case(
      RecordTypeId = RT_CASE_PAYAUT_SUPPORT,
      SuppliedEmail = 'test@example.com',
      Subject = 'Test Case 1',
      Origin = 'Email',
      Status = 'New',
      ContactId = contact1.Id
    );

    insert case1;
    EmailMessage em = new EmailMessage(
      ParentId = case1.Id,
      FromAddress = 'test@test.com',
      CcAddress = 'fakeEmail@fake.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'platforms-support@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();
    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Id = :case1.Id
    ];
    System.assertEquals('New', cases[0].Status);
  }

  @isTest
  static void testSendAutoReplyEmailSDKSupport() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCase = new Case(
      RecordTypeId = RT_CASE_BILLING_DP,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'Test1539 Test Case SDK Support'
    );
    insert testCase;
    EmailMessage em = new EmailMessage(
      ParentId = testCase.Id,
      FromAddress = 'test@test.com',
      CcAddress = 'sdksupport@nuvei.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'sdksupport@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Id = :testCase.Id
    ];
    System.assertEquals('New', cases[0].Status);
  }

  @isTest
  static void testSendAutoReplyEmailSoporteLatam() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCase = new Case(
      RecordTypeId = RT_CASE_BILLING_DP,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'Test1539 Test Case SDK Support'
    );
    insert testCase;
    EmailMessage em = new EmailMessage(
      ParentId = testCase.Id,
      FromAddress = 'test@test.com',
      CcAddress = 'soporte-latam@nuvei.com',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = 'soporte-latam@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Id = :testCase.Id
    ];
    System.assertEquals('New', cases[0].Status);
  }

  @isTest
  static void testSendAutoReplyEmailChargeback() {
    EmailMessageHandler.Email_To_Case_New = true;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCase = new Case(
      RecordTypeId = RT_CASE_CHARGBACK,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'Test1539 Test Case SDK Support'
    );
    insert testCase;
    EmailMessage em = new EmailMessage(
      ParentId = testCase.Id,
      FromAddress = 'test@test.com',
      CcAddress = '',
      Subject = 'Test',
      TextBody = 'Test',
      ToAddress = ' chargebacks-latam@nuvei.com',
      ThreadIdentifier = '<test-ThreadIdentifier@example.com>',
      MessageIdentifier = '<test-MessageIdentifier@example.com>',
      Incoming = true
    );

    Test.startTest();
    insert em;
    Test.stopTest();

    List<Case> cases = [
      SELECT Id, Status
      FROM Case
      WHERE Id = :testCase.Id
    ];
    System.assertEquals('New', cases[0].Status);
  }

  @isTest
  static void testUpsertCaseCommentErr() {
    EmailMessageHandler.Email_To_Case_New = true;

    Test.startTest();
    EmailMessageHandler.upsertCaseComment(null, '');
    Test.stopTest();

    List<Execution_Log__c> els = [
      SELECT Id, Class_Name__c, Method_Name__c, Status_Code__c
      FROM Execution_Log__c
      WHERE Class_Name__c = 'EmailMessageHandler' AND Method_Name__c = 'upsertCaseComment' AND Status_Code__c = 400
    ];

    System.assertEquals(1, els.size());
  }
}