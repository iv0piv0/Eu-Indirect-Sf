/**
 * Controller for MsaEuIndirectPdf VF page.
 *
 * Replaces Conga-driven PDF generation (TrackDMsaConga.generateMsaPdf) with a
 * native Salesforce Visualforce renderAs="pdf" pipeline. Pure Salesforce —
 * no external callouts, no API limits, no licensing.
 *
 * Usage from Apex:
 *   PageReference pr = Page.MsaEuIndirectPdf;
 *   pr.getParameters().put('id', complianceId);
 *   pr.getParameters().put('signerContactId', signerContactId);
 *   Blob pdf = Test.isRunningTest() ? Blob.valueOf('test') : pr.getContentAsPDF();
 *
 * The 'id' parameter is required (Compliance__c).
 * The 'signerContactId' parameter is optional — when present, it populates the
 * client-side signature block on page 1.
 */
public with sharing class MsaEuIndirectPdfController {

    public Compliance__c             compliance              { get; private set; }
    public List<Website__c>          websites                { get; private set; }
    public List<Merchant_Bank__c>    merchantBanks           { get; private set; }
    public List<Chargeback_Protection__c> chargebackProtections { get; private set; }
    public Application_Form__c       applicationForm         { get; private set; }
    public Boolean                   hasApplicationForm      { get; private set; }
    public Boolean                   hasReseller             { get; private set; }
    public String                    resellerName            { get; private set; }
    public String                    signerName              { get; private set; }
    public String                    signerTitle             { get; private set; }
    public String                    remittanceCurrencyDisplay { get; private set; }
    public Date                      todayDate               { get; private set; }

    public MsaEuIndirectPdfController() {
        this.todayDate = Date.today();

        Id complianceId = parseId(ApexPages.currentPage().getParameters().get('id'));
        if (complianceId == null) {
            // Render-safe empty state so design-time previews don't blow up.
            this.compliance = new Compliance__c();
            this.websites = new List<Website__c>();
            this.merchantBanks = new List<Merchant_Bank__c>();
            this.chargebackProtections = new List<Chargeback_Protection__c>();
            this.applicationForm = new Application_Form__c();
            this.hasApplicationForm = false;
            this.hasReseller = false;
            this.remittanceCurrencyDisplay = '';
            return;
        }

        loadCompliance(complianceId);
        loadWebsites(complianceId);
        loadMerchantBanks(complianceId);
        loadChargebackProtections(complianceId);
        loadApplicationForm(complianceId);
        resolveSigner(parseId(ApexPages.currentPage().getParameters().get('signerContactId')));

        this.remittanceCurrencyDisplay = formatRemittanceCurrency(this.compliance);
    }

    /**
     * Parent record. Hardcoded field list keeps the SOQL deterministic and
     * fast — every field here corresponds to a merge token in the template.
     */
    private void loadCompliance(Id complianceId) {
        List<Compliance__c> rows = [
            SELECT Id, Name,
                   MSA_Effective_Date__c,
                   Registered_Country__c,
                   Incorporation_number__c,
                   Registered_Address_New__c,
                   Remittance_Cycle_MSA_wording__c,
                   Minimum_Fee_SC_ACQIURER_MSA_section__c,
                   Contract_Term__c,
                   Fees_Currency__c,
                   Minimum_commitment_calculation__c,
                   Holdback_rate_for_APMs_for_PQ_MSA__c,
                   APM_Chargeback_Fee__c,
                   GW_Processing_Fee__c,
                   Wire_Fee__c,
                   Remittance_Currency__c,
                   Remittance_Currency_Text__c,
                   Mastercard_Automatic_Billing_Updater_ABU__c,
                   Tokenization_recurring__c,
                   Cashier_fee__c,
                   Smart_3D_Secure_Fee__c,
                   X3D_Transactions_Fee__c,
                   DCC__c,
                   Visa_Account_Name_Inquiry_ANI__c,
                   From_Reseller__c,
                   From_Reseller__r.Name
            FROM Compliance__c
            WHERE Id = :complianceId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            this.compliance = new Compliance__c();
            this.hasReseller = false;
            this.resellerName = '';
            return;
        }
        this.compliance = rows[0];
        this.hasReseller = (this.compliance.From_Reseller__c != null
            && this.compliance.From_Reseller__r != null
            && String.isNotBlank(this.compliance.From_Reseller__r.Name));
        this.resellerName = this.hasReseller ? this.compliance.From_Reseller__r.Name : '';
    }

    private void loadWebsites(Id complianceId) {
        this.websites = [
            SELECT Id, Name
            FROM Website__c
            WHERE Compliance__c = :complianceId
            ORDER BY Name
        ];
    }

    /**
     * Merchant-level pricing only. Mirrors the existing §18 filter
     * (Partner_Template_Pricing__c = false) so we render the same banks
     * the previous Conga template would have.
     */
    private void loadMerchantBanks(Id complianceId) {
        this.merchantBanks = [
            SELECT Id,
                   Bank_Name_for_Conga__c,
                   New_MSA_wording__c,
                   Setup_fee_per_bank_Merchant_ID_MID__c,
                   Annual_Fee__c,
                   bank_Monthly_Fee__c,
                   X3D_secure_registration_fee__c,
                   Arbitration_fee__c,
                   Remittance_Fee__c,
                   Risk_fee__c,
                   Trx_Fee__c,
                   Other_Cards__c,
                   Credit_Fee_Per_Credit__c,
                   Mastercard_PT__c,
                   Visa_Direct_fee__c,
                   Visa_Direct_RoW__c,
                   CMM_Report_Fee__c,
                   ECM_Report_Fee__c,
                   CHB_Handling__c,
                   CB_Chb_Representment__c,
                   Holdback_rate_For_PQ__c,
                   Retrieval_Fee__c,
                   Statement_Fee_per_MID__c
            FROM Merchant_Bank__c
            WHERE Compliance__c = :complianceId
            AND Partner_Template_Pricing__c = false
            ORDER BY Bank_Name_for_Conga__c NULLS LAST
        ];
    }

    private void loadChargebackProtections(Id complianceId) {
        this.chargebackProtections = [
            SELECT Id, MSA_Name__c, Success_Fee__c, Setup_Fee__c
            FROM Chargeback_Protection__c
            WHERE Company_Profile__c = :complianceId
            AND MSA_Name__c != null
            ORDER BY MSA_Name__c
        ];
    }

    /**
     * One Application_Form__c per Compliance is the assumed convention.
     * We sort by CreatedDate ASC so older forms win — they're the
     * canonical record per the existing C-Panel flow.
     */
    private void loadApplicationForm(Id complianceId) {
        List<Application_Form__c> rows = [
            SELECT Id, Name,
                   Primary_Contact_First_Name_New__c,
                   Primary_Contact_Last_Name_New__c,
                   Primary_Contact_Title_New__c,
                   Primary_Contact_Tel_New__c,
                   Primary_Contact_Email_New__c,
                   C_Panel_Administrator_First_Name__c,
                   C_Panel_Administrator_Last_Name__c,
                   C_Panel_Administrator_Title_Position__c,
                   C_Panel_Administrator_Email_Address__c,
                   C_Panel_Administrator_Secret_Word__c,
                   C_Panel_Administrator_Phone__c,
                   APM_Pricing_Manager_First_Name__c,
                   APM_Pricing_Manager_Last_Name__c,
                   APM_Pricing_Manager_Title_Position__c,
                   APM_Pricing_Manager_Email__c,
                   APM_Pricing_Manager_Secret_Word__c,
                   APM_Pricing_Manager_Phone__c
            FROM Application_Form__c
            WHERE Company_Profile__c = :complianceId
            ORDER BY CreatedDate ASC
            LIMIT 1
        ];
        this.hasApplicationForm = !rows.isEmpty();
        this.applicationForm = this.hasApplicationForm ? rows[0] : new Application_Form__c();
    }

    private void resolveSigner(Id signerContactId) {
        this.signerName = '';
        this.signerTitle = '';
        if (signerContactId == null) return;
        List<Contact> rows = [
            SELECT FirstName, LastName, Title
            FROM Contact
            WHERE Id = :signerContactId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        Contact c = rows[0];
        this.signerName = (c.FirstName == null ? '' : c.FirstName + ' ')
            + (c.LastName == null ? '' : c.LastName);
        this.signerTitle = c.Title == null ? '' : c.Title;
    }

    /**
     * Reproduce Conga's REPLACE logic for the multi-picklist semicolons:
     *   'EUR;USD;GBP'  →  'EUR, USD, GBP'
     * Falls back to the text-formula field, then to the raw multipicklist.
     */
    private String formatRemittanceCurrency(Compliance__c c) {
        if (c == null) return '';
        String raw = String.isNotBlank(c.Remittance_Currency_Text__c)
            ? c.Remittance_Currency_Text__c
            : (c.Remittance_Currency__c == null ? '' : c.Remittance_Currency__c);
        return raw == null ? '' : raw.replace(';', ', ');
    }

    private Id parseId(String s) {
        if (String.isBlank(s)) return null;
        try { return (Id) s; }
        catch (Exception e) { return null; }
    }
}
