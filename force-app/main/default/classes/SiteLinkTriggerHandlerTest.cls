@IsTest
private class SiteLinkTriggerHandlerTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Site__c site = SiteLinkTestFactory.site(SiteLinkTestFactory.LOC);
            SiteLinkTestFactory.unit(site, 2001);
            SiteLinkTestFactory.customer(null);
        }
    }

    private static SiteLinkMock createMock() {
        return new SiteLinkMock()
            .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(101, '')))
            .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(555, '')));
    }

    @IsTest
    static void newOpportunityIsPushedInTheBackground() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(true);
            Test.setMock(HttpCalloutMock.class, createMock());
            Account acc = [SELECT Id FROM Account];
            SiteLink_Site__c site = [SELECT Id FROM SiteLink_Site__c];
            SiteLink_Unit__c unit = [SELECT Id FROM SiteLink_Unit__c];

            Test.startTest();
            Opportunity o = SiteLinkTestFactory.reservation(acc, site, unit);
            Opportunity queued = [SELECT SiteLink_Sync_Status__c, SiteLink_Next_Attempt__c FROM Opportunity WHERE Id = :o.Id];
            Assert.areEqual('Pending', queued.SiteLink_Sync_Status__c);
            Assert.isNotNull(queued.SiteLink_Next_Attempt__c, 'safety net for the retry sweep');
            Test.stopTest();

            Opportunity done = [SELECT SiteLink_Sync_Status__c, SiteLink_Reservation_Id__c FROM Opportunity WHERE Id = :o.Id];
            Assert.areEqual('Synced', done.SiteLink_Sync_Status__c);
            Assert.areEqual(555, done.SiteLink_Reservation_Id__c);
        }
    }

    @IsTest
    static void unrelatedEditsAndIntegrationWritesDoNotPush() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account acc = [SELECT Id FROM Account];
            SiteLink_Site__c site = [SELECT Id FROM SiteLink_Site__c];
            Opportunity o = SiteLinkTestFactory.reservation(acc, site, null);
            Opportunity current = (Opportunity) Database.query(
                'SELECT ' + String.join(new List<String>(SiteLinkFieldMapper.fieldsToQuery('Opportunity')), ',') + ' FROM Opportunity WHERE Id = \'' + o.Id + '\''
            );
            SiteLinkTestFactory.markLinked(
                o,
                'Opportunity',
                new Map<String, Object>{ 'SiteLink_Sync_Hash__c' => SiteLinkFieldMapper.fingerprint(current, 'Opportunity'), 'SiteLink_Sync_Status__c' => 'Synced' }
            );
            SiteLinkTestFactory.configure(true);
            Test.setMock(HttpCalloutMock.class, createMock());

            Test.startTest();
            update new Opportunity(Id = o.Id, Name = 'Renamed only');
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c, 'name is not mapped');

            SiteLinkSyncContext.suppress();
            update new Opportunity(Id = o.Id, Description = 'written by the integration');
            SiteLinkSyncContext.release();
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c, 'integration writes are ignored');

            update new Opportunity(Id = o.Id, Description = 'changed by a user');
            Assert.areEqual('Pending', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c);
            Assert.areEqual(1, Limits.getQueueableJobs());
            Test.stopTest();
        }
    }

    @IsTest
    static void linkedAccountChangeIsQueued() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account acc = [SELECT Id FROM Account];
            SiteLinkTestFactory.markLinked(
                acc,
                'Account',
                new Map<String, Object>{ 'SiteLink_Tenant_Id__c' => 101, 'SiteLink_Site__c' => [SELECT Id FROM SiteLink_Site__c].Id }
            );
            SiteLinkTestFactory.configure(true);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '101' })))
                    .reply('TenantUpdate_v3', SiteLinkMock.dataSet('TenantUpdate_v3', SiteLinkMock.rt(101, '')))
            );
            Test.startTest();
            update new Account(Id = acc.Id, Tenant_First_Name__c = 'Janet');
            Assert.areEqual('Pending', [SELECT SiteLink_Sync_Status__c FROM Account].SiteLink_Sync_Status__c);
            Test.stopTest();
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Account].SiteLink_Sync_Status__c);
        }
    }

    @IsTest
    static void clonedRecordsDoNotInheritSiteLinkLinks() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account acc = [SELECT Id FROM Account];
            Opportunity o = new Opportunity(
                Name = 'Clone',
                AccountId = acc.Id,
                StageName = SiteLinkTestFactory.openStage(),
                CloseDate = Date.today(),
                SiteLink_Reservation_Id__c = 5,
                SiteLink_Reservation_Key__c = 'L001:5',
                SiteLink_Sync_Status__c = 'Synced'
            );
            insert o;
            Opportunity saved = [SELECT SiteLink_Reservation_Id__c, SiteLink_Reservation_Key__c, SiteLink_Sync_Status__c FROM Opportunity WHERE Id = :o.Id];
            Assert.isNull(saved.SiteLink_Reservation_Id__c);
            Assert.isNull(saved.SiteLink_Reservation_Key__c);
            Assert.areEqual('Not Synced', saved.SiteLink_Sync_Status__c);
        }
    }

    @IsTest
    static void inactiveIntegrationLeavesRecordsAlone() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLink_Setting__mdt s = SiteLinkTestFactory.configure(true);
            s.Active__c = false;
            Account acc = [SELECT Id FROM Account];
            Opportunity o = SiteLinkTestFactory.reservation(acc, [SELECT Id FROM SiteLink_Site__c], null);
            Assert.areNotEqual('Pending', [SELECT SiteLink_Sync_Status__c FROM Opportunity WHERE Id = :o.Id].SiteLink_Sync_Status__c);
        }
    }

    @IsTest
    static void retrySweepPicksUpDueRecords() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account acc = [SELECT Id FROM Account];
            Opportunity o = SiteLinkTestFactory.reservation(acc, [SELECT Id FROM SiteLink_Site__c], [SELECT Id FROM SiteLink_Unit__c]);
            SiteLinkTestFactory.markLinked(
                o,
                'Opportunity',
                new Map<String, Object>{ 'SiteLink_Sync_Status__c' => 'Retrying', 'SiteLink_Next_Attempt__c' => System.now().addMinutes(-1) }
            );
            Test.setMock(HttpCalloutMock.class, createMock());
            Test.startTest();
            SiteLinkScheduler.retryDuePushes();
            Test.stopTest();
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c);
        }
    }
}
