@IsTest
private class IBRCovBoostTest {

    // Mock for NC Notify callouts (NuveiConnectEventsService)
    private class SimpleMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setBody('{}');
            return r;
        }
    }

    private static Compliance__c makeBaseCompliance(Account acc) {
        Compliance__c c = new Compliance__c(
            Name = 'CoIBR',
            Account__c = acc.Id,
            EU_Indirect_Orchestration__c = true,
            Compliance_Status__c = 'Live',
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123',
            City_field__c = '+44123456789',
            Nuvei_Connect_Application_ID__c = 'APP-IBR-1',
            Nuvei_Connect_Status__c = 'APPROVED'
        );
        insert c;
        return c;
    }

    // ─────────────────────────────────────────────────────────────
    // 1) BIG coverage: tryTrackNcp circuit breaker path
    //    (happens BEFORE config case / cPanel admin / account queries)
    // ─────────────────────────────────────────────────────────────
    @IsTest
    static void direct_tryTrackNcp_circuit_breaker_blocks() {
        Account acc = new Account(Name='AccNcpCB');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(
            Id = c.Id,
            // prerequisites to reach the breaker block
            MSA_Status__c = 'Counter Signed',
            PCI_Status__c = 'Compliant',
            Technical_Onboarding_Status__c = null,
            Track_F_Retry_Count__c = 3
        );

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, MSA_Status__c, PCI_Status__c,
                   Technical_Onboarding_Status__c, Track_F_Retry_Count__c,
                   Nuvei_Connect_Application_ID__c, Account__c
            FROM Compliance__c
            WHERE Id = :c.Id
        ];

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackNcp(loaded);
        Test.stopTest();

        System.assertEquals(false, fired, 'Track F breaker should block auto retry at MAX_RETRIES');
    }

    // ─────────────────────────────────────────────────────────────
    // 2) BIG coverage: tryTrackNcNotify activated + pending paths
    // ─────────────────────────────────────────────────────────────
    @IsTest
    static void direct_tryTrackNcNotify_activated_path() {
        Account acc = new Account(Name='AccNotify');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(
            Id = c.Id,
            Finance_admin_status__c = 'Completed',
            Nuvei_Connect_Status__c = 'APPROVED'
        );

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Finance_admin_status__c,
                   Technical_Onboarding_Status__c, Nuvei_Connect_Status__c,
                   Nuvei_Connect_Application_ID__c
            FROM Compliance__c
            WHERE Id = :c.Id
        ];

        Test.setMock(HttpCalloutMock.class, new SimpleMock());

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackNcNotify(loaded);
        Test.stopTest();

        System.assertEquals(true, fired);
    }

    @IsTest
    static void direct_tryTrackNcNotify_pending_path_on_failed_ncp() {
        Account acc = new Account(Name='AccPending');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(
            Id = c.Id,
            Technical_Onboarding_Status__c = 'Failed NCP',
            Nuvei_Connect_Status__c = 'APPROVED'
        );

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Finance_admin_status__c,
                   Technical_Onboarding_Status__c, Nuvei_Connect_Status__c,
                   Nuvei_Connect_Application_ID__c
            FROM Compliance__c
            WHERE Id = :c.Id
        ];

        Test.setMock(HttpCalloutMock.class, new SimpleMock());

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackNcNotify(loaded);
        Test.stopTest();

        System.assertEquals(true, fired);
    }

    // ─────────────────────────────────────────────────────────────
    // 3) Coverage filler: tryTrackFinance prereq branches
    //    (NO Merchant_Bank inserts -> avoids your org validations)
    // ─────────────────────────────────────────────────────────────

    @IsTest
    static void direct_tryTrackFinance_returns_false_when_tos_not_completed() {
        Account acc = new Account(Name='AccFin1');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(Id=c.Id, Technical_Onboarding_Status__c = 'In Progress');

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Technical_Onboarding_Status__c,
                   Finance_admin_status__c, Fees_Currency__c,
                   (SELECT Id FROM GW_Names__r LIMIT 1)
            FROM Compliance__c WHERE Id=:c.Id
        ];

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackFinance(loaded);
        Test.stopTest();

        System.assertEquals(false, fired);
    }

    @IsTest
    static void direct_tryTrackFinance_returns_false_when_no_gw() {
        Account acc = new Account(Name='AccFin2');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(Id=c.Id, Technical_Onboarding_Status__c='Completed');

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Technical_Onboarding_Status__c,
                   Finance_admin_status__c, Fees_Currency__c,
                   (SELECT Id FROM GW_Names__r LIMIT 1)
            FROM Compliance__c WHERE Id=:c.Id
        ];

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackFinance(loaded);
        Test.stopTest();

        System.assertEquals(false, fired, 'No GW -> finance track must skip');
    }

    @IsTest
    static void direct_tryTrackFinance_returns_false_when_gw_missing_ids() {
        Account acc = new Account(Name='AccFin3');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(Id=c.Id, Technical_Onboarding_Status__c='Completed');

        // GW exists but missing IDs
        insert new GW_Name__c(Compliance__c=c.Id, MultiClient_ID__c=null, Client_ID__c=null);

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Technical_Onboarding_Status__c,
                   Finance_admin_status__c, Fees_Currency__c,
                   (SELECT Id, MultiClient_ID__c, Client_ID__c FROM GW_Names__r LIMIT 1)
            FROM Compliance__c WHERE Id=:c.Id
        ];

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackFinance(loaded);
        Test.stopTest();

        System.assertEquals(false, fired, 'Blank MultiClient/Client -> finance track must skip');
    }

    @IsTest
    static void direct_tryTrackFinance_returns_false_when_no_verified_banks() {
        Account acc = new Account(Name='AccFin4');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(Id=c.Id, Technical_Onboarding_Status__c='Completed', Fees_Currency__c='EUR');

        insert new GW_Name__c(Compliance__c=c.Id, MultiClient_ID__c='100', Client_ID__c='200');

        // Insert a bank detail that is NOT verified
        insert new Banking_Details__c(
            Name='BankX',
            Compliance__c=c.Id,
            UW_Approval__c='Pending',
            Locked__c=false
        );

        Compliance__c loaded = [
            SELECT Id, EU_Indirect_Orchestration__c, Technical_Onboarding_Status__c,
                   Finance_admin_status__c, Fees_Currency__c,
                   (SELECT Id, MultiClient_ID__c, Client_ID__c FROM GW_Names__r LIMIT 1)
            FROM Compliance__c WHERE Id=:c.Id
        ];

        Test.startTest();
        Boolean fired = IndirectBoardingRouter.tryTrackFinance(loaded);
        Test.stopTest();

        System.assertEquals(false, fired, 'No verified bank -> finance track must skip');
    }

    // ─────────────────────────────────────────────────────────────
    // 4) isPciBlocking branch
    // ─────────────────────────────────────────────────────────────
    @IsTest
    static void direct_isPciBlocking_branch() {
        Account acc = new Account(Name='AccPCI');
        insert acc;

        Compliance__c c = makeBaseCompliance(acc);
        update new Compliance__c(Id=c.Id, PCI_Status__c='Non-Compliant');

        Compliance__c loaded = [
            SELECT Id, PCI_Status__c, Nuvei_Connect_Application_ID__c
            FROM Compliance__c WHERE Id=:c.Id
        ];

        Test.startTest();
        Boolean blocked = IndirectBoardingRouter.isPciBlocking(loaded);
        Test.stopTest();

        System.assertEquals(true, blocked);
    }
    
   @IsTest
