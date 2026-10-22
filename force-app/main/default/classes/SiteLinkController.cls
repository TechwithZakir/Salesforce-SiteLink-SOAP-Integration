/**
 * Backs the siteLinkPush Lightning component on Opportunity and Account pages.
 * Checks the user can edit the record, then runs the integration synchronously
 * (callouts first, DML last) so staff see the result straight away.
 */
public with sharing class SiteLinkController {
    public class SyncStatus {
        @AuraEnabled
        public String objectType;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String message;
        @AuraEnabled
        public Datetime lastSynced;
        @AuraEnabled
        public Datetime nextAttempt;
        @AuraEnabled
        public Integer tenantId;
        @AuraEnabled
        public Integer reservationId;
        @AuraEnabled
        public String storeName;
        @AuraEnabled
        public String unitName;
        @AuraEnabled
        public String customerStatus;
        @AuraEnabled
        public String customerMessage;
        @AuraEnabled
        public Boolean canPush = false;
        @AuraEnabled
        public Boolean integrationActive = false;
    }

    @AuraEnabled
    public static SyncStatus getStatus(Id recordId) {
        assertAccess(recordId, false);
        return buildStatus(recordId);
    }

    @AuraEnabled
    public static SyncStatus pushToSiteLink(Id recordId) {
        assertAccess(recordId, true);
        assertActive();
        Boolean isAccount = recordId.getSObjectType() == Account.SObjectType;
        try {
            SiteLinkPushService.Outcome out = new SiteLinkPushService(new SiteLinkApi(), true)
                .push(isAccount ? new Set<Id>() : new Set<Id>{ recordId }, isAccount ? new Set<Id>{ recordId } : new Set<Id>());
            SiteLinkPushService.commitOutcome(out);
        } catch (Exception e) {
            SiteLinkLogger.flush();
            throw auraError(e);
        }
        return buildStatus(recordId);
    }

    /** Reads the tenant (and reservation) back from SiteLink and applies the inbound field mappings. */
    @AuraEnabled
    public static SyncStatus refreshFromSiteLink(Id recordId) {
        assertAccess(recordId, true);
        assertActive();
        SiteLinkApi api = new SiteLinkApi();
        SiteLinkLogger.currentDirection = 'Inbound';
        SiteLinkLogger.currentRecordId = recordId;
        try {
            Account acc;
            Opportunity opp;
            String loc;
            if (recordId.getSObjectType() == Account.SObjectType) {
                acc = queryAccount(recordId);
                loc = acc.SiteLink_Site__r?.Location_Code__c;
            } else {
                opp = queryOpportunity(recordId);
                loc = opp.SiteLink_Site__r?.Location_Code__c;
                acc = opp.AccountId == null ? null : queryAccount(opp.AccountId);
            }
            Integer tenantId = acc?.SiteLink_Tenant_Id__c?.intValue();
            Integer waitingId = opp?.SiteLink_Reservation_Id__c?.intValue();
            if (String.isBlank(loc) || (tenantId == null && waitingId == null)) {
                throw new SiteLinkException('This record has not been sent to SiteLink yet, so there is nothing to refresh.');
            }

            Map<String, String> tenantRow = tenantId == null ? null : api.getTenant(loc, tenantId);
            Map<String, String> reservationRow = waitingId == null ? null : api.getReservation(loc, waitingId);

            List<SObject> rows = new List<SObject>();
            if (tenantRow != null) {
                SiteLinkPullService.applyTenantRow(acc, tenantRow);
                rows.add(acc);
            }
            if (reservationRow != null) {
                SiteLinkPullService.applyReservationRow(opp, reservationRow);
                rows.add(opp);
            }
            if (rows.isEmpty()) {
                throw new SiteLinkException('SiteLink no longer has this customer or reservation. It may have been removed in SiteLink.');
            }
            SiteLinkSyncContext.suppress();
            try {
                Database.DMLOptions options = new Database.DMLOptions();
                options.allowFieldTruncation = true;
                Database.update(rows, options);
            } finally {
                SiteLinkSyncContext.release();
            }
            SiteLinkLogger.flush();
        } catch (Exception e) {
            SiteLinkLogger.flush();
            throw auraError(e);
        }
        return buildStatus(recordId);
    }

    // ------------------------------------------------------------------ helpers

    private static SyncStatus buildStatus(Id recordId) {
        SyncStatus s = new SyncStatus();
        s.objectType = String.valueOf(recordId.getSObjectType());
        s.integrationActive = SiteLinkConfig.isActive();
        if (recordId.getSObjectType() == Account.SObjectType) {
            Account acc = queryAccount(recordId);
            s.status = acc.SiteLink_Sync_Status__c;
            s.message = acc.SiteLink_Sync_Message__c;
            s.lastSynced = acc.SiteLink_Last_Synced__c;
            s.nextAttempt = acc.SiteLink_Next_Attempt__c;
            s.tenantId = acc.SiteLink_Tenant_Id__c?.intValue();
            s.storeName = acc.SiteLink_Site__r?.Name;
            s.canPush = acc.SiteLink_Site__c != null;
        } else {
            Opportunity opp = queryOpportunity(recordId);
            s.status = opp.SiteLink_Sync_Status__c;
            s.message = opp.SiteLink_Sync_Message__c;
            s.lastSynced = opp.SiteLink_Last_Synced__c;
            s.nextAttempt = opp.SiteLink_Next_Attempt__c;
            s.reservationId = opp.SiteLink_Reservation_Id__c?.intValue();
            s.storeName = opp.SiteLink_Site__r?.Name;
            s.unitName = opp.SiteLink_Unit__r?.Name;
            s.tenantId = opp.Account?.SiteLink_Tenant_Id__c?.intValue();
            s.customerStatus = opp.Account?.SiteLink_Sync_Status__c;
            s.customerMessage = opp.Account?.SiteLink_Sync_Message__c;
            s.canPush = opp.SiteLink_Site__c != null && opp.AccountId != null;
        }
        return s;
    }

    private static void assertAccess(Id recordId, Boolean needEdit) {
        if (recordId == null || (recordId.getSObjectType() != Opportunity.SObjectType && recordId.getSObjectType() != Account.SObjectType)) {
            throw aura('SiteLink sync works on Opportunity and Account records only.');
        }
        List<UserRecordAccess> access = [
            SELECT RecordId, HasReadAccess, HasEditAccess
            FROM UserRecordAccess
            WHERE UserId = :UserInfo.getUserId() AND RecordId = :recordId
        ];
        Boolean allowed = !access.isEmpty() && (needEdit ? access[0].HasEditAccess : access[0].HasReadAccess);
        if (!allowed) {
            throw aura(
                needEdit ? 'You need edit access to this record to sync it with SiteLink.' : 'You do not have access to this record.'
            );
        }
    }

    private static void assertActive() {
        if (!SiteLinkConfig.isActive()) {
            throw aura('The SiteLink integration is switched off. Ask your Salesforce admin to turn it on.');
        }
    }

    private static AuraHandledException auraError(Exception e) {
        return aura(
            e instanceof SiteLinkException ? e.getMessage() : 'Something unexpected went wrong talking to SiteLink: ' + e.getMessage()
        );
    }

    /** Without setMessage, getMessage() on the server (and in tests) is "Script-thrown exception". */
    private static AuraHandledException aura(String message) {
        AuraHandledException error = new AuraHandledException(message);
        error.setMessage(message);
        return error;
    }

    private static Account queryAccount(Id accountId) {
        Set<String> fields = new Set<String>{
            'id', 'name', 'sitelink_site__c', 'sitelink_site__r.name', 'sitelink_site__r.location_code__c', 'sitelink_tenant_id__c',
            'sitelink_sync_status__c', 'sitelink_sync_message__c', 'sitelink_last_synced__c', 'sitelink_next_attempt__c', 'sitelink_sync_hash__c'
        };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('Account')) {
            fields.add(f.toLowerCase());
        }
        return (Account) Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM Account WHERE Id = :accountId',
            new Map<String, Object>{ 'accountId' => accountId },
            AccessLevel.SYSTEM_MODE
        )[0];
    }

    private static Opportunity queryOpportunity(Id opportunityId) {
        Set<String> fields = new Set<String>{
            'id', 'name', 'accountid', 'account.sitelink_tenant_id__c', 'account.sitelink_sync_status__c', 'account.sitelink_sync_message__c',
            'sitelink_site__c', 'sitelink_site__r.name', 'sitelink_site__r.location_code__c', 'sitelink_unit__c', 'sitelink_unit__r.name',
            'sitelink_reservation_id__c', 'sitelink_sync_status__c', 'sitelink_sync_message__c', 'sitelink_last_synced__c',
            'sitelink_next_attempt__c', 'sitelink_sync_hash__c'
        };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('Opportunity')) {
            fields.add(f.toLowerCase());
        }
        return (Opportunity) Database.queryWithBinds(
            'SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM Opportunity WHERE Id = :opportunityId',
            new Map<String, Object>{ 'opportunityId' => opportunityId },
            AccessLevel.SYSTEM_MODE
        )[0];
    }
}
