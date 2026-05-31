public with sharing class EmailMessageHandler extends ITriggerHandlerImpl {
  // Record Type Ids (resolved at runtime)
  private static final Id RT_CASE_PO = RecordTypeHelper.getRecordTypeIdByName('Case', 'Partnerships_Operations'); // 012Pj000006lp0PIAQ
  private static final Id RT_CASE_IBT = RecordTypeHelper.getRecordTypeIdByName('Case', 'End_User_Inquire'); // 0125Y000001mWtqQAE
  private static final Id RT_CASE_CHARGBACK = RecordTypeHelper.getRecordTypeIdByName('Case', 'Chargeback'); // 012Pj0000088kx7IAA
  private static final Id RT_CASE_PAYAUT_SUPPORT = RecordTypeHelper.getRecordTypeIdByName('Case', 'Payaut_Support'); // 012Pj000007HwjVIAS
  private static final Id RT_CASE_BILLING_DP = RecordTypeHelper.getRecordTypeIdByName('Case', 'Billing_Team_DP'); // 012Pj000006yt4bIAA
  private static final Id RT_CASE_PAC = RecordTypeHelper.getRecordTypeIdByName('Case', 'Premium_Accounts_Team'); // 012Pj0000000CXRIA2
  private static final Id RT_CASE_TS = RecordTypeHelper.getRecordTypeIdByName('Case', 'TechSupport');
  private static final Id RT_CASE_PS = RecordTypeHelper.getRecordTypeIdByName('Case', 'PaymentSupport');
  private static final Id RT_CASE_EAS = RecordTypeHelper.getRecordTypeIdByName('Case', 'Enterprise_Account_Support');
  private static final Id RT_CASE_GS = RecordTypeHelper.getRecordTypeIdByName('Case', 'Global_Support'); //0125Y000002TN6IQAW
  private static final Id RT_CASE_IE = RecordTypeHelper.getRecordTypeIdByName('Case', 'Integration_Emails');
  private static final Id RT_CASE_ONBOARDING = RecordTypeHelper.getRecordTypeIdByName('Case', 'Onboarding');
  private static final Id RT_CASE_KS = RecordTypeHelper.getRecordTypeIdByName('Case', 'KEV_Support'); // 012Pj000002XIwHIAW

  private static Boolean isDuplicateEmailToCaseAlreadyRun = false;
  private static Set<String> NOT_RELEVANT_CASE_STATUSES = new Set<String>{
    'Cancelled',
    'Closed',
    'Closed - Unresponsive'
  };
  private static Set<String> CASE_ORIGIN = new Set<String>{ 'Email', 'Integration Team Email' };
  private static Set<String> CASE_ORIGIN_GS_EXTRA = new Set<String>{
    'Legacy Gateway',
    'TripleSeat',
    'CMS',
    'CMS Partners'
  };

  @TestVisible
  private static Map<String, Block_AutoResponse_Case__mdt> allRecordsMap = Block_AutoResponse_Case__mdt.getAll();

  @TestVisible
  private static Boolean Email_To_Case_New = false;
  public override void afterInsert(Object params) {
    System.debug('EmailMessageHandler-afterInsert before');
    Feature_Flag__mdt flag = Feature_Flag__mdt.getInstance('Email_To_Case_New');
    if ((!Test.isRunningTest() && flag != null && flag.Is_Enabled__c) || (Test.isRunningTest() && Email_To_Case_New))
      duplicateEmailToCase();
    System.debug('EmailMessageHandler-afterInsert after');
  }

  private void duplicateEmailToCase() {
    if (isDuplicateEmailToCaseAlreadyRun) {
      System.debug(
        'EmailMessageHandler - duplicateEmailToCase isDuplicateEmailToCaseAlreadyRun:' +
        isDuplicateEmailToCaseAlreadyRun
      );

      return;
    }

    duplicateEmailToCaseFuture(newRecordMap.keySet());
  }

  public static Map<String, List<String>> ignoreAllMap = new Map<String, List<String>>{
    'Domains' => new List<String>(),
    'Subjects' => new List<String>(),
    'Emails' => new List<String>()
  };
  public static Map<String, List<String>> ignoreAutoEmailMap = new Map<String, List<String>>{
    'Domains' => new List<String>(),
    'Subjects' => new List<String>(),
    'Emails' => new List<String>()
  };
  /**
   * Identifies duplicate Cases created via Email-to-Case by checking the MessageIdentifier.
   * If a duplicate is found, the new Case is marked as 'Cancelled'.
   */
  public static Set<Id> processedEmails = new Set<Id>();
  @future
  private static void duplicateEmailToCaseFuture(Set<Id> newEmailIds) {
    Set<String> messageIdentifiers = new Set<String>();
    Map<String, List<EmailMessage>> emailMap = new Map<String, List<EmailMessage>>();

    try {
      for (Block_AutoResponse_Case__mdt bac : allRecordsMap.values()) {
        // bac.Is_Block_Only_Auto_Res_Email__c
        // Is_Block_Only_Auto_Res_Email__c
        if (String.isNotBlank(bac.Domain__c)) {
          List<String> ignoreDomains = (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap)
            .get('Domains');
          ignoreDomains.add(bac.Domain__c);
          (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap).put('Domains', ignoreDomains);
        }

        if (String.isNotBlank(bac.Subject__c)) {
          List<String> ignoreSubjects = (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap)
            .get('Subjects');
          ignoreSubjects.add(bac.Subject__c);
          (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap).put('Subjects', ignoreSubjects);
        }

        if (String.isNotBlank(bac.Email_Address__c)) {
          List<String> ignoreEmails = (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap)
            .get('Emails');
          ignoreEmails.add(bac.Email_Address__c);
          (bac.Is_Block_Only_Auto_Res_Email__c ? ignoreAutoEmailMap : ignoreAllMap).put('Emails', ignoreEmails);
        }
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture ignoreAutoEmailMap:' + ignoreAutoEmailMap);
      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture ignoreAllMap:' + ignoreAllMap);

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture newEmailIds:' + newEmailIds);

      Set<Id> rtSet = new Set<Id>{
        RT_CASE_PAC,
        RT_CASE_TS,
        RT_CASE_PS,
        RT_CASE_EAS,
        RT_CASE_GS,
        RT_CASE_IE,
        RT_CASE_ONBOARDING,
        RT_CASE_KS,
        RT_CASE_BILLING_DP,
        RT_CASE_PAYAUT_SUPPORT,
        RT_CASE_CHARGBACK,
        RT_CASE_IBT,
        RT_CASE_PO
      };

      // Merge thread - in 30 sec(delete cases that insert in bulk - send to many email and open many cases)
      Set<Id> rtSetEmail = new Set<Id>{ RT_CASE_PAC, RT_CASE_GS, RT_CASE_TS, RT_CASE_PS, RT_CASE_EAS };

      List<EmailMessage> currEmails = [
        SELECT
          MessageIdentifier,
          Incoming,
          ParentId,
          FromName,
          FromAddress,
          ToAddress,
          CcAddress,
          BccAddress,
          Subject,
          TextBody,
          HtmlBody,
          Status,
          MessageDate,
          ThreadIdentifier,
          CreatedDate,
          Parent.RecordTypeId,
          Parent.Status,
          Parent.CreatedDate,
          Parent.CaseNumber,
          Parent.ContactId,
          Parent.Replied_Email_Subject__c,
          Parent.SuppliedEmail,
          Parent.Subject,
          Parent.Origin
        FROM EmailMessage
        WHERE
          Id IN :newEmailIds
          AND Parent.RecordTypeId IN :rtSet
          AND Parent.Status NOT IN :NOT_RELEVANT_CASE_STATUSES
          AND (Parent.Origin IN :CASE_ORIGIN
          OR (Parent.RecordTypeId = :RT_CASE_GS
          AND Parent.Origin IN :CASE_ORIGIN_GS_EXTRA))
        ORDER BY CreatedDate ASC
      ];
      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture currEmails:' + currEmails);

      if (currEmails.size() == 0)
        return;

      Map<Id, EmailMessage> currEmailsMap = new Map<Id, EmailMessage>(currEmails);
      Map<Id, String> caseCommentsToUpsert = new Map<Id, String>();
      List<Case> casesToCancel = new List<Case>();

      Set<Id> currEmailIds = new Set<Id>();
      for (EmailMessage em : currEmails) {
        if (processedEmails.contains(em.Id))
          continue;
        processedEmails.add(em.Id);

        //  Check if the domain Bad
        Integer atIndex = em.FromAddress.indexOf('@');

        String domain = null;

        if (atIndex != -1) {
          domain = em.FromAddress.substring(atIndex);

          if (ignoreAllMap.get('Domains').contains(domain))
            continue;
        }
        if (ignoreAllMap.get('Subjects').contains(em.Subject) || ignoreAllMap.get('Emails').contains(em.FromAddress))
          continue;
        //

        // We only care about Email-to-Case (Incoming) and those with a Parent Case
        if (em.Incoming && em.ParentId != null && em.MessageIdentifier != null) {
          messageIdentifiers.add(em.MessageIdentifier);
          currEmailIds.add(em.Id);
        }
      }
      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture messageIdentifiers:' + messageIdentifiers);

      if (messageIdentifiers.isEmpty()) {
        return;
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture currEmailIds:' + currEmailIds);
      System.debug(
        'EmailMessageHandler - duplicateEmailToCaseFuture NOT_RELEVANT_CASE_STATUSES:' + NOT_RELEVANT_CASE_STATUSES
      );

      //   check if email send to multi email address that open duplicate case
      List<EmailMessage> existingSameEmails = [
        SELECT
          MessageIdentifier,
          ParentId,
          CreatedDate,
          ToAddress,
          subject,
          Parent.Id,
          Parent.RecordTypeId,
          Parent.CaseNumber,
          Parent.Status,
          Parent.Origin
        FROM EmailMessage
        WHERE
          Id NOT IN :currEmailIds
          AND MessageIdentifier IN :messageIdentifiers
          AND Parent.RecordTypeId IN :rtSetEmail
          // AND Parent.Status NOT IN :NOT_RELEVANT_CASE_STATUSES
          AND (Parent.Origin IN :CASE_ORIGIN
          OR (Parent.RecordTypeId = :RT_CASE_GS
          AND Parent.Origin IN :CASE_ORIGIN_GS_EXTRA))
        //   AND Parent.Origin IN :CASE_ORIGIN
        ORDER BY CreatedDate ASC
      ];

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture existingSameEmails:' + existingSameEmails);

      if (existingSameEmails.size() > 0) {
        Set<String> foundIdentifiers = new Set<String>();
        for (EmailMessage existing : existingSameEmails) {
          foundIdentifiers.add(existing.MessageIdentifier);

          if (emailMap.get(existing.MessageIdentifier) == null)
            emailMap.put(existing.MessageIdentifier, new List<EmailMessage>());

          List<EmailMessage> ems = emailMap.get(existing.MessageIdentifier);
          ems.add(existing);
          emailMap.put(existing.MessageIdentifier, ems);
        }
        System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - foundIdentifiers: ' + foundIdentifiers);

        Set<Id> casesIdToCancel = new Set<Id>();
        for (EmailMessage em : currEmails) {
          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - found duplicate case: ' + em.ParentId);
          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - em: ' + em);
          // If the identifier was already found in the database, this Case is a duplicate
          if (emailMap.get(em.MessageIdentifier) != null && emailMap.get(em.MessageIdentifier).size() > 0) {
            //
            // *************** FIND OLD ****************
            //  Check if is the old one
            //  If yes ignore If no delete the case
            List<EmailMessage> ems = emailMap.get(em.MessageIdentifier);
            EmailMessage oldestEm = em;
            for (EmailMessage exEm : ems) {
              System.debug(
                'EmailMessageHandler - duplicateEmailToCaseFuture - oldestEm.Parent.CaseNumber  : ' +
                oldestEm.Parent.CaseNumber
              );
              System.debug(
                'EmailMessageHandler - duplicateEmailToCaseFuture - exEm.Parent.CaseNumber : ' + exEm.Parent.CaseNumber
              );
              if (oldestEm.Parent.CaseNumber > exEm.Parent.CaseNumber) {
                System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - exEm : ' + exEm);
                oldestEm = exEm;
              }
            }

            System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - oldestEm.Id : ' + oldestEm.Id);
            System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - em.Id: ' + em.Id);
            if (oldestEm.Id == em.Id)
              continue;
            // ***************

            casesIdToCancel.add(em.ParentId);
            currEmailsMap.remove(em.Id);

            String existingCaseId = oldestEm.ParentId;

            List<CaseComment> existingComment = [
              SELECT Id, CommentBody, ParentId
              FROM CaseComment
              WHERE ParentId = :existingCaseId
              LIMIT 1
            ];
            System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - existingComment: ' + existingComment);

            String commentId = '';
            if (existingComment != null && existingComment.size() > 0)
              commentId = existingComment[0].Id;

            String fromEmail = '';
            if (em.ToAddress != null)
              fromEmail = em.ToAddress;

            String CommentBody = String.isNotBlank(commentId) ? '\n' : '';
            CommentBody += 'This case was merged from: ' + fromEmail;

            caseCommentsToUpsert.put(existingCaseId, fromEmail);
          }
        }

        System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - casesIdToCancel: ' + casesIdToCancel);
        for (Id cId : casesIdToCancel) {
          casesToCancel.add(
            new Case(Id = cId, Status = 'Cancelled', Int_Sol_Teams_Controlling_Field2__c = 'To be deleted')
          );
        }

        if (!caseCommentsToUpsert.isEmpty()) {
          System.debug(
            'EmailMessageHandler - duplicateEmailToCaseFuture - caseCommentsToUpsert: ' + caseCommentsToUpsert
          );
          upsertCaseComment(caseCommentsToUpsert, 'mergedDuplicate');
        }
      }

      currEmails = currEmailsMap.values();
      System.debug(
        'EmailMessageHandler - duplicateEmailToCaseFuture - CancelNewDuplicateMailToCase: currEmails: ' + currEmails
      );
      caseCommentsToUpsert = new Map<Id, String>();
      List<Case> casesToUpdate = new List<Case>();
      Map<Id, EmailMessage> inputVariables = new Map<Id, EmailMessage>();
      List<EmailMessage> copiedEmails = new List<EmailMessage>();
      if (currEmails.size() > 0) {
        for (EmailMessage em : currEmails) {
          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - em: ' + em);

          Set<Id> rtSetSupport = new Set<Id>{ RT_CASE_PAC, RT_CASE_TS, RT_CASE_PS, RT_CASE_GS };
          Set<Id> rtSetAo = new Set<Id>{
            RT_CASE_EAS,
            RT_CASE_IE,
            RT_CASE_ONBOARDING,
            RT_CASE_KS,
            RT_CASE_BILLING_DP,
            RT_CASE_IBT,
            RT_CASE_PO
          };
          Set<Id> currRtSet = new Set<Id>();

          if (rtSetSupport.contains(em.Parent.RecordTypeId))
            currRtSet.addAll(rtSetSupport);

          if (rtSetAo.contains(em.Parent.RecordTypeId))
            currRtSet.add(em.Parent.RecordTypeId);

          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - casesToCancel: ' + casesToCancel);
          Set<Id> cToCancelIds = new Set<Id>();
          if (casesToCancel.size() > 0)
            cToCancelIds = new Map<Id, Case>(casesToCancel).keySet();
          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - cToCancelIds: ' + cToCancelIds);

          List<EmailMessage> emailMessages = [
            SELECT
              Id,
              MessageIdentifier,
              Incoming,
              ParentId,
              FromName,
              FromAddress,
              ToAddress,
              Subject,
              TextBody,
              HtmlBody,
              Status,
              MessageDate,
              ThreadIdentifier,
              CreatedDate,
              Parent.RecordTypeId,
              Parent.Status,
              Parent.CreatedDate,
              Parent.CaseNumber,
              Parent.ContactId,
              Parent.Replied_Email_Subject__c,
              Parent.SuppliedEmail,
              Parent.Subject,
              Parent.Origin
            FROM EmailMessage
            WHERE
              ParentId != :em.ParentId
              AND ThreadIdentifier = :em.ThreadIdentifier
              AND MessageIdentifier != :em.MessageIdentifier
              AND Parent.Status NOT IN :NOT_RELEVANT_CASE_STATUSES
              AND Parent.RecordTypeId IN :currRtSet
              AND ParentId NOT IN :cToCancelIds
            ORDER BY Parent.CreatedDate ASC
          ];
          System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - emailMessages: ' + emailMessages);

          if (emailMessages.size() > 0) {
            Id mainCaseId = emailMessages[0].ParentId;

            List<Group> mergeCasesQueue = [
              SELECT Id, DeveloperName, Name
              FROM Group
              WHERE DeveloperName = 'Merge_Cases_Queue'
              LIMIT 1
            ];

            Case newC = new Case(
              Id = em.ParentId,
              Status = 'Cancelled',
              Reason = 'Closed as Duplicate',
              Reason__c = 'Closed as Duplicate',
              Related_Case__c = mainCaseId
            );

            if (mergeCasesQueue.size() > 0)
              newC.OwnerId = mergeCasesQueue[0].Id;

            casesToUpdate.add(newC);

            EmailMessage newEmail = em.clone();
            newEmail.ParentId = mainCaseId;
            newEmail.Subject = em.Subject != null
              ? (em.Subject.length() > 255 ? em.Subject.substring(0, 255) : em.Subject)
              : null;

            newEmail.HtmlBody = em.HtmlBody != null
              ? (em.HtmlBody.length() > 32000 ? em.HtmlBody.substring(0, 32000) : em.HtmlBody)
              : null;

            newEmail.TextBody = em.TextBody != null
              ? (em.TextBody.length() > 32000 ? em.TextBody.substring(0, 32000) : em.TextBody)
              : null;
            copiedEmails.add(newEmail);

            caseCommentsToUpsert.put(mainCaseId, em.Parent.CaseNumber);
            inputVariables.put(mainCaseId, emailMessages[0]);
            casesToUpdate.add(new Case(Id = mainCaseId, Status = '*Updated*'));

            System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - em.ParentId:' + em.ParentId);
            currEmailsMap.remove(em.Id);

            System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - currEmailsMap:' + currEmailsMap);
          }
        }
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - caseCommentsToUpsert: ' + caseCommentsToUpsert);
      if (!caseCommentsToUpsert.isEmpty()) {
        upsertCaseComment(caseCommentsToUpsert, 'closedDuplicate');
      }

      if (casesToCancel.size() > 0) {
        list<Case> cToCancel = new Map<Id, Case>(casesToCancel).values();
        casesToUpdate.addAll(cToCancel);
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - casesToUpdate: ' + casesToUpdate);
      if (casesToUpdate.size() > 0) {
        // update casesToUpdate;
        List<Database.SaveResult> results = Database.update(casesToUpdate, false);
        List<String> errorMessages = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
          Database.SaveResult sr = results[i];

          if (!sr.isSuccess()) {
            // Collect all error details for the current record
            List<String> currentRecordErrors = new List<String>();
            for (Database.Error err : sr.getErrors()) {
              currentRecordErrors.add(err.getStatusCode() + ': ' + err.getMessage());
            }

            // Identify the record ID from the result or the original list
            Id recordId = sr.getId() != null ? sr.getId() : casesToUpdate[i].Id;
            errorMessages.add('Record ' + recordId + ': ' + String.join(currentRecordErrors, ', '));
          }
        }

        // If any errors occurred (including row locks), create one consolidated log
        if (errorMessages.size() > 0) {
          Boolean isInfo = false;

          String Accounts_Operations_VR = 'You cannot change the status when the case owner is Accounts_Operations - Please assign an owner please';
          for (String err : errorMessages) {
            if (err.contains(Accounts_Operations_VR))
              isInfo = true;
            else {
              isInfo = false;
              break;
            }
          }

          Execution_Log__c el = new Execution_Log__c(
            Class_Name__c = 'EmailMessageHandler',
            Initiated_By__c = UserInfo.getUserId(),
            Method_Name__c = 'duplicateEmailToCaseFuture casesToUpdate',
            Payload__c = JSON.serialize(casesToUpdate),
            Description__c = String.join(errorMessages, '\n'),
            Status_Code__c = 400,
            Type__c = isInfo ? 'Info' : 'Error'
          );

          WithoutSharingUtils.insertRecord(el);
        }
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - currEmailsMap: ' + currEmailsMap);
      for (EmailMessage emRemained : currEmailsMap.values()) {
        Integer olderMessagesCount = [
          SELECT COUNT()
          FROM EmailMessage
          WHERE
            (ThreadIdentifier = :emRemained.ThreadIdentifier
            OR ParentId = :emRemained.ParentId)
            AND MessageDate < :emRemained.MessageDate
          LIMIT 1
        ];
        if (olderMessagesCount == 0)
          inputVariables.put(emRemained.ParentId, emRemained);
      }

      System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - inputVariables: ' + inputVariables);
      if (!inputVariables.isEmpty()) {
        autoResponse(inputVariables);

        System.debug('EmailMessageHandler - duplicateEmailToCaseFuture - copiedEmails: ' + copiedEmails);
        if (!copiedEmails.isEmpty()) {
          isDuplicateEmailToCaseAlreadyRun = true;
          System.debug(
            'EmailMessageHandler - duplicateEmailToCaseFuture set isDuplicateEmailToCaseAlreadyRun:' +
            isDuplicateEmailToCaseAlreadyRun
          );
          insert copiedEmails;
        }
      }
    } catch (Exception e) {
      System.debug(
        'EmailMessageHandler - duplicateEmailToCaseFuture- ERROR: ' + e.getMessage() + e.getStackTraceString()
      );
      Execution_Log__c el = new Execution_Log__c(
        Class_Name__c = 'EmailMessageHandler',
        Initiated_By__c = UserInfo.getUserId(),
        Method_Name__c = 'duplicateEmailToCaseFuture',
        Payload__c = JSON.serialize(newEmailIds),
        Description__c = e.getMessage(),
        Path__c = e.getStackTraceString(),
        Related_Record_Id__c = '',
        Status_Code__c = 400,
        Type__c = 'Error'
      );

      WithoutSharingUtils.insertRecord(el);
    }
  }

  /**
   * @description Upserts a CaseComment by id if provided; otherwise inserts a new comment.
   * @since 2025-02-11
   */
  public static void upsertCaseComment(Map<Id, String> dataByCase, String type) {
    try {
      System.debug('EmailMessageHandler - upsertCaseComment - dataByCase: ' + dataByCase);
      System.debug('EmailMessageHandler - upsertCaseComment - type: ' + type);

      List<CaseComment> commentsToUpsert = new List<CaseComment>();

      for (String cId : dataByCase.keySet()) {
        System.debug('EmailMessageHandler - upsertCaseComment - cId: ' + cId);

        CaseComment comment = new CaseComment();
        String CommentBody = '';

        String CommentBodyToExist = type == 'mergedDuplicate'
          ? '%This case was merged from:%'
          : '%This case get email from another case that cancelled%';

        System.debug('EmailMessageHandler - upsertCaseComment - CommentBodyToExist: ' + CommentBodyToExist);
        List<CaseComment> existingComment = [
          SELECT Id, CommentBody, ParentId
          FROM CaseComment
          WHERE ParentId = :cId AND CommentBody LIKE :CommentBodyToExist
          ORDER BY CreatedDate DESC
          LIMIT 1
        ];

        if (existingComment.size() > 0)
          comment.Id = existingComment[0].Id;
        else
          comment.ParentId = cId;

        if (type == 'mergedDuplicate') {
          System.debug('EmailMessageHandler - upsertCaseComment- existingComment: ' + existingComment);

          String fromEmail = dataByCase.get(cId);

          CommentBody = comment.Id != null ? '\n' : '';
          CommentBody += 'This case was merged from: ' + fromEmail;
        }

        if (type == 'closedDuplicate') {
          String caseNumber = dataByCase.get(cId);

          commentBody = 'This case get email from another case that cancelled - ' + caseNumber;

          if (comment.Id != null)
            commentBody = existingComment[0].CommentBody + ', ' + caseNumber;
        }

        System.debug('EmailMessageHandler - upsertCaseComment - comment: ' + comment);
        if (String.isNotBlank(CommentBody)) {
          comment.CommentBody = CommentBody;
          commentsToUpsert.add(comment);
        }
      }

      if (commentsToUpsert.size() > 0)
        upsert commentsToUpsert;
    } catch (Exception e) {
      System.debug('EmailMessageHandler - Error inserting CaseComment: ' + e.getMessage());
      System.debug('EmailMessageHandler - Error inserting CaseComment: ' + e.getStackTraceString());

      Execution_Log__c el = new Execution_Log__c(
        Class_Name__c = 'EmailMessageHandler',
        Initiated_By__c = UserInfo.getUserId(),
        Method_Name__c = 'upsertCaseComment',
        Payload__c = 'casesMap: ' + JSON.serialize(dataByCase) + ' , type: ' + type,
        Description__c = e.getMessage(),
        Path__c = e.getStackTraceString(),
        Related_Record_Id__c = '',
        Status_Code__c = 400,
        Type__c = 'Error'
      );

      WithoutSharingUtils.insertRecord(el);
    }
  }

  /**
   * @description Sends auto-reply emails per record type using org-wide addresses and last inbound context.
   * @since 2025-02-27
   */
  public static void autoResponse(Map<Id, EmailMessage> emailMessageMap) {
    System.debug('EmailMessageHandler - autoResponse - emailMessageMap: ' + emailMessageMap);

    List<EmailMessage> ems = emailMessageMap.values();

    for (EmailMessage em : ems) {
      System.debug('EmailMessageHandler - autoResponse - em: ' + em);
      Case currCaseToUpdate = new Case(Id = em.ParentId);

      Map<Id, String> EmailTemplateNameByID = new Map<Id, String>{
        RT_CASE_GS => 'New_case_Global_Support',
        RT_CASE_PAC => 'Premium_Accounts_Case_Created',
        RT_CASE_TS => 'TechSupport_auto_reply',
        RT_CASE_PS => 'PaymentSupport_Holiday',
        RT_CASE_EAS => 'New_case_Accounts_Operations',
        RT_CASE_IE => 'Auto_Reply_Integrations_Emails_SDK_Support',
        RT_CASE_ONBOARDING => 'Auto_Response_Email_Onboarding',
        RT_CASE_PAYAUT_SUPPORT => 'Payout_Case_Creation',
        RT_CASE_BILLING_DP => 'Billing_Team_DP_Case_Created_Reply',
        RT_CASE_CHARGBACK => 'Chargeback_Case_Creation'
      };

      Map<String, object> inputVariables = new Map<String, object>{ 'IsNeedGetData' => true };

      Integer atIndex = em.FromAddress.indexOf('@');

      String domain = null;

      if (atIndex != -1) {
        domain = em.FromAddress.substring(atIndex);

        if (ignoreAutoEmailMap.get('Domains').contains(domain))
          continue;
      }
      if (
        ignoreAutoEmailMap.get('Subjects').contains(em.Subject) ||
        ignoreAutoEmailMap.get('Emails').contains(em.FromAddress)
      )
        continue;

      System.debug('EmailMessageHandler - c.Id: ' + em.ParentId);

      currCaseToUpdate.Replied_Email_Subject__c = (em.Subject == null
        ? 'Re: '
        : (em.Subject.contains('Re:') && em.Subject.length() < 251 ? '' : 'Re: ') + em.Subject);

      currCaseToUpdate.Replied_Email_Subject__c = currCaseToUpdate.Replied_Email_Subject__c.length() > 255
        ? currCaseToUpdate.Replied_Email_Subject__c.substring(0, 255)
        : currCaseToUpdate.Replied_Email_Subject__c;

      update currCaseToUpdate;

      System.debug('EmailMessageHandler - sendEmail: ' + em.Parent.Subject);

      inputVariables.put('TemplateIdOrName', (String) EmailTemplateNameByID.get(em.Parent.RecordTypeId));
      inputVariables.put('ReplyTo', 'marketing-admin@nuvei.com'); //enterprise.support@nuvei.com

      // soporte-latam
      if (em.ToAddress != null && em.ToAddress.contains('soporte-latam@nuvei.com')) {
        inputVariables.put('TemplateIdOrName', 'TechSupport_auto_reply_Spanish');
        inputVariables.put('ReplyTo', 'soporte-latam@nuvei.com');

        Id owaId = getOwaId('soporte-LATAM', 'soporte-latam@nuvei.com');
        inputVariables.put('OrgWideId', owaId);
      }

      // sdksupport
      if (em.ToAddress != null && em.ToAddress.contains('sdksupport@nuvei.com')) {
        inputVariables.put('ReplyTo', 'sdksupport@nuvei.com');

        Id owaId = getOwaId('SDK Support', 'sdksupport@nuvei.com');
        inputVariables.put('OrgWideId', owaId);
      }

      // Chargeback
      if (em.Parent.RecordTypeId == RT_CASE_CHARGBACK) {
        inputVariables.put('ReplyTo', 'chargebacks-latam@nuvei.com');

        Id owaId = getOwaId('Risk LATAM', 'chargebacks-latam@nuvei.com');
        inputVariables.put('OrgWideId', owaId);
      }

      // RT_CASE_PAYAUT_SUPPORT
      if (em.Parent.RecordTypeId == RT_CASE_PAYAUT_SUPPORT) {
        inputVariables.put('ReplyTo', 'platforms-support@nuvei.com');

        Id owaId = getOwaId('', 'platforms-support@nuvei.com');
        inputVariables.put('OrgWideId', owaId);
      }

      inputVariables.put('ObjId', em.ParentId);
      inputVariables.put('ParentId', em.ParentId);
      inputVariables.put('TargetObjectId', em.Parent.ContactId);

      inputVariables = sendEmailUtils.getLastEmailParams(inputVariables);
      if (
        inputVariables.get('ToAddresses') == null ||
        (inputVariables.get('ToAddresses') != null &&
        ((List<String>) inputVariables.get('ToAddresses')).size() < 1)
      )
        inputVariables.put('ToAddresses', new List<String>{ em.Parent.SuppliedEmail });

      // RT_CASE_BILLING_DP
      // if (
      //   em.Parent.RecordTypeId == RT_CASE_BILLING_DP && inputVariables.get('CcAddresses') == null ||
      //   (inputVariables.get('CcAddresses') != null &&
      //   ((List<String>) inputVariables.get('CcAddresses')).size() > 0)
      // ) {
      //   List<String> ccAdd = new List<String>{ 'billingteam@nuvei.com' };
      //   inputVariables.put('CcAddresses', cleanCcAddress(((List<String>) inputVariables.get('CcAddresses')), ccAdd));
      // }

      if (em.Parent.RecordTypeId == RT_CASE_BILLING_DP) {
        inputVariables.put('IsSaveAsActivity', false);

        if (
          inputVariables.containsKey('CcAddresses') &&
          inputVariables.get('CcAddresses') != null &&
          ((List<String>) inputVariables.get('CcAddresses')).size() > 0
        ) {
          List<String> ccAddresses = (List<String>) inputVariables.get('CcAddresses');
          List<String> filteredCc = new List<String>();

          for (String email : ccAddresses) {
            if (email != null && email.trim().toLowerCase() != 'billingteam@nuvei.com') {
              filteredCc.add(email);
            }
          }
          inputVariables.put('CcAddresses', filteredCc);
        }
      }

      if (Utils.isSandbox()) {
        inputVariables.put('CcAddresses', new List<String>());
        inputVariables.put('BccAddress', new List<String>());
      }

      if (inputVariables.get('TemplateIdOrName') == null) {
        Execution_Log__c el = new Execution_Log__c(
          Class_Name__c = 'EmailMessageHandler',
          Initiated_By__c = UserInfo.getUserId(),
          Method_Name__c = 'sendEmail',
          Payload__c = JSON.serialize(inputVariables),
          Description__c = 'No TemplateIdOrName',
          Related_Record_Id__c = em.Parent.Id,
          Status_Code__c = 200,
          Path__c = '',
          Type__c = 'Info'
        );

        WithoutSharingUtils.insertRecord(el);
        return;
      }

      isDuplicateEmailToCaseAlreadyRun = true;
      String res = sendEmailUtils.sendEmail(inputVariables);
    }
  }

  private static Id getOwaId(String displayName, String address) {
    String query = 'SELECT Id, Address, DisplayName FROM OrgWideEmailAddress WHERE ';

    // Check if at least one parameter is provided
    if (String.isBlank(displayName) && String.isBlank(address)) {
      return null;
    }

    // Build the WHERE clause manually
    if (String.isNotBlank(displayName) && String.isNotBlank(address)) {
      query += 'DisplayName = :displayName AND Address = :address';
    } else if (String.isNotBlank(displayName)) {
      query += 'DisplayName = :displayName';
    } else {
      query += 'Address = :address';
    }

    query += ' LIMIT 1';

    try {
      List<OrgWideEmailAddress> ows = Database.query(query);
      return ows[0].Id;
    } catch (Exception e) {
      return null;
    }
  }

  private static List<String> cleanCcAddress(List<String> CcAddresses, List<String> address) {
    List<String> cleanCcAddresses = new List<String>();
    System.debug('ccAddressesccAddresses' + ccAddresses);
    for (Integer i = ccAddresses.size() - 1; i >= 0; i--) {
      System.debug('ccAddresses[i]' + ccAddresses[i]);
      if (!(ccAddresses[i] != null && address.contains(ccAddresses[i].toLowerCase()))) {
        cleanCcAddresses.add(ccAddresses[i]);
      }
    }
    return cleanCcAddresses;
  }
}