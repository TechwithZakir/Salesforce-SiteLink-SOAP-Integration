/**
 * Polls SiteLink one store at a time (run with scope size 1). full = true ignores the
 * poll cursors and re-reads everything: the periodic reconciliation.
 */
public without sharing class SiteLinkPullBatch implements Database.Batchable<SObject>, Database.AllowsCallouts, Database.Stateful {
    private Boolean full;
    private Integer storesDone = 0;
    private List<String> problems = new List<String>();

    public SiteLinkPullBatch(Boolean full) {
        this.full = full == true;
    }

    public static Id run(Boolean full) {
        return Database.executeBatch(new SiteLinkPullBatch(full), 1);
    }

    public Database.QueryLocator start(Database.BatchableContext context) {
        return Database.getQueryLocator(
            [SELECT Id FROM SiteLink_Site__c WHERE Sync_Enabled__c = TRUE AND Location_Code__c != NULL ORDER BY Location_Code__c]
        );
    }

    public void execute(Database.BatchableContext context, List<SiteLink_Site__c> scope) {
        SiteLinkLogger.currentJobId = context?.getJobId();
        for (SiteLink_Site__c site : scope) {
            try {
                SiteLinkPullService.SiteResult result = new SiteLinkPullService(new SiteLinkApi()).pullSite(site.Id, full);
                if (!result.errors.isEmpty()) {
                    problems.add('Store ' + result.locationCode + ': ' + String.join(result.errors, ' | '));
                }
            } catch (Exception e) {
                problems.add('Store ' + site.Id + ': ' + e.getMessage());
                SiteLinkLogger.log('Inbound', 'Poll store', null, site.Id, 'Error', e.getMessage() + '\n' + e.getStackTraceString());
            } finally {
                storesDone++;
                SiteLinkLogger.flush();
            }
        }
    }

    public void finish(Database.BatchableContext context) {
        SiteLinkLogger.currentJobId = context?.getJobId();
        SiteLinkLogger.log(
            'Inbound',
            full ? 'Reconciliation' : 'Poll',
            null,
            null,
            problems.isEmpty() ? 'Success' : 'Error',
            storesDone + ' store(s) processed.' + (problems.isEmpty() ? '' : '\n' + String.join(problems, '\n'))
        );
        SiteLinkLogger.flush();
        if (!problems.isEmpty()) {
            SiteLinkAlerts.send('SiteLink ' + (full ? 'reconciliation' : 'poll') + ' had problems at ' + problems.size() + ' store(s)', problems);
        }
    }
}
