@IsTest
private class BoardingErrorLogServiceTest {

    // ── Helpers ──────────────────────────────────────────────────────────

    private static Compliance__c makeCompliance() {
        Account acc = new Account(Name = 'LogAcc');
        insert acc;
        Compliance__c comp = new Compliance__c(
            Name = 'LogCo',
            Account__c = acc.Id,
            Nuvei_Connect_Application_ID__c = 'LOG-APP-1',
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

    private static List<Execution_Log__c> rowsFor(Id complianceId) {
        return [
            SELECT Class_Name__c, Method_Name__c, Note__c, Description__c,
                   Path__c, Payload__c, Status_Code__c, Type__c,
                   Initiated_By__c, Related_Record_Id__c, CreatedDate
            FROM Execution_Log__c
            WHERE Related_Record_Id__c = :String.valueOf(complianceId)
            ORDER BY CreatedDate ASC
        ];
    }

    // ── logError happy path ─────────────────────────────────────────────

    @IsTest
    static void logError_inserts_row_with_full_field_mapping() {
        Compliance__c comp = makeCompliance();

        Test.startTest();
        BoardingErrorLogService.logError(
            'TrackDMsaConga',
            'failWithLog',
            comp.Id,
            'LOG-APP-1',
            'Track D: MSA Generation (Conga + DocuSign)',
            'Conga template missing',
            new DmlException('synthetic'),
            '{"sample":"payload"}'
        );
        Test.stopTest();

        List<Execution_Log__c> rows = rowsFor(comp.Id);
        System.assertEquals(1, rows.size(), 'Exactly one Execution_Log row inserted');
        Execution_Log__c r = rows[0];

        System.assertEquals('TrackDMsaConga', r.Class_Name__c);
        System.assertEquals('failWithLog', r.Method_Name__c);
        System.assertEquals('Track D: MSA Generation (Conga + DocuSign)', r.Note__c);
        System.assertEquals('Error', r.Type__c);
        System.assertEquals(500, r.Status_Code__c, 'Default error status code');
        System.assertEquals(UserInfo.getUserId(), r.Initiated_By__c);
        System.assertEquals(String.valueOf(comp.Id), r.Related_Record_Id__c);

        // Description must preserve human message + NC App Id + exception type
        System.assert(r.Description__c.contains('Conga template missing'),
            'Description must include the human message');
        System.assert(r.Description__c.contains('NC Application Id: LOG-APP-1'),
            'Description must include the NC application id');
        System.assert(r.Description__c.contains('System.DmlException'),
            'Description must include the exception type');
        System.assert(r.Description__c.contains('synthetic'),
            'Description must include the exception message');

        System.assertNotEquals(null, r.Path__c, 'Stack trace mapped to Path__c');
        System.assertEquals('{"sample":"payload"}', r.Payload__c);
    }

    // ── Append behaviour (insert-only — no upsert anymore) ───────────────

    @IsTest
    static void logError_appends_one_row_per_call_no_upsert() {
        Compliance__c comp = makeCompliance();

        Test.startTest();
        BoardingErrorLogService.logError(
            'TestClass', 'm', comp.Id, 'NC-1', 'Track D', 'first', null, null
        );
        BoardingErrorLogService.logError(
            'TestClass', 'm', comp.Id, 'NC-1', 'Track D', 'second', null, null
        );
        BoardingErrorLogService.logError(
            'TestClass', 'm', comp.Id, 'NC-1', 'Track D', 'third', null, null
        );
        Test.stopTest();

        List<Execution_Log__c> rows = rowsFor(comp.Id);
        System.assertEquals(3, rows.size(),
            'Each logError call must insert a new row (audit trail, not upsert)');
        System.assert(rows[0].Description__c.contains('first'));
        System.assert(rows[1].Description__c.contains('second'));
        System.assert(rows[2].Description__c.contains('third'));
    }

    // ── Null compliance is silently skipped ─────────────────────────────

    @IsTest
    static void logError_with_null_compliance_is_noop() {
        Test.startTest();
        BoardingErrorLogService.logError(
            'TestClass', 'm', null, 'NC-X', 'Track D', 'message', null, null
        );
        Test.stopTest();

        Integer total = [SELECT COUNT() FROM Execution_Log__c WHERE Class_Name__c = 'TestClass'];
        System.assertEquals(0, total,
            'logError must silently skip when complianceId is null (no exception, no row)');
    }

    // ── Log levels: Warning / Info / Success ─────────────────────────────

    @IsTest
    static void logWarning_logInfo_logSuccess_each_create_typed_row() {
        Compliance__c comp = makeCompliance();

        Test.startTest();
        BoardingErrorLogService.logWarning(
            'TestClass', 'mWarn', comp.Id, 'NC-1', 'PCI Gate',
            'Approval delayed but not blocking', '{"k":"v"}'
        );
        BoardingErrorLogService.logInfo(
            'TestClass', 'mInfo', comp.Id, 'NC-1', 'Track H',
            'Skipped — already activated'
        );
        BoardingErrorLogService.logSuccess(
            'TestClass', 'mSuccess', comp.Id, 'NC-1', 'Track G',
            'Finance Admin completed'
        );
        Test.stopTest();

        Map<String, Execution_Log__c> byType = new Map<String, Execution_Log__c>();
        for (Execution_Log__c r : rowsFor(comp.Id)) {
            byType.put(r.Type__c, r);
        }
        System.assert(byType.containsKey('Warning'), 'Warning row inserted');
        System.assertEquals(409, byType.get('Warning').Status_Code__c);
        System.assertEquals('{"k":"v"}', byType.get('Warning').Payload__c);

        System.assert(byType.containsKey('Info'), 'Info row inserted');
        System.assertEquals(204, byType.get('Info').Status_Code__c);

        System.assert(byType.containsKey('Success'), 'Success row inserted');
        System.assertEquals(200, byType.get('Success').Status_Code__c);
    }

    // ── Custom HTTP status code overload ─────────────────────────────────

    @IsTest
    static void log_with_explicit_status_code_overrides_default() {
        Compliance__c comp = makeCompliance();

        Test.startTest();
        BoardingErrorLogService.log(
            BoardingErrorLogService.Level.ERROR,
            'TestClass',
            'mHttp',
            comp.Id,
            'NC-1',
            'Track F: Technical Onboarding (NCP)',
            'NCP returned 502',
            null,
            '{"req":1}',
            502
        );
        Test.stopTest();

        Execution_Log__c r = rowsFor(comp.Id)[0];
        System.assertEquals('Error', r.Type__c);
        System.assertEquals(502, r.Status_Code__c,
            'Explicit status code (e.g. echoed upstream HTTP code) must override the default');
    }

    // ── Helper exposure: enum -> picklist + default codes ────────────────

    @IsTest
    static void picklist_and_defaults_match_object_definition() {
        System.assertEquals('Error',   BoardingErrorLogService.toPicklist(BoardingErrorLogService.Level.ERROR));
        System.assertEquals('Warning', BoardingErrorLogService.toPicklist(BoardingErrorLogService.Level.WARNING));
        System.assertEquals('Info',    BoardingErrorLogService.toPicklist(BoardingErrorLogService.Level.INFO));
        System.assertEquals('Success', BoardingErrorLogService.toPicklist(BoardingErrorLogService.Level.SUCCESS));

        System.assertEquals(500, BoardingErrorLogService.defaultStatusCode(BoardingErrorLogService.Level.ERROR));
        System.assertEquals(409, BoardingErrorLogService.defaultStatusCode(BoardingErrorLogService.Level.WARNING));
        System.assertEquals(204, BoardingErrorLogService.defaultStatusCode(BoardingErrorLogService.Level.INFO));
        System.assertEquals(200, BoardingErrorLogService.defaultStatusCode(BoardingErrorLogService.Level.SUCCESS));
    }

    // ── Description builder edge cases ───────────────────────────────────

    @IsTest
    static void buildDescription_returns_null_when_all_inputs_blank() {
        System.assertEquals(null, BoardingErrorLogService.buildDescription(null, null, null));
        System.assertEquals(null, BoardingErrorLogService.buildDescription('', '', null));
    }

    @IsTest
    static void buildDescription_only_human_message() {
        System.assertEquals('hello', BoardingErrorLogService.buildDescription('hello', null, null));
    }
}