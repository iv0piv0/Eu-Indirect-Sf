@RestResource(urlMapping='/nuveiConnectWebhook')
global without sharing class NuveiConnectWebhookHandler {
   @HttpPost
global static void handlePost() {
    RestRequest req = RestContext.request;
    RestResponse res = RestContext.response;
    res.addHeader('Content-Type', 'application/json');
    try {
        String body = req.requestBody.toString();
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(body);

        // NC sends applicationData as an escaped JSON string — parse it twice
        String appDataStr = (String) envelope.get('applicationData');
        Map<String, Object> appData = (Map<String, Object>) JSON.deserializeUntyped(appDataStr);

        // Merge applicationId and applicationStatus from envelope into appData
        appData.put('applicationId', envelope.get('applicationId'));
        appData.put('applicationStatus', envelope.get('applicationStatus'));

        NuveiConnectRequest ncReq = (NuveiConnectRequest) JSON.deserialize(
            JSON.serialize(appData), NuveiConnectRequest.class
        );
        WebhookResult result = processWebhook(ncReq);
        res.statusCode = result.success ? 200 : 422;
        res.responseBody = Blob.valueOf(JSON.serialize(result));
    } catch (Exception e) {
        res.statusCode = 500;
        res.responseBody = Blob.valueOf('{"success":false,"message":"' + e.getMessage().replace('"','\\"') + '"}');
    }
}

    private static final Id RT_EL_NC = RecordTypeHelper.getRecordTypeIdByName('Execution_Log__c', 'NuveiConnect');

    // ─── STATUS MAP: Nuvei Connect → Salesforce ─────────────────────────────
    private static final Map<String, String> NC_TO_SF_STATUS = new Map<String, String>{
        'SUBMITTED'                => 'Oscilar Submitted',
        'PENDING_REVIEW'           => 'Oscilar Pending Review',
        'IN_PROGRESS'              => 'Oscilar In Progress',
        'IN_REVIEW'                => 'Oscilar In Review',
        'ADDITIONAL_INFO_REQUESTED'=> 'Oscilar Additional Info Requested',
        'PENDING_APPROVAL'         => 'Oscilar Pending Approval',
        'CONDITIONALLY_APPROVED'   => 'Oscilar Conditionally Approved',
        'APPROVED'                 => 'Oscilar Approved',
        'DECLINED'                 => 'Oscilar Declined',
        'WITHDRAWN'                => 'Oscilar Withdrawn'
    };

    // ─── COMPANY TYPE: NC enum → SF picklist ────────────────────────────────────
    private static final Map<String, String> NC_TO_SF_COMPANY_TYPE =
        new Map<String, String>{
            'LIMITED_COMPANY'               => 'Limited',
            'PUBLIC_LIMITED_COMPANY'        => 'Public Limited',
            'LIMITED_LIABILITY_PARTNERSHIP' => 'Limited Liability Partnership',
            'SOLE_TRADER'                   => 'Sole Trader',
            'SOLE_PROPRIETORSHIP'           => 'Sole Proprietorship',
            'PARTNERSHIP'                   => 'Partnership',
            'CORPORATION'                   => 'Corporation',
            'NON_PROFIT'                    => 'Non-profit',
            'PUBLICLY_TRADED'               => 'Publicly Traded',
            'GOVERNMENT'                    => 'Government/Local Authority',
            'OTHER'                         => 'Other'
        };

    // ─── FULFILLMENT TIME: NC enum → SF picklist ─────────────────────────────
    private static final Map<String, String> NC_TO_SF_FULFILLMENT =
    new Map<String, String>{
        'SAME_DAY'     => 'No delay',
        'IMMEDIATE'    => 'No delay',
        'INSTANT'      => 'No delay',
        '1_5_DAYS'     => 'Up to 7 days',
        '1_7_DAYS'     => 'Up to 7 days',
        'UP_TO_7_DAYS' => 'Up to 7 days',
        '7_20_DAYS'    => 'Between 7 - 20 days',
        'OVER_20_DAYS' => 'More than 20 days',
        'MORE_THAN_20' => 'More than 20 days'
    };

    // ─── UK STATE: NC ISO 3166-2 → SF State_USA__c picklist ─────────────────
    private static final Map<String, String> NC_TO_SF_UK_STATE = new Map<String, String>{
        'GB-ENG' => 'England and Wales',
        'GB-WLS' => 'England and Wales',
        'GB-SCT' => 'Scotland',
        'GB-NIR' => 'Northern Ireland'
    };

    // ─── CHARGEBACK RATIO: NC decimal → SF picklist band ─────────────────────
    private static String mapChargebackRatio(Decimal ratio) {
        if (ratio == null)  return null;
        if (ratio < 0.5)    return 'Under 0.5%';
        if (ratio <= 1)     return '0.5 - 1%';
        if (ratio <= 2)     return '1 - 2%';
        if (ratio <= 5)     return '2 - 5%';
        return 'Above 5%';
    }

    // ─── REFUND RATIO: NC decimal → SF picklist band ──────────────────────────
    private static String mapRefundRatio(Decimal ratio) {
        if (ratio == null)  return null;
        if (ratio <= 3)     return 'Under 3%';
        if (ratio <= 5)     return '3 - 5%';
        if (ratio <= 10)    return '5 - 10%';
        return 'Above 10%';
    }

    // ─── ISO COUNTRY CODE → SF TARGET MARKET picklist name ───────────────────
    private static final Map<String, String> ISO_TO_COUNTRY_NAME =
        new Map<String, String>{
            'AF' => 'Afghanistan',              'AL' => 'Albania',
            'DZ' => 'Algeria',                 'AD' => 'Andorra',
            'AO' => 'Angola',                  'AG' => 'Antigua and Barbuda',
            'AR' => 'Argentina',               'AM' => 'Armenia',
            'AU' => 'Australia',               'AT' => 'Austria',
            'AZ' => 'Azerbaijan',              'BS' => 'Bahamas',
            'BH' => 'Bahrain',                 'BD' => 'Bangladesh',
            'BB' => 'Barbados',                'BY' => 'Belarus',
            'BE' => 'Belgium',                 'BZ' => 'Belize',
            'BJ' => 'Benin',                   'BT' => 'Bhutan',
            'BO' => 'Bolivia',                 'BA' => 'Bosnia and Herzegovina',
            'BW' => 'Botswana',                'BR' => 'Brazil',
            'BN' => 'Brunei',                  'BG' => 'Bulgaria',
            'BF' => 'Burkina Faso',            'BI' => 'Burundi',
            'KH' => 'Cambodia',                'CM' => 'Cameroon',
            'CA' => 'Canada',                  'CV' => 'Cape Verde',
            'CF' => 'Central African Republic','TD' => 'Chad',
            'CL' => 'Chile',                   'CN' => 'China',
            'CO' => 'Colombia',                'KM' => 'Comoros',
            'CG' => 'Congo',                   'CD' => 'Congo Democratic Republic',
            'CR' => 'Costa Rica',              'HR' => 'Croatia',
            'CU' => 'Cuba',                    'CY' => 'Cyprus',
            'CZ' => 'Czech Republic',          'DK' => 'Denmark',
            'DJ' => 'Djibouti',                'DM' => 'Dominica',
            'DO' => 'Dominican Republic',      'TL' => 'East Timor',
            'EC' => 'Ecuador',                 'EG' => 'Egypt',
            'SV' => 'El Salvador',             'GQ' => 'Equatorial Guinea',
            'ER' => 'Eritrea',                 'EE' => 'Estonia',
            'ET' => 'Ethiopia',                'FJ' => 'Fiji',
            'FI' => 'Finland',                 'FR' => 'France',
            'GA' => 'Gabon',                   'GM' => 'Gambia',
            'GE' => 'Georgia',                 'DE' => 'Germany',
            'GH' => 'Ghana',                   'GR' => 'Greece',
            'GD' => 'Grenada',                 'GT' => 'Guatemala',
            'GN' => 'Guinea',                  'GW' => 'Guinea-Bissau',
            'GY' => 'Guyana',                  'HT' => 'Haiti',
            'HN' => 'Honduras',                'HK' => 'Hong Kong',
            'HU' => 'Hungary',                 'IS' => 'Iceland',
            'IN' => 'India',                   'ID' => 'Indonesia',
            'IR' => 'Iran',                    'IQ' => 'Iraq',
            'IE' => 'Ireland',                 'IL' => 'Israel',
            'IT' => 'Italy',                   'CI' => 'Ivory Coast',
            'JM' => 'Jamaica',                 'JP' => 'Japan',
            'JO' => 'Jordan',                  'KZ' => 'Kazakhstan',
            'KE' => 'Kenya',                   'KI' => 'Kiribati',
            'KP' => 'Korea North',             'KR' => 'Korea South',
            'XK' => 'Kosovo',                  'KW' => 'Kuwait',
            'KG' => 'Kyrgyzstan',              'LA' => 'Laos',
            'LV' => 'Latvia',                  'LB' => 'Lebanon',
            'LS' => 'Lesotho',                 'LR' => 'Liberia',
            'LY' => 'Libya',                   'LI' => 'Liechtenstein',
            'LT' => 'Lithuania',               'LU' => 'Luxembourg',
            'MK' => 'Macedonia',               'MG' => 'Madagascar',
            'MW' => 'Malawi',                  'MY' => 'Malaysia',
            'MV' => 'Maldives',                'ML' => 'Mali',
            'MT' => 'Malta',                   'MH' => 'Marshall Islands',
            'MR' => 'Mauritania',              'MU' => 'Mauritius',
            'MX' => 'Mexico',                  'FM' => 'Micronesia',
            'MD' => 'Moldova',                 'MC' => 'Monaco',
            'MN' => 'Mongolia',                'ME' => 'Montenegro',
            'MA' => 'Morocco',                 'MZ' => 'Mozambique',
            'MM' => 'Myanmar (Burma)',         'NA' => 'Namibia',
            'NR' => 'Nauru',                   'NP' => 'Nepal',
            'NZ' => 'New Zealand',             'NI' => 'Nicaragua',
            'NE' => 'Niger',                   'NG' => 'Nigeria',
            'NO' => 'Norway',                  'OM' => 'Oman',
            'PK' => 'Pakistan',                'PW' => 'Palau',
            'PS' => 'Palestinian State*',      'PA' => 'Panama',
            'PG' => 'Papua New Guinea',        'PY' => 'Paraguay',
            'PE' => 'Peru',                    'PH' => 'The Philippines',
            'PL' => 'Poland',                  'PT' => 'Portugal',
            'QA' => 'Qatar',                   'RO' => 'Romania',
            'RU' => 'Russia',                  'RW' => 'Rwanda',
            'WS' => 'Samoa',                   'SM' => 'San Marino',
            'ST' => 'Sao Tome and Principe',   'SA' => 'Saudi Arabia',
            'SN' => 'Senegal',                 'RS' => 'Serbia',
            'SC' => 'Seychelles',              'SL' => 'Sierra Leone',
            'SG' => 'Singapore',               'SK' => 'Slovakia',
            'SI' => 'Slovenia',                'SB' => 'Solomon Islands',
            'SO' => 'Somalia',                 'ZA' => 'South Africa',
            'SS' => 'South Sudan',             'ES' => 'Spain',
            'LK' => 'Sri Lanka',               'KN' => 'St. Kitts and Nevis',
            'LC' => 'St. Lucia',               'VC' => 'St. Vincent and The Grenadines',
            'SD' => 'Sudan',                   'SR' => 'Suriname',
            'SZ' => 'Swaziland',               'SE' => 'Sweden',
            'CH' => 'Switzerland',             'SY' => 'Syria',
            'TW' => 'Taiwan',                  'TJ' => 'Tajikistan',
            'TZ' => 'Tanzania',                'TH' => 'Thailand',
            'NL' => 'The Netherlands',         'TG' => 'Togo',
            'TO' => 'Tonga',                   'TT' => 'Trinidad and Tobago',
            'TN' => 'Tunisia',                 'TR' => 'Turkey',
            'TM' => 'Turkmenistan',            'TV' => 'Tuvalu',
            'UG' => 'Uganda',                  'UA' => 'Ukraine',
            'AE' => 'United Arab Emirates',    'GB' => 'United Kingdom',
            'UK' => 'United Kingdom',          'US' => 'United States of America',
            'UY' => 'Uruguay',                 'UZ' => 'Uzbekistan',
            'VU' => 'Vanuatu',                 'VA' => 'Vatican City (Holy See)',
            'VE' => 'Venezuela',               'VN' => 'Vietnam',
            'YE' => 'Yemen',                   'ZM' => 'Zambia',
            'ZW' => 'Zimbabwe'
        };

    private static String resolveCountry(String code) {
        if (String.isBlank(code)) return null;
        String upper = code.toUpperCase().trim();
        return ISO_TO_COUNTRY_NAME.containsKey(upper)
            ? ISO_TO_COUNTRY_NAME.get(upper)
            : code;
    }

    private static String resolveCountryList(List<String> codes) {
        if (codes == null || codes.isEmpty()) return null;
        List<String> names = new List<String>();
        for (String code : codes) {
            String name = resolveCountry(code);
            if (String.isNotBlank(name)) names.add(name);
        }
        return String.join(names, ';');
    }

    // ─── PUBLIC ENTRY POINT ──────────────────────────────────────────────────

    global static WebhookResult processWebhook(NuveiConnectRequest req) {
        WebhookResult result = new WebhookResult();

        try {
            List<Compliance__c> existing = [
                SELECT Id, Name, Account__c, Compliance_Status__c,
                       Technical_Onboarding_Status__c,
                       Nuvei_Connect_Status__c, Nuvei_Connect_Last_Webhook__c,
                       Manual_MCC_Code__c, Url__c, From_Reseller__c,
                       EU_Indirect_Orchestration__c
                FROM   Compliance__c
                WHERE  Nuvei_Connect_Application_ID__c = :req.applicationId
                LIMIT  1
            ];

            if (!existing.isEmpty()) {
                handleStatusUpdate(existing[0], req);
                result.success = true;
                result.message = 'Status updated to: ' + req.applicationStatus;
            } else {
                Id complianceId = createAllObjects(req);
                result.success = true;
                result.message = 'Application created. Compliance Id: ' + complianceId;
                result.complianceId = String.valueOf(complianceId);
            }

        } catch (Exception e) {
            result.success = false;
            result.message = 'Processing error: ' + e.getMessage();
            result.errorDetail = e.getStackTraceString();
            logLegacyError('NC Webhook Processing Error', e, req.applicationId);
        }

        return result;
    }

    // ─── UPSERT PATH ────────────────────────────────────────────────────────

    private static void handleStatusUpdate(
        Compliance__c existing,
        NuveiConnectRequest req
    ) {
        if (String.isNotBlank(req.applicationStatus)) {
            String sfStatus = NC_TO_SF_STATUS.get(req.applicationStatus);
            if (sfStatus == null) {
                logLegacyError('Unknown NC status: ' + req.applicationStatus, null, req.applicationId);
                return;
            }
            existing.Nuvei_Connect_Status__c = req.applicationStatus;
            if (sfStatus != existing.Compliance_Status__c) {
                existing.Compliance_Status__c = sfStatus;
            }
        }

        if (req.businessInformation != null) {
            if (String.isNotBlank(req.businessInformation.legalName)) {
                existing.Name = req.businessInformation.legalName;
            }
            if (String.isNotBlank(req.businessInformation.websiteUrl)) {
                existing.Url__c = req.businessInformation.websiteUrl;
            }
            if (String.isNotBlank(req.businessInformation.merchantCategoryCode)) {
                existing.Manual_MCC_Code__c = req.businessInformation.merchantCategoryCode;
            }
        }

        if (req.applicationStatus == 'APPROVED' && existing.From_Reseller__c != null) {
            existing.EU_Indirect_Orchestration__c = true;
        }

        existing.Nuvei_Connect_Last_Webhook__c = DateTime.now();
        update existing;

        if (req.applicationStatus == 'APPROVED') {
            List<Banking_Details__c> bankDetails = [
                SELECT Id FROM Banking_Details__c
                WHERE Compliance__c = :existing.Id
            ];
            if (!bankDetails.isEmpty()) {
                for (Banking_Details__c bd : bankDetails) {
                    bd.UW_Approval__c = 'Verified';
                    bd.Locked__c      = true;
                }
                update bankDetails;
            }
            createConfigurationCase(existing);
        }
    }

    // ─── INSERT PATH ─────────────────────────────────────────────────────────

    private static Id createAllObjects(NuveiConnectRequest req) {
        Account acc = buildAccount(req);
        insert acc;

        String primaryEmail = req.businessInformation?.contactInformation?.businessEmail;
        String cPanelEmail  = req.additionalInformation?.portalAdminEmail;
        Boolean sameContact = String.isNotBlank(primaryEmail)
                              && String.isNotBlank(cPanelEmail)
                              && primaryEmail.equalsIgnoreCase(cPanelEmail);

        Contact con = buildContact(req, acc.Id, sameContact);
        insert con;

        if (!sameContact && String.isNotBlank(cPanelEmail)) {
            Contact cPanelCon = buildCPanelContact(req, acc.Id);
            insert cPanelCon;
        }

        Opportunity opp = buildOpportunity(req, acc.Id);
        insert opp;

        Compliance__c comp = buildCompliance(req, acc.Id, opp.Id, con.Id);
        insert comp;

        try {
            PCI__c pci = new PCI__c();
            pci.Company_Profile__c = comp.Id;
            insert pci;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'NuveiConnectWebhook | PCI__c creation failed: ' + e.getMessage());
        }

        Application_Form__c appForm = buildApplicationForm(req, comp.Id);
        insert appForm;

        if (String.isNotBlank(req.businessInformation?.websiteUrl)) {
            Website__c site = buildWebsite(req, comp.Id, appForm.Id);
            insert site;
        }

        List<Directors_or_Ultimate_Beneficial_Owner__c> directors = buildDirectors(req, comp.Id, appForm.Id);
        if (!directors.isEmpty()) insert directors;

        copyPartnerMerchantBanks(comp.Id, req.partnerId, req.bankingInformation);

        return comp.Id;
    }

    // ─── OBJECT BUILDERS ─────────────────────────────────────────────────────

    private static Account buildAccount(NuveiConnectRequest req) {
        BusinessInformationWrapper bi = req.businessInformation;
        Account acc = new Account();
        acc.Name = bi.legalName;
        acc.AccountNumber = bi.businessRegistrationNumber;
        if (String.isNotBlank(bi.websiteUrl)) {
            acc.Website = bi.websiteUrl;
        }
        if (bi.contactInformation != null) {
            acc.Phone = bi.contactInformation.contactNumber;
        }
        acc.Type = 'Merchant';
        return acc;
    }

    private static Contact buildContact(NuveiConnectRequest req, Id accountId, Boolean isCPanelAdmin) {
        Contact con = new Contact();
        con.AccountId = accountId;

        ContactInfoWrapper ci = req.businessInformation?.contactInformation;
        if (ci != null) {
            con.FirstName = ci.firstName;
            con.LastName  = String.isNotBlank(ci.lastName) ? ci.lastName : req.businessInformation.legalName;
            con.Email     = ci.businessEmail;
            con.Phone     = ci.contactNumber;
        }

        if (String.isBlank(con.LastName) && req.businessOwnerInformation != null
            && !req.businessOwnerInformation.isEmpty()) {
            BusinessOwnerWrapper bo = req.businessOwnerInformation[0];
            con.FirstName = bo.legalFirstName;
            con.LastName  = bo.legalLastName;
            con.Email     = bo.email;
            con.Phone     = bo.contactNumber;
        }

        con.Is_CPanel_Admin__c = isCPanelAdmin;
        return con;
    }

    private static Contact buildCPanelContact(NuveiConnectRequest req, Id accountId) {
        AdditionalInfoWrapper ai = req.additionalInformation;
        Contact con = new Contact();
        con.AccountId          = accountId;
        con.FirstName          = ai.portalAdminFirstName;
        con.LastName           = String.isNotBlank(ai.portalAdminLastName)
                                    ? ai.portalAdminLastName
                                    : req.businessInformation.legalName;
        con.Email              = ai.portalAdminEmail;
        con.Phone              = ai.portalAdminContactNumber;
        con.Is_CPanel_Admin__c = true;
        return con;
    }

