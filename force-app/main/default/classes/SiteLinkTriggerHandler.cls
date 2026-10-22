/**
 * Account / Opportunity trigger logic for automatic pushes.
 *
 * before: a linked record whose mapped fields really changed (fingerprint differs from
 *         SiteLink_Sync_Hash__c) is marked Pending.
 * after:  records that just became Pending are handed to SiteLinkPushQueueable.
 *
 * Writes made by the integration run with SiteLinkSyncContext suppressed, and inbound
 * writes store the new fingerprint, so SiteLink data is never bounced back.
 */
public without sharing class SiteLinkTriggerHandler {
    private static final Integer SAFETY_NET_MINUTES = 15;
    private static Set<Id> enqueued = new Set<Id>();

    public static void handle() {
        if (SiteLinkSyncContext.isSuppressed() || !SiteLinkConfig.isActive()) {
            return;
        }
        String objectName = String.valueOf(Trigger.new[0].getSObjectType());
        if (Trigger.isBefore && Trigger.isInsert) {
            clearCopiedLinks(Trigger.new, objectName);
        }
        if (!SiteLinkConfig.isAutoPush()) {
            return;
        }
        if (Trigger.isBefore) {
            markPending(Trigger.new, objectName);
        } else {
            enqueuePending(Trigger.new, Trigger.oldMap, objectName);
        }
    }

    /** A cloned or hand-entered record must not take over another record's SiteLink link. */
    @TestVisible
    private static void clearCopiedLinks(List<SObject> records, String objectName) {
        for (SObject rec : records) {
            if (objectName == 'Opportunity') {
                rec.put('SiteLink_Reservation_Id__c', null);
                rec.put('SiteLink_Reservation_Key__c', null);
            } else if (objectName == 'Account') {
                rec.put('SiteLink_Tenant_Id__c', null);
                rec.put('SiteLink_Tenant_Key__c', null);
            }
            rec.put('SiteLink_Sync_Hash__c', null);
            rec.put('SiteLink_Sync_Status__c', 'Not Synced');
            rec.put('SiteLink_Sync_Message__c', null);
            rec.put('SiteLink_Last_Synced__c', null);
            rec.put('SiteLink_Retry_Count__c', null);
            rec.put('SiteLink_Next_Attempt__c', null);
        }
    }

    @TestVisible
    private static void markPending(List<SObject> records, String objectName) {
        for (SObject rec : records) {
            if (!isLinkable(rec, objectName)) {
                continue;
            }
            String fingerprint = SiteLinkFieldMapper.fingerprint(rec, objectName);
            if (fingerprint == (String) rec.get('SiteLink_Sync_Hash__c')) {
                continue;
            }
            rec.put('SiteLink_Sync_Status__c', SiteLinkPushService.STATUS_PENDING);
            rec.put('SiteLink_Sync_Message__c', 'Waiting to send to SiteLink.');
            rec.put('SiteLink_Retry_Count__c', 0);
            // If the job below can't be queued or dies, the scheduler's retry sweep picks this up.
            rec.put('SiteLink_Next_Attempt__c', System.now().addMinutes(SAFETY_NET_MINUTES));
        }
    }

    @TestVisible
    private static void enqueuePending(List<SObject> records, Map<Id, SObject> oldMap, String objectName) {
        Set<Id> ids = new Set<Id>();
        Boolean anyNewTenant = false;
        for (SObject rec : records) {
            if (rec.get('SiteLink_Sync_Status__c') != SiteLinkPushService.STATUS_PENDING || enqueued.contains(rec.Id)) {
                continue;
            }
            SObject old = oldMap == null ? null : oldMap.get(rec.Id);
            if (old != null && old.get('SiteLink_Sync_Status__c') == SiteLinkPushService.STATUS_PENDING) {
                continue; // already queued by an earlier save
            }
            ids.add(rec.Id);
            if (objectName == 'Account' && rec.get('SiteLink_Tenant_Id__c') == null) {
                anyNewTenant = true;
            }
        }
        if (ids.isEmpty()) {
            return;
        }
        enqueued.addAll(ids);
        if (objectName == 'Opportunity') {
            SiteLinkPushQueueable.enqueue(ids, null, 0);
        } else {
            // A new customer saved alongside an opportunity is created by the opportunity's job;
            // the short delay lets that job link the tenant first so this one finds it.
            SiteLinkPushQueueable.enqueue(null, ids, anyNewTenant ? 2 : 0);
        }
    }

    private static Boolean isLinkable(SObject rec, String objectName) {
        if (objectName == 'Opportunity') {
            return rec.get('SiteLink_Site__c') != null;
        }
        return rec.get('SiteLink_Site__c') != null || rec.get('SiteLink_Tenant_Id__c') != null;
    }
}
