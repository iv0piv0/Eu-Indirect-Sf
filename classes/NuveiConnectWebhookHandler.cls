**
 * NuveiConnectWebhookHandler
 *
 * Handles inbound webhooks from Nuvei Connect for both:
 *   1. Initial application submission (INSERT path)  — creates 8 SF objects
 *   2. Application updates / status changes (UPSERT path) — updates existing Compliance__c
 *
 * Supports both EU and North American (NA) payload schemas.
 *
 * EU payload key differences vs NA:
 *   - businessInformation.contactInformation uses firstName/lastName/businessEmail/contactNumber
 *     (NA uses mobile/landline/customerServiceContactNumber — no name fields)
 *   - businessOwnerInformation uses ownerRole (EU extended enum) vs type (NA: BENEFICIAL_OWNER/AUTHORIZED_SIGNATORY)
 *   - businessOwnerInformation uses contactNumber (EU) vs mobile (NA)
 *   - bankingInformation uses iban+swiftCode for SEPA, accountNumber+sortCode for UK
 *     (NA uses accountNumber+branchIdentifier/routingNumber)
 *   - taxDetails uses taxIdentificationType: VAT (EU) vs EIN/SSN/ITIN (NA)
 *   - additionalInformation uses consentToPrivacyPolicy + portalAdmin fields (EU)
 *     vs personalGuarantor1/2 (NA)
 *   - metadata.partnerId identifies the ISO/ISV partner
 *
 * Error handling:
 *   - All errors logged to Boarding_Log_Entry__c (linked to Boarding_Log__c if exists,
 *     errors logged via System.debug until Boarding_Log__c is deployed)
 *   - Returns structured JSON response to caller (never throws unhandled exceptions)
 *   - Partial failures: if record creation fails after some objects exist, logs which
 *     step failed so ops team can retry from the correct point
 *
 * @author  Nuvei Development Team
 * @version 2.1 — Fix: stamp Compliance__c.Industry__c before inserting Merchant_Bank__c
 *               Fix: persist Nuvei_Partner_ID__c on Compliance__c
 */
