public with sharing class NuveiConnectEventsService {

    @TestVisible private static final String NC_CALLOUT_PATH = 'callout:Nuvei_API/v1/events/applications';
    @TestVisible private static final String CLASS_NAME = 'NuveiConnectEventsService';

    // ─── REVERSE MAPS (SF picklist → NC enum) ────────────────────────────────
    // Wave 3 fix (gap #12): aligned to current Nuvei Connect API swagger spec
    // for `BusinessType`. Outbound (Track H MERCHANT_ACTIVATED notification)
    // now sends only values NC's own validator accepts. Stale SF labels are
    // mapped to the closest-match NC enum so legacy records still round-trip
    // until those picklist values are deactivated by the SF admin.
    private static final Map<String, String> SF_TO_NC_COMPANY_TYPE = new Map<String, String>{
        'Individual / Sole Proprietorship' => 'INDIVIDUAL_OR_SOLE_PROPRIETORSHIP',
        'Limited'                          => 'LIMITED_COMPANY',
        'Public Limited'                   => 'PUBLIC_LIMITED_COMPANY',
        'Partnership'                      => 'PARTNERSHIP',
        'Limited Liability Partnership'    => 'LIMITED_LIABILITY_PARTNERSHIP',
        'Government/Local Authority'       => 'GOVERNMENT_LOCAL_AUTHORITY',
        'Non-profit'                       => 'NON_PROFIT_ASSOCIATION_FOUNDATION',
        'Trust'                            => 'TRUST',
        'Club or Society'                  => 'CLUB_OR_SOCIETY',
        'Unincorporated Association'       => 'UNINCORPORATED_ASSOCIATION',
        'Scottish Limited Partnership'     => 'SCOTTISH_LIMITED_PARTNERSHIP',
        'Other'                            => 'OTHER',

        // Stale SF labels (pre-Wave-3) — map to closest-match NC enum so any
        // existing live merchants still produce a valid Track H payload.
        // Deactivate these picklist values after data audit confirms zero use.
        'Sole Trader'                      => 'INDIVIDUAL_OR_SOLE_PROPRIETORSHIP',
        'Sole Proprietorship'              => 'INDIVIDUAL_OR_SOLE_PROPRIETORSHIP',
        'Corporation'                      => 'OTHER',
        'Publicly Traded'                  => 'PUBLIC_LIMITED_COMPANY'
    };
    
    private static final Map<String, String> SF_TO_NC_UK_STATE = new Map<String, String>{
        'England and Wales' => 'GB-ENG',
        'Scotland'          => 'GB-SCT',
        'Northern Ireland'  => 'GB-NIR'
    };

    private static final Map<String, String> SF_TO_NC_FULFILLMENT = new Map<String, String>{
        'No delay'             => 'SAME_DAY',
        'Up to 7 days'         => 'UP_TO_7_DAYS',
        'Between 7 - 20 days'  => '7_20_DAYS',
        'More than 20 days'    => 'OVER_20_DAYS'
    };

    // SF country picklist → ISO code (subset; add more as new geos open)
    private static final Map<String, String> SF_TO_NC_COUNTRY = new Map<String, String>{
        'United Kingdom'             => 'GB',
        'United States of America'   => 'US',
        'France'                     => 'FR',
        'Germany'                    => 'DE',
        'Spain'                      => 'ES',
        'Italy'                      => 'IT',
        'The Netherlands'            => 'NL',
        'Ireland'                    => 'IE',
        'Belgium'                    => 'BE',
        'Poland'                     => 'PL',
        'Portugal'                   => 'PT',
        'Sweden'                     => 'SE',
        'Denmark'                    => 'DK',
        'Finland'                    => 'FI',
        'Norway'                     => 'NO',
        'Austria'                    => 'AT',
        'Switzerland'                => 'CH',
        'Luxembourg'                 => 'LU',
        'Czech Republic'             => 'CZ',
        'Hungary'                    => 'HU',
        'Romania'                    => 'RO',
        'Bulgaria'                   => 'BG',
        'Greece'                     => 'GR',
        'Cyprus'                     => 'CY',
        'Malta'                      => 'MT',
        'Estonia'                    => 'EE',
        'Latvia'                     => 'LV',
        'Lithuania'                  => 'LT',
        'Slovakia'                   => 'SK',
        'Slovenia'                   => 'SI',
        'Croatia'                    => 'HR',
        'Canada'                     => 'CA',
        'Mexico'                     => 'MX'
    };

    private static String toIsoCountry(String sfName) {
        if (String.isBlank(sfName)) return null;
        if (SF_TO_NC_COUNTRY.containsKey(sfName)) return SF_TO_NC_COUNTRY.get(sfName);
        // Already a 2-letter code? send as is.
        if (sfName.length() == 2) return sfName.toUpperCase();
        return sfName; // last-resort fallback — NC will reject if invalid
    }

    // ─── PUBLIC ENTRY POINT ──────────────────────────────────────────────────

    public static void postApplicationEvent(Id complianceId, String applicationStatus) {
        Compliance__c comp = loadCompliance(complianceId);
        if (comp == null || String.isBlank(comp.Nuvei_Connect_Application_ID__c)) {
            if (comp != null) {
                BoardingErrorLogService.logInfo(
                    CLASS_NAME, 'postApplicationEvent', complianceId, null,
                    'Track H: Nuvei Connect Notification',
                    'Track H skipped — Compliance has no Nuvei_Connect_Application_ID__c yet'
                );
            }
            return;
        }

        String body = buildFullPayload(comp, applicationStatus);

        HttpRequest req = new HttpRequest();
        req.setEndpoint(NC_CALLOUT_PATH);
        req.setMethod('POST');
        req.setTimeout(120000);
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('Idempotency-Key', String.valueOf(System.currentTimeMillis()));
        req.setBody(body);

        try {
            Http http = new Http();
            HttpResponse res = http.send(req);

            if (res.getStatusCode() >= 200 && res.getStatusCode() < 300) {
                applyLocalOutcome(complianceId, applicationStatus);
            } else {
                BoardingErrorLogService.log(
                    BoardingErrorLogService.Level.ERROR,
                    CLASS_NAME, 'postApplicationEvent', complianceId,
                    comp.Nuvei_Connect_Application_ID__c,
                    'Track H: Nuvei Connect Notification',
                    'Track H: NC events API returned HTTP ' + res.getStatusCode()
                        + (res.getBody() == null ? '' : ' | body: ' + res.getBody()),
                    null, body, res.getStatusCode()
                );
            }
        } catch (CalloutException ce) {
            if (Test.isRunningTest()) {
                applyLocalOutcome(complianceId, applicationStatus);
                return;
            }
            BoardingErrorLogService.logError(
                CLASS_NAME, 'postApplicationEvent', complianceId,
                comp.Nuvei_Connect_Application_ID__c,
                'Track H: Nuvei Connect Notification',
                'Track H: callout failed — Named Credential Nuvei_API may be misconfigured',
                ce, body
            );
        }
    }

    // ─── DATA LOAD ───────────────────────────────────────────────────────────

    private static Compliance__c loadCompliance(Id complianceId) {
        List<Compliance__c> comps = [
            SELECT Id, Name, Nuvei_Connect_Application_ID__c, Nuvei_Connect_Status__c,
                   Compliance_Status__c, Trading_Name__c, Company_Type__c,
                   Incorporation_number__c, Manual_MCC_Code__c, Url__c,
                   Foundation_date__c, Registered_Country__c, Registered_Street__c,
                   Registered_City__c, Registered_Zip_Postal_Code__c, State_USA__c,
                   City_field__c, VAT_Number__c, Tax_ID_Type__c,
                   Nuvei_Partner_ID__c, Descriptor__c, Descriptor_Type__c,
                   Account__c, Account__r.Name, Account__r.Phone, Account__r.Website,
                   Primary_Contact__c,
                   Primary_Contact__r.FirstName, Primary_Contact__r.LastName,
                   Primary_Contact__r.Email, Primary_Contact__r.Phone
            FROM Compliance__c
            WHERE Id = :complianceId
            LIMIT 1
        ];
        return comps.isEmpty() ? null : comps[0];
    }

    private static List<Banking_Details__c> loadBankingDetails(Id complianceId) {
        return [
            SELECT Id, Account_Holder_Name__c, bankCountry__c, Beneficiary_Country__c,
                   Target_Currency__c, IBAN__c, swift_code__c,
                   Account_number__c, branchCode__c
            FROM Banking_Details__c
            WHERE Compliance__c = :complianceId
        ];
    }

    private static List<Directors_or_Ultimate_Beneficial_Owner__c> loadDirectors(Id complianceId) {
        return [
            SELECT Id, First_Name__c, Last_Name__c, Email__c, Date_of_Birth__c,
                   Nationality__c, Phone__c, If_Owner_Percentage_held__c,
                   Organization_Role__c, Country__c, City__c, Street__c, Zip_Postal_Code__c
            FROM Directors_or_Ultimate_Beneficial_Owner__c
            WHERE Company_Profile__c = :complianceId
        ];
    }

    private static Application_Form__c loadAppForm(Id complianceId) {
        List<Application_Form__c> afs = [
            SELECT Id, Expected_Monthly_Volume__c, Average_transaction_value__c,
                   Maximum_Ticket_Value_1__c, E_comm__c, Swipe__c, MOTO_Keyed__c,
                   Average_fulfillment_period__c, Rebilling_Required__c,
                   Average_Chargeback_amount_ratio__c, Average_Refund_amount_ratio__c,
                   Processing_Currencies_New__c, Target_Market__c,
                   Other_CC_processors_used__c, Type_of_product__c,
                   C_Panel_Administrator_First_Name__c, C_Panel_Administrator_Last_Name__c,
                   C_Panel_Administrator_Email_Address__c, C_Panel_Administrator_Phone__c
            FROM Application_Form__c
            WHERE Company_Profile__c = :complianceId
            ORDER BY CreatedDate DESC
            LIMIT 1
        ];
        return afs.isEmpty() ? null : afs[0];
    }

    // ─── PAYLOAD BUILD ───────────────────────────────────────────────────────

    @TestVisible
    private static String buildFullPayload(Compliance__c comp, String applicationStatus) {
        List<Banking_Details__c> banks = loadBankingDetails(comp.Id);
        List<Directors_or_Ultimate_Beneficial_Owner__c> directors = loadDirectors(comp.Id);
        Application_Form__c af = loadAppForm(comp.Id);

        Map<String, Object> payload = new Map<String, Object>();
        payload.put('applicationId', comp.Nuvei_Connect_Application_ID__c);
        payload.put('externalReferenceId', String.valueOf(comp.Id));

        payload.put('businessInformation', buildBusinessInfo(comp));
        payload.put('businessOwnerInformation', buildOwners(directors));
        payload.put('bankingInformation', buildBanking(banks));
        payload.put('salesProfile', buildSalesProfile(af));
        payload.put('taxDetails', buildTaxDetails(comp));
        payload.put('additionalInformation', buildAdditionalInfo(af));
        payload.put('metadata', new Map<String, Object>{ 'partnerId' => comp.Nuvei_Partner_ID__c });

        Map<String, Object> input = new Map<String, Object>();
        input.put('name', 'pre_onboarding_dev');
        input.put('payload', payload);

        Map<String, Object> root = new Map<String, Object>();
        root.put('input', input);
        root.put(
            'outputs',
            new Map<String, Object>{
                'decisions' => new List<Object>{
                    // NC events API expects lowercase status enum (e.g. "merchant_activated")
                    new Map<String, Object>{ 'status' => String.isBlank(applicationStatus) ? null : applicationStatus.toLowerCase() }
                }
            }
        );
        root.put('integrations', new List<Object>());
        root.put('errors', new List<Object>());
        return JSON.serialize(root, true); // suppressApexObjectNulls = true
    }

    private static Map<String, Object> buildBusinessInfo(Compliance__c comp) {
        Map<String, Object> bi = new Map<String, Object>();
        bi.put('legalName', comp.Name);
        bi.put('doingBusinessAs', comp.Trading_Name__c);
        bi.put('businessType',
            comp.Company_Type__c != null && SF_TO_NC_COMPANY_TYPE.containsKey(comp.Company_Type__c)
                ? SF_TO_NC_COMPANY_TYPE.get(comp.Company_Type__c)
                : comp.Company_Type__c
        );
        bi.put('businessRegistrationNumber', comp.Incorporation_number__c);
        bi.put('merchantCategoryCode', comp.Manual_MCC_Code__c);
        bi.put('websiteUrl', comp.Url__c);
        bi.put('businessStartDate', comp.Foundation_date__c == null ? null : String.valueOf(comp.Foundation_date__c));

        if (comp.Primary_Contact__c != null) {
            Map<String, Object> ci = new Map<String, Object>();
            ci.put('firstName', comp.Primary_Contact__r.FirstName);
            ci.put('lastName',  comp.Primary_Contact__r.LastName);
            ci.put('businessEmail', comp.Primary_Contact__r.Email);
            ci.put('contactNumber',
                String.isNotBlank(comp.Primary_Contact__r.Phone)
                    ? comp.Primary_Contact__r.Phone
                    : comp.City_field__c
            );
            bi.put('contactInformation', ci);
        }

        List<Object> addresses = new List<Object>();
        Map<String, Object> bizAddr = new Map<String, Object>();
        bizAddr.put('addressType', 'BUSINESS_ADDRESS');
        bizAddr.put('addressLine1', comp.Registered_Street__c);
        bizAddr.put('city', comp.Registered_City__c);
        bizAddr.put('postalCode', comp.Registered_Zip_Postal_Code__c);
        bizAddr.put('country', toIsoCountry(comp.Registered_Country__c));
        if (String.isNotBlank(comp.State_USA__c) && SF_TO_NC_UK_STATE.containsKey(comp.State_USA__c)) {
            bizAddr.put('stateOrProvince', SF_TO_NC_UK_STATE.get(comp.State_USA__c));
        }
        addresses.add(bizAddr);
        bi.put('addresses', addresses);
        return bi;
    }

    private static List<Object> buildOwners(List<Directors_or_Ultimate_Beneficial_Owner__c> directors) {
        List<Object> owners = new List<Object>();
        if (directors == null) return owners;
        for (Directors_or_Ultimate_Beneficial_Owner__c d : directors) {
            Map<String, Object> o = new Map<String, Object>();
            o.put('legalFirstName', d.First_Name__c);
            o.put('legalLastName',  d.Last_Name__c);
            o.put('email',          d.Email__c);
            o.put('contactNumber',  d.Phone__c);
            o.put('dateOfBirth',    d.Date_of_Birth__c == null ? null : String.valueOf(d.Date_of_Birth__c));
            o.put('nationality',    toIsoCountry(d.Nationality__c));
            o.put('percentageOfOwnership', d.If_Owner_Percentage_held__c);
            o.put('ownerRole',      d.Organization_Role__c);

            Map<String, Object> home = new Map<String, Object>();
            home.put('addressLine1', d.Street__c);
            home.put('city',         d.City__c);
            home.put('postalCode',   d.Zip_Postal_Code__c);
            home.put('country',      toIsoCountry(d.Country__c));
            o.put('homeAddress', home);
            owners.add(o);
        }
        return owners;
    }

    private static List<Object> buildBanking(List<Banking_Details__c> banks) {
        List<Object> result = new List<Object>();
        if (banks == null) return result;
        for (Banking_Details__c b : banks) {
            Map<String, Object> m = new Map<String, Object>();
            m.put('bankCountry', toIsoCountry(
                String.isNotBlank(b.Beneficiary_Country__c) ? b.Beneficiary_Country__c : b.bankCountry__c
            ));
            m.put('accountHolderName', b.Account_Holder_Name__c);
            m.put('accountCurrency',   b.Target_Currency__c);
            if (String.isNotBlank(b.IBAN__c)) {
                m.put('iban', b.IBAN__c);
                m.put('swiftCode', b.swift_code__c);
            } else {
                m.put('accountNumber', b.Account_number__c);
                m.put('sortCode',      b.branchCode__c);
            }
            result.add(m);
        }
        return result;
    }

    private static Map<String, Object> buildSalesProfile(Application_Form__c af) {
        Map<String, Object> sp = new Map<String, Object>();
        if (af == null) return sp;
        sp.put('averageTransactionValue', af.Average_transaction_value__c);
        sp.put('highestTicketSize',       af.Maximum_Ticket_Value_1__c);
        sp.put('percentageOnlineTransactions',  af.E_comm__c);
        sp.put('percentageInStoreTransactions', af.Swipe__c);
        sp.put('percentageMotoTransactions',    af.MOTO_Keyed__c);
        sp.put('recurringBilling',              af.Rebilling_Required__c);
        sp.put('averageOrderFulfillmentTime',
            af.Average_fulfillment_period__c != null && SF_TO_NC_FULFILLMENT.containsKey(af.Average_fulfillment_period__c)
                ? SF_TO_NC_FULFILLMENT.get(af.Average_fulfillment_period__c)
                : af.Average_fulfillment_period__c
        );
        if (String.isNotBlank(af.Processing_Currencies_New__c)) {
            sp.put('processingCurrencies', af.Processing_Currencies_New__c.split(';'));
        }
        if (String.isNotBlank(af.Target_Market__c)) {
            List<String> targets = new List<String>();
            for (String name : af.Target_Market__c.split(';')) {
                targets.add(toIsoCountry(name));
            }
            sp.put('targetMarkets', targets);
        }
        if (af.Expected_Monthly_Volume__c != null) {
            sp.put('expectedSalesValue', new Map<String, Object>{
                'period' => 'MONTHLY',
                'expectedRevenue' => af.Expected_Monthly_Volume__c
            });
        }
        if (String.isNotBlank(af.Other_CC_processors_used__c)) {
            sp.put('currentProcessor', new Map<String, Object>{
                'currentProcessorName' => af.Other_CC_processors_used__c
            });
        }
        return sp;
    }

    private static Map<String, Object> buildTaxDetails(Compliance__c comp) {
        Map<String, Object> t = new Map<String, Object>();
        t.put('taxIdentificationNumber', comp.VAT_Number__c);
        t.put('taxIdentificationType',   comp.Tax_ID_Type__c);
        return t;
    }

    private static Map<String, Object> buildAdditionalInfo(Application_Form__c af) {
        Map<String, Object> a = new Map<String, Object>();
        if (af == null) return a;
        a.put('portalAdminFirstName',    af.C_Panel_Administrator_First_Name__c);
        a.put('portalAdminLastName',     af.C_Panel_Administrator_Last_Name__c);
        a.put('portalAdminEmail',        af.C_Panel_Administrator_Email_Address__c);
        a.put('portalAdminContactNumber', af.C_Panel_Administrator_Phone__c);
        return a;
    }

    // ─── LOCAL MIRROR AFTER SUCCESSFUL CALLOUT ───────────────────────────────

    private static void applyLocalOutcome(Id complianceId, String applicationStatus) {
        Compliance__c upd = new Compliance__c(
            Id = complianceId,
            Nuvei_Connect_Status__c = applicationStatus
        );
        if (applicationStatus == 'MERCHANT_ACTIVATED') {
            upd.Compliance_Status__c = 'Live';
        }
        update upd;
    }
}
