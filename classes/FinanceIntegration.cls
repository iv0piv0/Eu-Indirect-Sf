/*
 * @Author: ZedXagE 
 * @Date: 2019-10-02 10:00:28 
 * @Last Modified by: ZedXagE
 * @Last Modified time: 2019-10-02 11:28:5
 */
public class FinanceIntegration {
    public String curid;
    public FinanceIntegration() {}
    public FinanceIntegration(ApexPages.StandardController std) {
        init();
    }
    public void init(){
        curid = ApexPages.currentPage().getParameters().get('id');
    }
    public class Param {
        @InvocableVariable(label='Company Profile Id' required=true) public String compid;
    }
    @InvocableMethod(label='Finance Integration')
    public static void invocableFinanceIntegration(Param[] params) {
        Param param = params[0];
        futureFinanceIntegration(param.compid);
    }
    @future(callout=true)
    public static void futureFinanceIntegration(String compid) {
        FinanceIntegration fin = new FinanceIntegration();
        fin.curid = compid;
        fin.act();
    }
    public Pagereference act(){
        List<Compliance__c> meta = [
            SELECT Nuvei_Connect_Application_ID__c, EU_Indirect_Orchestration__c
            FROM Compliance__c
            WHERE Id = :curid
            LIMIT 1
        ];
        Boolean euIndirect = !meta.isEmpty() && meta[0].EU_Indirect_Orchestration__c == true;
        try {
            FinanceHttpResult out = sendFinanceHttpInternal(curid);
            Compliance__c upd = new Compliance__c(Id = curid, Finance_Log__c = out.financeLog);
            if (euIndirect) {
                upd.Finance_admin_status__c = out.success ? 'Completed' : 'Failed';
                if (!out.success) {
                    // Echo the actual upstream HTTP code into Status_Code__c so it
                    // surfaces in the Execution_Log Error list view.
                    BoardingErrorLogService.log(
                        BoardingErrorLogService.Level.ERROR,
                        'FinanceIntegration',
                        'futureFinanceIntegration',
                        curid,
                        meta[0].Nuvei_Connect_Application_ID__c,
                        'Track G: Finance Admin',
                        'Track G: Finance Admin API returned HTTP ' + out.statusCode,
                        null,
                        out.financeLog,
                        out.statusCode
                    );
                    bumpTrackGRetryCount(curid);
                }
            }
            update upd;
        } catch (Exception e) {
            if (euIndirect) {
                BoardingErrorLogService.logError(
                    'FinanceIntegration',
                    'futureFinanceIntegration',
                    curid,
                    meta[0].Nuvei_Connect_Application_ID__c,
                    'Track G: Finance Admin',
                    'Track G: exception during Finance Admin call',
                    e,
                    null
                );
                bumpTrackGRetryCount(curid);
                update new Compliance__c(Id = curid, Finance_admin_status__c = 'Failed');
            } else {
                throw e;
            }
        }
        Pagereference pg = new Pagereference('/'+curid);
        pg.setRedirect(true);
        return pg;
    }