private static Opportunity buildOpportunity(NuveiConnectRequest req, Id accountId) {
    Opportunity opp = new Opportunity();
    opp.Name      = req.businessInformation.legalName + ' — Merchant Onboarding';
    opp.AccountId = accountId;
    opp.StageName = 'Prospecting';
    opp.CloseDate = Date.today().addDays(30);

    List<RecordType> rts = [
        SELECT Id FROM RecordType 
        WHERE SObjectType = 'Opportunity' 
        AND DeveloperName = 'Safecharge'
        AND IsActive = true 
        LIMIT 1
    ];
    if (!rts.isEmpty()) {
        opp.RecordTypeId = rts[0].Id;
    }

    return opp;
}

    private static Compliance__c buildCompliance(
        NuveiConnectRequest req,
        Id accountId,
        Id oppId,
        Id contactId
    ) {
        BusinessInformationWrapper bi = req.businessInformation;
        Compliance__c comp = new Compliance__c();

        comp.Name                             = bi.legalName;
        comp.Account__c                       = accountId;
        comp.Opportunity__c                   = oppId;
        comp.Nuvei_Connect_Application_ID__c  = req.applicationId;
        comp.Compliance_Status__c             = NC_TO_SF_STATUS.get(
            String.isNotBlank(req.applicationStatus) ? req.applicationStatus : 'SUBMITTED'
        );
        comp.From_Reseller__c                 = resolvePartnerId(req.partnerId);
        comp.Nuvei_Partner_ID__c              = req.partnerId;
        comp.Manual_MCC_Code__c               = bi.merchantCategoryCode;
        comp.Company_Type__c                  = NC_TO_SF_COMPANY_TYPE.containsKey(bi.businessType)
            ? NC_TO_SF_COMPANY_TYPE.get(bi.businessType) : bi.businessType;
        comp.Url__c                           = bi.websiteUrl;
        comp.Foundation_date__c               = parseDate(bi.businessStartDate);
        comp.Trading_Name__c                  = String.isNotBlank(bi.doingBusinessAs)
            ? bi.doingBusinessAs : bi.legalName;
        comp.Incorporation_number__c          = bi.businessRegistrationNumber;

        AddressWrapper bizAddr = getAddressByType(bi.addresses, 'BUSINESS_ADDRESS');
        if (bizAddr != null) {
            comp.Registered_Country__c         = resolveCountry(bizAddr.country);
            comp.Registered_City__c            = bizAddr.city;
            comp.Registered_Street__c          = bizAddr.addressLine1;
            comp.Registered_Zip_Postal_Code__c = bizAddr.postalCode;
            if (bizAddr.country == 'GB' && String.isNotBlank(bizAddr.stateOrProvince)) {
                String sfState = NC_TO_SF_UK_STATE.get(bizAddr.stateOrProvince.toUpperCase());
                if (String.isNotBlank(sfState)) {
                    comp.State_USA__c = sfState;
                }
            }
        }

        if (req.taxDetails != null) {
            comp.VAT_Number__c  = req.taxDetails.taxIdentificationNumber;
            comp.Tax_ID_Type__c = req.taxDetails.taxIdentificationType;
        }

        if (contactId != null) {
            comp.DocuSign_Recipient__c = contactId;
        }

        return comp;
    }

    private static Application_Form__c buildApplicationForm(
        NuveiConnectRequest req,
        Id complianceId
    ) {
        Application_Form__c af = new Application_Form__c();
        af.Company_Profile__c = complianceId;

        if (req.businessInformation != null) {
            af.Company_name__c         = req.businessInformation.legalName;
            af.Company_DBA__c          = req.businessInformation.doingBusinessAs;
            af.Company_Type__c         = NC_TO_SF_COMPANY_TYPE.containsKey(req.businessInformation.businessType)
                ? NC_TO_SF_COMPANY_TYPE.get(req.businessInformation.businessType)
                : req.businessInformation.businessType;
            af.Incorporation_number__c = req.businessInformation.businessRegistrationNumber;
            af.Tax_ID_Number__c        = req.taxDetails?.taxIdentificationNumber;
            af.Tax_ID_Type__c          = req.taxDetails?.taxIdentificationType;
            af.VAT__c                  = req.taxDetails?.taxIdentificationNumber;

            AddressWrapper bizAddr = getAddressByType(req.businessInformation.addresses, 'BUSINESS_ADDRESS');
            if (bizAddr != null) {
                af.Registered_Country__c         = resolveCountry(bizAddr.country);
                af.Registered_City__c            = bizAddr.city;
                af.Registered_Street__c          = bizAddr.addressLine1;
                af.Registered_Zip_Postal_Code__c = bizAddr.postalCode;
            }

            af.Type_of_product__c = req.businessInformation.productDescription;
        }

        if (req.salesProfile != null) {
            af.Expected_Monthly_Volume__c    = req.salesProfile.expectedSalesValue?.expectedRevenue;
            af.Average_transaction_value__c  = req.salesProfile.averageTransactionValue;
            af.Maximum_Ticket_Value_1__c     = req.salesProfile.highestTicketSize;
            af.E_comm__c                     = req.salesProfile.percentageOnlineTransactions;
            af.Swipe__c                      = req.salesProfile.percentageInStoreTransactions;
            af.MOTO_Keyed__c                 = req.salesProfile.percentageMotoTransactions;
            af.Average_fulfillment_period__c = NC_TO_SF_FULFILLMENT.containsKey(req.salesProfile.averageOrderFulfillmentTime)
                ? NC_TO_SF_FULFILLMENT.get(req.salesProfile.averageOrderFulfillmentTime)
                : req.salesProfile.averageOrderFulfillmentTime;
            af.Rebilling_Required__c                  = req.salesProfile.recurringBilling;
            af.Average_Chargeback_amount_ratio__c     = mapChargebackRatio(req.salesProfile.averageChargebackRatio);
            af.Average_Refund_amount_ratio__c         = mapRefundRatio(req.salesProfile.averageRefundRatio);

            if (req.salesProfile.transactionCurrencies != null && !req.salesProfile.transactionCurrencies.isEmpty()) {
                af.Processing_Currencies_New__c = String.join(req.salesProfile.transactionCurrencies, ';');
            }
            if (req.salesProfile.targetMarkets != null && !req.salesProfile.targetMarkets.isEmpty()) {
                af.Target_Market__c = resolveCountryList(req.salesProfile.targetMarkets);
            }

            if (req.salesProfile.currentProcessor != null &&
                String.isNotBlank(req.salesProfile.currentProcessor.currentProcessorName)) {
                af.Other_CC_processors_used__c = req.salesProfile.currentProcessor.currentProcessorName;
            }
        }

        if (req.additionalInformation != null) {
            af.C_Panel_Administrator_First_Name__c    = req.additionalInformation.portalAdminFirstName;
            af.C_Panel_Administrator_Last_Name__c     = req.additionalInformation.portalAdminLastName;
            af.C_Panel_Administrator_Email_Address__c = req.additionalInformation.portalAdminEmail;
            af.C_Panel_Administrator_Phone__c         = req.additionalInformation.portalAdminContactNumber;
        }

        return af;
    }
    
        private static Id getAppFormRecordTypeId(NuveiConnectRequest req) {
        String country = '';
        AddressWrapper bizAddr = getAddressByType(
            req.businessInformation?.addresses, 'BUSINESS_ADDRESS'
        );
        if (bizAddr != null) {
            country = bizAddr.country?.toUpperCase();
        }

        String devName;
        if (country == 'GB') {
            devName = 'UK';
        } else if (new Set<String>{'MX'}.contains(country)) {
            devName = 'Mexico';
        } else if (new Set<String>{'US', 'CA'}.contains(country)) {
            devName = 'US_Ecommerce';
        } else {
            devName = 'Ecommerce';
        }

        List<RecordType> rts = [
            SELECT Id FROM RecordType 
            WHERE SObjectType = 'Application_Form__c' 
            AND DeveloperName = :devName
            AND IsActive = true 
            LIMIT 1
        ];
        return rts.isEmpty() ? null : rts[0].Id;
    }

    private static Website__c buildWebsite(NuveiConnectRequest req, Id complianceId, Id appFormId) {
        Website__c site = new Website__c();
        site.Compliance__c       = complianceId;
        site.Application_Form__c = appFormId;
        site.URL__c              = req.businessInformation.websiteUrl;
        site.Primary_URL__c      = true;
        return site;
    }

    private static List<Directors_or_Ultimate_Beneficial_Owner__c> buildDirectors(
        NuveiConnectRequest req,
        Id complianceId,
        Id appFormId
    ) {
        List<Directors_or_Ultimate_Beneficial_Owner__c> directors = new List<Directors_or_Ultimate_Beneficial_Owner__c>();
        if (req.businessOwnerInformation == null) return directors;

        for (BusinessOwnerWrapper bo : req.businessOwnerInformation) {
            Directors_or_Ultimate_Beneficial_Owner__c d = new Directors_or_Ultimate_Beneficial_Owner__c();
            d.Company_Profile__c  = complianceId;
            d.Application_Form__c = appFormId;
            d.First_Name__c       = bo.legalFirstName;
            d.Last_Name__c        = bo.legalLastName;
            d.Email__c            = bo.email;
            d.Date_of_Birth__c    = parseDate(bo.dateOfBirth);
            d.If_Owner_Percentage_held__c = bo.percentageOfOwnership;
            d.Phone__c            = bo.contactNumber;
            d.Nationality__c      = resolveCountry(bo.nationality);
            d.Organization_Role__c = bo.ownerRole;

            if (bo.homeAddress != null) {
                d.Country__c         = resolveCountry(bo.homeAddress.country);
                d.City__c            = bo.homeAddress.city;
                d.Street__c          = bo.homeAddress.addressLine1;
                d.Zip_Postal_Code__c = bo.homeAddress.postalCode;
            }
            directors.add(d);
        }
        return directors;
    }

    // ─── PARTNER BANK COPY + BANKING_DETAILS__c ──────────────────────────────

    private static void copyPartnerMerchantBanks(
        Id complianceId,
        String partnerId,
        List<BankingInfoWrapper> bankingInfo
    ) {
        if (String.isBlank(partnerId)) {
            createBankingDetails(complianceId, bankingInfo);
            return;
        }

        Id partnerComplianceId = resolvePartnerId(partnerId);
        if (partnerComplianceId == null) {
            logLegacyError('Partner not found for partnerId: ' + partnerId, null, partnerId);
            createBankingDetails(complianceId, bankingInfo);
            return;
        }

        try {
            List<Merchant_Bank__c> templates = [
                SELECT Id, RecordTypeId,
                       CHB_Handling__c, Credit_Fee_Per_Credit__c, Trx_Fee__c,
                       Discount_Fee_ALL_Value_1__c,
                       Discount_Fee_EU_Value_1__c,
                       Discount_Fee_ROW_Value_1__c,
                       Industry__c
                FROM   Merchant_Bank__c
                WHERE  Compliance__c = :partnerComplianceId
                AND    Partner_Template_Pricing__c = true
            ];

            if (!templates.isEmpty()) {
                String templateIndustry = templates[0].Industry__c;
                if (String.isNotBlank(templateIndustry)) {
                    update new Compliance__c(
                        Id          = complianceId,
                        Industry__c = templateIndustry
                    );
                }

                List<Merchant_Bank__c> newBanks = new List<Merchant_Bank__c>();
                for (Merchant_Bank__c t : templates) {
                    Merchant_Bank__c nb = t.clone(false, true, false, false);
                    nb.Compliance__c               = complianceId;
                    nb.Partner_Template_Pricing__c = false;
                    newBanks.add(nb);
                }
                insert newBanks;
            }
        } catch (Exception e) {
            logLegacyError('Failed to copy partner merchant banks', e, partnerId);
        }

        createBankingDetails(complianceId, bankingInfo);
    }

    private static void createBankingDetails(
        Id complianceId,
        List<BankingInfoWrapper> bankingInfo
    ) {
        if (bankingInfo == null || bankingInfo.isEmpty()) return;

        List<Banking_Details__c> records = new List<Banking_Details__c>();
        for (BankingInfoWrapper bank : bankingInfo) {
            Banking_Details__c bd = new Banking_Details__c();
            bd.Compliance__c          = complianceId;
            bd.Account_Holder_Name__c = bank.accountHolderName;
            bd.bankCountry__c         = resolveCountry(bank.bankCountry);
            bd.Target_Currency__c     = bank.accountCurrency;

            if (String.isNotBlank(bank.iban)) {
                bd.IBAN__c       = bank.iban;
                bd.swift_code__c = bank.swiftCode;
            } else if (String.isNotBlank(bank.sortCode)) {
                bd.Account_number__c = bank.accountNumber;
                bd.branchCode__c     = bank.sortCode;
            }
            records.add(bd);
        }
        if (!records.isEmpty()) insert records;
    }

    // ─── HELPERS ─────────────────────────────────────────────────────────────

    private static AddressWrapper getAddressByType(
        List<AddressWrapper> addresses, String addressType
    ) {
        if (addresses == null) return null;
        for (AddressWrapper a : addresses) {
            if (a.addressType == addressType) return a;
        }
        return addresses.isEmpty() ? null : addresses[0];
    }

    private static Date parseDate(String val) {
        if (String.isBlank(val)) return null;
        try { return Date.valueOf(val); } catch (Exception e) { return null; }
    }

    private static Id resolvePartnerId(String partnerId) {
        if (String.isBlank(partnerId)) return null;
        List<Compliance__c> partners = [
            SELECT Id FROM Compliance__c
            WHERE  Nuvei_Partner_ID__c = :partnerId
            LIMIT  1
        ];
        return partners.isEmpty() ? null : partners[0].Id;
    }

    private static void createConfigurationCase(Compliance__c comp) {
        try {
            List<Contact> cPanelContacts = [
                SELECT Id, Email FROM Contact
                WHERE  AccountId = :comp.Account__c
                AND    Is_CPanel_Admin__c = true
                LIMIT  1
            ];
            List<RecordType> rts = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Case' AND DeveloperName = 'Configuration'
                LIMIT 1
            ];
            if (rts.isEmpty()) {
                System.debug(LoggingLevel.ERROR,
                    'NuveiConnectWebhook | Configuration RecordType not found — Case not created');
                return;
            }
            Case c = new Case();
            c.RecordTypeId       = rts[0].Id;
            c.Subject            = 'Creating EU Indirect Merchant — ' + comp.Name;
            c.Company_Profile__c = comp.Id;
            c.Status             = 'In Progress';
            c.Reason             = 'New Merchant';
            c.Type               = 'Create new GW account with a new Multi';
            c.Profile__c         = 'Merchant and merchantSite onboarding NCP acquiring CNP';
            c.Profile_Type__c    = 'None';
            if (!cPanelContacts.isEmpty()) {
                c.ContactId          = cPanelContacts[0].Id;
                c.SB_PPP_Username__c = cPanelContacts[0].Email;
            }
            List<ExpressConfig__c> cfgRows = [
                SELECT SB_Template__c FROM ExpressConfig__c LIMIT 1
            ];
            if (!cfgRows.isEmpty() && String.isNotBlank(cfgRows[0].SB_Template__c)) {
                c.SB_Template__c = cfgRows[0].SB_Template__c;
            }
            insert c;
        } catch (Exception e) {
            logLegacyError('createConfigurationCase failed', e, comp.Nuvei_Connect_Application_ID__c);
        }
    }

    // ─── ERROR LOGGING ───────────────────────────────────────────────────────

    private static void logLegacyError(String message, Exception e, String context) {
        String errorMsg = message != null ? message : 'Unknown error';
        System.debug(LoggingLevel.ERROR,
            'NuveiConnectWebhook ERROR | context=' + context
            + ' | message=' + errorMsg
            + (e != null ? ' | exception=' + e.getTypeName()
               + ' | trace=' + e.getStackTraceString() : ''));
        try {
            Execution_Log__c el = new Execution_Log__c(
                RecordTypeId         = RT_EL_NC,
                Class_Name__c        = 'NuveiConnectWebhookHandler',
                Initiated_By__c      = UserInfo.getUserId(),
                Method_Name__c       = 'logLegacyError',
                Note__c              = errorMsg,
                Payload__c           = context,
                Description__c       = e != null ? e.getMessage() : errorMsg,
                Path__c              = e != null ? e.getStackTraceString() : '',
                Related_Record_Id__c = context,
                Status_Code__c       = 400,
                Type__c              = 'Error'
            );
            WithoutSharingUtils.insertRecord(el);
        } catch (Exception logEx) {
            System.debug(LoggingLevel.ERROR,
                'NuveiConnectWebhook | Failed to write Execution_Log__c: '
                + logEx.getMessage());
        }
    }

    // ─── WRAPPER CLASSES ─────────────────────────────────────────────────────

    global class NuveiConnectRequest {
        public String applicationId;
        public String applicationStatus;
        public String rawPayload;
        public BusinessInformationWrapper businessInformation;
        public List<BusinessOwnerWrapper> businessOwnerInformation;
        public List<BankingInfoWrapper>   bankingInformation;
        public SalesProfileWrapper        salesProfile;
        public TaxDetailsWrapper          taxDetails;
        public AdditionalInfoWrapper      additionalInformation;
        public MetadataWrapper            metadata;
        public String partnerId {
            get { return metadata?.partnerId; }
        }
    }

    global class BusinessInformationWrapper {
        public String legalName;
        public String doingBusinessAs;
        public String businessType;
        public String merchantCategoryCode;
        public String productCategory;
        public String productDescription;
        public String businessRegistrationNumber;
        public String businessStartDate;
        public String websiteUrl;
        public List<AddressWrapper> addresses;
        public ContactInfoWrapper   contactInformation;
    }

    global class ContactInfoWrapper {
        public String firstName;
        public String lastName;
        public String businessEmail;
        public String contactNumber;
    }

    global class AddressWrapper {
        public String addressType;
        public String country;
        public String stateOrProvince;
        public String city;
        public String postalCode;
        public String addressLine1;
        public String addressLine2;
    }

    global class BusinessOwnerWrapper {
        public String  legalFirstName;
        public String  legalLastName;
        public String  dateOfBirth;
        public String  nationality;
        public String  email;
        public String  contactNumber;
        public Decimal percentageOfOwnership;
        public String  ownerRole;
        public AddressWrapper homeAddress;
    }

    global class BankingInfoWrapper {
        public String bankCountry;
        public String accountHolderName;
        public String accountCurrency;
        public String iban;
        public String swiftCode;
        public String accountNumber;
        public String sortCode;
    }

    global class SalesProfileWrapper {
        public Decimal averageTransactionValue;
        public Decimal highestTicketSize;
        public ExpectedSalesWrapper expectedSalesValue;
        public Decimal percentageOnlineTransactions;
        public Decimal percentageInStoreTransactions;
        public Decimal percentageMotoTransactions;
        public String  averageOrderFulfillmentTime;
        public Boolean recurringBilling;
        public Decimal averageChargebackRatio;
        public Decimal averageRefundRatio;
        public List<String> transactionCurrencies;
        public List<String> targetMarkets;
        public CurrentProcessorWrapper currentProcessor;
    }

    global class CurrentProcessorWrapper {
        public String  currentProcessorName;
        public Integer yearsWithCurrentProcessor;
    }

    global class ExpectedSalesWrapper {
        public String  period;
        public Decimal expectedRevenue;
        public Decimal expectedTransactionVolume;
    }

    global class TaxDetailsWrapper {
        public String  taxIdentificationNumber;
        public String  taxIdentificationType;
        public String  taxIssuingCountry;
        public String  taxRegistrationState;
        public String  taxClassificationType;
        public Boolean isGstExempt;
    }

    global class AdditionalInfoWrapper {
        public String portalAdminFirstName;
        public String portalAdminLastName;
        public String portalAdminEmail;
        public String portalAdminContactNumber;
    }

    global class MetadataWrapper {
        public String partnerId;
    }

    global class WebhookResult {
        public Boolean success = false;
        public String  message;
        public String  errorDetail;
        public String  complianceId;
    }
}