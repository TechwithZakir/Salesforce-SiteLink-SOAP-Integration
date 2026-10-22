@IsTest
private class SiteLinkControllerTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Site__c site = SiteLinkTestFactory.site(SiteLinkTestFactory.LOC);
            SiteLink_Unit__c unit = SiteLinkTestFactory.unit(site, 2001);
            Account acc = SiteLinkTestFactory.customer(null);
            SiteLinkTestFactory.reservation(acc, site, unit);
        }
    }

    @IsTest
    static void pushFromTheButtonReturnsFreshStatus() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(101, '')))
                    .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(555, '')))
            );
            Opportunity o = [SELECT Id FROM Opportunity];

            SiteLinkController.SyncStatus before = SiteLinkController.getStatus(o.Id);
            Assert.areEqual('Not Synced', before.status);
            Assert.isTrue(before.canPush);
            Assert.areEqual('A2001', before.unitName);

            Test.startTest();
            SiteLinkController.SyncStatus after = SiteLinkController.pushToSiteLink(o.Id);
            Test.stopTest();

            Assert.areEqual('Synced', after.status);
            Assert.areEqual(555, after.reservationId);
            Assert.areEqual(101, after.tenantId);
            Assert.areEqual('Synced', after.customerStatus);
            Assert.isNotNull(after.lastSynced);
        }
    }

    @IsTest
    static void refreshBringsSiteLinkValuesBack() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = [SELECT Id, AccountId FROM Opportunity];
            SiteLink_Site__c site = [SELECT Id FROM SiteLink_Site__c];
            SiteLinkTestFactory.markLinked(
                new Account(Id = o.AccountId),
                'Account',
                new Map<String, Object>{ 'SiteLink_Tenant_Id__c' => 101, 'SiteLink_Site__c' => site.Id }
            );
            SiteLinkTestFactory.markLinked(o, 'Opportunity', new Map<String, Object>{ 'SiteLink_Reservation_Id__c' => 555 });
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply(
                        'TenantInfoByTenantID',
                        SiteLinkMock.dataSet(
                            'TenantInfoByTenantID',
                            SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '101', 'sFName' => 'Janet', 'sLName' => 'Doe', 'sEmail' => 'janet@example.com' })
                        )
                    )
                    .reply(
                        'ReservationList_v3',
                        SiteLinkMock.dataSet(
                            'ReservationList_v3',
                            SiteLinkMock.row('Table', new Map<String, String>{ 'WaitingID' => '555', 'sComment' => 'Changed in SiteLink', 'iStatus' => '1' })
                        )
                    )
            );

            Test.startTest();
            SiteLinkController.SyncStatus status = SiteLinkController.refreshFromSiteLink(o.Id);
            Test.stopTest();

            Assert.areEqual('Synced', status.status);
            Account acc = [SELECT Tenant_First_Name__c, Tenant_Email__c FROM Account];
            Assert.areEqual('Janet', acc.Tenant_First_Name__c);
            Assert.areEqual('janet@example.com', acc.Tenant_Email__c);
            Opportunity saved = [SELECT Description, SiteLink_Reservation_Status__c FROM Opportunity];
            Assert.areEqual('Changed in SiteLink', saved.Description);
            Assert.areEqual('1', saved.SiteLink_Reservation_Status__c);
        }
    }

    @IsTest
    static void accountPageWorksToo() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account acc = [SELECT Id FROM Account];
            SiteLinkTestFactory.markLinked(acc, 'Account', new Map<String, Object>{ 'SiteLink_Site__c' => [SELECT Id FROM SiteLink_Site__c].Id });
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock().reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(77, '')))
            );
            Test.startTest();
            SiteLinkController.SyncStatus status = SiteLinkController.pushToSiteLink(acc.Id);
            Test.stopTest();
            Assert.areEqual('Account', status.objectType);
            Assert.areEqual(77, status.tenantId);
            Assert.areEqual('Store L001', status.storeName);
        }
    }

    @IsTest
    static void explainsWhyItCannotRun() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLink_Setting__mdt s = SiteLinkTestFactory.configure(false);
            Opportunity o = [SELECT Id FROM Opportunity];
            Integer errors = 0;
            try {
                SiteLinkController.refreshFromSiteLink(o.Id);
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('not been sent'), e.getMessage());
                errors++;
            }
            try {
                SiteLinkController.getStatus([SELECT Id FROM SiteLink_Site__c].Id);
            } catch (AuraHandledException e) {
                errors++;
            }
            s.Active__c = false;
            try {
                SiteLinkController.pushToSiteLink(o.Id);
            } catch (AuraHandledException e) {
                Assert.isTrue(e.getMessage().contains('switched off'));
                errors++;
            }
            Assert.areEqual(3, errors, 'every call should explain itself');
        }
    }
}