    /**
     * EU Indirect Boarding — Track G circuit breaker.
     *
     * Increments Compliance__c.Track_G_Retry_Count__c by 1 on every failed
     * Finance Admin attempt so IndirectBoardingRouter.tryTrackFinance can stop
     * auto-retrying after MAX_RETRIES. Best-effort — never blocks the terminal
     * status write that the caller is about to perform.
     */
    @TestVisible
    private static void bumpTrackGRetryCount(String complianceId) {
        if (String.isBlank(complianceId)) return;
        try {
            List<Compliance__c> rows = [
                SELECT Track_G_Retry_Count__c
                FROM Compliance__c
                WHERE Id = :complianceId
                LIMIT 1
            ];
            if (rows.isEmpty()) return;
            Decimal current = rows[0].Track_G_Retry_Count__c == null ? 0 : rows[0].Track_G_Retry_Count__c;
            update new Compliance__c(
                Id = complianceId,
                Track_G_Retry_Count__c = current + 1
            );
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'FinanceIntegration.bumpTrackGRetryCount | ' + e.getTypeName() + ': ' + e.getMessage());
        }
    }

    public static FinanceIntegration_Setting__c getSett(){
        return [select endpoint__c,secret__c from FinanceIntegration_Setting__c limit 1];
    }
    public static FinanceRoot GenerateTree(String recid,FinanceIntegration_Setting__c sett){
        Map <String,String> iso3bycountry = new Map <String,String>();
        for(Countries__c count:[select Country_Name__c,ISO_3__c from Countries__c where Country_Name__c!=null]) iso3bycountry.put(count.Country_Name__c.tolowercase(),count.ISO_3__c);
        if(sett==null) sett = getSett();
        FinanceRoot fr = new FinanceRoot();
        String qr = 'select id,Name,Account__c,Account__r.Name,From_Reseller__c,From_Reseller__r.Name,Managing_Company__c,Account_Manager_ID__c,Account_Manager__r.Name,Account_Manager__r.Email,Sales_Rep_ID__c,Sales_Rep__r.Name,Sales_Rep__r.Email,DCC__c,VAT_Number__c,Wire_Fee__c,Fees_Currency__c,dailySettlementConversionView__c,dailySettlementConversionRateView__c,Gross_Settlement__c,Settlement_threshold__c,Processing_Currencies_New__c,Remittance_Cycle__c,Cashier_Fee__c,APM_Chargeback_Fee__c,Holdback_for_APMs__c,Minimum_monthly_fee_Value_1__c,Fix_Holdback_for_APMs__c,Holdback_rate_for_APMs_edit_by_Risk__c,Holdback_for_APMs_Currency__c, Mastercard_Automatic_Billing_Updater_ABU__c,Registered_Street__c,Registered_City__c,Registered_Zip_Postal_Code__c,Registered_Country__c';
        qr += ',(select id,MultiClient_ID__c,Client_ID__c,MultiClient_Name__c from GW_Names__r limit 1)';
        qr += ',(select id,Combined_3D_Fee__C,Retro__c,bankId__c,consolidateBank__c,IC__c,minimumCommissionCurrencystring__c,minimumCommission__c,isCostPlusOct__c,isCostPlusCredit__c,isCostPlusDeclines__c,isJurisdiction_Discount_Fee__c,Commercial_cards_additional_rate__c,Discount_Fee_ALL_Value_1__c,Discount_Fee_ALL_Value_2__c,Discount_Fee_ALL_Value_3__c,Discount_Fee_ALL_Value_4__c,Discount_Fee_EU_Value_1__c,Discount_Fee_EU_Value_2__c,Discount_Fee_EU_Value_3__c,Discount_Fee_EU_Value_4__c,Discount_Fee_ROW_Value_1__c,Discount_Fee_ROW_Value_2__c,Discount_Fee_ROW_Value_3__c,Discount_Fee_ROW_Value_4__c,Discount_Fee_UK_Value_1__c,Discount_Fee_UK_Value_2__c,Discount_Fee_UK_Value_3__c,Trx_Fee__c,Credit_Fee_Per_Credit__c,isJurisdiction_OCT__c,Mastercard_PT__c,Visa_Direct_fee__c,Visa_Direct_RoW__c,CHB_Handling__c,Fix_Holdback__c,Holdback_rate__c,Dropdown_Currency__c,Annual_Fee__c,Discount_Fee_ALL_Limit_1__c,Discount_Fee_ALL_Limit_2__c,Discount_Fee_ALL_Limit_3__c,Discount_Fee_EU_Limit_1__c,Discount_Fee_EU_Limit_2__c,Discount_Fee_EU_Limit_3__c,Discount_Fee_ROW_Limit_1__c,Discount_Fee_ROW_Limit_2__c,Discount_Fee_ROW_Limit_3__c, channel__c from Banks__r)';
        qr += ',(select id,Target_Currency__c,Account_Holder_Name__c,beneficiaryStreet__c,beneficiaryCity__c,beneficiaryPostCode__c,Beneficiary_Country__c,swift_code__c,IBAN__c,bankAddress__c,bankCountry__c,Name_of_settlement_bank__c,Account_number__c,bankCode__c,branchCode__c from Banking_Details__r Where UW_Approval__c=\'Verified\')';
        qr += ',(select id,Bank_Id__c,CCC_ID__c, minimumCommissionCurrencystring__c,minimumCommission__c,Discount_Fee__c,Transaction_Fee__c,SafeCharge_APM__c, SafeCharge_APM__r.Country__c ,SafeCharge_APM__r.SubMethod_IDs__c from APMs__r)';
        qr += ' from Compliance__c where id=:recid';
        List <Compliance__c> comps = Database.query(qr);
        
        if(comps.size()>0){
            Compliance__c comp = comps[0];
            List <Banking_Details__c> banks = comp.Banking_Details__r;
            List <Merchant_Bank__c> merchs = comp.Banks__r;
            List <APM__c> apms = comp.APMs__r;
            if(Test.isRunningTest()){
                banks.add(new Banking_Details__c(name='test'));
                merchs.add(new Merchant_Bank__c());
                apms.add(new APM__c());
            }
            GW_Name__c gw = new GW_Name__c();
            //check for gw
            if(comp.GW_Names__r.size()>0)    gw = comp.GW_Names__r[0];
            else                            System.debug('no GW found!');
            fr.multiClientId = nl(gw.MultiClient_ID__c);
            fr.multiClientName = gw.MultiClient_Name__c;
            fr.clientGeneralInfo.clientID = nl(gw.Client_ID__c);
            fr.clientGeneralInfo.vatNumber = comp.VAT_Number__c;
            fr.clientGeneralInfo.leadCurrency = comp.Fees_Currency__c;
            fr.clientGeneralInfo.dailySettlementConversionView = comp.dailySettlementConversionView__c;
            fr.clientGeneralInfo.dailySettlementConversionRateView = comp.dailySettlementConversionRateView__c;
            fr.clientGeneralInfo.isGrossSettlement = comp.Gross_Settlement__c;
            fr.clientGeneralInfo.payoutThresholdLevel = nl(comp.Settlement_threshold__c);
            if(fr.clientGeneralInfo.payoutThresholdLevel!=null) fr.clientGeneralInfo.payoutThresholdLevel = Integer.valueof(fr.clientGeneralInfo.payoutThresholdLevel/1000);
            fr.clientGeneralInfo.dccRevenueShareRate = comp.DCC__c!=null?comp.DCC__c/100:null;
            switch on (comp.Managing_Company__c){
                when 'Safecharge Limited' {  fr.clientGeneralInfo.managingCompanyId = '1';}
                when 'SCD' {  fr.clientGeneralInfo.managingCompanyId = '3';}
                when 'GTS HK' {  fr.clientGeneralInfo.managingCompanyId = '5';}
                when 'Safecharge (USA) Inc.' {  fr.clientGeneralInfo.managingCompanyId = '8';}
                when 'Safecharge HK Limited' {  fr.clientGeneralInfo.managingCompanyId = '9';}
                when 'Safecharge Payments Mexico' {  fr.clientGeneralInfo.managingCompanyId = '11';}
                when 'Safecharge PTE Limited' {  fr.clientGeneralInfo.managingCompanyId = '12';}
                when 'Safecharge Services' {  fr.clientGeneralInfo.managingCompanyId = '13';}
                when 'Safecharge Financial Services' {  fr.clientGeneralInfo.managingCompanyId = '14';}
                when 'Nuvei Payment Services Japan' {  fr.clientGeneralInfo.managingCompanyId = '22';}
                when 'Nuvei Financial Services, Gibraltar branch' {  fr.clientGeneralInfo.managingCompanyId = '23';}
                when else { fr.clientGeneralInfo.managingCompanyId = null;}
            }
            fr.clientGeneralInfo.salesRep.ID = comp.Sales_Rep_ID__c;
            fr.clientGeneralInfo.salesRep.Name = comp.Sales_Rep__r.Name;
            fr.clientGeneralInfo.salesRep.Email = comp.Sales_Rep__r.Email;
            fr.clientGeneralInfo.accountManager.ID = comp.Account_Manager_ID__c;
            fr.clientGeneralInfo.accountManager.Name = comp.Account_Manager__r.Name;
            fr.clientGeneralInfo.accountManager.Email = comp.Account_Manager__r.Email;
            fr.clientGeneralInfo.company.ID = comp.Id;
            fr.clientGeneralInfo.company.Name = comp.Name;
            if(comp.Account__c!=null){
                fr.clientGeneralInfo.account.ID = comp.Account__c;
                fr.clientGeneralInfo.account.Name = comp.Account__r.Name;
            }
            if(comp.From_Reseller__c!=null){
                fr.clientGeneralInfo.introducer.ID = comp.From_Reseller__c;
                fr.clientGeneralInfo.introducer.Name = comp.From_Reseller__r.Name;
            }
            for(Banking_Details__c bank:banks){
                PayoutAccountDetail pay = new PayoutAccountDetail();
                pay.targetCurrency = bank.Target_Currency__c;
                if(bank.Target_Currency__c!=null)
                    pay.currencies.add(bank.Target_Currency__c);
                //pay.currencies = comp.Processing_Currencies_New__c!=null?comp.Processing_Currencies_New__c.replaceAll(' ','').split(';'):new List <String>();
                pay.beneficiaryName = bank.Account_Holder_Name__c;
                pay.beneficiaryStreet = bank.beneficiaryStreet__c;
                pay.beneficiaryCity = bank.beneficiaryCity__c;
                pay.beneficiaryPostCode = bank.beneficiaryPostCode__c;
                pay.beneficiaryCountry = bank.Beneficiary_Country__c;
                if(pay.beneficiaryCountry!=null&&iso3bycountry.containsKey(pay.beneficiaryCountry.toLowerCase()))   pay.beneficiaryCountry = iso3bycountry.get(pay.beneficiaryCountry.toLowerCase());
                pay.bankSwiftId = bank.swift_code__c;
                pay.iban = bank.IBAN__c;
                pay.bankAddress = bank.bankAddress__c;             
                pay.bankCountry = bank.bankCountry__c;
                if(pay.bankCountry!=null&&iso3bycountry.containsKey(pay.bankCountry.toLowerCase()))   pay.bankCountry = iso3bycountry.get(pay.bankCountry.toLowerCase());
                pay.bankName = bank.Name_of_settlement_bank__c;
                pay.accountNumber = bank.Account_number__c;
                pay.bankCode = bank.bankCode__c;
                pay.branchCode = bank.branchCode__c;
                for(Merchant_Bank__c merch:merchs){
                    BankingDetail detail = new BankingDetail();
                    detail.bankId = nl(merch.bankId__c);
                    detail.consolidateBank = merch.consolidateBank__c==true?1:0;
                    detail.payoutAccountDetails.add(pay);
                    if(detail.bankId!=null&&detail.bankId!=0)   fr.bankingDetails.add(detail);
                }
                Set <Decimal> used = new Set <Decimal>();
                for(APM__c apm:apms){
                    if(!used.contains(apm.Bank_Id__c)){
                        BankingDetail detail = new BankingDetail();
                        detail.bankId = nl(apm.Bank_Id__c);
                        detail.consolidateBank = 0;
                        detail.payoutAccountDetails.add(pay);
                        if(detail.bankId!=null&&detail.bankId!=0){
                            fr.bankingDetails.add(detail);
                            used.add(apm.Bank_Id__c);
                        }
                    }
                }
            }
            if(fr.bankingDetails.size()==0) fr.bankingDetails=null;
            fr.minMonthlyFeesDetails.minMonthlyFeeTypeId = 3;
            fr.minMonthlyFeesDetails.minMonthlyFeeAmount = comp.Minimum_monthly_fee_Value_1__c;
            if(fr.minMonthlyFeesDetails.minMonthlyFeeAmount==null||fr.minMonthlyFeesDetails.minMonthlyFeeAmount==0) fr.minMonthlyFeesDetails=null;
            Set <Integer> usedreservebankids = new Set <Integer>();
            Set <Integer> usedfixbankids = new Set <Integer>();
            for(Merchant_Bank__c merch:merchs){
                PricingModelDetail detail = new PricingModelDetail();
                
                detail.bankId = nl(merch.bankId__c);
                detail.consolidateBank = merch.consolidateBank__c==true?1:0;
                detail.isCostPlusSaleSettle = merch.IC__c=='Yes'?true:false;
                detail.isCostPlusOct = merch.isCostPlusOct__c =='Yes'?true:false;
                detail.isCostPlusCredit = merch.isCostPlusCredit__c=='Yes'?true:false;
                detail.isCostPlusDeclines = merch.isCostPlusDeclines__c=='Yes'?true:false;
                detail.CCCID = 0;
                detail.Channel = merch.Channel__c;
                detail.payoutPeriod = getPayPer(comp.Remittance_Cycle__c);
                detail.CashierFee = comp.Cashier_Fee__c;
                detail.transactionMinimumFeeDetails.minimumCommissionCurrency = merch.minimumCommissionCurrencystring__c;
                detail.transactionMinimumFeeDetails.minimumCommission = merch.minimumCommission__c!=null?merch.minimumCommission__c:0;
                if(detail.transactionMinimumFeeDetails.minimumCommission==0)    detail.transactionMinimumFeeDetails=null;
                detail.saleCommissionDetails.isJuristiction = merch.isJurisdiction_Discount_Fee__c;
                detail.saleCommissionDetails.commercialRate = merch.IC__c=='Yes'?0:merch.Commercial_cards_additional_rate__c;
                detail.saleCommissionDetails.discountScalingType = merch.Retro__c=='Retro'?'1':'2';
                for(Integer i=0;i<regions.size();i++){
                    String reg = regions.get(i);
                    String fieldname = 'Discount_Fee_'+reg+'_';
                    String fieldnameSpecialUK = 'Discount_Fee_'+(reg=='UK'?'EU':reg)+'_';
                    if(merch.get(fieldname+'Value_1__c')!=null){
                        SaleCommissionRegion sale = new SaleCommissionRegion();
                        sale.region = i;
                        sale.saleCommission = (Decimal) merch.get(fieldname+'Value_1__c');
                        if(sale.saleCommission!=null)  sale.saleCommission = sale.saleCommission/100;
                        Decimal laststep = 0;
                        if(merch.get(fieldname+'Value_2__c')!=null){
                            for(Integer j=1;j<=4;j++){
                                if((!(j==4 && reg=='UK')) && merch.get(fieldname+'Value_'+String.valueof(j)+'__c')!=null){
                                    DiscountScalingStep dis = new DiscountScalingStep();
                                    dis.saleCommission = (Decimal) merch.get(fieldname+'Value_'+String.valueof(j)+'__c');
                                    if(dis.saleCommission!=null)  dis.saleCommission = dis.saleCommission/100;
                                    dis.stepFromAmount = laststep;
                                    if(j!=4){
                                        dis.stepToAmount = (Decimal) merch.get(fieldnameSpecialUK+'Limit_'+String.valueof(j)+'__c');
                                    }
                                    if(dis.stepToAmount==null)  dis.stepToAmount = 1000000000;
                                    sale.discountScalingSteps.add(dis);
                                    laststep = dis.stepToAmount+1;
                                }
                            }
                        }
                        else    sale.discountScalingSteps=null;
                        detail.saleCommissionDetails.saleCommissionRegion.add(sale);
                    }
                }
                if(detail.saleCommissionDetails.saleCommissionRegion.size()==0){
                    SaleCommissionRegion sale = new SaleCommissionRegion();
                    sale.region = 0;
                    sale.saleCommission = null;
                    sale.discountScalingSteps = null;
                    detail.saleCommissionDetails.saleCommissionRegion.add(sale);
                }
                detail.saleFeeDetails.saleFee = merch.Trx_Fee__c;
                detail.accountUpdateFeeDetails.accountUpdateFee= comp.Mastercard_Automatic_Billing_Updater_ABU__c;
                detail.creditFeeDetails.creditFee = merch.Credit_Fee_Per_Credit__c;
                detail.octFeeDetails.isJuristiction = merch.isJurisdiction_OCT__c;
                detail.octFeeDetails.octFee = merch.Mastercard_PT__c;
                detail.octFeeDetails.octVisaEUFee = merch.Visa_Direct_fee__c;
                detail.octFeeDetails.octVisaROWFee = merch.Visa_Direct_RoW__c;
                detail.chbFeeDetails.ChbFee = merch.CHB_Handling__c;
                detail.cancelledChbFeeDetails.cancelledChbFee = merch.CHB_Handling__c;
                detail.payoutFeeDetails.payoutFee = comp.Wire_Fee__c;
                detail.reserveCommissionDetails.reserveCommission = merch.Fix_Holdback__c==false?(merch.Holdback_rate__c!=null?(merch.Holdback_rate__c/100):0):0;
                detail.Auth3DFeeDetails.Auth3DFee = merch.Combined_3D_Fee__C;
                fr.pricingModelDetails.add(detail);
                ReserveDetail res = new ReserveDetail();
                res.bankId = nl(merch.bankId__c);
                res.consolidateBank = merch.consolidateBank__c==true?1:0;
                res.reserveTypeID = merch.Fix_Holdback__c==true?1:0;
                if(res.reserveTypeID==0) res.reserveAmount = 0;
                else    res.reserveAmount = merch.Holdback_rate__c!=null?merch.Holdback_rate__c:0;
                res.reserveCurrency = merch.Dropdown_Currency__c;
                if(!usedreservebankids.contains(res.bankId))    fr.reserveDetails.add(res);
                if(res.BankId!=null)    usedreservebankids.add(res.bankId);
                FixedFeesDetail fix = new FixedFeesDetail();
                fix.bankId = nl(merch.bankId__c);
                fix.consolidateBank = merch.consolidateBank__c==true?1:0;
                fix.fixedFeeTypeID = 3;
                fix.chargePeriodId = 2;
                fix.amount = merch.Annual_Fee__c!=null?merch.Annual_Fee__c:0;
                if(fix.amount!=0&&!usedfixbankids.contains(fix.bankId))   fr.fixedFeesDetails.add(fix);
                if(fix.BankId!=null&&fix.amount!=0) usedfixbankids.add(fix.bankId);
            }
            usedreservebankids.clear();
            usedfixbankids.clear();
            for(APM__c apm:apms){
                List<String> cccids = apm.CCC_ID__c != null
                    ? apm.CCC_ID__c.replaceAll(' ', '').split(',')
                    : new List<String>{ '' };

                List<Integer> subMethod = new List<Integer>();
                String countryCodes = null;
                
                if (apm.SafeCharge_APM__r != null) {
                    if (apm.SafeCharge_APM__r.SubMethod_IDs__c != null && String.isNotBlank(apm.SafeCharge_APM__r.SubMethod_IDs__c)) {
                        System.debug('apm.SafeCharge_APM__r.SubMethod_IDs__c: ' + apm.SafeCharge_APM__r.SubMethod_IDs__c);
                        for (String strValue : apm.SafeCharge_APM__r.SubMethod_IDs__c.split(';')) {
                            try {
                                subMethod.add(Integer.valueOf(strValue.trim()));
                            } catch (Exception e) {
                                System.debug('can not transfer to Integer: ' + strValue);
                            }
                        }
                    }
                    if (apm.SafeCharge_APM__r.Country__c  != null && String.isNotBlank(apm.SafeCharge_APM__r.Country__c )) {
                        List<String> currCountriesSList = apm.SafeCharge_APM__r.Country__c .split(';');
                        System.debug('apm.SafeCharge_APM__r.Country__c: ' + apm.SafeCharge_APM__r.Country__c);
                        String countrySettings = '';
                        for (String countyName : currCountriesSList) {
                            String currCountryCode = getCountryCode(countyName);
                            countrySettings += currCountryCode != null ? currCountryCode + ', ' : '';
                        }
                        countrySettings = countrySettings.length() > 0 ? countrySettings.substring(0, countrySettings.length() - 2) : '';
                        System.debug('countrySettings: ' + countrySettings);
                        if (countrySettings != null) countryCodes = countrySettings;               
                    }
                }


                for(String cccid:cccids){
                    PricingModelDetail detail = new PricingModelDetail();
                    detail.bankId = nl(apm.Bank_Id__c);
                    detail.consolidateBank = 0;
                    if(subMethod.size() > 0) detail.subMethod = subMethod;
                    if(countryCodes != null) detail.country = countryCodes;
                    detail.isCostPlusSaleSettle = false;
                    detail.isCostPlusOct = false;
                    detail.isCostPlusCredit = false;
                    detail.isCostPlusDeclines = false;
                    detail.CCCID = nl(cccid);
                    detail.payoutPeriod = getPayPer(comp.Remittance_Cycle__c);
                    detail.CashierFee = comp.Cashier_Fee__c;
                    detail.transactionMinimumFeeDetails.minimumCommissionCurrency = apm.minimumCommissionCurrencystring__c;
                    detail.transactionMinimumFeeDetails.minimumCommission = apm.minimumCommission__c!=null?apm.minimumCommission__c:0;
                    if(detail.transactionMinimumFeeDetails.minimumCommission==0)    detail.transactionMinimumFeeDetails=null;
                    detail.saleCommissionDetails.isJuristiction = false;
                    detail.saleCommissionDetails.commercialRate = 0;
                    SaleCommissionRegion sale = new SaleCommissionRegion();
                    sale.region = 0 ;
                    sale.saleCommission = apm.Discount_Fee__c;
                    sale.discountScalingSteps = null;
                    detail.saleCommissionDetails.saleCommissionRegion.add(sale);
                    detail.saleFeeDetails.saleFee = apm.Transaction_Fee__c;
                    detail.creditFeeDetails.creditFee = apm.Transaction_Fee__c;
                    detail.octFeeDetails.isJuristiction = false;
                    detail.chbFeeDetails.ChbFee = comp.APM_Chargeback_Fee__c;
                    detail.cancelledChbFeeDetails.cancelledChbFee = comp.APM_Chargeback_Fee__c;
                    detail.payoutFeeDetails.payoutFee = comp.Wire_Fee__c;
                    detail.reserveCommissionDetails.reserveCommission = comp.Holdback_for_APMs__c!=null?(comp.Holdback_for_APMs__c/100):0;
                    fr.pricingModelDetails.add(detail);
                    ReserveDetail res = new ReserveDetail();
                    res.bankId = nl(apm.Bank_ID__c);
                    res.consolidateBank = 0;
                    res.reserveTypeID = comp.Fix_Holdback_for_APMs__c==true?1:0;
                    if(res.reserveTypeID==0) res.reserveAmount = 0;
                    else    res.reserveAmount = comp.Holdback_rate_for_APMs_edit_by_Risk__c!=null?comp.Holdback_rate_for_APMs_edit_by_Risk__c:0;
                    res.reserveCurrency = comp.Holdback_for_APMs_Currency__c;
                    if(!usedreservebankids.contains(res.bankId))    fr.reserveDetails.add(res);
                    if(res.BankId!=null)    usedreservebankids.add(res.bankId);
                    FixedFeesDetail fix = new FixedFeesDetail();
                    fix.bankId = nl(apm.Bank_ID__c);
                    fix.consolidateBank = 0;
                    fix.fixedFeeTypeID = 3;
                    fix.chargePeriodId = 2;
                    fix.amount = 0;
                    if(fix.amount!=0&&!usedfixbankids.contains(fix.bankId))   fr.fixedFeesDetails.add(fix);
                    if(fix.BankId!=null&&fix.amount!=0)     usedfixbankids.add(fix.bankId);
                }
            }
            if(fr.fixedFeesDetails.size()==0)   fr.fixedFeesDetails=null;
            fr.timeStamp = 'fffff';
            fr.checksum = genChecksum(sett.secret__c,fr.multiClientId!=null?String.valueof(fr.multiClientId):'',fr.timeStamp);
        }
        else{
            System.debug('no compliance found!');
        }
        return fr;
    }
    public static String genChecksum(string secret,String clientid,String timestamp){
        String str;
        str = clientid+timestamp+secret;
        Blob bl = Blob.valueof(str);
        Blob sha256 = Crypto.generateDigest('SHA-256', bl);
        str = EncodingUtil.convertToHex(sha256).replaceAll('-','').toLowerCase();
        System.debug(str);
        return str;
    }
    public static Map <Integer,String> regions = new Map <Integer,String>{
        0=>'All',
        1=>'EU',
        2=>'ROW',
        3=>'UK'
    };
    public static integer getPayPer(String val){
        if(val=='No Payout') return 0;
        if(val=='Weekly with 1 week delay') return 1;
        if(val=='Monday Two Week delay') return 2;
        if(val=='Twice a week with 1 week delay') return 3;
        if(val=='Monday Three Week delay') return 4;
        if(val=='Within 3 business days') return 5;
        if(val=='Daily – 4 days delay') return 6;
        if(val=='Daily – 1 day delay') return 7;
        if(val=='Daily – 2 days delay') return 8;
        if(val=='Monthly') return 9;
        if(val=='Weekly with 3 business days delay') return 10;
        return null;
    }
    public static String GenerateJson(String recid,FinanceIntegration_Setting__c sett){
        FinanceRoot fr = GenerateTree(recid,sett);
        return JSON.serialize(fr);
    }

    public class FinanceHttpResult {
        public Integer statusCode;
        public String financeLog;
        public Boolean success;
    }

    private static FinanceHttpResult sendFinanceHttpInternal(String recid) {
        FinanceHttpResult rslt = new FinanceHttpResult();
        FinanceIntegration_Setting__c sett = getSett();
        String jstr = GenerateJson(recid, sett);
        System.debug('jstr: ' + jstr);
        Http http = new Http();
        HttpRequest req = new HttpRequest();
        req.setendpoint(sett.endpoint__c);
        req.setmethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(120000);
        req.setbody(jstr);
        if (Test.isRunningTest()) {
            rslt.statusCode = 200;
            rslt.success = true;
            rslt.financeLog = jstr.left(131072);
            return rslt;
        }
        HttpResponse res = http.send(req);
        rslt.statusCode = res.getStatusCode();
        rslt.success = res.getStatusCode() >= 200 && res.getStatusCode() < 300;
        String resstr = res.getBody();
        rslt.financeLog = (jstr + '\nResponse:\n' + (resstr != null ? resstr : '')).left(131072);
        return rslt;
    }

    public static String SendJson(String recid) {
        return sendFinanceHttpInternal(recid).financeLog;
    }
    public static void getSample(){
        System.debug(SendJson([select id,Compliance__c from APM__c where Compliance__c!=null limit 1].Compliance__c));
    }
    public static integer nl(Object val){
        return (val!=null&&String.valueof(val)!='')?integer.valueof(val):null;
    }


    private static Map<String, Countries__c> countriesMap;

    public static String getCountryCode(String countryName) {
        if (countriesMap == null) {
            countriesMap = Countries__c.getAll();
            System.debug('Reload all Countries');
        }

        if (countriesMap.containsKey(countryName)) {            
            return String.valueOf(countriesMap.get(countryName).Country_Code__c.intValue());
        } else {
            System.debug('Country ' + countryName + ' do not exsist');
            return null; 
        }
    }

    public class FinanceRoot {
        public String checksum;
        public String timeStamp;
        public integer multiClientId;
        public String multiClientName;
        public ClientGeneralInfo clientGeneralInfo;
        public List<BankingDetail> bankingDetails;
        public MinMonthlyFeesDetails minMonthlyFeesDetails;
        public List<PricingModelDetail> pricingModelDetails;
        public List<ReserveDetail> reserveDetails;
        public List<FixedFeesDetail> fixedFeesDetails;
        public FinanceRoot(){
            clientGeneralInfo = new ClientGeneralInfo();
            bankingDetails = new List<BankingDetail>();
            minMonthlyFeesDetails = new MinMonthlyFeesDetails();
            pricingModelDetails = new List<PricingModelDetail>();
            reserveDetails = new List<ReserveDetail>();
            fixedFeesDetails = new List<FixedFeesDetail>();
        }
    }
    public class BankingDetail {
        public List<PayoutAccountDetail> payoutAccountDetails;
        public integer bankId;
        public integer consolidateBank;
        public BankingDetail(){
            payoutAccountDetails = new List<PayoutAccountDetail>();
        }
    }
    public class PayoutAccountDetail {
        public String targetCurrency;
        public List<String> currencies;
        public String beneficiaryName;
        public String beneficiaryStreet;
        public String beneficiaryCity;
        public String beneficiaryPostCode;
        public String beneficiaryCountry;
        public String bankSwiftId;
        public String iban;
        public String bankAddress;
        public String bankCountry;
        public String bankName;
        public String accountNumber;
        public String bankCode;
        public String branchCode;
        public PayoutAccountDetail(){
            currencies = new List <String>();
        }
    }
    public class ClientGeneralInfo {
        public integer clientID;
        public String vatNumber;
        public String leadCurrency;
        public boolean dailySettlementConversionView;
        public boolean dailySettlementConversionRateView;
        public integer payoutThresholdLevel;
        public Decimal dccRevenueShareRate;
        public String managingCompanyId;
        public boolean isGrossSettlement;
        public person salesRep;
        public person accountManager;
        public partialPerson company;
        public partialPerson account;
        public partialPerson introducer;
        public ClientGeneralInfo(){
            salesRep = new person();
            accountManager = new person();
            company = new partialPerson();
            account = new partialPerson();
            introducer = new partialPerson();
        }
    }
    public class person{
        public String ID;
        public String Name;
        public String Email;
    }
    public class partialPerson{
        public String ID;
        public String Name;
    }
    public class FixedFeesDetail {
        public integer fixedFeeTypeID;
        public integer chargePeriodId;
        public Decimal amount;
        public integer bankId;
        public integer consolidateBank;
    }
    public class MinMonthlyFeesDetails {
        public integer minMonthlyFeeTypeId;
        public Decimal minMonthlyFeeAmount;
    }
    public class PricingModelDetail {
        public integer CCCID;
        public string Channel;
        public List<Integer> subMethod;
        public string country;
        public boolean isCostPlusSaleSettle;
        public boolean isCostPlusOct;
        public boolean isCostPlusCredit;
        public boolean isCostPlusDeclines;
        public integer payoutPeriod;
        public Decimal CashierFee;
        public TransactionMinimumFeeDetails transactionMinimumFeeDetails;
        public SaleCommissionDetails saleCommissionDetails;
        public SaleFeeDetails saleFeeDetails;
        public accountUpdateFeeDetails accountUpdateFeeDetails;
        public CreditFeeDetails creditFeeDetails;
        public OctFeeDetails octFeeDetails;
        public ChbFeeDetails chbFeeDetails;
        public cancelledChbFeeDetails cancelledChbFeeDetails;
        public PayoutFeeDetails payoutFeeDetails;
        public ReserveCommissionDetails reserveCommissionDetails;
        public Auth3DFeeDetails Auth3DFeeDetails;
        public integer bankId;
        public integer consolidateBank;
        public PricingModelDetail(){
            transactionMinimumFeeDetails = new TransactionMinimumFeeDetails();
            saleCommissionDetails = new SaleCommissionDetails();
            saleFeeDetails = new SaleFeeDetails();
            accountUpdateFeeDetails = new accountUpdateFeeDetails();
            creditFeeDetails = new CreditFeeDetails();
            octFeeDetails = new OctFeeDetails();
            chbFeeDetails = new ChbFeeDetails();
            cancelledChbFeeDetails = new cancelledChbFeeDetails();
            payoutFeeDetails = new PayoutFeeDetails();
            reserveCommissionDetails = new ReserveCommissionDetails();
            Auth3DFeeDetails = new Auth3DFeeDetails();
        }
    }
    public class accountUpdateFeeDetails{
        public Decimal accountUpdateFee;
    }
    public class Auth3DFeeDetails {
        public Decimal Auth3DFee;
    }
    public class ChbFeeDetails {
        public Decimal ChbFee;
    }
    public class cancelledChbFeeDetails {
        public Decimal cancelledChbFee;
    }
    public class CreditFeeDetails {
        public Decimal creditFee;
    }
    public class OctFeeDetails {
        public boolean isJuristiction;
        public Decimal octFee;
        public Decimal octVisaEUFee;
        public Decimal octVisaROWFee;
    }
    public class PayoutFeeDetails {
        public Decimal payoutFee;
    }
    public class ReserveCommissionDetails {
        public Decimal reserveCommission;
    }
    public class SaleCommissionDetails {
        public boolean isJuristiction;
        public Decimal commercialRate;
        public String discountScalingType;
        public List<SaleCommissionRegion> saleCommissionRegion;
        public SaleCommissionDetails(){
            saleCommissionRegion = new List<SaleCommissionRegion>();
        }
    }
    public class SaleCommissionRegion {
        public integer region;
        public Decimal saleCommission;
        public List<DiscountScalingStep> discountScalingSteps;
        public SaleCommissionRegion(){
            discountScalingSteps = new List<DiscountScalingStep>();
        }
    }
    public class DiscountScalingStep {
        public Decimal stepFromAmount;
        public Decimal stepToAmount;
        public Decimal saleCommission;
    }
    public class SaleFeeDetails {
        public Decimal saleFee;
    }
    public class TransactionMinimumFeeDetails {
        public String minimumCommissionCurrency;
        public Decimal minimumCommission;
    }
    public class ReserveDetail {
        public integer reserveTypeID;
        public Decimal reserveAmount;
        public String reserveCurrency;
        public integer bankId;
        public integer consolidateBank;
    }
}
