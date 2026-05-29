public without sharing class WithoutSharingUtils {
  // Create record
  public static SObject insertRecord(SObject record) {
    System.debug('WithoutSharingUtils > insertRecords > record: ' + record);

    if (record == null)
      return null;
    insert record;

    return record;
  }

  // Create records
  public static List<SObject> insertRecords(List<SObject> records) {
    System.debug('WithoutSharingUtils > insertRecords > records: ' + records);

    if (records == null || records.isEmpty())
      return null;
    insert records;

    return records;
  }

  // Update records
  public static List<SObject> updateRecords(List<SObject> records) {
    System.debug('WithoutSharingUtils > updateRecords > records: ' + records);
    if (records == null || records.isEmpty())
      return null;
    update records;

    return records;
  }

  // Upsert records
  public static List<SObject> upsertRecords(List<SObject> records) {
    System.debug('WithoutSharingUtils > upsertRecords > records: ' + records);
    if (records == null || records.isEmpty())
      return null;
    upsert records;

    return records;
  }

  // Delete records
  public static List<SObject> deleteRecords(List<SObject> records) {
    System.debug('WithoutSharingUtils > deleteRecords > records: ' + records);
    if (records == null || records.isEmpty())
      return null;
    delete records;
    return records;
  }

  // Execute a SOQL query without parameters (returns a list of records)
  public static List<SObject> queryRecords(String query) {
    return (List<SObject>) Database.query(query);
  }

  // Execute a SOQL query with parameters (returns a list of records)
  public static List<SObject> queryRecords(String query, Map<String, Object> params) {
    // String finalQuery = query;
    // for (String key : params.keySet()) {
    //   finalQuery = finalQuery.replace(':' + key, '\'' + String.valueOf(params.get(key)) + '\'');
    // }

    // return (List<SObject>) queryRecords(finalQuery);
    return Database.queryWithBinds(query, params, AccessLevel.SYSTEM_MODE);
  }

  // Fetch a single record
  public static SObject querySingleRecord(String query) {
    List<SObject> results = (List<SObject>) queryRecords(query + ' LIMIT 1');
    return results.isEmpty() ? null : results[0];
  }

  // Fetch a single record with parameters
  public static SObject querySingleRecord(String query, Map<String, Object> params) {
    List<SObject> results = queryRecords(query + ' LIMIT 1', params);
    return results.isEmpty() ? null : results[0];
  }

  /**
   * Sends emails in system context to bypass sharing restrictions.
   * @param emails A list of Messaging.SingleEmailMessage objects prepared beforehand.
   */
  public static List<Messaging.SendEmailResult> sendEmailsAsSystem(List<Messaging.SingleEmailMessage> emails) {
    return Messaging.sendEmail(emails);
  }
}