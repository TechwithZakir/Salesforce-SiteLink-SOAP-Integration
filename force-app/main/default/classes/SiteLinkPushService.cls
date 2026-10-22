/**
 * Salesforce -> SiteLink. Pushes Opportunities (tenant + reservation) and Accounts (tenant).
 *
 * push() only makes callouts and collects field updates; commitOutcome() does all DML
 * afterwards, so callouts never follow uncommitted work in the same transaction.
 *
 * Runs without sharing: it is the integration acting on records a user already saved
 * or explicitly pushed (the controller checks the user's access first).
 */
public without sharing class SiteLinkPushService {
    public static final String STATUS_PENDING = 'Pending';
    public static final String STATUS_SYNCED = 'Synced';
    public static final String STATUS_RETRYING = 'Retrying';
    public static final String STATUS_FAILED = 'Failed';

    public class Result {
        public Id recordId;
        public Boolean success = false;
        public String status;
        public String message;
        public Integer tenantId;
        public Integer reservationId;
    }

    public class Outcome {
        public Map<Id, SObject> updates = new Map<Id, SObject>();
        public Map<Id, Result> results = new Map<Id, Result>();
        public List<String> failures = new List<String>();
    }

    private SiteLinkApi api;
    private Boolean force;
    private Map<Id, Account> accounts = new Map<Id, Account>();
    private Map<Id, Integer> resolvedTenants = new Map<Id, Integer>();
    private Map<Id, SiteLinkException> accountErrors = new Map<Id, SiteLinkException>();

    /**
     * @param force push even when the fingerprint says nothing changed (the Push button)
     */
    public SiteLinkPushService(SiteLinkApi api, Boolean force) {
        this.api = api;
        this.force = force == true;
    }

    public Outcome push(Set<Id> opportunityIds, Set<Id> accountIds) {
        Outcome out = new Outcome();
        SiteLinkLogger.currentDirection = 'Outbound';
        List<Opportunity> opportunities = opportunityIds == null || opportunityIds.isEmpty()
            ? new List<Opportunity>()
            : queryOpportunities(opportunityIds);

        Set<Id> allAccountIds = accountIds == null ? new Set<Id>() : new Set<Id>(accountIds);
        for (Opportunity opp : opportunities) {
            if (opp.AccountId != null) {
                allAccountIds.add(opp.AccountId);
            }
        }
        if (!allAccountIds.isEmpty()) {
            accounts = new Map<Id, Account>(queryAccounts(allAccountIds));
        }

        for (Opportunity opp : opportunities) {
            pushOpportunity(opp, out);
        }
        if (accountIds != null) {
            for (Id accountId : accountIds) {
                if (!out.results.containsKey(accountId) && accounts.containsKey(accountId)) {
                    pushAccount(accounts.get(accountId), out);
                }
            }
        }
        SiteLinkLogger.currentRecordId = null;
        return out;
    }

    // ---------------------------------------------------------------- opportunity

    private void pushOpportunity(Opportunity opp, Outcome out) {
        String locationCode = opp.SiteLink_Site__r?.Location_Code__c;
        try {
            if (String.isBlank(locationCode)) {
                throw new SiteLinkException('Choose a SiteLink store on this opportunity before sending it to SiteLink.');
            }
            Account acc = opp.AccountId == null ? null : accounts.get(opp.AccountId);
            if (acc == null) {
                throw new SiteLinkException('Add the customer (Account) to this opportunity before sending it to SiteLink.');
            }
            Integer tenantId = ensureTenant(acc, locationCode, opp.SiteLink_Site__c, out);

            SiteLinkLogger.currentRecordId = opp.Id;
            if (opp.SiteLink_Unit__c == null || opp.SiteLink_Unit__r.Unit_Id__c == null) {
                throw new SiteLinkException('The customer was sent. Choose a SiteLink unit on this opportunity to send the reservation.');
            }
            if (opp.SiteLink_Unit__r.Site__c != null && opp.SiteLink_Unit__r.Site__c != opp.SiteLink_Site__c) {
                throw new SiteLinkException('The chosen unit belongs to a different store than this opportunity. Pick a unit at the same store.');
            }

            Map<String, Object> params = SiteLinkFieldMapper.toParams(opp, 'Opportunity');
            params.put('sTenantID', String.valueOf(tenantId));
            params.put('sUnitID', String.valueOf(opp.SiteLink_Unit__r.Unit_Id__c.intValue()));
            String fingerprint = SiteLinkFieldMapper.fingerprint(opp, 'Opportunity');

            Integer waitingId = opp.SiteLink_Reservation_Id__c?.intValue();
            if (waitingId == null) {
                applyReservationDefaults(params);
                waitingId = api.createReservation(locationCode, params);
            } else if (force || fingerprint != opp.SiteLink_Sync_Hash__c) {
                api.updateReservation(locationCode, waitingId, params);
            }

            SObject row = rowFor(out, opp.Id);
            row.put('SiteLink_Reservation_Id__c', waitingId);
            row.put('SiteLink_Reservation_Key__c', externalKey(locationCode, waitingId));
            row.put('SiteLink_Sync_Hash__c', fingerprint);
            Result r = markSuccess(opp.Id, out);
            r.tenantId = tenantId;
            r.reservationId = waitingId;
        } catch (SiteLinkException e) {
            markFailure(opp, locationCode, e, out);
        } catch (Exception e) {
            markFailure(opp, locationCode, unexpected(e), out);
        }
    }

    /** Values SiteLink needs on ReservationNewWithSource_v5 that Salesforce doesn't map. */
    public static void applyReservationDefaults(Map<String, Object> params) {
        SiteLink_Setting__mdt cfg = SiteLinkConfig.settings();
        Object needed = params.get('dNeeded');
        Date neededDate = needed instanceof Date ? (Date) needed : Date.today();
        params.put('dNeeded', neededDate);
        params.put('iSource', SiteLinkConfig.intSetting(cfg.Reservation_Source_Id__c, 5));
        params.put('sSource', SiteLinkConfig.strSetting(cfg.Reservation_Source_Name__c, 'Salesforce'));
        params.put('QTRentalTypeID', SiteLinkConfig.intSetting(cfg.Reservation_Rental_Type_Id__c, 2));
        params.put('iInquiryType', SiteLinkConfig.intSetting(cfg.Reservation_Inquiry_Type__c, 0));
        params.put('dExpires', neededDate.addDays(SiteLinkConfig.intSetting(cfg.Reservation_Expiry_Days__c, 7)));
        params.put('dFollowUp', Date.today().addDays(1));
    }

    // ----------------------------------------------------------------- account

    private void pushAccount(Account acc, Outcome out) {
        String locationCode = acc.SiteLink_Site__r?.Location_Code__c;
        if (String.isBlank(locationCode)) {
            markFailure(acc, null, new SiteLinkException('Choose a SiteLink store on this customer before sending it to SiteLink.'), out);
            return;
        }
        try {
            ensureTenant(acc, locationCode, acc.SiteLink_Site__c, out);
        } catch (SiteLinkException e) {
            // already recorded on the account by ensureTenant
        }
    }

    /** Finds, creates or updates the SiteLink tenant for an account. Returns the TenantID. */
    private Integer ensureTenant(Account acc, String locationCode, Id siteId, Outcome out) {
        if (resolvedTenants.containsKey(acc.Id)) {
            return resolvedTenants.get(acc.Id);
        }
        if (accountErrors.containsKey(acc.Id)) {
            throw accountErrors.get(acc.Id);
        }
        SiteLinkLogger.currentRecordId = acc.Id;
        try {
            String accountLocation = acc.SiteLink_Site__r?.Location_Code__c;
            Integer tenantId = acc.SiteLink_Tenant_Id__c?.intValue();
            if (tenantId != null && accountLocation != null && !accountLocation.equalsIgnoreCase(locationCode)) {
                throw new SiteLinkException(
                    'This customer is already a SiteLink tenant at store ' + accountLocation +
                    '. SiteLink keeps a separate tenant per store, so use a separate customer account for store ' + locationCode + '.'
                );
            }
            if (acc.SiteLink_Site__c == null) {
                acc.SiteLink_Site__c = siteId;
            }
            Map<String, Object> params = SiteLinkFieldMapper.toParams(acc, 'Account');
            String fingerprint = SiteLinkFieldMapper.fingerprint(acc, 'Account');

            if (tenantId == null) {
                if (params.containsKey('sLName') && String.isBlank(String.valueOf(params.get('sLName')))) {
                    throw new SiteLinkException('Enter the customer\'s last name before sending them to SiteLink.');
                }
                tenantId = findExistingTenant(locationCode, params);
                if (tenantId == null) {
                    tenantId = api.createTenant(locationCode, params);
                } else {
                    api.updateTenant(locationCode, tenantId, params);
                }
            } else if (force || fingerprint != acc.SiteLink_Sync_Hash__c) {
                api.updateTenant(locationCode, tenantId, params);
            }

            SObject row = rowFor(out, acc.Id);
            row.put('SiteLink_Tenant_Id__c', tenantId);
            row.put('SiteLink_Tenant_Key__c', externalKey(locationCode, tenantId));
            row.put('SiteLink_Site__c', acc.SiteLink_Site__c);
            row.put('SiteLink_Sync_Hash__c', fingerprint);
            markSuccess(acc.Id, out).tenantId = tenantId;
            resolvedTenants.put(acc.Id, tenantId);
            return tenantId;
        } catch (Exception e) {
            SiteLinkException error = e instanceof SiteLinkException ? (SiteLinkException) e : unexpected(e);
            accountErrors.put(acc.Id, error);
            markFailure(acc, locationCode, error, out);
            throw error;
        }
    }

    /**
     * Duplicate guard: before creating a tenant, look for one at the store with the same
     * email (and last name when SiteLink returns it). One match is linked; several matches
     * stop the push so staff can pick the right one.
     */
    private Integer findExistingTenant(String locationCode, Map<String, Object> params) {
        if (SiteLinkConfig.settings().Match_Existing_Tenants__c != true) {
            return null;
        }
        String email = params.containsKey('sEmail') ? String.valueOf(params.get('sEmail')) : null;
        if (String.isBlank(email)) {
            return null;
        }
        String lastName = params.containsKey('sLName') ? String.valueOf(params.get('sLName')) : '';
        List<Integer> matches = new List<Integer>();
        for (Map<String, String> row : api.findTenants(locationCode, '', lastName, email, '')) {
            String rowEmail = row.get('semail');
            String rowLast = row.get('slname');
            Boolean emailOk = rowEmail == null || rowEmail.trim().equalsIgnoreCase(email.trim());
            Boolean lastOk = rowLast == null || String.isBlank(lastName) || rowLast.trim().equalsIgnoreCase(lastName.trim());
            Integer id = SiteLinkXmlParser.toInteger(row.get('tenantid'));
            if (emailOk && lastOk && id != null && !matches.contains(id)) {
                matches.add(id);
            }
        }
        if (matches.size() > 1) {
            throw new SiteLinkException(
                'SiteLink already has ' + matches.size() + ' customers at store ' + locationCode + ' with this email (tenant IDs ' +
                String.join(matches, ', ') + '). Enter the right one in SiteLink Tenant ID, then push again.'
            );
        }
        return matches.isEmpty() ? null : matches[0];
    }

    // ----------------------------------------------------------- status writes

    private Result markSuccess(Id recordId, Outcome out) {
        SObject row = rowFor(out, recordId);
        row.put('SiteLink_Sync_Status__c', STATUS_SYNCED);
        row.put('SiteLink_Sync_Message__c', 'In sync with SiteLink.');
        row.put('SiteLink_Last_Synced__c', System.now());
        row.put('SiteLink_Retry_Count__c', 0);
        row.put('SiteLink_Next_Attempt__c', null);
        Result r = resultFor(out, recordId);
        r.success = true;
        r.status = STATUS_SYNCED;
        r.message = 'In sync with SiteLink.';
        return r;
    }

    private void markFailure(SObject record, String locationCode, SiteLinkException e, Outcome out) {
        applyFailure(record, rowFor(out, record.Id), e);
        Result r = resultFor(out, record.Id);
        r.success = false;
        r.status = (String) out.updates.get(record.Id).get('SiteLink_Sync_Status__c');
        r.message = e.getMessage();
        if (r.status == STATUS_FAILED) {
            out.failures.add(describe(record) + ': ' + e.getMessage());
        }
        SiteLinkLogger.log(
            'Outbound',
            'Push ' + record.getSObjectType(),
            locationCode,
            record.Id,
            r.status,
            e.getMessage() + (e.technicalDetail == null ? '' : '\n' + e.technicalDetail)
        );
    }

    /** Retryable errors back off exponentially until Max_Retries__c, then become Failed. */
    public static void applyFailure(SObject source, SObject row, SiteLinkException e) {
        SiteLink_Setting__mdt cfg = SiteLinkConfig.settings();
        Decimal used = (Decimal) source.get('SiteLink_Retry_Count__c');
        Integer retries = used == null ? 0 : used.intValue();
        Integer maxRetries = SiteLinkConfig.intSetting(cfg.Max_Retries__c, 5);
        if (e.isRetryable && retries < maxRetries) {
            Integer waitMinutes = SiteLinkConfig.intSetting(cfg.Retry_Base_Minutes__c, 5) * Math.pow(2, retries).intValue();
            row.put('SiteLink_Sync_Status__c', STATUS_RETRYING);
            row.put('SiteLink_Retry_Count__c', retries + 1);
            row.put('SiteLink_Next_Attempt__c', System.now().addMinutes(waitMinutes));
        } else {
            row.put('SiteLink_Sync_Status__c', STATUS_FAILED);
            row.put('SiteLink_Next_Attempt__c', null);
        }
        row.put('SiteLink_Sync_Message__c', SiteLinkLogger.truncate(e.getMessage(), 255));
    }

    /** Writes collected updates with triggers suppressed, then flushes logs and sends alerts. */
    public static void commitOutcome(Outcome out) {
        List<SObject> rows = new List<SObject>();
        for (SObject row : out.updates.values()) {
            if (row.getSObjectType() == Account.SObjectType) {
                rows.add(row);
            }
        }
        for (SObject row : out.updates.values()) {
            if (row.getSObjectType() != Account.SObjectType) {
                rows.add(row);
            }
        }
        SiteLinkSyncContext.suppress();
        try {
            List<Database.SaveResult> saves = Database.update(rows, false);
            for (Integer i = 0; i < saves.size(); i++) {
                if (!saves[i].isSuccess()) {
                    SiteLinkLogger.log('Outbound', 'Save result', null, rows[i].Id, 'Error', String.valueOf(saves[i].getErrors()));
                }
            }
        } finally {
            SiteLinkSyncContext.release();
        }
        SiteLinkLogger.flush();
        if (!out.failures.isEmpty()) {
            SiteLinkAlerts.send('SiteLink sync failed for ' + out.failures.size() + ' record(s)', out.failures);
        }
    }

    // ----------------------------------------------------------------- helpers

    public static String externalKey(String locationCode, Integer id) {
        return locationCode.trim().toUpperCase() + ':' + id;
    }

    private static SObject rowFor(Outcome out, Id recordId) {
        if (!out.updates.containsKey(recordId)) {
            out.updates.put(recordId, recordId.getSObjectType().newSObject(recordId));
        }
        return out.updates.get(recordId);
    }

    private static Result resultFor(Outcome out, Id recordId) {
        if (!out.results.containsKey(recordId)) {
            Result r = new Result();
            r.recordId = recordId;
            out.results.put(recordId, r);
        }
        return out.results.get(recordId);
    }

    private static SiteLinkException unexpected(Exception e) {
        return new SiteLinkException('Something unexpected went wrong while sending to SiteLink. Salesforce will try again automatically.')
            .retryable(true)
            .detail(e.getTypeName() + ': ' + e.getMessage() + '\n' + e.getStackTraceString());
    }

    private static String describe(SObject record) {
        Object name = record.get('Name');
        return record.getSObjectType() + ' ' + (name == null ? '' : String.valueOf(name) + ' ') + '(' + record.Id + ')';
    }

    private static List<Opportunity> queryOpportunities(Set<Id> ids) {
        Set<String> fields = new Set<String>{
            'id', 'name', 'accountid', 'sitelink_site__c', 'sitelink_site__r.location_code__c', 'sitelink_unit__c',
            'sitelink_unit__r.unit_id__c', 'sitelink_unit__r.site__c', 'sitelink_reservation_id__c', 'sitelink_sync_hash__c',
            'sitelink_retry_count__c', 'sitelink_sync_status__c'
        };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('Opportunity')) {
            fields.add(f.toLowerCase());
        }
        return Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM Opportunity WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => ids },
            AccessLevel.SYSTEM_MODE
        );
    }

    private static List<Account> queryAccounts(Set<Id> ids) {
        Set<String> fields = new Set<String>{
            'id', 'name', 'sitelink_tenant_id__c', 'sitelink_site__c', 'sitelink_site__r.location_code__c',
            'sitelink_sync_hash__c', 'sitelink_retry_count__c', 'sitelink_sync_status__c'
        };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('Account')) {
            fields.add(f.toLowerCase());
        }
        return Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM Account WHERE Id IN :ids',
            new Map<String, Object>{ 'ids' => ids },
            AccessLevel.SYSTEM_MODE
        );
    }
}
