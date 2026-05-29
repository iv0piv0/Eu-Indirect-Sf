global class StartIntegrationProcess_Controller {
    
    public Integration_Project__c theIP {get;set;}
    public Provisioning_Request__c thePR {get;set;}
    public List<Integration_Task__c> itList {get;set;}
    private Map<Id, Id> featuresMap = new Map<Id, Id>();
    public class MyException extends Exception {}
    
    public PageReference DoAction(){
        return Save();
    }
    
    static webservice String StartAction(Id provisioningRequestId){
        String result='';
        Savepoint sp = Database.setSavepoint();
        try{
            Provisioning_Request__c pr = [SELECT Id, RecordTypeId, Account__c, Opportunity__c FROM Provisioning_Request__c WHERE Id =:provisioningRequestId LIMIT 1];
            
            //List<Profile> pList = [SELECT Id FROM Profile WHERE Name = 'SC Standard User' OR Name = 'Integration User' LIMIT 2 ];
            List<Profile> pList = [SELECT Id FROM Profile WHERE Name = 'SC Standard User + Integration' LIMIT 1 ];
            Boolean condition = pList.size() > 0 && pList[0].Id == UserInfo.getProfileId();
            condition |= pList.size() > 1 && pList[1].Id == UserInfo.getProfileId();
            
            if( !condition ){
                
                Apexpages.standardController sc = new Apexpages.standardController(pr);
                StartIntegrationProcess_Controller controller = new StartIntegrationProcess_Controller(sc);
                controller.Save();
                result = controller.theIP.Id;
                
            }else{
                pr.Submit_for_Integration__c = true;
                update pr;
                result = pr.Id;
            }
        }catch(Exception e){
            Database.rollback(sp);
            result = 'Error: ' + e.getMessage();
        }
        return result;
    }
    
    public StartIntegrationProcess_Controller(ApexPages.StandardController controller) {
        try{
            thePR = (Provisioning_Request__c) controller.getRecord();
            
            String recordTypeName_PR = Provisioning_Request__c.sObjectType.getDescribe().getRecordTypeInfosById().get(thePR.RecordTypeId).name;
            
            if( !Integration_Project__c.sObjectType.getDescribe().getRecordTypeInfosByName().containsKey(recordTypeName_PR) ){
                throw new MyException('No Integration Project Record Type was found with name ' + recordTypeName_PR + '. Contact your admin.');
            }
            Id recordTypeId_IP = Integration_Project__c.sObjectType.getDescribe().getRecordTypeInfosByName().get(recordTypeName_PR).recordTypeId;
            
            theIP = new Integration_Project__c();
            theIP.recordTypeId = recordTypeId_IP;
            theIP.Account__c = thePR.Account__c;
            theIP.Provisioning_Request__c = thePR.Id;
            theIp.Opportunity__c = thePR.Opportunity__c;
            
            Set<Id> features2Query = new Set<Id>();
            
            for( Feature__c f : [SELECT Id, Hidden_Original_Feature__c FROM Feature__c WHERE Provisioning_Request__c = :thePR.Id AND Active__c = true]){
                features2Query.add(f.Hidden_Original_Feature__c);
                featuresMap.put(f.Hidden_Original_Feature__c, f.Id);
            }
            
            itList = new List<Integration_Task__c>();
            
            // Create the query to get All possible fields to be cloned later.
            Map<String, Schema.SObjectField> integrationTaskFieldsMap = Schema.SObjectType.Integration_Task__c.fields.getMap();
            String qITask = 'SELECT ' + buildQueryFields(integrationTaskFieldsMap) + ', Feature__r.Name FROM Integration_Task__c WHERE Feature__c =:features2Query';
            
            //for( Integration_Task__c it : [SELECT Id, Order__c, Feature__c, Feature__r.Name, Description__c, Remarks__c, Name, Completed_On__c, Phase__c, Product__c FROM Integration_Task__c WHERE Feature__c =:features2Query]){
            for(Integration_Task__c it : database.query(qITask)){
                itList.add(it);
            }
            
            System.debug(System.Logginglevel.INFO, 'itList: ' + itList);
        
        }catch(Exception e){
            String  errorMsg = e.getMessage();
            System.debug(System.Logginglevel.ERROR, 'errorMsg: ' + errorMsg);
                            
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, errorMsg));
        }
        
    }
    
    public PageReference Save(){
        PageReference page=null;
        Savepoint sp = Database.setSavepoint();
        try{
            insert theIP;
            
            List<Integration_Task__c> it2Ins = new List<Integration_Task__c>();
            //IMPORTANT: Changes in this logic should also be done in trigger : MantainsIntegrationTasksUnderIntegrationProjects
            for( Integration_Task__c it : itList ){
                Integration_Task__c clonedIt = it.clone(false,true,false,false);
                clonedIt.Feature__c = featuresMap.get(it.Feature__c);
                clonedIt.Integration_Project__c = theIP.Id;
                clonedIt.Hidden_Original_Integration_Task__c = it.Id;
                clonedIt.OwnerId = UserInfo.getUserId();
                it2Ins.add(clonedIt);
            }
            
            System.debug(System.Logginglevel.INFO, 'it2Ins: ' + it2Ins);
            
            if( !it2Ins.isEmpty() ){
                insert it2Ins;
            }
            
            List<Feature__c> features2Udp = new List<Feature__c>();
            
            for( Id featureId : featuresMap.values() ){
                features2Udp.add( new Feature__c(Id=featureId, Integration_Project__c = theIP.Id) );
            }
            
            if( !features2Udp.isEmpty() ){
                update features2Udp;
            }
            
            thePR.Hidden_Integration_Process_Started__c = true;
            update thePR;
            
            page = new Pagereference('/' + theIP.Id);
        }catch(Exception e){
            Database.rollback(sp);
            String  errorMsg = e.getMessage();
            
            System.debug(System.Logginglevel.ERROR, 'errorMsg: ' + errorMsg);
                            
            ApexPages.addMessage(new ApexPages.Message(ApexPages.Severity.ERROR, e.getMessage()));
        }
        
        return page;
    }
    
    private static String buildQueryFields( Map<String, Schema.SObjectField> fieldMap ){
        //Method that returns all the Fields , commas separated, from the Schema. Used for dynamic query.               
        String QueryFields='';
        for(String nameField: fieldMap.KeySet()){
            if(nameField <> 'LastViewedDate'){
                Schema.DescribeFieldResult fd = fieldMap.get(nameField).getDescribe(); // describe each field (fd)
                if(fd.isCreateable()){ // field is creatable
                    QueryFields += ',' + nameField;
                }   
            }
        }
        QueryFields = QueryFields.substring(1);
        return QueryFields;
    }
    
    static testmethod void Test01(){
        User u = [SELECT id FROM user WHERE profile.name = 'System Administrator' and isactive = true Limit 1];
        
        // Required parent records for Provisioning_Request__c
        Account a = new Account(Name = 'PR Test Acc');
        insert a;
        
        Compliance__c comp = new Compliance__c(
            Name = 'PR Test Comp',
            Account__c = a.Id,
            Registered_Country__c = 'United Kingdom',
            Registered_Street__c = '1 St',
            Registered_City__c = 'London',
            Registered_Zip_Postal_Code__c = 'E1 1AA',
            VAT_Number__c = 'GB123',
            City_field__c = '+44123456789'
        );
        insert comp;
        
        Opportunity o = new Opportunity(
            Name = 'PR Test Opp',
            AccountId = a.Id,
            StageName = 'Prospecting',
            CloseDate = Date.today().addDays(30)
        );
        insert o;
        
        Provisioning_Request__c pr = new Provisioning_Request__c();
        String recTypeName;
        System.runAs(u) {
            pr.RecordTypeId = Provisioning_Request__c.sObjectType.getDescribe().getRecordTypeInfosById().values()[2].recordtypeId;
            recTypeName = Provisioning_Request__c.sObjectType.getDescribe().getRecordTypeInfosById().values()[2].Name;
        }
        pr.Account__c = a.Id;
        pr.Opportunity__c = o.Id;
        pr.Company_Profile__c = comp.Id;
        insert pr;
        
        Integration_Package__c ip = new Integration_Package__c(Name = recTypeName);
        insert ip;
        
        Feature__c f1 = new Feature__c(Integration_Package__c = ip.Id);
        insert f1;
        Feature__c f2 = new Feature__c(Provisioning_Request__c = pr.Id, Hidden_Original_Feature__c = f1.Id, Active__c = true);
        insert f2;
        
        Integration_Task__c it1 = new Integration_Task__c( Feature__c = f1.Id );
        insert it1;
        
        Apexpages.standardController sc = new Apexpages.standardController(pr);
        StartIntegrationProcess_Controller controller = new StartIntegrationProcess_Controller(sc);
        
        controller.Save();
    }
}