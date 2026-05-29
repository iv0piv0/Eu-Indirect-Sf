public class MerchantValidator {

    // בדיקת שדה טקסט עם חיתוך תווים לא חוקיים
    public static String sanitizeText(String value, Integer maxLength) {
        if (String.isBlank(value)) {
            return null; // אם הערך ריק, מחזירים null כדי לא להוסיף לשדה האופציונלי
        }
    
        // הסרת תווים לא חוקיים והסרת רווחים מיותרים
        String cleanValue = value.trim().replaceAll('[\\^<>%]', '');
    
        // החזרת הערך תוך הגבלת האורך למקסימום המותר
        return cleanValue.length() > maxLength ? cleanValue.substring(0, maxLength) : cleanValue;
    }

    // מחזיר רק קוד מדינה חוקי (2 אותיות)
    public static String validateCountryCode(String country) {
        return (String.isBlank(country) || country.length() != 2) ? null : country.toUpperCase();
    }

    // מחזיר רק מספר MCC חוקי (4 ספרות)
    public static String validateMCC(String mcc) {
        if (String.isBlank(mcc)) return null;
        Pattern pattern = Pattern.compile('\\d{4}');
        Matcher matcher = pattern.matcher(mcc);
        return matcher.matches() ? mcc : null;
    }

    // מסיר תווים לא חוקיים ממספר טלפון (השארת ספרות בלבד)
    public static String sanitizePhone(String phone) {
        return String.isBlank(phone) ? null : phone.replaceAll('[^0-9]', '');
    }

    // מחזיר תאריך בפורמט API
    public static String formatDate(DateTime dt) {
        return dt == null ? null : dt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS\'Z\'');
    }

    // מחזיר רק תפקידים חוקיים למשתמשים
    public static List<String> validateRoles(List<String> roles) {
        if (roles == null || roles.isEmpty()) return null;
        List<String> validRoles = new List<String>{ 'tempUser', 'management', 'commercial' };
        List<String> filteredRoles = new List<String>();

        for (String role : roles) {
            if (validRoles.contains(role)) {
                filteredRoles.add(role);
            }
        }
        return filteredRoles.isEmpty() ? null : filteredRoles;
    }

    public static String getStateCode(String country, String state) {
        if (String.isBlank(country)) return null; // אם אין מדינה, לא מחזירים כלום
    
        // אם המדינה היא אירופאית, מחזירים את קוד המדינה ISO_2__c במקום state
        if (isEuropeanCountry(country)) {
            Countries__c countryRecord = [SELECT ISO_2__c FROM Countries__c WHERE Name = :country LIMIT 1];
            return (countryRecord != null) ? countryRecord.ISO_2__c : null;
        }
    
        // אם המדינה היא ארה"ב, קנדה או בריטניה - שולפים את ה-Code__c מה-States__c
        Set<String> specialCountries = new Set<String>{'United States', 'Canada', 'United Kingdom', 'Brazil', 'Austria', 'Germany', 'Hong Kong', 'Singapore', 'Italy'};
        if (specialCountries.contains(country)) {
            List<States__c> stateRecords = [SELECT Code__c FROM States__c WHERE Name = :state LIMIT 1];
            return (!stateRecords.isEmpty()) ? stateRecords[0].Code__c : null;
        }
    
        // אם זו מדינה אחרת - שולפים את ISO_2__c מתוך Countries__c
        List<Countries__c> countryRecords = [SELECT ISO_2__c FROM Countries__c WHERE Name = :country LIMIT 1];
        return (!countryRecords.isEmpty()) ? countryRecords[0].ISO_2__c : null;
    }
    

    public static Boolean isEuropeanCountry(String country) {
        Set<String> europeanCountries = new Set<String>{
            'AT', 'BE', 'BG', 'CY', 'CZ', 'DE', 'DK', 'EE', 'ES', 'FI', 'FR', 'GR', 
            'HR', 'HU', 'IE', 'IT', 'LT', 'LU', 'LV', 'MT', 'NL', 'PL', 'PT', 'RO', 
            'SE', 'SI', 'SK', 'GB' // GB = United Kingdom
        };
        return europeanCountries.contains(country);
    }
    

    public static Boolean isPaymentProcessingRequired(Case cas) {
        // אם יש Location__c או Company_Profile__c, אז חייבים לשלוח paymentProcessing
        return cas.Location__c != null || cas.Company_Profile__c != null;
    }

    public static String getCountryCode(String countryName) {
        List<Countries__c> countryRecords = [
            SELECT ISO_2__c 
            FROM Countries__c 
            WHERE Name = :countryName 
            LIMIT 1
        ];
        return (!countryRecords.isEmpty()) ? countryRecords[0].ISO_2__c : null;

    }

    public static String genPassword(Integer len) {
        final String upchars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
        final String lowchars = 'abcdefghijklmnopqrstuvwxyz';
        final String numchars = '0123456789';
        String randStr = '';
        Integer idx = Math.mod(
          Math.abs(Crypto.getRandomInteger()),
          upchars.length()
        );
        randStr += upchars.substring(idx, idx + 1);
        idx = Math.mod(Math.abs(Crypto.getRandomInteger()), lowchars.length());
        randStr += lowchars.substring(idx, idx + 1);
        idx = Math.mod(Math.abs(Crypto.getRandomInteger()), numchars.length());
        randStr += numchars.substring(idx, idx + 1);
        while (randStr.length() < len) {
          idx = Math.mod(
            Math.abs(Crypto.getRandomInteger()),
            (upchars + lowchars + numchars).length()
          );
          randStr += (upchars + lowchars + numchars).substring(idx, idx + 1);
        }
        return randStr;
      }

}