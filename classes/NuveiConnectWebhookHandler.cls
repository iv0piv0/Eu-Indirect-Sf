@RestResource(urlMapping='/nuveiConnectWebhook')
global without sharing class NuveiConnectWebhookHandler {
       @HttpPost
    global static void handlePost() {
        RestRequest req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        String body = req.requestBody == null ? '' : req.requestBody.toString();

        // Phase 1 — log inbound (fast, <100ms). Never blocks the ACK.
        Id logId;
        try {
            Execution_Log__c logRow = new Execution_Log__c(
                Class_Name__c  = 'NuveiConnectWebhookHandler',
                Method_Name__c = 'handlePost',
                Type__c        = 'Info',
                Note__c        = 'NC Webhook Inbound Payload (async queued)',
                Payload__c     = String.isBlank(body) ? '(empty body)' : body.left(131072)
            );
            insert logRow;
            logId = logRow.Id;
        } catch (Exception ignore) { /* never block ACK on logging */ }

        // Phase 2 — sanity check that the payload is parseable JSON.
        // Malformed JSON gets a 400 immediately (NC won't retry a 400).
        try {
            JSON.deserializeUntyped(body);
        } catch (Exception badJson) {
            res.statusCode = 400;
            res.responseBody = Blob.valueOf(
                '{"success":false,"message":"Malformed JSON: '
                + badJson.getMessage().replace('"','\\"') + '"}'
            );
            return;
        }

        // Phase 3 — enqueue the actual work in a separate transaction.
        try {
            System.enqueueJob(new NuveiConnectWebhookQueueable(body, logId));
        } catch (Exception e) {
            // enqueueJob can fail if we're already inside a queueable chain hitting
            // limits. Fall back to synchronous processing so we don't drop the webhook.
            try {
                Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(body);
                String appDataStr = (String) envelope.get('applicationData');
                Map<String, Object> appData = (Map<String, Object>) JSON.deserializeUntyped(appDataStr);
                appData.put('applicationId', envelope.get('applicationId'));
                appData.put('applicationStatus', envelope.get('applicationStatus'));
                NuveiConnectRequest ncReq = (NuveiConnectRequest) JSON.deserialize(
                    JSON.serialize(appData), NuveiConnectRequest.class
                );
                processWebhook(ncReq); // best-effort sync fallback
            } catch (Exception ignore2) { /* already logged inbound */ }
        }

        // Phase 4 — ACK immediately with 200 as NC expects.
        res.statusCode = 200;
        res.responseBody = Blob.valueOf(
            '{"success":true,"message":"Accepted for asynchronous processing"}'
        );
    }

    private static final Id RT_EL_NC = RecordTypeHelper.getRecordTypeIdByName('Execution_Log__c', 'NuveiConnect');

    // ─── STATUS MAP: Nuvei Connect → Salesforce ─────────────────────────────
private static final Map<String, String> NC_TO_SF_STATUS = new Map<String, String>{
    // ── Legacy / short keys (kept for backward compatibility) ──────────
    'SUBMITTED'                          => 'Oscilar Submitted',
    'PENDING_REVIEW'                     => 'Oscilar Pending Review',
    'IN_PROGRESS'                        => 'Oscilar In Progress',
    'IN_REVIEW'                          => 'Oscilar In Review',
    'ADDITIONAL_INFO_REQUESTED'          => 'Oscilar Additional Info Requested',
    'PENDING_APPROVAL'                   => 'Oscilar Pending Approval',
    'CONDITIONALLY_APPROVED'             => 'Oscilar Conditionally Approved',
    'APPROVED'                           => 'Oscilar Approved',
    'DECLINED'                           => 'Oscilar Declined',
    'WITHDRAWN'                          => 'Oscilar Withdrawn',

    // ── NC's actual outbound event names (per NC channel config) ───────
    'APPLICATION_SUBMITTED'              => 'Oscilar Submitted',
    'APPLICATION_UPDATED'                => 'Oscilar In Review',
    'APPLICATION_APPROVED'               => 'Oscilar Approved',
    'APPLICATION_CONDITIONALLY_APPROVED' => 'Oscilar Conditionally Approved',
    'APPLICATION_DECLINED'               => 'Oscilar Declined',
    'ADDITIONAL_INFORMATION_REQUIRED'    => 'Oscilar Additional Info Requested'
};

// ─── NC EVENT NAME → picklist-compatible short form ─────────────────────
// Nuvei_Connect_Status__c picklist only contains the short values
// (APPROVED, DECLINED, ...), not NC's outbound event names. Normalize.
private static final Map<String, String> NC_TO_NC_NORMALIZED = new Map<String, String>{
    'APPLICATION_SUBMITTED'              => 'SUBMITTED',
    'APPLICATION_UPDATED'                => 'IN_REVIEW',
    'APPLICATION_APPROVED'               => 'APPROVED',
    'APPLICATION_CONDITIONALLY_APPROVED' => 'CONDITIONALLY_APPROVED',
    'APPLICATION_DECLINED'               => 'DECLINED',
    'ADDITIONAL_INFORMATION_REQUIRED'    => 'ADDITIONAL_INFO_REQUESTED'
};

// Helper: treat both old (APPROVED) and new (APPLICATION_APPROVED) as approval triggers
private static Boolean isApprovedStatus(String ncStatus) {
    return ncStatus == 'APPROVED' || ncStatus == 'APPLICATION_APPROVED';
}

        // ─── COMPANY TYPE: NC enum → SF picklist ────────────────────────────────────
    // Wave 3 fix (gap #12): aligned to current Nuvei Connect API swagger spec
    // for `BusinessType`. Source of truth: NC OpenAPI schema.
    //
    // SAFE-PICKLIST mode: 5 NC enum values do not yet have matching SF picklist
    // entries (Compliance__c.Company_Type__c). To avoid INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST
    // errors on insert, those 5 are temporarily mapped to the closest existing
    // SF label. Round-trip is lossy for those 5 — they will outbound as `OTHER`
    // (or `LIMITED_LIABILITY_PARTNERSHIP` for Scottish LP) on Track H.
    //
    // SF admin follow-up — add these picklist values to both
    // Compliance__c.Company_Type__c and Application_Form__c.Company_Type__c,
    // then change the 5 lines below to use them:
    //   * Individual / Sole Proprietorship  → currently 'Sole Proprietorship'
    //   * Trust                              → currently 'Other'
    //   * Club or Society                    → currently 'Other'
    //   * Unincorporated Association         → currently 'Other'
    //   * Scottish Limited Partnership       → currently 'Limited Liability Partnership'
    private static final Map<String, String> NC_TO_SF_COMPANY_TYPE =
        new Map<String, String>{
            'INDIVIDUAL_OR_SOLE_PROPRIETORSHIP' => 'Sole Proprietorship',           // TODO: 'Individual / Sole Proprietorship'
            'LIMITED_COMPANY'                   => 'Limited',
            'PUBLIC_LIMITED_COMPANY'            => 'Public Limited',
            'PARTNERSHIP'                       => 'Partnership',
            'LIMITED_LIABILITY_PARTNERSHIP'     => 'Limited Liability Partnership',
            'GOVERNMENT_LOCAL_AUTHORITY'        => 'Government/Local Authority',
            'NON_PROFIT_ASSOCIATION_FOUNDATION' => 'Non-profit',
            'TRUST'                             => 'Other',                         // TODO: 'Trust'
            'CLUB_OR_SOCIETY'                   => 'Other',                         // TODO: 'Club or Society'
            'UNINCORPORATED_ASSOCIATION'        => 'Other',                         // TODO: 'Unincorporated Association'
            'SCOTTISH_LIMITED_PARTNERSHIP'      => 'Limited Liability Partnership', // TODO: 'Scottish Limited Partnership'
            'OTHER'                             => 'Other',

            // Legacy NC values — kept read-only for any historical webhooks
            // that still send the old enums. Outbound (SF → NC) does not use these.
            'SOLE_TRADER'                       => 'Sole Trader',
            'SOLE_PROPRIETORSHIP'               => 'Sole Proprietorship',
            'CORPORATION'                       => 'Corporation',
            'PUBLICLY_TRADED'                   => 'Publicly Traded',
            'GOVERNMENT'                        => 'Government/Local Authority',
            'NON_PROFIT'                        => 'Non-profit'
        };
        
          // ─── Post-demo Batch A: Managing Company + Account Record Type ───────────
    // Mapping locked with Compliance team:
    //   UK / Gibraltar → RecordType "Nuvei UK" (DevName Safecharge_Financial_Services)
    //   Rest of EU     → RecordType "Nuvei Global" (DevName Safecharge)
    //   Managing_Company__c API values are picklist API names (not display labels).

    private static final Set<String> UK_COUNTRIES        = new Set<String>{ 'United Kingdom' };
    private static final Set<String> GIBRALTAR_COUNTRIES = new Set<String>{ 'Gibraltar' };
    private static final Set<String> EU_COUNTRIES        = new Set<String>{
        'Germany','France','Spain','Italy','The Netherlands','Ireland','Belgium',
        'Poland','Portugal','Sweden','Denmark','Finland','Norway','Austria',
        'Switzerland','Luxembourg','Czech Republic','Hungary','Romania','Bulgaria',
        'Greece','Cyprus','Malta','Estonia','Latvia','Lithuania','Slovakia',
        'Slovenia','Croatia'
        // Extend as more geos come online — keep aligned with SF_TO_NC_COUNTRY.
    };

    private static String resolveManagingCompany(String sfCountry) {
        if (String.isBlank(sfCountry)) return null;
        if (UK_COUNTRIES.contains(sfCountry))        return 'Safecharge Financial Services';
        if (GIBRALTAR_COUNTRIES.contains(sfCountry)) return 'Nuvei Financial Services, Gibraltar branch';
        if (EU_COUNTRIES.contains(sfCountry))        return 'Safecharge Limited';
        return null;
    }

        private static Map<String, Id> complianceRtIdByDevName;
    private static Id resolveComplianceRecordTypeId(String sfCountry) {
        if (String.isBlank(sfCountry)) return null;
        String devName;
        if (UK_COUNTRIES.contains(sfCountry) || GIBRALTAR_COUNTRIES.contains(sfCountry)) {
            devName = 'Safecharge_Financial_Services';   // Label: Nuvei UK
        } else if (EU_COUNTRIES.contains(sfCountry)) {
            devName = 'Safecharge';                       // Label: Nuvei Global
        } else {
            return null;
        }
        if (complianceRtIdByDevName == null) {
            complianceRtIdByDevName = new Map<String, Id>();
            for (RecordType rt : [
                SELECT Id, DeveloperName FROM RecordType
                WHERE SObjectType = 'Compliance__c'
                AND DeveloperName IN ('Safecharge','Safecharge_Financial_Services')
            ]) {
                complianceRtIdByDevName.put(rt.DeveloperName, rt.Id);
            }
        }
        return complianceRtIdByDevName.get(devName);
    }
     
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

// ─── Post-demo Batch E: Application Form address-match helper ────────────
        private static Boolean addressesMatch(AddressWrapper a, AddressWrapper b) {
        if (a == null && b == null) return true;
        if (a == null || b == null) return false;
        return equalsIgnoreCaseTrim(a.addressLine1, b.addressLine1)
            && equalsIgnoreCaseTrim(a.city,         b.city)
            && equalsIgnoreCaseTrim(a.postalCode,   b.postalCode)
            && equalsIgnoreCaseTrim(a.country,      b.country);
    }

    private static Boolean equalsIgnoreCaseTrim(String s1, String s2) {
        if (s1 == null && s2 == null) return true;
        if (s1 == null || s2 == null) return false;
        return s1.trim().equalsIgnoreCase(s2.trim());
    }

    // ─── PUBLIC ENTRY POINT ──────────────────────────────────────────────────

        global static WebhookResult processWebhook(NuveiConnectRequest req) {
    WebhookResult result = new WebhookResult();

    try {
        // NOTE: This existence check is race-vulnerable when NC sends
        // SUBMITTED + APPROVED nearly simultaneously (both transactions see
        // "no existing" and both go INSERT path). The Unique constraint on
        // Nuvei_Connect_Application_ID__c + the DUPLICATE_VALUE catch inside
        // createAllObjects are the actual guardrails.
        List<Compliance__c> existing = [
            SELECT Id, Name, Account__c, Compliance_Status__c,
                   Technical_Onboarding_Status__c,
                   Nuvei_Connect_Status__c, Nuvei_Connect_Last_Webhook__c,
                   Manual_MCC_Code__c, Url__c, From_Reseller__c,
                   EU_Indirect_Orchestration__c,
                   City_field__c, Primary_Contact__c, Descriptor__c, Descriptor_Type__c
            FROM   Compliance__c
            WHERE  Nuvei_Connect_Application_ID__c = :req.applicationId
            LIMIT  1
        ];

        if (!existing.isEmpty()) {
            Boolean ok = handleStatusUpdate(existing[0], req);
            result.complianceId = String.valueOf(existing[0].Id);
            if (ok) {
                result.success = true;
                result.message = 'Status updated to: ' + req.applicationStatus;
            } else {
                result.success = false;
                result.message = 'Unknown NC status: ' + req.applicationStatus;
                result.errorDetail = 'Status "' + req.applicationStatus
                    + '" is not in NC_TO_SF_STATUS map. Compliance not updated.';
            }
        } else {
            Id complianceId = createAllObjects(req);
            if (complianceId == null) {
                // createAllObjects detected a concurrent-insert race, re-fetched,
                // and routed through handleStatusUpdate. Nothing more to do here.
                result.success = true;
                result.message = 'Status updated to (concurrent race resolved): ' + req.applicationStatus;
            } else {
                result.success = true;
                result.message = 'Application created. Compliance Id: ' + complianceId;
                result.complianceId = String.valueOf(complianceId);
            }
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

    private static Boolean handleStatusUpdate(
        Compliance__c existing,
        NuveiConnectRequest req
    ) {
        // ─── Status mapping ──────────────────────────────────────────────
        if (String.isNotBlank(req.applicationStatus)) {
            String sfStatus = NC_TO_SF_STATUS.get(req.applicationStatus);
            if (sfStatus == null) {
                logLegacyError('Unknown NC status: ' + req.applicationStatus, null, req.applicationId);
                return false;  // ← signal failure so caller returns 422 to NC
            }
            existing.Nuvei_Connect_Status__c = NC_TO_NC_NORMALIZED.containsKey(req.applicationStatus)
    ? NC_TO_NC_NORMALIZED.get(req.applicationStatus)
    : req.applicationStatus;
            if (sfStatus != existing.Compliance_Status__c) {
                existing.Compliance_Status__c = sfStatus;
            }
        }

        // Edit 4 — patch City_field__c on update path
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
            // Wave 2 fix (gap #6) — also patch update path. Only set when blank
            // so manual OCT edits are never overwritten.
            if (req.businessInformation.contactInformation != null
                && String.isBlank(existing.City_field__c)
                && String.isNotBlank(req.businessInformation.contactInformation.contactNumber)) {
                existing.City_field__c = req.businessInformation.contactInformation.contactNumber;
            }
        }

        // Edit 6 — idempotent fixes for Primary_Contact__c, Descriptor__c, Descriptor_Type__c
        // Wave 2 fix (gap #7) — also patch update path. Only set when blank.
        if (String.isBlank(existing.Primary_Contact__c)
            && req.businessInformation != null
            && req.businessInformation.contactInformation != null
            && String.isNotBlank(req.businessInformation.contactInformation.businessEmail)) {
            List<Contact> existingCons = [
                SELECT Id FROM Contact
                WHERE AccountId = :existing.Account__c
                AND Email = :req.businessInformation.contactInformation.businessEmail
                LIMIT 1
            ];
            if (!existingCons.isEmpty()) {
                existing.Primary_Contact__c = existingCons[0].Id;
            }
        }

        // Wave 2 fix (gap #8) — also patch update path. Only set when blank.
        if (String.isBlank(existing.Descriptor__c)
            && req.businessInformation != null
            && String.isNotBlank(req.businessInformation.legalName)) {
            Integer descMax = 22;
            try {
                Integer fieldLen = Compliance__c.Descriptor__c.getDescribe().getLength();
                if (fieldLen > 0 && fieldLen < descMax) descMax = fieldLen;
            } catch (Exception ignore) { /* keep 22 */ }
            String descriptor = req.businessInformation.legalName.length() > descMax
                ? req.businessInformation.legalName.substring(0, descMax)
                : req.businessInformation.legalName;
            existing.Descriptor__c = descriptor;
        }

        // Wave 2 fix (gap #9) — also patch update path. Only set when blank.
        if (String.isBlank(existing.Descriptor_Type__c)) {
            existing.Descriptor_Type__c = 'Static';
        }

        // CHANGED: use isApprovedStatus() so this also fires for APPLICATION_APPROVED
        if (isApprovedStatus(req.applicationStatus) && existing.From_Reseller__c != null) {
            existing.EU_Indirect_Orchestration__c = true;
        }

        // ── Wave 4 (gaps #24, #25): backfill owner Contacts + junction rows
        // when missing. Idempotent — only inserts what doesn't exist yet.
        backfillOwnerContactsAndJunctions(existing, req);

        existing.Nuvei_Connect_Last_Webhook__c = DateTime.now();
        update existing;

        // CHANGED: use isApprovedStatus() so this also fires for APPLICATION_APPROVED
        if (isApprovedStatus(req.applicationStatus)) {
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

        return true;
    }
    
    // ─── INSERT PATH ─────────────────────────────────────────────────────────

        private static Id createAllObjects(NuveiConnectRequest req) {
        Account acc = buildAccount(req);
        insert acc;

        // ── Wave 4 (gap #24): build one Contact per business owner.
        // Dedupe by lowercased email. cPanel admin merge: if portalAdminEmail
        // matches an owner email (case-insensitive), set Is_CPanel_Admin__c=true
        // on that single Contact (no duplicates).
        String primaryEmail = req.businessInformation?.contactInformation?.businessEmail;
        String cPanelEmail  = req.additionalInformation?.portalAdminEmail;
        String cPanelLower  = String.isBlank(cPanelEmail) ? null : cPanelEmail.toLowerCase();

        Map<String, Contact> ownerContactsByEmail = new Map<String, Contact>();
        Boolean cPanelMatchedOwner = false;

        if (req.businessOwnerInformation != null) {
            for (BusinessOwnerWrapper bo : req.businessOwnerInformation) {
                if (String.isBlank(bo.email)) continue;
                String emailLower = bo.email.toLowerCase();
                if (ownerContactsByEmail.containsKey(emailLower)) continue; // dedupe

                               Contact c = new Contact();
                c.AccountId               = acc.Id;
                c.FirstName               = bo.legalFirstName;
                c.LastName                = String.isNotBlank(bo.legalLastName)
                                              ? bo.legalLastName
                                              : req.businessInformation.legalName;
                c.Email                   = bo.email;
                c.Phone                   = bo.contactNumber;
                c.Authorized_Signature__c = bo.isAuthorizedSignatory == true; // Wave 4 (#24)
                // Post-demo Batch D: flag Director role from NC ownerRole string.
                c.Director__c             = String.isNotBlank(bo.ownerRole)
                                            && bo.ownerRole.containsIgnoreCase('Director');

                if (cPanelLower != null && emailLower == cPanelLower) {
                    c.Is_CPanel_Admin__c = true;
                    cPanelMatchedOwner   = true;
                }
                ownerContactsByEmail.put(emailLower, c);
            }
        }

        // Primary business contact (contactInformation): create if no owner
        // shares the same email. Wave 4 keeps existing Wave 2 behaviour intact.
        Contact primaryCon;
        Boolean primaryMatchedOwner = false;
        if (String.isNotBlank(primaryEmail)
            && ownerContactsByEmail.containsKey(primaryEmail.toLowerCase())) {
            primaryCon = ownerContactsByEmail.get(primaryEmail.toLowerCase());
            primaryMatchedOwner = true;
        }
        if (primaryCon == null) {
            // Build the legacy primary contact (existing buildContact logic).
            Boolean primaryIsCPanel = String.isNotBlank(primaryEmail)
                                      && String.isNotBlank(cPanelEmail)
                                      && primaryEmail.equalsIgnoreCase(cPanelEmail);
            primaryCon = buildContact(req, acc.Id, primaryIsCPanel);
            if (primaryIsCPanel) cPanelMatchedOwner = true; // legacy already handled this
        }

        // Standalone cPanel contact: only if no owner AND not the primary email
        // already matched it.
        Contact cPanelOnlyCon;
        if (!cPanelMatchedOwner
            && String.isNotBlank(cPanelEmail)
            && (String.isBlank(primaryEmail) || !primaryEmail.equalsIgnoreCase(cPanelEmail))) {
            cPanelOnlyCon = buildCPanelContact(req, acc.Id);
        }

        // Insert all Contacts in one DML
        List<Contact> toInsert = new List<Contact>();
        if (!primaryMatchedOwner) toInsert.add(primaryCon); // primary is its own row
        toInsert.addAll(ownerContactsByEmail.values());
        if (cPanelOnlyCon != null) toInsert.add(cPanelOnlyCon);
        if (!toInsert.isEmpty()) insert toInsert;

        // Resolve the Contact Id used for DocuSign_Recipient__c / Primary_Contact__c.
        // Preference order:
        //   1. Authorized signatory owner (highest %ownership wins on ties)
        //   2. Primary business contact (current default)
        Id docuRecipientId = pickAuthorizedSignatoryId(req, ownerContactsByEmail);
        if (docuRecipientId == null) docuRecipientId = primaryCon.Id;

               // Post-demo Batch C: resolve partner Sales Rep once, reuse for Opp.
        Id partnerSalesRepId = resolvePartnerSalesRep(req.partnerId);
        Opportunity opp = buildOpportunity(req, acc.Id, partnerSalesRepId);
        insert opp;

        Compliance__c comp = buildCompliance(req, acc.Id, opp.Id, docuRecipientId);
        try {
            insert comp;
        } catch (DmlException e) {
            // Concurrency race — another webhook for the same applicationId
            // won the INSERT while this transaction was mid-flight. Detect
            // DUPLICATE_VALUE (fired by the Unique constraint on
            // Nuvei_Connect_Application_ID__c), re-fetch the winning row,
            // and route through the UPDATE path so we don't orphan a second
            // Compliance with all its child DML.
            Boolean isDup = false;
            for (Integer i = 0; i < e.getNumDml(); i++) {
                if (e.getDmlType(i) == StatusCode.DUPLICATE_VALUE) {
                    isDup = true;
                    break;
                }
            }
            if (!isDup) {
                throw e;
            }
            List<Compliance__c> winner = [
                SELECT Id, Name, Account__c, Compliance_Status__c,
                       Technical_Onboarding_Status__c,
                       Nuvei_Connect_Status__c, Nuvei_Connect_Last_Webhook__c,
                       Manual_MCC_Code__c, Url__c, From_Reseller__c,
                       EU_Indirect_Orchestration__c,
                       City_field__c, Primary_Contact__c, Descriptor__c, Descriptor_Type__c
                FROM   Compliance__c
                WHERE  Nuvei_Connect_Application_ID__c = :req.applicationId
                LIMIT  1
            ];
            if (winner.isEmpty()) {
                // Extremely unlikely — DUPLICATE_VALUE fired but the winning
                // row is not visible. Rethrow so NC retries the webhook.
                throw e;
            }
            handleStatusUpdate(winner[0], req);
            // Signal to processWebhook that the race was resolved via update
            // path; skip the rest of createAllObjects (Case create, junctions,
            // pricing clone, etc. were done by the winner's transaction).
            return null;
        }

        // ── Wave 4 (gap #25): one Compliance_Contact__c junction row per owner.
        // Director__c is a formula on the junction → auto-fills from
        // Contact__r.Authorized_Signature__c.
        List<Compliance_Contact__c> junctions = new List<Compliance_Contact__c>();
        for (Contact c : ownerContactsByEmail.values()) {
            junctions.add(new Compliance_Contact__c(
                Compliance__c = comp.Id,
                Contact__c    = c.Id
            ));
        }
        if (!junctions.isEmpty()) {
            try {
                insert junctions;
            } catch (Exception e) {
                logLegacyError('Wave 4 (gap #25): Compliance_Contact__c junction insert failed',
                               e, req.applicationId);
            }
        }

        try {
    PCI__c pci = new PCI__c();
    pci.Company_Profile__c = comp.Id;

    // Defaults required by ops
    pci.Status__c         = 'Active';
    pci.Aperia_Consent__c = true;

    // Contact details — straight from NC payload (same source used by
    // buildContact to create the SF Contact record earlier in this flow).
    ContactInfoWrapper ci = req.businessInformation != null
        ? req.businessInformation.contactInformation
        : null;
    if (ci != null) {
        String fullName = String.isNotBlank(ci.firstName)
            ? (ci.firstName + ' ' + (ci.lastName != null ? ci.lastName : '')).trim()
            : ci.lastName;
        pci.Contact_Name__c  = fullName;
        pci.Contact_Email__c = ci.businessEmail;
        pci.Contact_Phone__c = ci.contactNumber;
    }

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

        copyPartnerMerchantBanks(
            comp.Id,
            req.partnerId,
            req.bankingInformation,
            req.businessInformation != null ? req.businessInformation.legalName : null,
            req.metadata != null ? req.metadata.msaTemplateId : null
        );

        // Post-demo: defensively clone Chargeback_Protection__c rows from the
        // partner Compliance to the newly-created merchant. Written with dynamic
        // SOQL / describe so the day the CBP custom object is deleted from the
        // org, this class still compiles and the flow keeps working.
        copyPartnerChargebackProtection(comp.Id, resolvePartnerId(req.partnerId));

        return comp.Id;
    }

    /**
     * Wave 4 helper — pick authorized signatory Contact Id from already-built
     * owner Contact map. Tiebreaker: highest percentageOfOwnership wins.
     * Returns null if no owner is flagged as signatory.
     */
    private static Id pickAuthorizedSignatoryId(
        NuveiConnectRequest req,
        Map<String, Contact> ownerContactsByEmail
    ) {
        if (req.businessOwnerInformation == null || ownerContactsByEmail.isEmpty()) return null;
        BusinessOwnerWrapper best;
        for (BusinessOwnerWrapper bo : req.businessOwnerInformation) {
            if (bo.isAuthorizedSignatory != true) continue;
            if (String.isBlank(bo.email)) continue;
            if (best == null
                || (bo.percentageOfOwnership != null
                    && (best.percentageOfOwnership == null
                        || bo.percentageOfOwnership > best.percentageOfOwnership))) {
                best = bo;
            }
        }
        if (best == null) return null;
        Contact c = ownerContactsByEmail.get(best.email.toLowerCase());
        return c == null ? null : c.Id;
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

       private static Opportunity buildOpportunity(NuveiConnectRequest req, Id accountId, Id salesRepId) {
        Opportunity opp = new Opportunity();
        opp.Name      = req.businessInformation.legalName + ' — Merchant Onboarding';
        opp.AccountId = accountId;
        // Post-demo Batch C: Oscilar is 'Submitted' at creation → In Pre-Approval.
        opp.StageName = 'In Pre-Approval';
        opp.CloseDate = Date.today().addDays(30);

        // Post-demo Batch C: mirror partner Sales Rep onto the Opportunity.
        if (salesRepId != null) {
            opp.Sales_Rep__c = salesRepId;
        }

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
    if (String.isNotBlank(req.applicationStatus)) {
    comp.Nuvei_Connect_Status__c = NC_TO_NC_NORMALIZED.containsKey(req.applicationStatus)
        ? NC_TO_NC_NORMALIZED.get(req.applicationStatus)
        : req.applicationStatus;
}
        comp.From_Reseller__c    = resolvePartnerId(req.partnerId);
        comp.Nuvei_Partner_ID__c = req.partnerId;
        if (comp.From_Reseller__c != null) {
            seedRolesFromPartner(comp);
        }
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
            // Wave 2 fix (gap #7): seed Primary_Contact__c so MerchantPayload can
            // resolve top-level email, paymentProcessing.email, and
            // clientManagementDetails.contact[0].
            comp.Primary_Contact__c = contactId;
            // Post-demo fix (Batch B): MSA Recipient lookup mirrors the
            // authorized signatory Contact (same Id already resolved for
            // DocuSign_Recipient__c by pickAuthorizedSignatoryId()).
            comp.MSA_Recipient__c = contactId;
        }

                // ─── Post-demo fix (Batch B): Compliance defaults at creation ────────
        // Underwriting team requires these to be set on every new EU indirect
        // merchant. All three are safe defaults — UW can override manually.
        comp.Risk_Level__c                 = 'Low';
        comp.Checklist_Type__c             = 'Simplified';
        comp.Customer_Due_Diligence_New__c = 'Simplified';

        // ─── Post-demo Batch A: Managing Company + Record Type by country ────
        // Reuses Registered_Country__c set above from BUSINESS_ADDRESS block.
        //   UK / Gibraltar → RecordType "Nuvei UK" (Safecharge_Financial_Services)
        //   Rest of EU     → RecordType "Nuvei Global" (Safecharge)
        String managingCo = resolveManagingCompany(comp.Registered_Country__c);
        if (String.isNotBlank(managingCo)) {
            comp.Managing_Company__c = managingCo;
        }
        Id compRtId = resolveComplianceRecordTypeId(comp.Registered_Country__c);
        if (compRtId != null) {
            comp.RecordTypeId = compRtId;
        }

                // NOTE: metadata.msaTemplateId is NOT a static-PDF ContentVersion Id
        // (that was legacy from the abandoned static-PDF + DocuSign flow).
        // It is the Salesforce Id of a specific partner Merchant_Bank__c
        // (Partner_Template_Pricing__c = true) that NC wants us to clone as
        // the merchant's pricing when the partner has multiple templates.
        // Consumed in copyPartnerMerchantBanks below.
        
        // Wave 2 fix (gap #6): seed City_field__c from NC contactNumber so
        // MerchantPayload can populate merchant.phoneNumber and
        // paymentProcessing.phoneNumber without manual entry.
        if (bi.contactInformation != null && String.isNotBlank(bi.contactInformation.contactNumber)) {
            comp.City_field__c = bi.contactInformation.contactNumber;
        }

        // Wave 2 fix (gap #8): default Descriptor__c from legal name (truncated
        // to the field's max length) so Track G has a value to send to Finance.
        if (String.isNotBlank(bi.legalName)) {
            Integer descMax = 22;
            try {
                Integer fieldLen = Compliance__c.Descriptor__c.getDescribe().getLength();
                if (fieldLen > 0 && fieldLen < descMax) descMax = fieldLen;
            } catch (Exception ignore) { /* keep 22 */ }
            String descriptor = bi.legalName.length() > descMax ? bi.legalName.substring(0, descMax) : bi.legalName;
            comp.Descriptor__c = descriptor;
        }

        // Wave 2 fix (gap #9): default Descriptor_Type__c to 'Static'.
        comp.Descriptor_Type__c = 'Static';

        return comp;
    }

    private static Application_Form__c buildApplicationForm(
        NuveiConnectRequest req,
        Id complianceId
    ) {
        Application_Form__c af = new Application_Form__c();
        af.Company_Profile__c = complianceId;

        Id rtId = getAppFormRecordTypeId(req);
        if (rtId != null) af.RecordTypeId = rtId;

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

        // ─── Post-demo Batch E: Application Form checkboxes ──────────────────
        // Webhook always represents an application that has been submitted
        // through Nuvei Connect, so Submit__c is always true.
        af.Submit__c = true;

        // Operational_address_same_as_registered__c: compare OPERATION_ADDRESS
        // to BUSINESS_ADDRESS. If OPERATION_ADDRESS is missing, default to
        // true (assume same as registered).
        if (req.businessInformation != null) {
            AddressWrapper bizAddr = getAddressByType(req.businessInformation.addresses, 'BUSINESS_ADDRESS');
            AddressWrapper opAddr  = getAddressByType(req.businessInformation.addresses, 'OPERATION_ADDRESS');
            af.Operational_address_same_as_registered__c = addressesMatch(bizAddr, opAddr);
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

        // ─── Post-demo Batch F: populate Name (Field Label "URL") and MCC ────
        // Name is the standard record label. Was previously auto-generated
        // (looked like a Salesforce Id) because we never set it. Set it to
        // the URL string, truncated to the field's 80-char max.
        if (String.isNotBlank(req.businessInformation.websiteUrl)) {
            String url = req.businessInformation.websiteUrl.trim();
            site.Name = url.length() > 80 ? url.substring(0, 80) : url;
        }

        // MCC_Code__c (text 10) mirrors the raw NC MCC. Kept separate from
        // the Company_profile_MCC__c formula so it survives if the Compliance
        // MCC is manually edited later.
        if (String.isNotBlank(req.businessInformation.merchantCategoryCode)) {
            String mcc = req.businessInformation.merchantCategoryCode.trim();
            site.MCC_Code__c = mcc.length() > 10 ? mcc.substring(0, 10) : mcc;
        }

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
            // Post-demo Batch D: mirror the NC authorized-signatory flag onto
            // the Director/UBO row (Contact side is already set — this makes
            // the KYC-side reporting consistent with the Contact side).
            d.Authorized_Signatory__c = bo.isAuthorizedSignatory == true;

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

    /**
     * Copy the partner's pricing template Merchant_Bank__c onto the merchant
     * Compliance being created.
     *
     * Selection rules (fail loud — pricing errors are expensive to unwind):
     *   1. No partnerId → skip cloning entirely (proceed with Banking_Details__c).
     *   2. Partner not found → log + skip cloning.
     *   3. msaTemplateId supplied:
     *        - Matches a partner Merchant_Bank__c with Partner_Template_Pricing__c=true
     *          → clone that one row.
     *        - No match → log clear error + clone nothing. Track D's pricing gate
     *          (hasMerchantPricing) will then hold MSA composition until the
     *          admin manually adds a Merchant_Bank__c.
     *   4. msaTemplateId NOT supplied:
     *        - Partner has 0 template rows → skip cloning (nothing to do).
     *        - Partner has exactly 1 template row → clone it.
     *        - Partner has 2+ template rows → log clear error + clone nothing.
     *          NC MUST send metadata.msaTemplateId in this case to disambiguate.
     *
     * Banking_Details__c is always created regardless — those describe the
     * merchant's own bank account, not partner pricing.
     */
    private static void copyPartnerMerchantBanks(
        Id complianceId,
        String partnerId,
        List<BankingInfoWrapper> bankingInfo,
        String legalName,
        String msaTemplateId
    ) {
        if (String.isBlank(partnerId)) {
            createBankingDetails(complianceId, bankingInfo, legalName);
            return;
        }

        Id partnerComplianceId = resolvePartnerId(partnerId);
        if (partnerComplianceId == null) {
            logLegacyError('Partner not found for partnerId: ' + partnerId, null, partnerId);
            createBankingDetails(complianceId, bankingInfo, legalName);
            return;
        }

        try {
            String trimmedTemplateId = String.isBlank(msaTemplateId) ? null : msaTemplateId.trim();

            List<Merchant_Bank__c> allPartnerTemplates = [
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

            List<Merchant_Bank__c> chosen = new List<Merchant_Bank__c>();

            if (String.isNotBlank(trimmedTemplateId)) {
    // NC specified which template to use — must find an exact match.
    // Cast to Id so 15-char / 18-char and case differences are normalized.
    Id targetTemplateId;
    try {
        targetTemplateId = (Id) trimmedTemplateId;
    } catch (System.StringException e) {
        targetTemplateId = null;
    }
    if (targetTemplateId != null) {
        for (Merchant_Bank__c t : allPartnerTemplates) {
            if (t.Id == targetTemplateId) {
                chosen.add(t);
                break;
            }
        }
    }
    if (chosen.isEmpty()) {
        logLegacyError(
            'metadata.msaTemplateId "' + trimmedTemplateId + '" does not match any '
            + 'Merchant_Bank__c with Partner_Template_Pricing__c=true on partner '
            + partnerId + ' (partner Compliance ' + partnerComplianceId + '). '
            + 'No pricing template cloned — merchant will need manual Merchant_Bank__c '
            + 'setup before Track D can compose MSA.',
            null, partnerId
        );
    }
                // else: 0 templates on partner → nothing to clone, no error (legit case).
            }

            if (!chosen.isEmpty()) {
                String templateIndustry = chosen[0].Industry__c;
                if (String.isNotBlank(templateIndustry)) {
                    update new Compliance__c(
                        Id          = complianceId,
                        Industry__c = templateIndustry
                    );
                }

                List<Merchant_Bank__c> newBanks = new List<Merchant_Bank__c>();
                for (Merchant_Bank__c t : chosen) {
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

        createBankingDetails(complianceId, bankingInfo, legalName);
    }

    private static void createBankingDetails(
        Id complianceId,
        List<BankingInfoWrapper> bankingInfo
    ) {
        createBankingDetails(complianceId, bankingInfo, null);
    }

    private static void createBankingDetails(
        Id complianceId,
        List<BankingInfoWrapper> bankingInfo,
        String legalName
    ) {
        if (bankingInfo == null || bankingInfo.isEmpty()) return;

        // Post-demo Batch G: mirror the same "Multi" suffix used by
        // MerchantOnboardingController when it creates GW_Name records after
        // NCP boarding. Keeps identity consistent across GW_Name and Banking.
        String multiClientName = String.isNotBlank(legalName)
            ? legalName + ' Multi'
            : null;

        List<Banking_Details__c> records = new List<Banking_Details__c>();
        for (BankingInfoWrapper bank : bankingInfo) {
            Banking_Details__c bd = new Banking_Details__c();
            bd.Compliance__c          = complianceId;
            bd.Account_Holder_Name__c = bank.accountHolderName;
            bd.bankCountry__c         = resolveCountry(bank.bankCountry);
            // Wave 2 fix (gap #16): also seed Beneficiary_Country__c from the
            // NC bankCountry so FinanceIntegration's payload has a value to send
            // to Finance Admin (Track G HTTP 400 root cause).
            bd.Beneficiary_Country__c = resolveCountry(bank.bankCountry);
            bd.Target_Currency__c     = bank.accountCurrency;
            // Post-demo Batch G: mirror merchant identity onto Banking row.
            if (String.isNotBlank(multiClientName)) {
                bd.MultiClient_Name__c = multiClientName;
            }

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
    
        /**
     * Defensively clone Chargeback_Protection__c rows from partner → merchant.
     *
     * Nuvei ops are planning to delete the Chargeback_Protection__c custom
     * object in the near future. This helper is written entirely via dynamic
     * SOQL / describe / dynamic DML, so when the object is removed from the
     * org:
     *   - This class still compiles (no static references to the object).
     *   - The merchant creation flow proceeds normally (early return).
     *   - No error is logged during normal operation post-deletion.
     *
     * Never throws. Never blocks merchant creation.
     */
    private static void copyPartnerChargebackProtection(Id merchantComplianceId, Id partnerComplianceId) {
        if (merchantComplianceId == null || partnerComplianceId == null) return;

        final String CBP_API_NAME = 'Chargeback_Protection__c';

        try {
            // 1) Object existence guard — the day ops deletes the object, this
            //    early-returns silently.
            Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
            if (!gd.containsKey(CBP_API_NAME)) return;

            Schema.SObjectType cbpType = gd.get(CBP_API_NAME);
            Schema.DescribeSObjectResult cbpDescribe = cbpType.getDescribe();
            Map<String, Schema.SObjectField> fieldMap = cbpDescribe.fields.getMap();

            // 2) Discover the reference field on Chargeback_Protection__c that
            //    points to Compliance__c. Cannot hardcode the API name since
            //    the object may not exist at compile time.
            String parentLookupField;
            for (String fName : fieldMap.keySet()) {
                Schema.DescribeFieldResult f = fieldMap.get(fName).getDescribe();
                if (f.getType() != Schema.DisplayType.REFERENCE) continue;
                for (Schema.SObjectType ref : f.getReferenceTo()) {
                    if (ref.getDescribe().getName() == 'Compliance__c') {
                        parentLookupField = f.getName();
                        break;
                    }
                }
                if (parentLookupField != null) break;
            }
            if (parentLookupField == null) return; // no way to relate — silent no-op

            // 3) Build a SELECT of all createable, non-formula, non-audit fields.
            List<String> selectFields = new List<String>{ 'Id' };
            for (String fName : fieldMap.keySet()) {
                Schema.DescribeFieldResult f = fieldMap.get(fName).getDescribe();
                if (!f.isCreateable()) continue;
                if (f.isCalculated()) continue;
                if (f.isAutoNumber()) continue;
                selectFields.add(f.getName());
            }
            String soql =
                'SELECT ' + String.join(selectFields, ', ')
                + ' FROM ' + CBP_API_NAME
                + ' WHERE ' + parentLookupField + ' = :partnerComplianceId';

            List<SObject> partnerRows = Database.query(soql);
            if (partnerRows.isEmpty()) return;

            // 4) Clone each row, rewriting the parent lookup to the merchant.
            List<SObject> newRows = new List<SObject>();
            for (SObject src : partnerRows) {
                SObject clone = cbpType.newSObject();
                for (String fName : selectFields) {
                    if (fName == 'Id') continue;
                    if (fName.equalsIgnoreCase(parentLookupField)) continue;
                    Object v = src.get(fName);
                    if (v != null) clone.put(fName, v);
                }
                clone.put(parentLookupField, merchantComplianceId);
                newRows.add(clone);
            }
            insert newRows;
        } catch (Exception e) {
            // Never rethrow — this is defensive and must never block merchant creation.
            logLegacyError('copyPartnerChargebackProtection failed', e,
                           String.valueOf(partnerComplianceId));
        }
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
    
        // Post-demo Batch C: resolve partner Sales Rep upfront so we can stamp it
    // onto the Opportunity (which is inserted before Compliance).
    private static Id resolvePartnerSalesRep(String partnerId) {
        if (String.isBlank(partnerId)) return null;
        List<Compliance__c> partners = [
            SELECT Sales_Rep__c FROM Compliance__c
            WHERE Nuvei_Partner_ID__c = :partnerId
            LIMIT 1
        ];
        return partners.isEmpty() ? null : partners[0].Sales_Rep__c;
    }
    
           private static void seedRolesFromPartner(Compliance__c comp) {
        Id partnerComplianceId = comp.From_Reseller__c;
        if (partnerComplianceId == null) return;

        List<Compliance__c> partners = [
            SELECT Sales_Rep__c, Account_Manager__c, Underwriting_Mgr__c,
                   Assessment_Handling_Service_Fee__c,
                   Minimum_monthly_fee_Value_1__c,
                   Remittance_Cycle__c,
                   Settlement_threshold__c
            FROM Compliance__c
            WHERE Id = :partnerComplianceId
            LIMIT 1
        ];
        if (partners.isEmpty()) {
            return;
        }
        Compliance__c p = partners[0];

        // Roles
        if (comp.Sales_Rep__c == null)         comp.Sales_Rep__c         = p.Sales_Rep__c;
        if (comp.Account_Manager__c == null)   comp.Account_Manager__c   = p.Account_Manager__c;
        if (comp.Underwriting_Mgr__c == null)  comp.Underwriting_Mgr__c  = p.Underwriting_Mgr__c;

        // Pricing defaults — copy only when merchant value is blank so any
        // manual override on the merchant Compliance is preserved.
        if (comp.Assessment_Handling_Service_Fee__c == null)
            comp.Assessment_Handling_Service_Fee__c = p.Assessment_Handling_Service_Fee__c;
        if (comp.Minimum_monthly_fee_Value_1__c == null)
            comp.Minimum_monthly_fee_Value_1__c = p.Minimum_monthly_fee_Value_1__c;
        if (comp.Remittance_Cycle__c == null)
            comp.Remittance_Cycle__c = p.Remittance_Cycle__c;
        if (comp.Settlement_threshold__c == null)
            comp.Settlement_threshold__c = p.Settlement_threshold__c;
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
            c.Profile_Type__c    = 'None';
            if (!cPanelContacts.isEmpty()) {
                c.ContactId              = cPanelContacts[0].Id;
                c.SB_PPP_Username__c     = cPanelContacts[0].Email;
                // Wave 2 fix (gap #11): seed Contact_Information__c so OCT
                // doesn't have to fill it manually.
                c.Contact_Information__c = cPanelContacts[0].Email;
            }
            List<ExpressConfig__c> cfgRows = [
                SELECT SB_Template__c FROM ExpressConfig__c LIMIT 1
            ];
            // Wave 2 fix (gap #10): SB_Template__c falls back to 'Ecommerce' when
            // ExpressConfig is missing or its SB_Template__c is blank.
            if (!cfgRows.isEmpty() && String.isNotBlank(cfgRows[0].SB_Template__c)) {
                c.SB_Template__c = cfgRows[0].SB_Template__c;
            } else {
                c.SB_Template__c = 'Ecommerce';
                System.debug(LoggingLevel.WARN,
                    'NuveiConnectWebhook | gap #10 fallback — ExpressConfig.SB_Template__c blank, defaulted Case.SB_Template__c to Ecommerce');
            }
            insert c;
        } catch (Exception e) {
            logLegacyError('createConfigurationCase failed', e, comp.Nuvei_Connect_Application_ID__c);
        }
    }
    
        private static void backfillOwnerContactsAndJunctions(
        Compliance__c existing,
        NuveiConnectRequest req
    ) {
        if (req.businessOwnerInformation == null || req.businessOwnerInformation.isEmpty()) return;

        // Existing junction rows for this Compliance — keyed by Contact email lowercase
        Set<String> alreadyLinkedEmails = new Set<String>();
        for (Compliance_Contact__c cc : [
            SELECT Contact__c, Contact__r.Email
            FROM Compliance_Contact__c
            WHERE Compliance__c = :existing.Id
        ]) {
            if (cc.Contact__r != null && String.isNotBlank(cc.Contact__r.Email)) {
                alreadyLinkedEmails.add(cc.Contact__r.Email.toLowerCase());
            }
        }

        // Existing Contacts on the Account by email (lowercase key)
        Map<String, Contact> existingByEmail = new Map<String, Contact>();
        for (Contact c : [
            SELECT Id, Email, Authorized_Signature__c, Is_CPanel_Admin__c
            FROM Contact
            WHERE AccountId = :existing.Account__c AND Email != null
        ]) {
            existingByEmail.put(c.Email.toLowerCase(), c);
        }

        String cPanelEmail = req.additionalInformation?.portalAdminEmail;
        String cPanelLower = String.isBlank(cPanelEmail) ? null : cPanelEmail.toLowerCase();

        List<Contact> contactsToInsert = new List<Contact>();
        List<Contact> contactsToUpdate = new List<Contact>();

        for (BusinessOwnerWrapper bo : req.businessOwnerInformation) {
            if (String.isBlank(bo.email)) continue;
            String emailLower = bo.email.toLowerCase();

            if (existingByEmail.containsKey(emailLower)) {
                Contact existingC = existingByEmail.get(emailLower);
                Boolean dirty = false;
                if (bo.isAuthorizedSignatory == true && existingC.Authorized_Signature__c != true) {
                    existingC.Authorized_Signature__c = true;
                    dirty = true;
                }
                if (cPanelLower != null && emailLower == cPanelLower
                    && existingC.Is_CPanel_Admin__c != true) {
                    existingC.Is_CPanel_Admin__c = true;
                    dirty = true;
                }
                if (dirty) contactsToUpdate.add(existingC);
            } else {
                Contact c = new Contact();
                c.AccountId               = existing.Account__c;
                c.FirstName               = bo.legalFirstName;
                c.LastName                = String.isNotBlank(bo.legalLastName)
                                              ? bo.legalLastName
                                              : (req.businessInformation != null
                                                    ? req.businessInformation.legalName : 'Unknown');
                c.Email                   = bo.email;
                c.Phone                   = bo.contactNumber;
                c.Authorized_Signature__c = bo.isAuthorizedSignatory == true;
                if (cPanelLower != null && emailLower == cPanelLower) {
                    c.Is_CPanel_Admin__c = true;
                }
                contactsToInsert.add(c);
            }
        }

        if (!contactsToUpdate.isEmpty()) {
            try { update contactsToUpdate; }
            catch (Exception e) { logLegacyError('Wave 4: contact update failed', e, req.applicationId); }
        }
        if (!contactsToInsert.isEmpty()) {
            try { insert contactsToInsert; }
            catch (Exception e) { logLegacyError('Wave 4: contact insert failed', e, req.applicationId); }
        }

        Map<String, Id> emailToId = new Map<String, Id>();
        for (Contact c : [
            SELECT Id, Email FROM Contact
            WHERE AccountId = :existing.Account__c AND Email != null
        ]) {
            emailToId.put(c.Email.toLowerCase(), c.Id);
        }

        List<Compliance_Contact__c> junctions = new List<Compliance_Contact__c>();
        for (BusinessOwnerWrapper bo : req.businessOwnerInformation) {
            if (String.isBlank(bo.email)) continue;
            String emailLower = bo.email.toLowerCase();
            if (alreadyLinkedEmails.contains(emailLower)) continue;
            if (!emailToId.containsKey(emailLower)) continue;
            junctions.add(new Compliance_Contact__c(
                Compliance__c = existing.Id,
                Contact__c    = emailToId.get(emailLower)
            ));
        }
        if (!junctions.isEmpty()) {
            try { insert junctions; }
            catch (Exception e) { logLegacyError('Wave 4: junction insert failed', e, req.applicationId); }
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
            get {
                if (metadata == null) return null;
                return metadata.partnerExternalId;
            }
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
        public Boolean isAuthorizedSignatory;   // ← Wave 4 (gap #23)
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
    // NC's internal UUID for the partner — meaningless to Salesforce.
    // Kept for logging/debugging only; NOT used for partner resolution.
    public String partnerId;
    // Our UUID that we shared with NC when configuring the partner.
    // Matches Compliance__c.Nuvei_Partner_ID__c → used for resolution.
    public String partnerExternalId;
    public String msaTemplateId;
}
    global class WebhookResult {
        public Boolean success = false;
        public String  message;
        public String  errorDetail;
        public String  complianceId;
    }
}
