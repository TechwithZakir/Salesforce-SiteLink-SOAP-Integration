@IsTest
private class SiteLinkJobsTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkTestFactory.site(SiteLinkTestFactory.LOC);
        }
    }

    private static SiteLinkMock discoveryMock() {
        return new SiteLinkMock()
            .reply(
                'SiteSearchByPostalCode',
                SiteLinkMock.dataSet(
                    'SiteSearchByPostalCode',
                    SiteLinkMock.row('Table', new Map<String, String>{ 'SiteID' => '11', 'sLocationCode' => 'L001', 'sSiteName' => 'Calgary North' }) +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'SiteID' => '12', 'sLocationCode' => 'L002', 'sSiteName' => 'Edmonton South' }) +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'SiteID' => '12', 'sLocationCode' => 'l002' })
                )
            );
    }

    @IsTest
    static void discoveryAddsNewStoresAutomatically() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = discoveryMock();
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            System.enqueueJob(new SiteLinkDiscoveryQueueable(false));
            Test.stopTest();

            Assert.isFalse(mock.lastBody('SiteSearchByPostalCode').contains('sLocationCode'), 'corp-level call');
            Assert.isTrue(mock.lastBody('SiteSearchByPostalCode').contains('<iCountry>-999</iCountry>'));
            Map<String, SiteLink_Site__c> sites = new Map<String, SiteLink_Site__c>();
            for (SiteLink_Site__c s : [SELECT Name, Location_Code__c, Sync_Enabled__c FROM SiteLink_Site__c]) {
                sites.put(s.Location_Code__c, s);
            }
            Assert.areEqual(2, sites.size(), 'duplicate rows ignored');
            Assert.areEqual('Calgary North', sites.get('L001').Name);
            Assert.areEqual('Edmonton South', sites.get('L002').Name);
            Assert.isTrue(sites.get('L002').Sync_Enabled__c);
        }
    }

    @IsTest
    static void discoveryFailureIsLoggedAndAlerted() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock().onStatus('SiteSearchByPostalCode', 500, SiteLinkMock.fault('Invalid corp login')));
            Test.startTest();
            System.enqueueJob(new SiteLinkDiscoveryQueueable(true));
            Test.stopTest();
            Assert.areEqual(1, [SELECT COUNT() FROM SiteLink_Sync_Log__c WHERE Operation__c = 'Discover stores' AND Status__c = 'Error']);
        }
    }

    @IsTest
    static void batchPollsEachEnabledStore() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            insert new SiteLink_Site__c(Name = 'Off', Location_Code__c = 'L009', Sync_Enabled__c = false);
            SiteLinkMock mock = new SiteLinkMock()
                .reply('SiteInformation', SiteLinkMock.dataSet('SiteInformation', SiteLinkMock.row('Table', new Map<String, String>{ 'SiteID' => '11', 'sSiteName' => 'Calgary North' })))
                .onTimeout('ReservationList');
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            SiteLinkPullBatch.run(false);
            Test.stopTest();

            Assert.areEqual(1, mock.count('SiteInformation'), 'disabled store skipped');
            SiteLink_Site__c site = [SELECT Name, Last_Poll_Status__c FROM SiteLink_Site__c WHERE Location_Code__c = 'L001'];
            Assert.areEqual('Calgary North', site.Name);
            Assert.areEqual('Partial', site.Last_Poll_Status__c);
            Assert.areEqual(1, [SELECT COUNT() FROM SiteLink_Sync_Log__c WHERE Operation__c = 'Poll' AND Status__c = 'Error']);
        }
    }

    @IsTest
    static void pollRetriesAndStartsIncrementalPull() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock());
            Test.startTest();
            new SiteLinkScheduler(SiteLinkScheduler.MODE_POLL).execute(null);
            Test.stopTest();
            Assert.areEqual(1, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'SiteLinkPullBatch' AND JobType = 'BatchApex']);
            Assert.areEqual('Success', [SELECT Last_Poll_Status__c FROM SiteLink_Site__c].Last_Poll_Status__c);
        }
    }

    @IsTest
    static void reconcileDiscoversStores() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            // Tests allow one batch chunk: leave only the newly discovered store enabled.
            update new SiteLink_Site__c(Id = [SELECT Id FROM SiteLink_Site__c].Id, Sync_Enabled__c = false);
            Test.setMock(HttpCalloutMock.class, discoveryMock());
            Test.startTest();
            new SiteLinkScheduler(SiteLinkScheduler.MODE_RECONCILE).execute(null);
            Test.stopTest();
            Assert.areEqual(2, [SELECT COUNT() FROM SiteLink_Site__c]);
        }
    }

    @IsTest
    static void scheduleDefaultsCreatesFiveJobs() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.startTest();
            List<Id> ids = SiteLinkScheduler.scheduleDefaults();
            Assert.areEqual(5, ids.size());
            Assert.areEqual(5, [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'SiteLink %']);
            for (Id jobId : ids) {
                System.abortJob(jobId); // registered correctly; not meant to run here
            }
            Test.stopTest();
        }
    }

    @IsTest
    static void purgesOldLogsOnly() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Sync_Log__c oldLog = new SiteLink_Sync_Log__c(Operation__c = 'old');
            SiteLink_Sync_Log__c newLog = new SiteLink_Sync_Log__c(Operation__c = 'new');
            insert new List<SiteLink_Sync_Log__c>{ oldLog, newLog };
            Test.setCreatedDate(oldLog.Id, System.now().addDays(-60));
            Test.startTest();
            Assert.areEqual(1, SiteLinkScheduler.purgeLogs());
            Test.stopTest();
            Assert.areEqual('new', [SELECT Operation__c FROM SiteLink_Sync_Log__c].Operation__c);
        }
    }

    @IsTest
    static void inactiveSchedulerDoesNothing() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false).Active__c = false;
            Test.startTest();
            new SiteLinkScheduler(null).execute(null);
            Test.stopTest();
            Assert.areEqual(0, [SELECT COUNT() FROM AsyncApexJob WHERE ApexClass.Name = 'SiteLinkPullBatch']);
        }
    }

    @IsTest
    static void alertsAreSkippedWithoutRecipients() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false).Alert_Emails__c = null;
            SiteLinkAlerts.send('x', new List<String>{ 'y' });
            Assert.areEqual(0, SiteLinkAlerts.sentCount);
            SiteLinkTestFactory.configure(false).Alert_Emails__c = 'a@example.com; b@example.com';
            SiteLinkAlerts.send('x', new List<String>{ 'y' });
            Assert.areEqual(1, SiteLinkAlerts.sentCount);
        }
    }
}
