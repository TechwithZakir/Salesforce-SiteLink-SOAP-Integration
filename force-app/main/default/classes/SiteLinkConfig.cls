/**
 * Reads SiteLink_Setting__mdt (record "Default") and SiteLink_Field_Map__mdt.
 * Tests inject in-memory records through the @TestVisible overrides.
 */
public inherited sharing class SiteLinkConfig {
    public static final String DIRECTION_OUTBOUND = 'Outbound';
    public static final String DIRECTION_INBOUND = 'Inbound';
    public static final String DIRECTION_BOTH = 'Both';

    @TestVisible
    private static SiteLink_Setting__mdt settingsOverride;
    @TestVisible
    private static List<SiteLink_Field_Map__mdt> mappingsOverride;

    private static SiteLink_Setting__mdt cachedSettings;
    private static List<SiteLink_Field_Map__mdt> cachedMappings;

    public static SiteLink_Setting__mdt settings() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        if (cachedSettings == null) {
            cachedSettings = SiteLink_Setting__mdt.getInstance('Default');
        }
        if (cachedSettings == null) {
            throw new SiteLinkException(
                'SiteLink is not set up yet. Ask your Salesforce admin to create the "Default" SiteLink Setting.'
            );
        }
        return cachedSettings;
    }

    /** True when settings exist and the master switch is on. Never throws, so it is safe in triggers. */
    public static Boolean isActive() {
        try {
            return settings().Active__c == true;
        } catch (Exception e) {
            return false;
        }
    }

    public static Boolean isAutoPush() {
        return isActive() && settings().Auto_Push__c == true;
    }

    public static Integer intSetting(Decimal value, Integer fallback) {
        return value == null ? fallback : value.intValue();
    }

    public static String strSetting(String value, String fallback) {
        return String.isBlank(value) ? fallback : value;
    }

    public static List<SiteLink_Field_Map__mdt> allMappings() {
        if (mappingsOverride != null) {
            return mappingsOverride;
        }
        if (cachedMappings == null) {
            cachedMappings = SiteLink_Field_Map__mdt.getAll().values();
        }
        return cachedMappings;
    }

    /**
     * Active mappings for an object, in one direction, sorted by field for stable hashing.
     * Inbound mappings are filtered by source operation: null matches mappings with a blank
     * Source_Operation__c (the object's default list call).
     */
    public static List<SiteLink_Field_Map__mdt> mappings(String objectName, String direction, String sourceOperation) {
        Map<String, SiteLink_Field_Map__mdt> byKey = new Map<String, SiteLink_Field_Map__mdt>();
        for (SiteLink_Field_Map__mdt m : allMappings()) {
            if (m.Active__c != true || m.Object__c == null || !m.Object__c.equalsIgnoreCase(objectName)) {
                continue;
            }
            String dir = String.isBlank(m.Direction__c) ? DIRECTION_BOTH : m.Direction__c;
            Boolean include = false;
            if (direction == DIRECTION_OUTBOUND) {
                include = dir != DIRECTION_INBOUND && String.isNotBlank(m.Outbound_Param__c);
            } else if (direction == DIRECTION_INBOUND) {
                Boolean sourceMatches = String.isBlank(sourceOperation)
                    ? String.isBlank(m.Source_Operation__c)
                    : sourceOperation.equalsIgnoreCase(m.Source_Operation__c);
                include = dir != DIRECTION_OUTBOUND && String.isNotBlank(m.Inbound_Column__c) && sourceMatches;
            }
            if (include) {
                byKey.put(m.Field__c.toLowerCase() + '|' + (direction == DIRECTION_OUTBOUND ? m.Outbound_Param__c : m.Inbound_Column__c), m);
            }
        }
        List<String> keys = new List<String>(byKey.keySet());
        keys.sort();
        List<SiteLink_Field_Map__mdt> result = new List<SiteLink_Field_Map__mdt>();
        for (String k : keys) {
            result.add(byKey.get(k));
        }
        return result;
    }

    @TestVisible
    private static void resetCache() {
        cachedSettings = null;
        cachedMappings = null;
    }
}
