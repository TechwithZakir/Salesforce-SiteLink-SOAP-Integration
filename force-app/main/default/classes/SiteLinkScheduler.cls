/**
 * Scheduled entry point.
 *   POLL      - retry sweep for due pushes + incremental pull of every store
 *   RECONCILE - purge old logs, discover stores, then full pull of every store
 *
 * SiteLink has no webhook / event API (none of the 308 CallCenterWs or 63 ReportingWs
 * operations is one), so near-real-time inbound sync is frequent polling.
 * Run SiteLinkScheduler.scheduleDefaults() once as the integration admin.
 */
public without sharing class SiteLinkScheduler implements Schedulable {
    public static final String MODE_POLL = 'POLL';
    public static final String MODE_RECONCILE = 'RECONCILE';
    private static final Integer RETRY_SWEEP_LIMIT = 200;

    private String mode;

    public SiteLinkScheduler(String mode) {
        this.mode = mode == MODE_RECONCILE ? MODE_RECONCILE : MODE_POLL;
    }

    public void execute(SchedulableContext context) {
        if (!SiteLinkConfig.isActive()) {
            return;
        }
        if (mode == MODE_RECONCILE) {
            purgeLogs();
            System.enqueueJob(new SiteLinkDiscoveryQueueable(true));
            return;
        }
        retryDuePushes();
        if (SiteLinkConfig.settings().Inbound_Enabled__c == true && !pullRunning()) {
            SiteLinkPullBatch.run(false);
        }
    }

    /** Every 15 minutes poll, plus nightly reconciliation at 02:30 (org time zone). */
    public static List<Id> scheduleDefaults() {
        List<Id> jobIds = new List<Id>();
        for (String minute : new List<String>{ '00', '15', '30', '45' }) {
            jobIds.add(System.schedule('SiteLink Poll :' + minute, '0 ' + minute + ' * * * ?', new SiteLinkScheduler(MODE_POLL)));
        }
        jobIds.add(System.schedule('SiteLink Nightly Reconcile', '0 30 2 * * ?', new SiteLinkScheduler(MODE_RECONCILE)));
        return jobIds;
    }

    /** Queues records whose next attempt is due: Retrying after a failure, or Pending whose job never ran. */
    public static void retryDuePushes() {
        Datetime now = System.now();
        Set<String> statuses = new Set<String>{ SiteLinkPushService.STATUS_PENDING, SiteLinkPushService.STATUS_RETRYING };
        List<Opportunity> opps = [
            SELECT Id
            FROM Opportunity
            WHERE SiteLink_Sync_Status__c IN :statuses AND SiteLink_Next_Attempt__c <= :now
            ORDER BY SiteLink_Next_Attempt__c
            LIMIT :RETRY_SWEEP_LIMIT
        ];
        List<Account> accounts = [
            SELECT Id
            FROM Account
            WHERE SiteLink_Sync_Status__c IN :statuses AND SiteLink_Next_Attempt__c <= :now
            ORDER BY SiteLink_Next_Attempt__c
            LIMIT :RETRY_SWEEP_LIMIT
        ];
        if (opps.isEmpty() && accounts.isEmpty()) {
            return;
        }
        // Push the safety-net time out so the next sweep doesn't queue the same records again.
        List<SObject> rows = new List<SObject>();
        for (Account a : accounts) {
            rows.add(new Account(Id = a.Id, SiteLink_Next_Attempt__c = now.addMinutes(30)));
        }
        for (Opportunity o : opps) {
            rows.add(new Opportunity(Id = o.Id, SiteLink_Next_Attempt__c = now.addMinutes(30)));
        }
        SiteLinkSyncContext.suppress();
        try {
            Database.update(rows, false);
        } finally {
            SiteLinkSyncContext.release();
        }
        SiteLinkPushQueueable.enqueue(new Map<Id, Opportunity>(opps).keySet(), new Map<Id, Account>(accounts).keySet(), 0);
    }

    public static Integer purgeLogs() {
        Integer days = SiteLinkConfig.intSetting(SiteLinkConfig.settings().Log_Retention_Days__c, 30);
        Datetime cutoff = System.now().addDays(-days);
        List<SiteLink_Sync_Log__c> old = [SELECT Id FROM SiteLink_Sync_Log__c WHERE CreatedDate < :cutoff LIMIT 9000];
        Database.delete(old, false);
        return old.size();
    }

    private static Boolean pullRunning() {
        return [
                SELECT COUNT()
                FROM AsyncApexJob
                WHERE ApexClass.Name = 'SiteLinkPullBatch' AND JobType = 'BatchApex' AND Status IN ('Holding', 'Queued', 'Preparing', 'Processing')
            ] > 0;
    }
}
