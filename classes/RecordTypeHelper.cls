public with sharing class RecordTypeHelper {
    // Method to get the RecordType Id by Object Name and RecordType Name
    public static Id getRecordTypeIdByName(String objectName, String recordTypeName) {
        // Check if objectName or recordTypeName is null or empty
        if (String.isEmpty(objectName) || String.isEmpty(recordTypeName)) {
            return null;
        }
        
        // Dynamic SOQL query to get the RecordType Id based on object and record type name
        String query = 'SELECT Id FROM RecordType WHERE SObjectType = :objectName AND DeveloperName = :recordTypeName LIMIT 1';
        
        // Execute the query and fetch the RecordType
        RecordType rt = Database.query(query);
        
        // Return the RecordType Id or null if not found
        return rt != null ? rt.Id : null;
    }
}