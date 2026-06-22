public class MerchantPayload {
    
    public String profile { get; set; }
    public Decimal tier { get; set; }
    public String name { get; set; }
    public String merchantCategoryCode { get; set; }
    public String taxId { get; set; }
    public String phoneNumber { get; set; }
    public Address address { get; set; }
    public List<User> users { get; set; }
    public PaymentProcessing paymentProcessing { get; set; }
    public ClientManagementDetails clientManagementDetails { get; set; }
    public String dateSigned { get; set; }
    public String email { get; set; }
    public Boolean isPayFac { get; set; }
    public String externalId { get; set; }
    /** Partner entity UUID for EU indirect — omitted from JSON when blank. */
    public String parentEntityId { get; set; }
    /** Partner webhook URL for NCP credentials — omitted from JSON when blank. */
    public String credentialsUrl { get; set; }

    public MerchantPayload(Case cas, Boolean isProd, Boolean isPayFac) {
        this.isPayFac = isPayFac;
        if (cas != null && cas.Company_Profile__r != null) {
            name = cas.Company_Profile__r.Name;
            externalId = cas.Company_Profile__r.Id;

            if (cas.Company_Profile__r.Merchant_Tier__c != null) {
                tier = cas.Company_Profile__r.Merchant_Tier__c;
            }
            
            if (cas.Company_Profile__r.VAT_Number__c != null) {
                taxId = cas.Company_Profile__r.VAT_Number__c;
            }

            // NCP "profile" string from Configuration Case (Phase 1 hardcoded); fallback to SB template for legacy flows
            if (String.isNotBlank(cas.Profile__c)) {
                profile = cas.Profile__c;
            } else {
                profile = cas.SB_Template__c;
            }

            if (cas.Company_Profile__r.From_Reseller__r != null) {
                String pid = cas.Company_Profile__r.From_Reseller__r.Nuvei_Partner_ID__c;
                if (String.isNotBlank(pid)) {
                    parentEntityId = pid.trim();
                }
                String credUrl = cas.Company_Profile__r.From_Reseller__r.Credentials_URL__c;
                if (String.isNotBlank(credUrl)) {
                    credentialsUrl = credUrl.trim();
                }
            }
            
            if (cas.Company_Profile__r.MSA_Effective_Date__c != null) {
                DateTime myDateTime = DateTime.newInstance(
                    cas.Company_Profile__r.MSA_Effective_Date__c.year(),
                    cas.Company_Profile__r.MSA_Effective_Date__c.month(),
                    cas.Company_Profile__r.MSA_Effective_Date__c.day()
                );
                dateSigned = myDateTime.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss\'Z\'');
            }
            
            
            phoneNumber = cas.Company_Profile__r.City_field__c;
            
            String stateSource = MerchantValidator.getStateCode(
                cas.Company_Profile__r.Registered_Country__c,
                cas.Company_Profile__r.State_USA__c
            );
            
            
            if (cas.Company_Profile__r.Primary_Contact__r != null
                && String.isNotBlank(cas.Company_Profile__r.Primary_Contact__r.Email)) {
                email = cas.Company_Profile__r.Primary_Contact__r.Email;
            }
            
            address = new Address(
                cas.Company_Profile__r.Registered_Street__c,
                cas.Company_Profile__r.Registered_City__c,
                cas.Company_Profile__r.Registered_Country__c,
                cas.Company_Profile__r.Registered_Zip_Postal_Code__c,
                stateSource
            );
            
            users = new List<User>();
            if (cas.ContactId != null) {
                users.add(new User(cas, isProd));
            }
            
            if (cas.Location__c != null || cas.Company_Profile__c != null) {
                paymentProcessing = new PaymentProcessing(cas);
            }
            
            clientManagementDetails = new ClientManagementDetails(cas);
            merchantCategoryCode = cas.Company_Profile__r.MCC_Code__c;
        }

        if (isPayFac) {
            paymentProcessing.paymentMethods = new List<PaymentMethod>{
                new PaymentMethod('Visa', new Map<String, String>{ 'payfacId' => cas.Company_Profile__r.Visa_Payfac_ID__c }),
                new PaymentMethod('MasterCard', new Map<String, String>{ 'payfacId' => cas.Company_Profile__r.Mastercard_Payfac_ID__c })
            };
        }
    }
    
    public MerchantPayload(Case cas, Boolean isProd) {
        this(cas, isProd, false); // ברירת מחדל – לא PayFac
    } 
    
    public class PaymentMethod {
        public String name { get; set; }
        public Map<String, String> properties { get; set; }
    
        public PaymentMethod(String name, Map<String, String> properties) {
            this.name = name;
            this.properties = properties;
        }
    }

    public class Property {
        public String key { get; set; }
        public String value { get; set; }
        
        public Property(String key, String value) {
            this.key = key;
            this.value = value;
        }
    }
    
    public class Address {
        public String line1 { get; set; }
        public String line2 { get; set; }
        public String line3 { get; set; }
        public String city { get; set; }
        public String state { get; set; }
        public String country { get; set; }
        public String postalCode { get; set; }
        
        public Address(String street, String city, String country, String postalCode, String state) {
            if (!String.isBlank(street)) {
                line1 = MerchantValidator.sanitizeText(street, 30);
                line1 = line1.replaceAll('[\\^<>%,]', '');
                if (street.length() > 30) {
                    line2 = MerchantValidator.sanitizeText(street.substring(30, Math.min(60, street.length())), 30);
                    line2 = line2.replaceAll('[\\^<>%,]', '');
                }
                if (street.length() > 60) {
                    line3 = MerchantValidator.sanitizeText(street.substring(60, Math.min(90, street.length())), 30);
                    line3 = line3.replaceAll('[\\^<>%,]', '');
                }
            }
            
            if (!String.isBlank(city)) {
                this.city = city.replaceAll('[\\^<>%,]', '');
            }
            
            if (state != null) {
                this.state = state.toUpperCase();
            }
            
            if (!String.isBlank(country)) {
                this.country = MerchantValidator.getCountryCode(country);
            }
            
            this.postalCode = postalCode;
        }
    }
    
    
    /**
     * NCP cPanel User wrapper.
     *
     * IMPORTANT — DO NOT add a phoneNumber field here.
     * The NCP merchants JSON schema defines User with `additionalProperties: false`
     * and the allowed properties are ONLY: name, email, roles, password, username,
     * adminOfAdmins. Sending phoneNumber on the user object causes NCP to reject
     * the whole request with HTTP 422:
     *   "Additional properties not allowed: phoneNumber at
     *    #->allOf[0]->$ref[#/$defs/Merchant]->properties:users
     *    ->$ref[#/$defs/UserList]->items[0]:0->$ref[#/$defs/User]"
     *
     * The merchant-level (top-level) phoneNumber on the parent MerchantPayload
     * is the correct place to carry the phone number; that field IS required by
     * NCP and is populated from Compliance__c.City_field__c above.
     *
     * ROLE & ADMIN-OF-ADMINS ASSIGNMENT:
     *   - Legacy / non-EU-indirect prod flow: prod accounts get 'tempUser'.
     *     adminOfAdmins is NOT set (left null) so the JSON serializer omits it
     *     entirely — preserving the exact request body legacy callers expect.
     *   - EU Indirect Orchestration flow: prod accounts must get 'management'
     *     AND adminOfAdmins=true so the cPanel admin can manage other admin
     *     users within their NCP merchant. We detect this flow via
     *     Compliance__c.EU_Indirect_Orchestration__c (already on the Case's
     *     Company_Profile__r — no new params needed).
     *   - Sandbox (non-prod) always gets 'management' regardless of flow.
     *     adminOfAdmins is NOT set — preserving prior sandbox behavior.
     *
     * Null-serialization note: callers serialize the payload with
     * JSON.serialize(payload, true); the second arg suppresses nulls so a
     * null adminOfAdmins is silently dropped from the request body.
     */
    public class User {
        public Name name { get; set; }
        public String email { get; set; }
        public List<String> roles { get; set; }
        public String password { get; set; }
        public String username { get; set; }
        // Only populated for EU Indirect prod (see constructor + class doc).
        public Boolean adminOfAdmins { get; set; }
        
        public User(Case cas, Boolean isProd) {
            if (cas != null && cas.Contact != null) {
                System.debug('cas.Contact: '+cas.Contact);
                username = cas.SB_PPP_Username__c;
                name = new Name(cas.Contact.FirstName, cas.Contact.LastName);
                email = cas.Contact.Email;
                password = cas.SB_PPP_Password__c != null ? cas.SB_PPP_Password__c : MerchantValidator.genPassword(8);

                // EU Indirect flow: prod accounts must be 'management', not 'tempUser',
                // AND must carry adminOfAdmins=true so the cPanel admin can manage
                // other admin users within their NCP merchant. For every other path
                // (non-EU-indirect prod, any sandbox) adminOfAdmins is left null and
                // therefore omitted from the serialized JSON — preserving the exact
                // request body legacy callers have been sending all along.
                Boolean isEuIndirect = cas.Company_Profile__r != null
                    && cas.Company_Profile__r.EU_Indirect_Orchestration__c == true;
                if (isProd && !isEuIndirect) {
                    // Legacy prod path — unchanged.
                    roles = new List<String>{ 'tempUser' };
                } else {
                    // Either EU Indirect prod, or any sandbox flow.
                    roles = new List<String>{ 'management' };
                    if (isProd && isEuIndirect) {
                        adminOfAdmins = true;
                    }
                }
            }
        }
    }
    
    public class PaymentProcessing {
        public String name { get; set; }
        public Address address { get; set; }
        public String email { get; set; }
        public String website { get; set; }
        public List<Contact> contacts { get; set; }
        public String phoneNumber { get; set; }
        public List<PaymentMethod> paymentMethods { get; set; }

        public PaymentProcessing(Case cas) {
            if (cas != null) {
                Boolean useLocation = (cas.Location__c != null);
                name = useLocation ? cas.Location__r.Name : cas.Company_Profile__r.Name;
                email = useLocation ? cas.Location__r.Email_Address__c : cas.Company_Profile__r.Primary_Contact__r.Email;
                phoneNumber = useLocation ? String.valueOf(cas.Location__r.Phone_Number__c) : cas.Company_Profile__r.City_field__c;
                website = MerchantPayload.fetchWebsite(cas);
                
                String stateSource = MerchantValidator.getStateCode(
                    cas.Company_Profile__r.Registered_Country__c,
                    cas.Company_Profile__r.State_USA__c
                );
                
                address = new Address(
                    useLocation ? cas.Location__r.Street__c : cas.Company_Profile__r.Registered_Street__c,
                    useLocation ? cas.Location__r.City__c : cas.Company_Profile__r.Registered_City__c,
                    useLocation ? cas.Location__r.Country__c : cas.Company_Profile__r.Registered_Country__c,
                    useLocation ? cas.Location__r.Postal_Code__c : cas.Company_Profile__r.Registered_Zip_Postal_Code__c,
                    stateSource
                );
                
                if (cas.Company_Profile__r.Primary_Contact__r != null) {
                    contacts = new List<Contact>();
                    contacts.add(new Contact(cas, 'PaymentProcessing'));
                }
            }
        }
    }
    
    
    public class Contact {
        public String id { get; set; }
        public Name name { get; set; }
        public String email { get; set; }
        public List<String> roles { get; set; }
        public Address address { get; set; }
        public String phoneNumber { get; set; }
        
        public Contact(Case cas, String objectName) {
            
            if(cas != null && cas.Company_Profile__r != null) {
                if(objectName == 'PaymentProcessing' && cas.Company_Profile__r.Primary_Contact__r != null){
                    name = new Name(
                        cas.Company_Profile__r.Primary_Contact__r.FirstName,
                        cas.Company_Profile__r.Primary_Contact__r.LastName
                    );
                    email = cas.Company_Profile__r.Primary_Contact__r.Email;
                    roles = new List<String>{ 'Contact' };
                    
                    // phoneNumber = !String.isBlank(cas.Company_Profile__r.Primary_Contact__r.Phone)
                    //     ? String.valueOf(cas.Company_Profile__r.Primary_Contact__r.Phone)
                    //     : String.valueOf(cas.Company_Profile__r.City_field__c);
                    
                    String countrySource = !String.isBlank(cas.Company_Profile__r.Primary_Contact__r.MailingCountry)
                        ? cas.Company_Profile__r.Primary_Contact__r.MailingCountry
                        : cas.Company_Profile__r.Registered_Country__c;
                    
                    String stateSource = MerchantValidator.getStateCode(
                        countrySource,
                        cas.Company_Profile__r.State_USA__c
                    );
                    
                    // address = new Address(...)  // kept commented as in source
                }
                
                if(objectName == 'ClientManagementDetails'){
                    if(cas.Company_Profile__r.Sales_Rep__c != null){
                        id = cas.Company_Profile__r.Sales_Rep__c;
                        roles = new List<String>{ 'sales' };
                        name = new Name(cas.Company_Profile__r.Sales_Rep__r.FirstName, cas.Company_Profile__r.Sales_Rep__r.LastName);
                        email = cas.Company_Profile__r.Sales_Rep__r.Email;
                    }
                    
                    if(cas.Company_Profile__r.Account_Manager__c != null){
                        id = cas.Company_Profile__r.Account_Manager__c;
                        roles = new List<String>{ 'accountManager' };
                        name = new Name(cas.Company_Profile__r.Account_Manager__r.FirstName, cas.Company_Profile__r.Account_Manager__r.LastName);
                        email = cas.Company_Profile__r.Account_Manager__r.Email;
                    }
                    
                    if(cas.Company_Profile__r.Account_Operational_Manager_CP__c != null){
                        id = cas.Company_Profile__r.Account_Operational_Manager_CP__c;
                        roles = new List<String>{ 'operationalManager' };
                        name = new Name(cas.Company_Profile__r.Account_Operational_Manager_CP__r.FirstName, cas.Company_Profile__r.Account_Operational_Manager_CP__r.LastName);
                        email = cas.Company_Profile__r.Account_Operational_Manager_CP__r.Email;
                    }
                }
            }
        }
    }
    
    public class ClientManagementDetails {
        public Account account { get; set; }
        public Company company { get; set; }
        public List<Contact> contact { get; set; }
        public String platform { get; set; }
        public Introducer introducer { get; set; }
        public String integrationCaseId { get; set; }
        public IndustryIndication industryIndication { get; set; }
        public BusinessOriginRegion businessOriginRegion { get; set; }
        public String customerIntegrationChannel { get; set; }
        
        public ClientManagementDetails(Case cas){
            if (cas != null && cas.Company_Profile__r != null) {
                contact = new List<Contact>();
                contact.add(new Contact(cas, 'ClientManagementDetails'));
                company = new Company(cas);
                account = new Account(cas);
                introducer = new Introducer(cas);
                businessOriginRegion = new BusinessOriginRegion(cas);
                industryIndication = new IndustryIndication(cas);
                customerIntegrationChannel = cas.Integration_Channel__c;
                integrationCaseId = cas.Id != null ? String.valueOf(cas.Id) : null;
                platform = cas.Platform_Integration__c;
            }
        }
    }
    
    
    public class Account {
        public String id { get; set; }
        public String name { get; set; }
        
        public Account(Case cas){
            if(cas != null && cas.Company_Profile__r != null && cas.Company_Profile__r.Account__r != null){
                id = cas.Company_Profile__r.Account__r.Id;
                name = cas.Company_Profile__r.Account__r.Name;
            }
        }
    }
    
    public class Company {
        public String id { get; set; }
        public String name { get; set; }
        
        public Company(Case cas){
            if(cas != null && cas.Company_Profile__r != null){
                id = cas.Company_Profile__r.Id;
                name = cas.Company_Profile__r.Name;
            }
        }
    }
    
    public class Introducer {
        public String id { get; set; }
        public String name { get; set; }
        public Integer industryIndicationId { get; set; }
        public String merchantCategoryCode { get; set; }
        
        public Introducer(Case cas){
            if(cas != null && cas.Company_Profile__r != null && cas.Company_Profile__r.From_Reseller__r != null){
                id = cas.Company_Profile__r.From_Reseller__r.Id;
                name = cas.Company_Profile__r.From_Reseller__r.Name;
                String verticalValue = cas.Company_Profile__r.From_Reseller__r.Overwrite_Financial_Vertical__c;
                
                if (verticalValue == 'Cryptocurrency') {
                    industryIndicationId = 1;
                } else if (verticalValue == 'Marketplace') {
                    industryIndicationId = 2;
                } else if (verticalValue == 'Social Gaming') {
                    industryIndicationId = 3;
                }
                merchantCategoryCode = cas.Company_Profile__r.MCC_Code__c;
            }
        }
    }
    
    
    public class IndustryIndication {
        public String id { get; set; }
        public String name { get; set; }
        
        public IndustryIndication(Case cas){
            name = cas.Company_Profile__r.Overwrite_Financial_Vertical__c;
            if (name == 'Cryptocurrency') {
                id = '1';
            } else if (name == 'Marketplace') {
                id = '2';
            } else if (name == 'Social Gaming') {
                id = '3';
            }
        }
    }
    
    public class BusinessOriginRegion {
        public String id { get; set; }
        public String name { get; set; }
        
        public BusinessOriginRegion(Case cas){
            name = cas.Company_Profile__r.Origin_Region__c;
            if (name == 'NA') {
                id = '1';
            } else if (name == 'EMEA') {
                id = '2';
            } else if (name == 'LATAM') {
                id = '3';
            } else if (name == 'APAC') {
                id = '4';
            }
        }
    }
    
    public class Name {
        public String first { get; set; }
        public String last { get; set; }
        
        public Name(String first, String Last){
            this.first = first;
            this.last = last;
        }
    }
    
    public static String fetchWebsite(Case cas) {
        if (cas != null && cas.Company_Profile__c != null) {
            List<Website__c> websiteRecords = [
                SELECT Name FROM Website__c  
                WHERE Compliance__c = :cas.Company_Profile__c 
                ORDER BY Primary_URL__c DESC, CreatedDate ASC 
                LIMIT 1
            ];
            return websiteRecords.isEmpty() ? null : websiteRecords[0].Name;
        }
        return null;
    }
    
}
