/**
 * Safety net for SiteLinkPushQueueable: if the job dies on an uncatchable error
 * (limit exception, timeout), mark its records for retry instead of leaving them Pending.
 */
public without sharing class SiteLinkPushFinalizer implements Finalizer {
    private Set<Id> opportunityIds;
    private Set<Id> accountIds;

    public SiteLinkPushFinalizer(Set<Id> opportunityIds, Set<Id> accountIds) {
        this.opportunityIds = opportunityIds;
        this.accountIds = accountIds;
    }

    public void execute(FinalizerContext context) {
        if (context.getResult() == ParentJobResult.SUCCESS) {
            return;
        }
        String detail = context.getException() == null ? 'unknown error' : context.getException().getMessage();
        handleFailure(opportunityIds, accountIds, detail, context.getAsyncApexJobId());
    }

    @TestVisible
    private static void handleFailure(Set<Id> opportunityIds, Set<Id> accountIds, String detail, Id jobId) {
        SiteLinkException error = new SiteLinkException(
                'The background sync stopped unexpectedly. Salesforce will try again automatically.'
            )
            .retryable(true)
            .detail(detail);
        List<SObject> rows = new List<SObject>();
        if (accountIds != null && !accountIds.isEmpty()) {
            for (Account a : [SELECT Id, SiteLink_Retry_Count__c FROM Account WHERE Id IN :accountIds]) {
                rows.add(failureRow(a, error));
            }
        }
        if (opportunityIds != null && !opportunityIds.isEmpty()) {
            for (Opportunity o : [SELECT Id, SiteLink_Retry_Count__c FROM Opportunity WHERE Id IN :opportunityIds]) {
                rows.add(failureRow(o, error));
            }
        }
        SiteLinkSyncContext.suppress();
        try {
            Database.update(rows, false);
        } finally {
            SiteLinkSyncContext.release();
        }
        SiteLinkLogger.currentJobId = jobId;
        SiteLinkLogger.log('Outbound', 'Push job', null, null, 'Retrying', 'Push job failed: ' + detail);
        SiteLinkLogger.flush();
    }

    private static SObject failureRow(SObject source, SiteLinkException error) {
        SObject row = source.getSObjectType().newSObject(source.Id);
        SiteLinkPushService.applyFailure(source, row, error);
        return row;
    }
}