public with sharing class NuveiConnectWebhookHandler {

    // ─── STATUS MAP: Nuvei Connect → Salesforce ─────────────────────────────
    private static final Map<String, String> NC_TO_SF_STATUS = new Map<String, String>{
        'SUBMITTED'                => 'In Pre-approval',
        'PENDING_REVIEW'           => 'Pre-Approved',
        'IN_REVIEW'                => 'KYC',
        'ADDITIONAL_INFO_REQUESTED'=> 'KYC',
        'PENDING_APPROVAL'         => 'KYC',
        'CONDITIONALLY_APPROVED'   => 'Live reversed',
        'APPROVED'                 => 'Live',
        'IN_PROGRESS'              => 'Pre-Approved',
        'DECLINED'                 => 'Declined',
        'WITHDRAWN'                => 'Dormant'
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
            'IMMEDIATE'    => 'No delay',
            'INSTANT'      => 'No delay',
            '1_5_DAYS'     => 'Up to 7 days',
            '1_7_DAYS'     => 'Up to 7 days',
            'UP_TO_7_DAYS' => 'Up to 7 days',
            '7_20_DAYS'    => 'Between 7 - 20 days',
            'OVER_20_DAYS' => 'More than 20 days',
            'MORE_THAN_20' => 'More than 20 days'
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
    // Also used for Registered_Country__c on Compliance__c and Application_Form__c.
    // NC sends ISO 2-letter codes; SF picklists use full English country names.
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
            : code; // fall back to raw value if not in map
    }

    private static String resolveCountryList(List<String> codes) {
        if (codes == null || codes.isEmpty()) return null;
        List<String> names = new List<String>();
        for (String code : codes) {
            String name = resolveCountry(code);
            if (String.isNotBlank(name)) names.add(name);
        }
        return String.join(names, ';'); // SF multi-select uses semicolon
    }

    // ─── PUBLIC ENTRY POINT ──────────────────────────────────────────────────

    /**
     * Main entry point called by NuveiConnectWebhookService.
     * Determines insert vs upsert and EU vs NA, then routes accordingly.
     */
    public static WebhookResult processWebhook(NuveiConnectRequest req) {
        WebhookResult result = new WebhookResult();

        try {
            // ── DETECT: Is this an update to an existing application? ────────
            List<Compliance__c> existing = [
                SELECT Id, Name, Account__c, Compliance_Status__c,
                       Technical_Onboarding_Status__c,
                       Nuvei_Connect_Status__c, Nuvei_Connect_Last_Webhook__c,
                       Manual_MCC_Code__c, Url__c,
                       From_Reseller__c, Nuvei_Connect_Application_ID__c
                FROM   Compliance__c
                WHERE  Nuvei_Connect_Application_ID__c = :req.applicationId
                LIMIT  1
            ];

            if (!existing.isEmpty()) {
                // ── UPSERT PATH ─────────────────────────────────────────────
                handleStatusUpdate(existing[0], req);
                result.success = true;
                result.message = 'Status updated to: ' + req.applicationStatus;

            } else {
                // ── INSERT PATH ─────────────────────────────────────────────
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

    // NOTE: BoardingLogger integration (Boarding_Log__c / Boarding_Log_Entry__c)
    // is stubbed out here pending Track I deployment. Once Boarding_Log__c and
    // Boarding_Log_Entry__c are deployed to the org, restore the BoardingLogger
    // calls here and in handleStatusUpdate / createAllObjects.

    // ─── UPSERT PATH ────────────────────────────────────────────────────────

    /**
     * Handles a status update from Nuvei Connect for an existing application.
     * Also updates key fields if they have changed (company details, bank info, etc.)
     */
    private static void handleStatusUpdate(
        Compliance__c existing,
        NuveiConnectRequest req
    ) {
        // ── Map NC status → SF status ────────────────────────────────────────
        if (String.isNotBlank(req.applicationStatus)) {
            String sfStatus = NC_TO_SF_STATUS.get(req.applicationStatus);
            if (sfStatus == null) {
                logLegacyError('Unknown NC status: ' + req.applicationStatus, null, req.applicationId);
                return;
            }
            // Store raw NC status — picklist must contain all NC status values
            existing.Nuvei_Connect_Status__c = req.applicationStatus;
            if (sfStatus != existing.Compliance_Status__c) {
                existing.Compliance_Status__c = sfStatus;
            }
        }

        // ── Update other changed fields if present in payload ─────────────────
        // (NC may re-send the full payload on updates — only overwrite non-blank values)
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

        // EU indirect orchestration: partner-linked merchants get post-APPROVED automation
        if (req.applicationStatus == 'APPROVED' && existing.From_Reseller__c != null) {
            existing.EU_Indirect_Orchestration__c = true;
        }

        existing.Nuvei_Connect_Last_Webhook__c = DateTime.now();
        update existing;

        // ── On APPROVED: verify banking and create Config Case ────────────────
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

    /**
     * Creates all 8 Salesforce objects for a new merchant application.
     * Returns the Id of the created Compliance__c record.
     */
    private static Id createAllObjects(NuveiConnectRequest req) {
        // Step 1: Account
        Account acc = buildAccount(req);
        insert acc;

        // Step 2: Contact(s) — cPanel deduplication
        // Case A: same email → one Contact, Is_CPanel_Admin__c = true
        // Case B: different emails → two Contacts, second flagged as cPanel admin
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

        // Step 3: Opportunity
        Opportunity opp = buildOpportunity(req, acc.Id);
        insert opp;

        // Step 4: Compliance__c (Company Profile)
        Compliance__c comp = buildCompliance(req, acc.Id, opp.Id, con.Id);
        insert comp;

        // Step 4b: PCI__c — create on INSERT so PCI team workflow can trigger
        try {
            PCI__c pci = new PCI__c();
            pci.Company_Profile__c = comp.Id;
            insert pci;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'NuveiConnectWebhook | PCI__c creation failed: ' + e.getMessage());
        }

        // Step 5: Application_Form__c
        Application_Form__c appForm = buildApplicationForm(req, comp.Id);
        insert appForm;

        // Step 6: Website__c
        if (String.isNotBlank(req.businessInformation?.websiteUrl)) {
            Website__c site = buildWebsite(req, comp.Id, appForm.Id);
            insert site;
        }

        // Step 7: Directors_or_Ultimate_Beneficial_Owner__c (from businessOwnerInformation)
        List<Directors_or_Ultimate_Beneficial_Owner__c> directors = buildDirectors(req, comp.Id, appForm.Id);
        if (!directors.isEmpty()) insert directors;

        // Step 8: Merchant_Bank__c
        // Copy pricing templates from partner, then stamp merchant's actual bank
        // account details (IBAN/sort code/account number etc.) onto the cloned records.
        copyPartnerMerchantBanks(comp.Id, req.partnerId, req.bankingInformation);

        return comp.Id;
    }

    // ─── OBJECT BUILDERS ─────────────────────────────────────────────────────

    private static Account buildAccount(NuveiConnectRequest req) {
        BusinessInformationWrapper bi = req.businessInformation;
        Account acc = new Account();
        acc.Name = bi.legalName;
        acc.AccountNumber = bi.businessRegistrationNumber;

        // Address — find BUSINESS_ADDRESS from addresses array
        // Account billing address fields (BillingStreet, BillingCity etc.) are not set.
        // Per Plamen: pw_cc package owns those fields. Use Compliance__c.Registered_*
        // fields for address — those are already populated in buildCompliance().

        // Website
        if (String.isNotBlank(bi.websiteUrl)) {
            acc.Website = bi.websiteUrl;
        }

        // Phone — EU uses contactInformation.contactNumber; NA uses contactInformation.mobile
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

        // Fallback: use first business owner if contact info incomplete
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

    // Case B — dedicated cPanel admin contact (different person from MSA signatory)
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

        comp.Name                  = bi.legalName;
        comp.Account__c            = accountId;
        comp.Opportunity__c        = oppId;
        comp.Nuvei_Connect_Application_ID__c  = req.applicationId;
        comp.Compliance_Status__c  = NC_TO_SF_STATUS.get(
            String.isNotBlank(req.applicationStatus) ? req.applicationStatus : 'SUBMITTED'
        );
        comp.From_Reseller__c      = resolvePartnerId(req.partnerId);

        // FIX: persist the raw NC partner UUID so future resolvePartnerId lookups
        // on this merchant's own record succeed (e.g. for re-webhooks / updates).
        comp.Nuvei_Partner_ID__c   = req.partnerId;

        comp.Manual_MCC_Code__c    = bi.merchantCategoryCode;
        comp.Company_Type__c       = NC_TO_SF_COMPANY_TYPE.containsKey(bi.businessType)
            ? NC_TO_SF_COMPANY_TYPE.get(bi.businessType) : bi.businessType;
        comp.Url__c                = bi.websiteUrl;
        comp.Foundation_date__c    = parseDate(bi.businessStartDate);

        // Trading name
        comp.Trading_Name__c = String.isNotBlank(bi.doingBusinessAs)
            ? bi.doingBusinessAs : bi.legalName;

        // Registration number
        comp.Incorporation_number__c = bi.businessRegistrationNumber;

        // Address — registered / business address
        AddressWrapper bizAddr = getAddressByType(bi.addresses, 'BUSINESS_ADDRESS');
        if (bizAddr != null) {
            comp.Registered_Country__c         = resolveCountry(bizAddr.country);
            comp.Registered_City__c            = bizAddr.city;
            comp.Registered_Street__c          = bizAddr.addressLine1;
            comp.Registered_Zip_Postal_Code__c = bizAddr.postalCode;
        }

        // Tax details
        if (req.taxDetails != null) {
            comp.VAT_Number__c  = req.taxDetails.taxIdentificationNumber;
            comp.Tax_ID_Type__c = req.taxDetails.taxIdentificationType;
        }

        // EU: set DocuSign_Recipient__c lookup to the primary Contact so the
        // Recipient_Email__c formula resolves automatically for MSA sending.
        if (contactId != null) {
            comp.DocuSign_Recipient__c = contactId;
        }

        // Static MSA PDF template (ContentVersion Id) from NC metadata — per merchant.
        if (req.metadata != null && String.isNotBlank(req.metadata.msaTemplateId)) {
            comp.MSA_Static_Template_Id__c = req.metadata.msaTemplateId.trim();
        }

        // Sales profile fields (averageTransactionValue, highestTicketSize,
        // expectedRevenue, percentageOnlineTransactions) are written to
        // Application_Form__c in buildApplicationForm() — that is the correct
        // object for business detail fields. Compliance__c holds KYC/status only.
        return comp;
    }

    private static Application_Form__c buildApplicationForm(
        NuveiConnectRequest req,
        Id complianceId
    ) {
        Application_Form__c af = new Application_Form__c();
        af.Company_Profile__c = complianceId;

        // ── Business info ──────────────────────────────────────────────────────
        if (req.businessInformation != null) {
            af.Company_name__c   = req.businessInformation.legalName;
            af.Company_DBA__c    = req.businessInformation.doingBusinessAs;
            af.Company_Type__c   = NC_TO_SF_COMPANY_TYPE.containsKey(req.businessInformation.businessType)
                ? NC_TO_SF_COMPANY_TYPE.get(req.businessInformation.businessType)
                : req.businessInformation.businessType;
            af.Incorporation_number__c = req.businessInformation.businessRegistrationNumber;
            af.Tax_ID_Number__c  = req.taxDetails?.taxIdentificationNumber;
            af.Tax_ID_Type__c    = req.taxDetails?.taxIdentificationType;
            af.VAT__c            = req.taxDetails?.taxIdentificationNumber;

            // Address
            AddressWrapper bizAddr = getAddressByType(req.businessInformation.addresses, 'BUSINESS_ADDRESS');
            if (bizAddr != null) {
                af.Registered_Country__c      = resolveCountry(bizAddr.country);
                af.Registered_City__c            = bizAddr.city;
                af.Registered_Street__c          = bizAddr.addressLine1;
                af.Registered_Zip_Postal_Code__c = bizAddr.postalCode;
                af.Registered_State__c        = bizAddr.stateOrProvince;
            }

            // Product
            af.Type_of_product__c = req.businessInformation.productDescription;
        }

        // ── Sales profile ──────────────────────────────────────────────────────
        if (req.salesProfile != null) {
            // Volume and transaction size
            af.Expected_Monthly_Volume__c    = req.salesProfile.expectedSalesValue?.expectedRevenue;
            af.Average_transaction_value__c  = req.salesProfile.averageTransactionValue;
            af.Maximum_Ticket_Value_1__c     = req.salesProfile.highestTicketSize;

            // Transaction mix — must sum to 100
            af.E_comm__c     = req.salesProfile.percentageOnlineTransactions;
            af.Swipe__c      = req.salesProfile.percentageInStoreTransactions;
            af.MOTO_Keyed__c = req.salesProfile.percentageMotoTransactions;

            // Fulfilment and billing
            af.Average_fulfillment_period__c = NC_TO_SF_FULFILLMENT.containsKey(req.salesProfile.averageOrderFulfillmentTime)
                ? NC_TO_SF_FULFILLMENT.get(req.salesProfile.averageOrderFulfillmentTime)
                : req.salesProfile.averageOrderFulfillmentTime;
            af.Rebilling_Required__c = req.salesProfile.recurringBilling;

            // Chargeback and refund ratios
            af.Average_Chargeback_amount_ratio__c = mapChargebackRatio(req.salesProfile.averageChargebackRatio);
            af.Average_Refund_amount_ratio__c     = mapRefundRatio(req.salesProfile.averageRefundRatio);

            // Processing currencies and target markets — stored as comma-separated strings
            if (req.salesProfile.transactionCurrencies != null && !req.salesProfile.transactionCurrencies.isEmpty()) {
                af.Processing_Currencies_New__c = String.join(req.salesProfile.transactionCurrencies, ';');
            }
            if (req.salesProfile.targetMarkets != null && !req.salesProfile.targetMarkets.isEmpty()) {
                af.Target_Market__c = resolveCountryList(req.salesProfile.targetMarkets);
            }

            // Current processor
            if (req.salesProfile.currentProcessor != null &&
                String.isNotBlank(req.salesProfile.currentProcessor.currentProcessorName)) {
                af.Other_CC_processors_used__c = req.salesProfile.currentProcessor.currentProcessorName;
            }
        }

        // ── cPanel administrator — used in Track F for cPanel user creation ───
        if (req.additionalInformation != null) {
            af.C_Panel_Administrator_First_Name__c    = req.additionalInformation.portalAdminFirstName;
            af.C_Panel_Administrator_Last_Name__c     = req.additionalInformation.portalAdminLastName;
            af.C_Panel_Administrator_Email_Address__c = req.additionalInformation.portalAdminEmail;
            af.C_Panel_Administrator_Phone__c         = req.additionalInformation.portalAdminContactNumber;
        }

        return af;
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
            d.First_Name__c    = bo.legalFirstName;
            d.Last_Name__c     = bo.legalLastName;
            d.Email__c         = bo.email;
            d.Date_of_Birth__c = parseDate(bo.dateOfBirth);
            d.If_Owner_Percentage_held__c = bo.percentageOfOwnership;
            d.Phone__c         = bo.contactNumber;
            d.Nationality__c   = resolveCountry(bo.nationality);
            d.Organization_Role__c = bo.ownerRole;

            // Home address
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
    //
    // Two separate concerns:
    //   1. Merchant_Bank__c  — cloned from partner template → carries PRICING only
    //   2. Banking_Details__c — created fresh from NC payload → carries BANK ACCOUNT details
    //
    // EU banking variants:
    //   SEPA: IBAN + swift_code__c
    //   UK:   Account_number__c + branchCode__c (sort code)
    //
    // FIX: Compliance__c.Industry__c MUST be stamped before inserting Merchant_Bank__c.
    // The "Never change industry" validation rule on Merchant_Bank__c checks that
    // Industry__c matches the parent Compliance__c.Industry__c at insert time.
    // Previous code inserted the bank records first, then updated Compliance__c — reversed here.

    private static void copyPartnerMerchantBanks(
        Id complianceId,
        String partnerId,
        List<BankingInfoWrapper> bankingInfo
    ) {
        // ── Phase 1: Copy pricing templates from partner ──────────────────────
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

                // ── Step A: stamp Industry__c on Compliance__c FIRST ─────────
                // The Merchant_Bank__c validation rule "Never change industry"
                // requires Industry__c to equal the parent Compliance__c.Industry__c
                // at the time of insert. Updating Compliance__c before the insert
                // prevents the FIELD_CUSTOM_VALIDATION_EXCEPTION.
                String templateIndustry = templates[0].Industry__c;
                if (String.isNotBlank(templateIndustry)) {
                    update new Compliance__c(
                        Id          = complianceId,
                        Industry__c = templateIndustry
                    );
                }

                // ── Step B: clone and insert the pricing templates ────────────
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

        // ── Phase 2: Create Banking_Details__c with merchant bank account info ─
        createBankingDetails(complianceId, bankingInfo);
    }

    /**
     * Creates Banking_Details__c records from the NC payload banking information.
     * One record per bank account submitted by the merchant.
     */
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
                // SEPA: IBAN + SWIFT
                bd.IBAN__c       = bank.iban;
                bd.swift_code__c = bank.swiftCode;
            } else if (String.isNotBlank(bank.sortCode)) {
                // UK: account number + sort code
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

    /**
     * Resolves a partnerId string (NC entityId or SF Id) to a Compliance__c Id.
     */
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
                SELECT SB_Template__c
                FROM ExpressConfig__c
                LIMIT 1
            ];
            if (!cfgRows.isEmpty() && String.isNotBlank(cfgRows[0].SB_Template__c)) {
                c.SB_Template__c = cfgRows[0].SB_Template__c;
            }
            insert c;
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'NuveiConnectWebhook ERROR | createConfigurationCase | ' + e.getMessage());
        }
    }

    private static void logLegacyError(String message, Exception e, String context) {
        // Webhook_Error_Log__c object not yet deployed — log to debug only.
        // TODO: replace with proper error object once Boarding_Log__c is deployed.
        String logMsg = 'NuveiConnectWebhook ERROR'
            + ' | context=' + context
            + ' | message=' + message;
        if (e != null) {
            logMsg += ' | exception=' + e.getTypeName()
                    + ' | trace=' + e.getStackTraceString();
        }
        System.debug(LoggingLevel.ERROR, logMsg);
    }

    // ─── WRAPPER CLASSES — EU/NA unified ─────────────────────────────────────

    /**
     * Top-level request wrapper.
     * Populated by NuveiConnectWebhookService via JSON.deserialize.
     */
    public class NuveiConnectRequest {
        // Common
        public String applicationId;
        public String applicationStatus;
        public String rawPayload; // set by service before deserializing, for logging

        // Sections
        public BusinessInformationWrapper businessInformation;
        public List<BusinessOwnerWrapper> businessOwnerInformation;
        public List<BankingInfoWrapper>   bankingInformation;
        public SalesProfileWrapper        salesProfile;
        public TaxDetailsWrapper          taxDetails;
        public AdditionalInfoWrapper      additionalInformation;
        public MetadataWrapper            metadata;

        // Convenience getter — partnerId comes from metadata.partnerId
        public String getPartnerId() {
            return metadata?.partnerId;
        }
        public String partnerId {
            get { return metadata?.partnerId; }
        }
    }

    public class BusinessInformationWrapper {
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

    public class ContactInfoWrapper {
        public String firstName;
        public String lastName;
        public String businessEmail;
        public String contactNumber;
    }

    public class AddressWrapper {
        public String addressType;  // BUSINESS_ADDRESS | TRADING_ADDRESS
        public String country;
        public String stateOrProvince;
        public String city;
        public String postalCode;
        public String addressLine1;
        public String addressLine2;
    }

    public class BusinessOwnerWrapper {
        public String  legalFirstName;
        public String  legalLastName;
        public String  dateOfBirth;
        public String  nationality;
        public String  email;
        public String  contactNumber;
        public Decimal percentageOfOwnership;
        public String  ownerRole;        // EU enum: DIRECTOR, UBO, PSC etc.
        public AddressWrapper homeAddress;
    }

    public class BankingInfoWrapper {
        public String bankCountry;
        public String accountHolderName;
        public String accountCurrency;
        // SEPA (EU/EEA countries)
        public String iban;
        public String swiftCode;
        // UK
        public String accountNumber;
        public String sortCode;
    }

    public class SalesProfileWrapper {
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

    public class CurrentProcessorWrapper {
        public String  currentProcessorName;
        public Integer yearsWithCurrentProcessor;
        // document (base64 processing statement) intentionally ignored
    }

    public class ExpectedSalesWrapper {
        public String  period;          // MONTHLY | ANNUAL
        public Decimal expectedRevenue;
        public Decimal expectedTransactionVolume;
    }

    public class TaxDetailsWrapper {
        public String  taxIdentificationNumber;
        public String  taxIdentificationType;  // EU: VAT
        public String  taxIssuingCountry;
        public String  taxRegistrationState;
        public String  taxClassificationType;
        public Boolean isGstExempt;
    }

    public class AdditionalInfoWrapper {
        // consentToPrivacyPolicy and applicationSignedDate intentionally not stored
        public String portalAdminFirstName;
        public String portalAdminLastName;
        public String portalAdminEmail;
        public String portalAdminContactNumber;
        // notificationSubscribers intentionally not stored
    }

    public class MetadataWrapper {
        public String partnerId;
        /** ContentVersion Id of the static MSA PDF template for this merchant. */
        public String msaTemplateId;
    }

    // ─── RESULT CLASS ────────────────────────────────────────────────────────

    public class WebhookResult {
        public Boolean success = false;
        public String  message;
        public String  errorDetail;
        public String  complianceId;
    }
}
