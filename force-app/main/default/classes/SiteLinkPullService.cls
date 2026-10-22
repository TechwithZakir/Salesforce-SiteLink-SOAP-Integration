/**
 * SiteLink -> Salesforce for one store per call.
 *
 * Phase 1 makes every callout (store details, units, tenants, reservations, optional rent
 * roll, plus any tenants missing for reservations). Phase 2 writes Salesforce records.
 * A failed call skips only its own part; the rest of the store still syncs.
 *
 * Conflict rule: a record with local edits still waiting to go out (Pending / Retrying)
 * is not overwritten by an inbound change. The local edit is pushed and wins.
 * Unchanged rows produce no DML at all.
 */
public without sharing class SiteLinkPullService {
    private static final Long TICKS_AT_UNIX_EPOCH = 621355968000000000L;
    private static final Integer MAX_TENANT_LOOKUPS = 20;
    private static final Set<String> LOCAL_CHANGES_WAITING = new Set<String>{
        SiteLinkPushService.STATUS_PENDING,
        SiteLinkPushService.STATUS_RETRYING
    };

    public class SiteResult {
        public String locationCode;
        public Integer units = 0;
        public Integer tenants = 0;
        public Integer reservations = 0;
        public Integer skipped = 0;
        public List<String> errors = new List<String>();

        public String summary() {
            return 'Units ' + units + ', customers ' + tenants + ', reservations ' + reservations + ' changed; ' + skipped + ' skipped' +
                (errors.isEmpty() ? '.' : '. Problems: ' + String.join(errors, ' | '));
        }
    }

    private SiteLinkApi api;

    public SiteLinkPullService(SiteLinkApi api) {
        this.api = api;
    }

    public SiteResult pullSite(Id siteId, Boolean full) {
        SiteLink_Site__c site = querySite(siteId);
        String loc = site.Location_Code__c;
        SiteLink_Setting__mdt cfg = SiteLinkConfig.settings();
        SiteResult result = new SiteResult();
        result.locationCode = loc;
        SiteLinkLogger.currentDirection = 'Inbound';
        SiteLinkLogger.currentRecordId = site.Id;

        Datetime started = System.now();
        String nextCursor = toTicks(started.addMinutes(-SiteLinkConfig.intSetting(cfg.Poll_Overlap_Minutes__c, 720)));

        // ---------------- phase 1: callouts only
        SiteLinkResponse siteInfo;
        SiteLinkResponse units;
        SiteLinkResponse tenants;
        SiteLinkResponse reservations;
        SiteLinkResponse rentRoll;
        try {
            siteInfo = api.siteInformation(loc);
        } catch (SiteLinkException e) {
            result.errors.add('Store details: ' + e.getMessage());
        }
        try {
            units = api.unitsSince(loc, full ? null : site.Unit_Cursor__c, withKeys(SiteLinkFieldMapper.inboundColumns('SiteLink_Unit__c', null), 'unitid'));
        } catch (SiteLinkException e) {
            result.errors.add('Units: ' + e.getMessage());
        }
        try {
            tenants = api.tenantsSince(loc, full ? null : site.Tenant_Cursor__c, withKeys(SiteLinkFieldMapper.inboundColumns('Account', null), 'tenantid,sfname,slname,scompany'));
        } catch (SiteLinkException e) {
            result.errors.add('Customers: ' + e.getMessage());
        }
        try {
            reservations = api.listReservations(loc, withKeys(SiteLinkFieldMapper.inboundColumns('Opportunity', null), 'waitingid,tenantid,unitid'));
        } catch (SiteLinkException e) {
            result.errors.add('Reservations: ' + e.getMessage());
        }
        if (full && cfg.Pull_Rent_Roll__c == true) {
            try {
                rentRoll = api.rentRoll(loc, Date.today(), Date.today(), withKeys(SiteLinkFieldMapper.inboundColumns('SiteLink_Unit__c', 'RentRoll'), 'unitid'));
            } catch (SiteLinkException e) {
                result.errors.add('Rent roll: ' + e.getMessage());
            }
        }
        List<Map<String, String>> tenantRows = tenants == null ? new List<Map<String, String>>() : tenants.rowsWith('TenantID');
        List<Map<String, String>> reservationRows = reservations == null ? new List<Map<String, String>>() : reservations.rowsWith('WaitingID');
        tenantRows.addAll(fetchMissingTenants(loc, tenantRows, reservationRows, result));

        // ---------------- phase 2: DML only
        SiteLinkSyncContext.suppress();
        try {
            if (siteInfo != null) {
                Map<String, String> row = siteInfo.firstRowWith('SiteID');
                if (row != null) {
                    SiteLinkFieldMapper.applyInbound(site, row, 'SiteLink_Site__c', null);
                }
            }
            if (units != null || rentRoll != null) {
                upsertUnits(site, units == null ? new List<Map<String, String>>() : units.rowsWith('UnitID'), rentRoll, result);
            }
            upsertTenants(site, tenantRows, result);
            if (reservations != null) {
                upsertReservations(site, reservationRows, result);
            }
        } finally {
            SiteLinkSyncContext.release();
        }

        site.Last_Poll_At__c = started;
        if (units != null) {
            site.Unit_Cursor__c = nextCursor;
        }
        if (tenants != null) {
            site.Tenant_Cursor__c = nextCursor;
        }
        Boolean nothingWorked = siteInfo == null && units == null && tenants == null && reservations == null;
        site.Last_Poll_Status__c = result.errors.isEmpty() ? 'Success' : (nothingWorked ? 'Error' : 'Partial');
        site.Last_Poll_Message__c = result.summary();
        if (full && result.errors.isEmpty()) {
            site.Last_Full_Sync_At__c = started;
        }
        Database.update(new List<SObject>{ site }, dmlOptions());
        SiteLinkLogger.log(
            'Inbound',
            full ? 'Reconcile store' : 'Poll store',
            loc,
            site.Id,
            result.errors.isEmpty() ? 'Success' : 'Error',
            result.summary()
        );
        return result;
    }

    /** Reservations can point at tenants that are not in Salesforce yet (e.g. created before the first poll). */
    private List<Map<String, String>> fetchMissingTenants(
        String loc,
        List<Map<String, String>> tenantRows,
        List<Map<String, String>> reservationRows,
        SiteResult result
    ) {
        List<Map<String, String>> fetched = new List<Map<String, String>>();
        Set<String> known = new Set<String>();
        for (Map<String, String> row : tenantRows) {
            known.add(key(loc, row.get('tenantid')));
        }
        Set<String> wanted = new Set<String>();
        for (Map<String, String> row : reservationRows) {
            String k = key(loc, row.get('tenantid'));
            if (k != null && !known.contains(k)) {
                wanted.add(k);
            }
        }
        if (wanted.isEmpty()) {
            return fetched;
        }
        for (Account a : [SELECT SiteLink_Tenant_Key__c FROM Account WHERE SiteLink_Tenant_Key__c IN :wanted]) {
            wanted.remove(a.SiteLink_Tenant_Key__c.toUpperCase());
        }
        Integer lookups = 0;
        for (String k : wanted) {
            if (lookups++ >= MAX_TENANT_LOOKUPS) {
                break;
            }
            try {
                Map<String, String> row = api.getTenant(loc, Integer.valueOf(k.substringAfter(':')));
                if (row != null) {
                    fetched.add(row);
                }
            } catch (SiteLinkException e) {
                result.errors.add('Customer ' + k + ': ' + e.getMessage());
            }
        }
        return fetched;
    }

    // ------------------------------------------------------------------ units

    private void upsertUnits(SiteLink_Site__c site, List<Map<String, String>> unitRows, SiteLinkResponse rentRoll, SiteResult result) {
        String loc = site.Location_Code__c;
        List<Map<String, String>> rentRows = rentRoll == null ? new List<Map<String, String>>() : rentRoll.rowsWith('UnitID');
        Set<String> keys = new Set<String>();
        for (Map<String, String> row : unitRows) {
            keys.add(key(loc, row.get('unitid')));
        }
        for (Map<String, String> row : rentRows) {
            keys.add(key(loc, row.get('unitid')));
        }
        keys.remove(null);
        Map<String, SiteLink_Unit__c> byKey = new Map<String, SiteLink_Unit__c>();
        for (SiteLink_Unit__c u : (List<SiteLink_Unit__c>) queryByKey('SiteLink_Unit__c', 'External_Key__c', keys, 'id, name, external_key__c')) {
            byKey.put(u.External_Key__c.toUpperCase(), u);
        }

        Map<String, SiteLink_Unit__c> changed = new Map<String, SiteLink_Unit__c>();
        for (Map<String, String> row : unitRows) {
            String k = key(loc, row.get('unitid'));
            if (k == null) {
                continue;
            }
            SiteLink_Unit__c unit = byKey.get(k);
            Boolean isNew = unit == null;
            if (isNew) {
                unit = new SiteLink_Unit__c(Site__c = site.Id, External_Key__c = k, Unit_Id__c = Decimal.valueOf(k.substringAfter(':')), Name = 'Unit ' + k.substringAfter(':'));
                byKey.put(k, unit);
            }
            if (SiteLinkFieldMapper.applyInbound(unit, row, 'SiteLink_Unit__c', null) || isNew) {
                changed.put(k, unit);
            }
        }
        for (Map<String, String> row : rentRows) {
            String k = key(loc, row.get('unitid'));
            SiteLink_Unit__c unit = k == null ? null : byKey.get(k);
            if (unit != null && SiteLinkFieldMapper.applyInbound(unit, row, 'SiteLink_Unit__c', 'RentRoll')) {
                changed.put(k, unit);
            }
        }
        for (SiteLink_Unit__c unit : changed.values()) {
            unit.Last_Synced__c = System.now();
        }
        result.units += save(changed.values(), 'Units', loc, result);
    }

    // ---------------------------------------------------------------- tenants

    private void upsertTenants(SiteLink_Site__c site, List<Map<String, String>> rows, SiteResult result) {
        if (rows.isEmpty()) {
            return;
        }
        String loc = site.Location_Code__c;
        Set<String> keys = new Set<String>();
        for (Map<String, String> row : rows) {
            keys.add(key(loc, row.get('tenantid')));
        }
        keys.remove(null);
        Map<String, Account> byKey = new Map<String, Account>();
        for (Account a : (List<Account>) queryByKey('Account', 'SiteLink_Tenant_Key__c', keys, accountFields())) {
            byKey.put(a.SiteLink_Tenant_Key__c.toUpperCase(), a);
        }

        Map<String, Account> changed = new Map<String, Account>();
        for (Map<String, String> row : rows) {
            String k = key(loc, row.get('tenantid'));
            if (k == null || changed.containsKey(k)) {
                continue;
            }
            Account acc = byKey.get(k);
            Boolean isNew = acc == null;
            if (!isNew && LOCAL_CHANGES_WAITING.contains(acc.SiteLink_Sync_Status__c)) {
                result.skipped++;
                continue;
            }
            if (isNew) {
                acc = new Account(
                    SiteLink_Tenant_Key__c = k,
                    SiteLink_Tenant_Id__c = Decimal.valueOf(k.substringAfter(':')),
                    SiteLink_Site__c = site.Id,
                    Name = tenantName(row, k)
                );
            }
            if (applyTenantRow(acc, row) || isNew) {
                changed.put(k, acc);
            }
        }
        result.tenants += save(changed.values(), 'Customers', loc, result);
    }

    /** Applies a SiteLink tenant row and stamps the record as in sync. Returns true if a mapped field changed. */
    public static Boolean applyTenantRow(Account acc, Map<String, String> row) {
        Boolean changed = SiteLinkFieldMapper.applyInbound(acc, row, 'Account', null);
        stampSynced(acc, 'Account');
        return changed;
    }

    private static String tenantName(Map<String, String> row, String k) {
        String name = (nz(row.get('sfname')) + ' ' + nz(row.get('slname'))).trim();
        if (String.isBlank(name)) {
            name = nz(row.get('scompany')).trim();
        }
        return String.isBlank(name) ? 'SiteLink Tenant ' + k : name;
    }

    // ----------------------------------------------------------- reservations

    private void upsertReservations(SiteLink_Site__c site, List<Map<String, String>> rows, SiteResult result) {
        if (rows.isEmpty()) {
            return;
        }
        String loc = site.Location_Code__c;
        Set<String> keys = new Set<String>();
        Set<String> tenantKeys = new Set<String>();
        Set<String> unitKeys = new Set<String>();
        for (Map<String, String> row : rows) {
            keys.add(key(loc, row.get('waitingid')));
            tenantKeys.add(key(loc, row.get('tenantid')));
            unitKeys.add(key(loc, row.get('unitid')));
        }
        keys.remove(null);
        tenantKeys.remove(null);
        unitKeys.remove(null);

        Map<String, Opportunity> byKey = new Map<String, Opportunity>();
        for (Opportunity o : (List<Opportunity>) queryByKey('Opportunity', 'SiteLink_Reservation_Key__c', keys, opportunityFields())) {
            byKey.put(o.SiteLink_Reservation_Key__c.toUpperCase(), o);
        }
        Map<String, Id> accountIds = new Map<String, Id>();
        for (Account a : [SELECT Id, SiteLink_Tenant_Key__c FROM Account WHERE SiteLink_Tenant_Key__c IN :tenantKeys]) {
            accountIds.put(a.SiteLink_Tenant_Key__c.toUpperCase(), a.Id);
        }
        Map<String, Id> unitIds = new Map<String, Id>();
        for (SiteLink_Unit__c u : [SELECT Id, External_Key__c FROM SiteLink_Unit__c WHERE External_Key__c IN :unitKeys]) {
            unitIds.put(u.External_Key__c.toUpperCase(), u.Id);
        }
        String defaultStage = SiteLinkConfig.strSetting(SiteLinkConfig.settings().Default_Opportunity_Stage__c, 'Prospecting');

        Map<String, Opportunity> changed = new Map<String, Opportunity>();
        for (Map<String, String> row : rows) {
            String k = key(loc, row.get('waitingid'));
            if (k == null || changed.containsKey(k)) {
                continue;
            }
            Opportunity opp = byKey.get(k);
            Boolean isNew = opp == null;
            if (!isNew && LOCAL_CHANGES_WAITING.contains(opp.SiteLink_Sync_Status__c)) {
                result.skipped++;
                continue;
            }
            Id accountId = accountIds.get(key(loc, row.get('tenantid')));
            if (isNew && accountId == null) {
                result.skipped++;
                SiteLinkLogger.log('Inbound', 'Reservation', loc, null, 'Skipped', 'Reservation ' + k + ' skipped: its customer is not in Salesforce yet. It will be picked up on a later poll.');
                continue;
            }
            if (isNew) {
                opp = new Opportunity(
                    SiteLink_Reservation_Key__c = k,
                    SiteLink_Reservation_Id__c = Decimal.valueOf(k.substringAfter(':')),
                    SiteLink_Site__c = site.Id,
                    Name = 'SiteLink Reservation ' + k,
                    StageName = defaultStage
                );
            }
            Boolean rowChanged = applyReservationRow(opp, row);
            if (accountId != null && opp.AccountId != accountId) {
                opp.AccountId = accountId;
                rowChanged = true;
            }
            Id unitId = unitIds.get(key(loc, row.get('unitid')));
            if (unitId != null && opp.SiteLink_Unit__c != unitId) {
                opp.SiteLink_Unit__c = unitId;
                rowChanged = true;
            }
            if (opp.CloseDate == null) {
                opp.CloseDate = opp.SiteLink_Date_Needed__c != null ? opp.SiteLink_Date_Needed__c : Date.today();
            }
            if (rowChanged || isNew) {
                stampSynced(opp, 'Opportunity'); // re-stamp: account/unit are part of the fingerprint
                changed.put(k, opp);
            }
        }
        result.reservations += save(changed.values(), 'Reservations', loc, result);
    }

    public static Boolean applyReservationRow(Opportunity opp, Map<String, String> row) {
        Boolean changed = SiteLinkFieldMapper.applyInbound(opp, row, 'Opportunity', null);
        stampSynced(opp, 'Opportunity');
        return changed;
    }

    // ---------------------------------------------------------------- helpers

    private static void stampSynced(SObject record, String objectName) {
        record.put('SiteLink_Sync_Hash__c', SiteLinkFieldMapper.fingerprint(record, objectName));
        record.put('SiteLink_Sync_Status__c', SiteLinkPushService.STATUS_SYNCED);
        record.put('SiteLink_Sync_Message__c', 'Updated from SiteLink.');
        record.put('SiteLink_Last_Synced__c', System.now());
        record.put('SiteLink_Retry_Count__c', 0);
        record.put('SiteLink_Next_Attempt__c', null);
    }

    /** Inserts new and updates existing records (partial success), logging row failures. Returns the number saved. */
    private static Integer save(List<SObject> records, String what, String loc, SiteResult result) {
        List<SObject> inserts = new List<SObject>();
        List<SObject> updates = new List<SObject>();
        for (SObject rec : records) {
            if (rec.Id == null) {
                inserts.add(rec);
            } else {
                updates.add(rec);
            }
        }
        Integer saved = 0;
        List<String> failures = new List<String>();
        for (Database.SaveResult sr : Database.insert(inserts, dmlOptions())) {
            if (sr.isSuccess()) {
                saved++;
            } else {
                failures.add(String.valueOf(sr.getErrors()[0].getMessage()));
            }
        }
        for (Database.SaveResult sr : Database.update(updates, dmlOptions())) {
            if (sr.isSuccess()) {
                saved++;
            } else {
                failures.add(String.valueOf(sr.getErrors()[0].getMessage()));
            }
        }
        if (!failures.isEmpty()) {
            result.errors.add(what + ': ' + failures.size() + ' record(s) could not be saved, e.g. ' + failures[0]);
            SiteLinkLogger.log('Inbound', 'Save ' + what, loc, null, 'Error', String.join(failures, '\n'));
        }
        return saved;
    }

    private static Database.DMLOptions dmlOptions() {
        Database.DMLOptions options = new Database.DMLOptions();
        options.allowFieldTruncation = true;
        options.optAllOrNone = false;
        return options;
    }

    private static List<SObject> queryByKey(String objectName, String keyField, Set<String> keys, String baseFields) {
        if (keys.isEmpty()) {
            return new List<SObject>();
        }
        Set<String> fields = new Set<String>(baseFields.toLowerCase().split(',\\s*'));
        for (String f : SiteLinkFieldMapper.fieldsToQuery(objectName)) {
            fields.add(f.toLowerCase());
        }
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_INBOUND, 'RentRoll')) {
            fields.add(m.Field__c.toLowerCase());
        }
        return Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM ' + objectName + ' WHERE ' + keyField + ' IN :keys',
            new Map<String, Object>{ 'keys' => keys },
            AccessLevel.SYSTEM_MODE
        );
    }

    private static String accountFields() {
        return 'id, name, sitelink_tenant_key__c, sitelink_site__c, sitelink_sync_status__c, sitelink_sync_hash__c';
    }

    private static String opportunityFields() {
        return 'id, name, stagename, closedate, accountid, sitelink_reservation_key__c, sitelink_site__c, sitelink_unit__c, ' +
            'sitelink_date_needed__c, sitelink_sync_status__c, sitelink_sync_hash__c';
    }

    private SiteLink_Site__c querySite(Id siteId) {
        Set<String> fields = new Set<String>{
            'id', 'name', 'location_code__c', 'tenant_cursor__c', 'unit_cursor__c', 'last_full_sync_at__c'
        };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('SiteLink_Site__c')) {
            fields.add(f.toLowerCase());
        }
        return (SiteLink_Site__c) Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM SiteLink_Site__c WHERE Id = :siteId',
            new Map<String, Object>{ 'siteId' => siteId },
            AccessLevel.SYSTEM_MODE
        )[0];
    }

    private static Set<String> withKeys(Set<String> columns, String keys) {
        Set<String> result = new Set<String>(columns);
        result.addAll(keys.split(','));
        return result;
    }

    /** LOCATION:ID, or null when the id is blank or not a number. */
    public static String key(String loc, String id) {
        Integer value = SiteLinkXmlParser.toInteger(id);
        return value == null ? null : SiteLinkPushService.externalKey(loc, value);
    }

    /** .NET DateTime ticks (100 ns since 0001-01-01), the form SiteLink's lngLastTimePolled takes. */
    public static String toTicks(Datetime value) {
        return String.valueOf(TICKS_AT_UNIX_EPOCH + value.getTime() * 10000L);
    }

    private static String nz(String value) {
        return value == null ? '' : value;
    }
}
