global class ContentDocumentLinkTriggerHandler extends ITriggerHandlerImpl {
  public override void afterInsert(Object params) {
    ChangeStatus(newRecordList);
    ConfigurationToNCP(newRecordList);
    resumeCongaMsa(newRecordList);
  }

  /*
        ------------------------------------------------------------------------
            Name              : resumeCongaMsa
            Description       : Track D (Conga path) Phase 2 resume. When Conga
                                Trigger stores its composed MSA PDF as a File on
                                a Compliance still awaiting it (MSA_Status__c =
                                'started'), enqueue the DocuSign send.
            ------------------------------------------------------------------------
  */
  private static void resumeCongaMsa(List<ContentDocumentLink> files) {
    if (files == null || files.isEmpty()) {
      return;
    }
    String compPrefix = Compliance__c.sObjectType.getDescribe().getKeyPrefix();

    // ContentDocumentId -> Compliance Id, only for links to Compliance records.
    Map<Id, Id> docToCompliance = new Map<Id, Id>();
    for (ContentDocumentLink cdl : files) {
      if (cdl.LinkedEntityId == null || cdl.ContentDocumentId == null) {
        continue;
      }
      if (String.valueOf(cdl.LinkedEntityId).startsWith(compPrefix)) {
        docToCompliance.put(cdl.ContentDocumentId, cdl.LinkedEntityId);
      }
    }
    if (docToCompliance.isEmpty()) {
      return;
    }

    // Only Compliance still awaiting the Conga output should be resumed.
    Set<Id> startedComplianceIds = new Map<Id, Compliance__c>(
      [
        SELECT Id
        FROM Compliance__c
        WHERE Id IN :docToCompliance.values() AND MSA_Status__c = 'started'
      ]
    ).keySet();
    if (startedComplianceIds.isEmpty()) {
      return;
    }

    // Latest version per document, filtered to the Conga MSA output prefix.
    for (ContentVersion cv : [
      SELECT Id, ContentDocumentId, Title
      FROM ContentVersion
      WHERE ContentDocumentId IN :docToCompliance.keySet() AND IsLatest = TRUE
    ]) {
      Id complianceId = docToCompliance.get(cv.ContentDocumentId);
      if (complianceId == null || !startedComplianceIds.contains(complianceId)) {
        continue;
      }
      if (cv.Title == null || !cv.Title.startsWith(TrackDMsaConga.OUTPUT_FILENAME_PREFIX)) {
        continue;
      }
      // Defensive: Conga may store the File from an async context. Enqueue is
      // valid from triggers and Queueables; if the surrounding context forbids
      // it (e.g. a @future), log so ops can rerun rather than fail silently.
      try {
        System.enqueueJob(new MsaCongaDocuSignQueueable(complianceId, cv.Id));
      } catch (Exception e) {
        BoardingErrorLogService.log(
          BoardingErrorLogService.Level.ERROR,
          'ContentDocumentLinkTriggerHandler',
          'resumeCongaMsa',
          complianceId,
          null,
          'Track D: MSA Generation (Conga Trigger / Static PDF + DocuSign)',
          'Track D: could not enqueue Conga MSA DocuSign send — ' + e.getMessage(),
          e,
          null,
          500
        );
      }
    }
  }

  global static void ChangeStatus(List<ContentDocumentLink> files) {
    Schema.DescribeSObjectResult r = Action_Item__c.sObjectType.getDescribe();
    String actionItemKeyPrefix = r.getKeyPrefix();

    Map<id, List<ContentDocumentLink>> mapFiles = new Map<id, List<ContentDocumentLink>>();

    for (ContentDocumentLink cdl : files) {
      if (cdl.LinkedEntityId != null) {
        if (String.valueOf(cdl.LinkedEntityId).substring(0, 3) == actionItemKeyPrefix) {
          if (mapFiles.containskey(cdl.LinkedEntityId)) {
            mapFiles.get(cdl.LinkedEntityId).add(cdl);
          } else {
            mapFiles.put(cdl.LinkedEntityId, new List<ContentDocumentLink>());
            mapFiles.get(cdl.LinkedEntityId).add(cdl);
          }
        }
      }
    }

    if (mapFiles.size() > 0) {
      Map<id, Action_item__C> actionItemMap = new Map<id, Action_item__C>(
        [SELECT id, Status__c FROM Action_item__C WHERE id IN :mapFiles.keySet()]
      );
      List<Action_item__C> list2update = new List<Action_item__C>();

      for (Action_item__c ai : actionItemMap.values()) {
        if (ai.Status__c != 'Recieved') {
          ai.Status_changed_to_Recived__c = true;
          ai.Status__c = 'Received';
          list2update.add(ai);
        }
      }

      update list2update;
    }
  }

  /*
        ------------------------------------------------------------------------
            Name              : ConfigurationToNCP
            Description       : Copy CV from Configuration Case to NCP
            Revision History  :-
            Created/Modified by: Aviel Cohanian
            Created/Modified Date: 13.07.2025
            
        ------------------------------------------------------------------------
  */
  private static void ConfigurationToNCP(List<ContentDocumentLink> files) {
    List<ContentDocumentLink> cdlToInsert = new List<ContentDocumentLink>();
    try {
      for (ContentDocumentLink cdl : files) {
        if (cdl.ShareType == 'V')
          continue;

        if (cdl.LinkedEntityId.getSObjectType().getDescribe().getName() == 'Case') {
          List<case> currCase = [
            SELECT Id, RecordTypeId, Related_Case__c
            FROM case
            WHERE Id = :cdl.LinkedEntityId AND RecordType.developerName = 'Configuration'
          ];

          if (currCase.size() > 0) {
            ContentDocumentLink newCdl = cdl.clone();
            newCdl.ShareType = 'V';
            newCdl.LinkedEntityId = currCase[0].Related_Case__c;
            cdlToInsert.add(newCdl);
          }
        }
      }
      System.debug('ContentDocumentLinkTriggerHandler - ConfigurationToNCP - cdlToInsert:' + cdlToInsert);
      if (cdlToInsert.size() > 0)
        insert cdlToInsert;
    } catch (Exception e) {
      System.debug('ContentDocumentLinkTriggerHandler - ConfigurationToNCP Error: ' + e.getMessage());
    }
  }
}
