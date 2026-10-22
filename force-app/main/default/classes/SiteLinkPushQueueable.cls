/**
 * Background push to SiteLink. Processes Push_Batch_Size__c records per execution
 * (each can take several callouts) and chains itself for the rest.
 * Opportunities go first, so an account and its opportunity saved together share one tenant lookup.
 */
public without sharing class SiteLinkPushQueueable implements Queueable, Database.AllowsCallouts {
    private List<Id> opportunityIds;
    private List<Id> accountIds;

    public SiteLinkPushQueueable(Set<Id> opportunityIds, Set<Id> accountIds) {
        this.opportunityIds = opportunityIds == null ? new List<Id>() : new List<Id>(opportunityIds);
        this.accountIds = accountIds == null ? new List<Id>() : new List<Id>(accountIds);
    }

    public void execute(QueueableContext context) {
        if (!SiteLinkConfig.isActive()) {
            return;
        }
        Integer size = Math.max(1, SiteLinkConfig.intSetting(SiteLinkConfig.settings().Push_Batch_Size__c, 10));
        Set<Id> oppChunk = new Set<Id>();
        Set<Id> accChunk = new Set<Id>();
        while (!opportunityIds.isEmpty() && oppChunk.size() < size) {
            oppChunk.add(opportunityIds.remove(0));
        }
        while (!accountIds.isEmpty() && oppChunk.size() + accChunk.size() < size) {
            accChunk.add(accountIds.remove(0));
        }

        System.attachFinalizer(new SiteLinkPushFinalizer(oppChunk, accChunk));
        SiteLinkLogger.currentJobId = context?.getJobId();

        SiteLinkPushService.Outcome out = new SiteLinkPushService(new SiteLinkApi(), false).push(oppChunk, accChunk);
        SiteLinkPushService.commitOutcome(out);

        if (!opportunityIds.isEmpty() || !accountIds.isEmpty()) {
            enqueue(new Set<Id>(opportunityIds), new Set<Id>(accountIds), 0);
        }
    }

    /**
     * Enqueues when the transaction still has room; otherwise the records stay Pending
     * and the scheduler's retry sweep picks them up at SiteLink_Next_Attempt__c.
     */
    public static Id enqueue(Set<Id> opportunityIds, Set<Id> accountIds, Integer delayMinutes) {
        if ((opportunityIds == null || opportunityIds.isEmpty()) && (accountIds == null || accountIds.isEmpty())) {
            return null;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return null;
        }
        if (Test.isRunningTest() && System.isQueueable()) {
            return null; // chaining is not allowed in tests
        }
        SiteLinkPushQueueable job = new SiteLinkPushQueueable(opportunityIds, accountIds);
        return delayMinutes != null && delayMinutes > 0 ? System.enqueueJob(job, delayMinutes) : System.enqueueJob(job);
    }
}