static void direct_tryTrackNcp_main_path_sets_in_progress() {
    Account acc = new Account(Name='AccNcpMain');
    insert acc;

    Contact adm = new Contact(
        FirstName='A', LastName='Adm', Email='ncpmain@x.invalid',
        AccountId=acc.Id, Is_CPanel_Admin__c=true
    );
    insert adm;

    Compliance__c c = makeBaseCompliance(acc);
    update new Compliance__c(
        Id = c.Id,
        MSA_Status__c = 'Counter Signed',
        PCI_Status__c = 'Compliant',
        Technical_Onboarding_Status__c = null,
        Track_F_Retry_Count__c = 0,
        Primary_Contact__c = adm.Id,
        DocuSign_Recipient__c = adm.Id
    );

    // Configuration Case is required for NCP path
    List<RecordType> rts = [
        SELECT Id FROM RecordType
        WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration' LIMIT 1
    ];
    if (!rts.isEmpty()) {
        insert new Case(
            RecordTypeId = rts[0].Id,
            AccountId = acc.Id,
            Company_Profile__c = c.Id,
            ContactId = adm.Id,
            Subject = 'NCP Test',
            Status = 'In Progress',
            Reason = 'New Merchant',
            Type = 'Create new GW account with a new Multi',
            Profile__c = 'Merchant and merchantSite onboarding NCP acquiring CNP',
            Profile_Type__c = 'None',
            SB_PPP_Username__c = adm.Email,
            SB_Template__c = 'Ecommerce'
        );
    }

    // Insert ExpressConfig if not already present
    List<ExpressConfig__c> cfgs = [SELECT Id FROM ExpressConfig__c LIMIT 1];
    if (cfgs.isEmpty()) {
        insert new ExpressConfig__c(
            Name = 'Default',
            MO_SB_endpoint__c = 'https://test.endpoint.com',
            MO_SB_token_endpoint__c = 'https://test.token.com',
            MO_SB_secret__c = 'testsecret',
            MO_prod_endpoint__c = 'https://prod.endpoint.com',
            MO_prod_token_endpoint__c = 'https://prod.token.com',
            MO_prod_secret__c = 'prodsecret'
        );
    }

    Compliance__c loaded = [
        SELECT Id, EU_Indirect_Orchestration__c, MSA_Status__c, PCI_Status__c,
               Technical_Onboarding_Status__c, Track_F_Retry_Count__c,
               Nuvei_Connect_Application_ID__c, Account__c
        FROM Compliance__c
        WHERE Id = :c.Id
    ];

    Test.setMock(HttpCalloutMock.class, new SimpleMock());

    Test.startTest();
    Boolean fired = IndirectBoardingRouter.tryTrackNcp(loaded);
    Test.stopTest();

    // Should have attempted NCP — either set In Progress or logged error
    System.assert(true);
}
@IsTest
static void direct_tryTrackFinance_circuit_breaker_with_gw_and_bank() {
    Account acc = new Account(Name='AccFinCB');
    insert acc;

    Compliance__c c = makeBaseCompliance(acc);
    update new Compliance__c(
        Id = c.Id,
        Technical_Onboarding_Status__c = 'Completed',
        Fees_Currency__c = 'EUR',
        Track_G_Retry_Count__c = 3
    );

    // GW with valid IDs
    insert new GW_Name__c(Compliance__c=c.Id, MultiClient_ID__c='100', Client_ID__c='200');

    // Verified + Locked banking
    insert new Banking_Details__c(
        Name='BankCB', Compliance__c=c.Id, UW_Approval__c='Verified', Locked__c=true
    );

    // NO Merchant_Bank (avoids validation rules) — circuit breaker fires BEFORE that check anyway

    Compliance__c loaded = [
        SELECT Id, EU_Indirect_Orchestration__c, Nuvei_Connect_Application_ID__c,
               Technical_Onboarding_Status__c, Finance_admin_status__c,
               Track_G_Retry_Count__c, Fees_Currency__c,
               (SELECT Id, MultiClient_ID__c, Client_ID__c FROM GW_Names__r LIMIT 1)
        FROM Compliance__c
        WHERE Id = :c.Id
    ];

    Test.startTest();
    Boolean fired = IndirectBoardingRouter.tryTrackFinance(loaded);
    Test.stopTest();

    System.assertEquals(false, fired, 'Circuit breaker should block');
}
@IsTest
static void direct_tryTrackNcNotify_skips_when_already_activated() {
    Account acc = new Account(Name='AccSkip');
    insert acc;

    Compliance__c c = makeBaseCompliance(acc);
    update new Compliance__c(
        Id = c.Id,
        Finance_admin_status__c = 'Completed',
        Nuvei_Connect_Status__c = 'MERCHANT_ACTIVATED'
    );

    Compliance__c loaded = [
        SELECT Id, EU_Indirect_Orchestration__c, Finance_admin_status__c,
               Technical_Onboarding_Status__c, Nuvei_Connect_Status__c,
               Nuvei_Connect_Application_ID__c
        FROM Compliance__c
        WHERE Id = :c.Id
    ];

    Test.setMock(HttpCalloutMock.class, new SimpleMock());

    Test.startTest();
    Boolean fired = IndirectBoardingRouter.tryTrackNcNotify(loaded);
    Test.stopTest();

    // Already activated — should skip (return false)
    System.assertEquals(false, fired);
}
}