/**
 * Finds every store in the SiteLink corp (SiteSearchByPostalCode, as the PHP reference does)
 * and creates/updates SiteLink_Site__c records, so new locations need no code or config.
 * Optionally starts the full reconciliation batch afterwards.
 */
public without sharing class SiteLinkDiscoveryQueueable implements Queueable, Database.AllowsCallouts {
    private Boolean startFullSync;

    public SiteLinkDiscoveryQueueable(Boolean startFullSync) {
        this.startFullSync = startFullSync == true;
    }

    public void execute(QueueableContext context) {
        SiteLinkLogger.currentJobId = context?.getJobId();
        SiteLinkLogger.currentDirection = 'Inbound';
        try {
            discover(new SiteLinkApi());
        } catch (SiteLinkException e) {
            SiteLinkLogger.log('Inbound', 'Discover stores', null, null, 'Error', e.getMessage());
            SiteLinkAlerts.send('SiteLink store discovery failed', new List<String>{ e.getMessage() });
        }
        SiteLinkLogger.flush();
        if (startFullSync && SiteLinkConfig.settings().Inbound_Enabled__c == true) {
            SiteLinkPullBatch.run(true);
        }
    }

    /** @return number of stores created or changed */
    public static Integer discover(SiteLinkApi api) {
        List<Map<String, String>> rows = api.searchSites().rowsWith('sLocationCode');
        Map<String, SiteLink_Site__c> existing = new Map<String, SiteLink_Site__c>();
        Set<String> fields = new Set<String>{ 'id', 'name', 'location_code__c' };
        for (String f : SiteLinkFieldMapper.fieldsToQuery('SiteLink_Site__c')) {
            fields.add(f.toLowerCase());
        }
        for (SiteLink_Site__c s : Database.query('SELECT ' + String.join(new List<String>(fields), ', ') + ' FROM SiteLink_Site__c')) {
            if (s.Location_Code__c != null) {
                existing.put(s.Location_Code__c.toUpperCase(), s);
            }
        }
        List<SiteLink_Site__c> changed = new List<SiteLink_Site__c>();
        Set<String> seen = new Set<String>();
        for (Map<String, String> row : rows) {
            String code = row.get('slocationcode');
            if (String.isBlank(code) || !seen.add(code.trim().toUpperCase())) {
                continue;
            }
            SiteLink_Site__c site = existing.get(code.trim().toUpperCase());
            Boolean isNew = site == null;
            if (isNew) {
                site = new SiteLink_Site__c(Location_Code__c = code.trim(), Name = code.trim());
            }
            if (SiteLinkFieldMapper.applyInbound(site, row, 'SiteLink_Site__c', null) || isNew) {
                changed.add(site);
            }
        }
        Database.DMLOptions options = new Database.DMLOptions();
        options.allowFieldTruncation = true;
        options.optAllOrNone = false;
        List<SiteLink_Site__c> inserts = new List<SiteLink_Site__c>();
        List<SiteLink_Site__c> updates = new List<SiteLink_Site__c>();
        for (SiteLink_Site__c s : changed) {
            if (s.Id == null) {
                inserts.add(s);
            } else {
                updates.add(s);
            }
        }
        Database.insert(inserts, options);
        Database.update(updates, options);
        SiteLinkLogger.log(
            'Inbound',
            'Discover stores',
            null,
            null,
            'Success',
            rows.size() + ' store(s) in SiteLink; ' + inserts.size() + ' new, ' + updates.size() + ' updated.'
        );
        return changed.size();
    }
}
