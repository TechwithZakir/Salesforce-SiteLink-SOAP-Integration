/**
 * Applies SiteLink_Field_Map__mdt in both directions and fingerprints records.
 *
 * Loop prevention rests on the fingerprint (SiteLink_Sync_Hash__c): a SHA-256 of the
 * outbound-mapped Salesforce values at the last successful sync, in either direction.
 * A record is only pushed when its current fingerprint differs, and inbound writes
 * store the new fingerprint, so data that just arrived from SiteLink is never sent back.
 */
public inherited sharing class SiteLinkFieldMapper {
    private static Map<String, Map<String, Schema.DescribeFieldResult>> describeCache = new Map<String, Map<String, Schema.DescribeFieldResult>>();

    /** Extra non-mapped fields that also count as a change, per object. */
    public static final Map<String, List<String>> HASH_EXTRA_FIELDS = new Map<String, List<String>>{
        'Account' => new List<String>{ 'SiteLink_Site__c' },
        'Opportunity' => new List<String>{ 'SiteLink_Site__c', 'SiteLink_Unit__c', 'AccountId' }
    };

    // ---------------------------------------------------------------- outbound

    /** Mapped values for a SiteLink request, keyed by parameter name. */
    public static Map<String, Object> toParams(SObject record, String objectName) {
        Map<String, Object> params = new Map<String, Object>();
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_OUTBOUND, null)) {
            Object value = record.get(m.Field__c);
            if (isBlank(value) && String.isNotBlank(m.Default_Value__c)) {
                value = m.Default_Value__c;
            }
            value = translate(value, m.Value_Map__c, true);
            params.put(m.Outbound_Param__c, value == null ? '' : value);
        }
        return params;
    }

    /** Field API names needed to build outbound params and the fingerprint. */
    public static Set<String> fieldsToQuery(String objectName) {
        Set<String> fields = new Set<String>();
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_OUTBOUND, null)) {
            fields.add(m.Field__c);
        }
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_INBOUND, null)) {
            fields.add(m.Field__c);
        }
        if (HASH_EXTRA_FIELDS.containsKey(objectName)) {
            fields.addAll(HASH_EXTRA_FIELDS.get(objectName));
        }
        return fields;
    }

    public static String fingerprint(SObject record, String objectName) {
        List<String> parts = new List<String>();
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_OUTBOUND, null)) {
            parts.add(m.Field__c + '=' + normalize(safeGet(record, m.Field__c)));
        }
        if (HASH_EXTRA_FIELDS.containsKey(objectName)) {
            for (String f : HASH_EXTRA_FIELDS.get(objectName)) {
                parts.add(f + '=' + normalize(safeGet(record, f)));
            }
        }
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(String.join(parts, '\n')));
        return EncodingUtil.convertToHex(digest);
    }

    // ----------------------------------------------------------------- inbound

    /** Lower-case response columns needed for an object's inbound mappings. */
    public static Set<String> inboundColumns(String objectName, String sourceOperation) {
        Set<String> columns = new Set<String>();
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_INBOUND, sourceOperation)) {
            columns.add(m.Inbound_Column__c.toLowerCase());
        }
        return columns;
    }

    /**
     * Copies mapped columns from a SiteLink row onto the record. Columns absent from the
     * row are left alone (a missing column never blanks a Salesforce field).
     * @return true if any field value changed
     */
    public static Boolean applyInbound(SObject record, Map<String, String> row, String objectName, String sourceOperation) {
        Boolean changed = false;
        Map<String, Schema.DescribeFieldResult> fields = describe(objectName);
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_INBOUND, sourceOperation)) {
            String column = m.Inbound_Column__c.toLowerCase();
            if (!row.containsKey(column)) {
                continue;
            }
            Schema.DescribeFieldResult field = fields.get(m.Field__c.toLowerCase());
            // Not isUpdateable(): that reflects the running user's field security, and the
            // integration writes on SiteLink's behalf. Only skip fields nobody can write.
            if (field == null || field.isCalculated() || field.isAutoNumber()) {
                continue;
            }
            String raw = (String) translate(row.get(column), m.Value_Map__c, false);
            if (String.isBlank(raw) && String.isNotBlank(m.Default_Value__c)) {
                raw = m.Default_Value__c;
            }
            Object value = convert(raw, field);
            if (value == null && field.getType() == Schema.DisplayType.BOOLEAN) {
                value = false;
            }
            if (!sameValue(safeGet(record, m.Field__c), value)) {
                record.put(m.Field__c, value);
                changed = true;
            }
        }
        return changed;
    }

    @TestVisible
    private static Object convert(String raw, Schema.DescribeFieldResult field) {
        if (String.isBlank(raw)) {
            return null;
        }
        String value = raw.trim();
        switch on field.getType() {
            when BOOLEAN {
                return value.equalsIgnoreCase('true') || value == '1' || value.equalsIgnoreCase('yes');
            }
            when INTEGER {
                return Decimal.valueOf(value).intValue();
            }
            when DOUBLE, CURRENCY, PERCENT {
                return Decimal.valueOf(value);
            }
            when DATE {
                return Date.valueOf(value.left(10));
            }
            when DATETIME {
                return parseDatetime(value);
            }
            when else {
                return raw;
            }
        }
    }

    /** SiteLink sends ISO 8601 (with or without offset); without one it is treated as GMT. */
    public static Datetime parseDatetime(String value) {
        String v = value.trim();
        if (v.length() == 10) {
            v += 'T00:00:00';
        }
        if (!v.endsWith('Z') && !v.substring(10).contains('+') && !v.substring(10).contains('-')) {
            v += 'Z';
        }
        return (Datetime) JSON.deserialize('"' + v + '"', Datetime.class);
    }

    // ----------------------------------------------------------------- helpers

    /** Value_Map__c lines "SalesforceValue=SiteLinkValue". Unmapped values pass through. */
    @TestVisible
    private static Object translate(Object value, String valueMap, Boolean outbound) {
        if (String.isBlank(valueMap) || value == null) {
            return value;
        }
        String key = String.valueOf(value);
        for (String line : valueMap.split('\n')) {
            if (!line.contains('=')) {
                continue;
            }
            String sfValue = line.substringBefore('=').trim();
            String slValue = line.substringAfter('=').trim();
            if (outbound && sfValue.equalsIgnoreCase(key)) {
                return slValue;
            }
            if (!outbound && slValue.equalsIgnoreCase(key)) {
                return sfValue;
            }
        }
        return value;
    }

    public static Map<String, Schema.DescribeFieldResult> describe(String objectName) {
        String key = objectName.toLowerCase();
        if (!describeCache.containsKey(key)) {
            Map<String, Schema.DescribeFieldResult> result = new Map<String, Schema.DescribeFieldResult>();
            Schema.DescribeSObjectResult d = Schema.describeSObjects(new List<String>{ objectName })[0];
            for (Schema.SObjectField f : d.fields.getMap().values()) {
                Schema.DescribeFieldResult fd = f.getDescribe();
                result.put(fd.getName().toLowerCase(), fd);
            }
            describeCache.put(key, result);
        }
        return describeCache.get(key);
    }

    private static Object safeGet(SObject record, String field) {
        try {
            return record.get(field);
        } catch (SObjectException e) {
            return null; // field not queried / not populated on a new record
        }
    }

    private static Boolean isBlank(Object value) {
        return value == null || (value instanceof String && String.isBlank((String) value));
    }

    @TestVisible
    private static Boolean sameValue(Object a, Object b) {
        if (isBlank(a) && isBlank(b)) {
            return true;
        }
        if (isBlank(a) || isBlank(b)) {
            return false;
        }
        if ((a instanceof Decimal || a instanceof Integer) && (b instanceof Decimal || b instanceof Integer)) {
            return Decimal.valueOf(String.valueOf(a)) == Decimal.valueOf(String.valueOf(b));
        }
        return normalize(a) == normalize(b);
    }

    private static String normalize(Object value) {
        if (isBlank(value)) {
            return '';
        }
        if (value instanceof Decimal) {
            return ((Decimal) value).stripTrailingZeros().toPlainString();
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).formatGmt('yyyy-MM-dd\'T\'HH:mm:ss');
        }
        return String.valueOf(value).trim();
    }
}
