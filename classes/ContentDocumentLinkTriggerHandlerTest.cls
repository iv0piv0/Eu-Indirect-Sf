@istest(seealldata=true)
global class ContentDocumentLinkTriggerHandlerTest {
  public static Id RT_ACTION_ITEM_PCI = RecordTypeHelper.getRecordTypeIdByName('Action_Item__c', 'PCI');
  private static Id RT_CASE_CONFIGURATION = RecordTypeHelper.getRecordTypeIdByName('Case', 'Configuration'); // 0121O000001ZXQOQA4
  private static Id RT_CASE_NCP = RecordTypeHelper.getRecordTypeIdByName('Case', 'NCP_Profile_Maintenance'); // 0125Y000001E6FcQAK

  @IsTest
  static void execute() {
    Account testAccount = new Account(Name = 'Test Account');
    insert testAccount;

    Compliance__c testCompliance = new Compliance__c(
      Account__c = testAccount.Id,
      Active__c = true,
      Merchant_Status__c = 'Account Application',
      Management_Approval__c = true,
      Finance_admin_status__c = '',
      MRSI_status__c = ''
    );
    insert testCompliance;

    Action_Item_setting__c setting = new Action_Item_setting__c();
    insert setting;

    Action_item__C ai = new Action_item__C(
      Order__c = 101,
      Status__c = 'Pending',
      description_1__c = 'Please complete your task',
      Description2__c = 'or send it to',
      Name = 'https://cs24.salesforce.com/a1f19000000E6q7',
      Comments__c = 'XXX',
      Received_Date__c = Date.today().addDays(-7),
      Company_Profile__c = testCompliance.Id,
      RecordTypeId = RT_ACTION_ITEM_PCI,
      Setting__c = setting.id,
      Display_As__c = 'Document'
    );
    ai.Company_Profile__c = testCompliance.Id;
    insert ai;

    Test.startTest();

    ContentVersion contentVersion = new ContentVersion(
      Title = 'Test Attachment',
      PathOnClient = 'TestAttachment.txt',
      VersionData = Blob.valueOf('This is a test attachment')
    );
    insert contentVersion;

    List<ContentVersion> contentVersions = [
      SELECT Title, VersionData, ContentDocumentId, FileExtension
      FROM ContentVersion
      WHERE Id = :contentVersion.Id
    ];

    ContentDocumentLink link = new ContentDocumentLink();
    link.LinkedEntityId = ai.Id;
    link.ContentDocumentId = contentVersions[0].ContentDocumentId;
    insert link;

    ContentDocumentLinkTriggerHandler.changeStatus(new List<ContentDocumentLink>{ link });

    Test.stopTest();
  }

  @IsTest
  static void testNaOnboarding() {
    User u = TestUtils.createTestUser('testuser1', 'Operational Managers');

    Account testAccount = new Account(Name = 'Test Account');
    insert testAccount;

    Opportunity newOpp = new Opportunity(
      Name = testAccount.Name + '-Automated',
      CloseDate = System.today() + 90,
      StageName = 'Live',
      Potential_Volume__c = 123,
      Pricing_Commission__c = 10,
      Pricing_Trx_Fee__c = 11,
      Rolling_Reserve__c = 10,
      Charge_Fee__c = 11,
      Set_Up_Fee__c = 10,
      Minimum_Monthly_Fee__c = 10,
      Credit_Fee__c = 10
    );
    insert newOpp;

    Compliance__c testCompliance = new Compliance__c(
      Account__c = testAccount.Id,
      Active__c = true,
      Opportunity__c = newOpp.Id,
      Merchant_Status__c = 'Account Application',
      Management_Approval__c = true,
      Finance_admin_status__c = '',
      MRSI_status__c = '',
      Sales_Rep__c = u.Id,
      Account_Operational_Manager_CP__c = u.Id,
      Account_Manager__c = u.Id,
      Managing_Company__c = 'Nuvei Technologies Inc.'
    );
    insert testCompliance;

    Contact contact = new Contact(Email = 'recipient@example.com', LastName = 'test1');
    insert contact;

    Case testCaseNCP = new Case(
      RecordTypeId = RT_CASE_NCP,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'North America new account',
      Type = 'North America new account',
      // Managing_Company__c = '* Technologies Inc',
      Company_Profile__c = testCompliance.Id
    );

    insert testCaseNCP;
   
    Case testCase = new Case(
      RecordTypeId = RT_CASE_CONFIGURATION,
      ContactId = contact.Id,
      SuppliedEmail = 'test@example.com',
      Status = 'New',
      Origin = 'Email',
      Subject = 'North America new account',
      Type = 'North America new account',
      Related_Case__c = testCaseNCP.Id,
      // Managing_Company__c = '* Technologies Inc',
      Company_Profile__c = testCompliance.Id
    );

    insert testCase;
    Test.startTest();
    ContentVersion contentVersion = new ContentVersion(
      Title = 'Test Attachment',
      PathOnClient = 'TestAttachment.txt',
      VersionData = Blob.valueOf('This is a test attachment'),
      FirstPublishLocationId = testCase.Id
    );
    insert contentVersion;

    // List<ContentVersion> contentVersions = [
    //   SELECT Title, VersionData, ContentDocumentId, FileExtension
    //   FROM ContentVersion
    //   WHERE Id = :contentVersion.Id
    // ];

    // ContentDocumentLink link = new ContentDocumentLink();
    // link.LinkedEntityId = ai.Id;
    // link.ContentDocumentId = contentVersions[0].ContentDocumentId;
    // insert link;
    Test.stopTest();
  }
}
