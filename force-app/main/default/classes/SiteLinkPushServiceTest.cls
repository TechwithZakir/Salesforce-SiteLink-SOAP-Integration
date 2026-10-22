@IsTest
private class SiteLinkPushServiceTest {
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

    private static Opportunity opp() {
        return [SELECT Id, AccountId FROM Opportunity LIMIT 1];
    }

    private static SiteLinkPushService.Outcome push(Set<Id> oppIds, Set<Id> accIds, Boolean force) {
        SiteLinkPushService.Outcome out = new SiteLinkPushService(new SiteLinkApi(), force).push(oppIds, accIds);
        SiteLinkPushService.commitOutcome(out);
        return out;
    }

    @IsTest
    static void createsTenantThenReservation() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock()
                .reply('TenantListDetailed', SiteLinkMock.dataSet('TenantListDetailed', SiteLinkMock.rt(-1, 'No tenants found')))
                .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(101, '')))
                .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(555, '')));
            Test.setMock(HttpCalloutMock.class, mock);
            Opportunity o = opp();

            Test.startTest();
            SiteLinkPushService.Outcome out = push(new Set<Id>{ o.Id }, null, false);
            Test.stopTest();

            Assert.isTrue(out.results.get(o.Id).success, out.results.get(o.Id).message);
            Opportunity saved = [
                SELECT SiteLink_Reservation_Id__c, SiteLink_Reservation_Key__c, SiteLink_Sync_Status__c, SiteLink_Sync_Hash__c, SiteLink_Last_Synced__c
                FROM Opportunity
                WHERE Id = :o.Id
            ];
            Assert.areEqual(555, saved.SiteLink_Reservation_Id__c);
            Assert.areEqual('L001:555', saved.SiteLink_Reservation_Key__c);
            Assert.areEqual('Synced', saved.SiteLink_Sync_Status__c);
            Assert.isNotNull(saved.SiteLink_Sync_Hash__c);
            Account acc = [SELECT SiteLink_Tenant_Id__c, SiteLink_Tenant_Key__c, SiteLink_Site__c, SiteLink_Sync_Status__c FROM Account WHERE Id = :o.AccountId];
            Assert.areEqual(101, acc.SiteLink_Tenant_Id__c);
            Assert.areEqual('L001:101', acc.SiteLink_Tenant_Key__c);
            Assert.isNotNull(acc.SiteLink_Site__c, 'customer is linked to the opportunity\'s store');
            Assert.areEqual('Synced', acc.SiteLink_Sync_Status__c);

            String tenantBody = mock.lastBody('TenantNewDetailed_v3');
            Assert.isTrue(tenantBody.contains('<sFName>Jane</sFName>'));
            Assert.isTrue(tenantBody.contains('<sEmail>jane@example.com</sEmail>'));
            Assert.isTrue(tenantBody.contains('<bCommercial>false</bCommercial>'));
            Assert.isTrue(tenantBody.contains('<sMobile></sMobile>'));
            Assert.isFalse(tenantBody.contains('<dDOB>'), 'unmapped dates are omitted');
            String resBody = mock.lastBody('ReservationNewWithSource_v5');
            Assert.isTrue(resBody.contains('<sTenantID>101</sTenantID>'), resBody);
            Assert.isTrue(resBody.contains('<sUnitID>2001</sUnitID>'));
            Assert.isTrue(resBody.contains('<iSource>5</iSource>'));
            Assert.isTrue(resBody.contains('<QTRentalTypeID>2</QTRentalTypeID>'));
            Assert.isTrue(resBody.contains('<dcQuotedRate>99.50</dcQuotedRate>') || resBody.contains('<dcQuotedRate>99.5</dcQuotedRate>'));
            Assert.isTrue(resBody.contains('<sComment>Needs ground floor</sComment>'));
        }
    }

    @IsTest
    static void linksExistingTenantInsteadOfCreatingDuplicate() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock()
                .reply(
                    'TenantListDetailed',
                    SiteLinkMock.dataSet(
                        'TenantListDetailed',
                        SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '300', 'sEmail' => 'JANE@example.com', 'sLName' => 'Doe' })
                    )
                )
                .reply(
                    'TenantInfoByTenantID',
                    SiteLinkMock.dataSet(
                        'TenantInfoByTenantID',
                        SiteLinkMock.row(
                            'Table',
                            new Map<String, String>{
                                'TenantID' => '300',
                                'sFName' => 'J',
                                'sLName' => 'Doe',
                                'sAddr1' => '1 Main St',
                                'sSSN' => '***-**-1234',
                                'bCommercial' => 'false',
                                'dDOB' => '1980-01-01T00:00:00'
                            }
                        )
                    )
                )
                .reply('TenantUpdate_v3', SiteLinkMock.dataSet('TenantUpdate_v3', SiteLinkMock.rt(300, '')))
                .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(556, '')));
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            push(new Set<Id>{ opp().Id }, null, false);
            Test.stopTest();

            Assert.areEqual(0, mock.count('TenantNewDetailed_v3'));
            String body = mock.lastBody('TenantUpdate_v3');
            Assert.isTrue(body.contains('<iTenantID>300</iTenantID>'));
            Assert.isTrue(body.contains('<sFName>Jane</sFName>'), 'mapped value overlays SiteLink');
            Assert.isTrue(body.contains('<sAddr1>1 Main St</sAddr1>'), 'unmapped SiteLink value is preserved');
            Assert.isTrue(body.contains('<dDOB>1980-01-01T00:00:00</dDOB>'));
            Assert.isFalse(body.contains('sSSN'), 'masked values are never written back');
            Assert.areEqual(300, [SELECT SiteLink_Tenant_Id__c FROM Account].SiteLink_Tenant_Id__c);
        }
    }

    @IsTest
    static void ambiguousMatchStopsAndAlerts() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply(
                        'TenantListDetailed',
                        SiteLinkMock.dataSet(
                            'TenantListDetailed',
                            SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '1', 'sEmail' => 'jane@example.com' }) +
                            SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '2', 'sEmail' => 'jane@example.com' })
                        )
                    )
            );
            Test.startTest();
            push(new Set<Id>{ opp().Id }, null, false);
            Test.stopTest();

            Account acc = [SELECT SiteLink_Sync_Status__c, SiteLink_Sync_Message__c, SiteLink_Tenant_Id__c FROM Account];
            Assert.areEqual('Failed', acc.SiteLink_Sync_Status__c);
            Assert.isTrue(acc.SiteLink_Sync_Message__c.contains('1, 2'), acc.SiteLink_Sync_Message__c);
            Assert.isNull(acc.SiteLink_Tenant_Id__c);
            Assert.areEqual('Failed', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c);
            Assert.areEqual(1, SiteLinkAlerts.sentCount);
        }
    }

    @IsTest
    static void updatesLinkedRecordsOnlyWhenChanged() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
            SiteLink_Site__c site = [SELECT Id FROM SiteLink_Site__c];
            SiteLinkTestFactory.markLinked(
                new Account(Id = o.AccountId),
                'Account',
                new Map<String, Object>{ 'SiteLink_Tenant_Id__c' => 101, 'SiteLink_Tenant_Key__c' => 'L001:101', 'SiteLink_Site__c' => site.Id, 'SiteLink_Sync_Hash__c' => 'stale' }
            );
            SiteLinkTestFactory.markLinked(
                o,
                'Opportunity',
                new Map<String, Object>{ 'SiteLink_Reservation_Id__c' => 555, 'SiteLink_Reservation_Key__c' => 'L001:555', 'SiteLink_Sync_Hash__c' => 'stale' }
            );
            SiteLinkMock mock = new SiteLinkMock()
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '101', 'sFName' => 'Old' })))
                .reply('TenantUpdate_v3', SiteLinkMock.dataSet('TenantUpdate_v3', SiteLinkMock.rt(101, '')))
                .reply(
                    'ReservationList_v3',
                    SiteLinkMock.dataSet(
                        'ReservationList_v3',
                        SiteLinkMock.row(
                            'Table',
                            new Map<String, String>{ 'WaitingID' => '555', 'iStatus' => '0', 'sComment' => 'old', 'QTRentalTypeID' => '2', 'ConcessionID' => '' }
                        )
                    )
                )
                .reply('ReservationUpdate_v4', SiteLinkMock.dataSet('ReservationUpdate_v4', SiteLinkMock.rt(555, '')));
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            push(new Set<Id>{ o.Id }, null, false);
            push(new Set<Id>{ o.Id }, null, false); // nothing changed since: no further updates
            Test.stopTest();

            Assert.areEqual(1, mock.count('TenantUpdate_v3'));
            Assert.areEqual(1, mock.count('ReservationUpdate_v4'));
            String body = mock.lastBody('ReservationUpdate_v4');
            Assert.isTrue(body.contains('<WaitingID>555</WaitingID>'));
            Assert.isTrue(body.contains('<iStatus>0</iStatus>'), 'current status is echoed back');
            Assert.isTrue(body.contains('<sComment>Needs ground floor</sComment>'));
            Assert.isFalse(body.contains('<ConcessionID>'), 'blank numeric column is omitted');
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c);
        }
    }

    @IsTest
    static void reservationUpdateWithoutStatusIsRefused() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
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
                    .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '101' })))
                    .reply('TenantUpdate_v3', SiteLinkMock.dataSet('TenantUpdate_v3', SiteLinkMock.rt(101, '')))
                    .reply('ReservationList_v3', SiteLinkMock.dataSet('ReservationList_v3', SiteLinkMock.row('Table', new Map<String, String>{ 'WaitingID' => '555' })))
            );
            Test.startTest();
            push(new Set<Id>{ o.Id }, null, true);
            Test.stopTest();
            Opportunity saved = [SELECT SiteLink_Sync_Status__c, SiteLink_Sync_Message__c FROM Opportunity];
            Assert.areEqual('Failed', saved.SiteLink_Sync_Status__c);
            Assert.isTrue(saved.SiteLink_Sync_Message__c.contains('current status'));
        }
    }

    @IsTest
    static void transientErrorsBackOff() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock().onStatus('TenantListDetailed', 503, 'busy'));
            Test.startTest();
            push(new Set<Id>{ opp().Id }, null, false);
            Test.stopTest();
            Opportunity saved = [SELECT SiteLink_Sync_Status__c, SiteLink_Retry_Count__c, SiteLink_Next_Attempt__c FROM Opportunity];
            Assert.areEqual('Retrying', saved.SiteLink_Sync_Status__c);
            Assert.areEqual(1, saved.SiteLink_Retry_Count__c);
            Assert.isTrue(saved.SiteLink_Next_Attempt__c > System.now().addMinutes(4));
            Assert.areEqual('Retrying', [SELECT SiteLink_Sync_Status__c FROM Account].SiteLink_Sync_Status__c);
        }
    }

    @IsTest
    static void exhaustedRetriesFailAndAlert() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
            SiteLinkTestFactory.markLinked(o, 'Opportunity', new Map<String, Object>{ 'SiteLink_Retry_Count__c' => 3 });
            SiteLinkTestFactory.markLinked(new Account(Id = o.AccountId), 'Account', new Map<String, Object>{ 'SiteLink_Retry_Count__c' => 3 });
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock().onTimeout('TenantListDetailed'));
            Test.startTest();
            push(new Set<Id>{ o.Id }, null, false);
            Test.stopTest();
            Opportunity saved = [SELECT SiteLink_Sync_Status__c, SiteLink_Next_Attempt__c, SiteLink_Sync_Message__c FROM Opportunity];
            Assert.areEqual('Failed', saved.SiteLink_Sync_Status__c);
            Assert.isNull(saved.SiteLink_Next_Attempt__c);
            Assert.isTrue(saved.SiteLink_Sync_Message__c.contains('too long'), saved.SiteLink_Sync_Message__c);
            Assert.areEqual(1, SiteLinkAlerts.sentCount);
            Assert.isTrue([SELECT COUNT() FROM SiteLink_Sync_Log__c WHERE Status__c = 'Failed'] > 0);
        }
    }

    @IsTest
    static void missingUnitSendsCustomerOnly() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
            SiteLinkTestFactory.markLinked(o, 'Opportunity', new Map<String, Object>{ 'SiteLink_Unit__c' => null });
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock().reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(101, '')))
            );
            Test.startTest();
            push(new Set<Id>{ o.Id }, null, false);
            Test.stopTest();
            String message = [SELECT SiteLink_Sync_Message__c FROM Opportunity].SiteLink_Sync_Message__c;
            Assert.isTrue(message.contains('Choose a SiteLink unit'), message);
            Assert.areEqual('Synced', [SELECT SiteLink_Sync_Status__c FROM Account].SiteLink_Sync_Status__c);
            Assert.areEqual(101, [SELECT SiteLink_Tenant_Id__c FROM Account].SiteLink_Tenant_Id__c);
        }
    }

    @IsTest
    static void customerAtAnotherStoreIsExplained() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
            SiteLink_Site__c home = [SELECT Id FROM SiteLink_Site__c];
            SiteLink_Site__c other = SiteLinkTestFactory.site('L002');
            SiteLinkTestFactory.markLinked(
                new Account(Id = o.AccountId),
                'Account',
                new Map<String, Object>{ 'SiteLink_Tenant_Id__c' => 101, 'SiteLink_Site__c' => home.Id }
            );
            SiteLinkTestFactory.markLinked(o, 'Opportunity', new Map<String, Object>{ 'SiteLink_Site__c' => other.Id });
            SiteLinkMock mock = new SiteLinkMock();
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            push(new Set<Id>{ o.Id }, null, false);
            Test.stopTest();
            String message = [SELECT SiteLink_Sync_Message__c FROM Opportunity].SiteLink_Sync_Message__c;
            Assert.isTrue(message.contains('already a SiteLink tenant at store L001'), message);
            Assert.areEqual(0, mock.requests.size(), 'stopped before calling SiteLink');
        }
    }

    @IsTest
    static void missingStoreIsExplained() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Opportunity o = opp();
            SiteLinkTestFactory.markLinked(o, 'Opportunity', new Map<String, Object>{ 'SiteLink_Site__c' => null });
            Test.startTest();
            SiteLinkPushService.Outcome out = push(new Set<Id>{ o.Id }, null, false);
            Test.stopTest();
            Opportunity saved = [SELECT SiteLink_Sync_Status__c, SiteLink_Sync_Message__c FROM Opportunity];
            Assert.areEqual('Failed', saved.SiteLink_Sync_Status__c);
            Assert.isTrue(saved.SiteLink_Sync_Message__c.contains('Choose a SiteLink store'), saved.SiteLink_Sync_Message__c);
            Assert.isFalse(out.results.get(o.Id).success);
        }
    }

    @IsTest
    static void pushesAccountOnItsOwn() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock().reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(808, '')))
            );
            Account noStore = new Account(Name = 'No Store', Tenant_Last_Name__c = 'Store');
            Account noName = new Account(Name = 'No Name', SiteLink_Site__c = [SELECT Id FROM SiteLink_Site__c].Id);
            insert new List<Account>{ noStore, noName };
            Account ready = [SELECT Id FROM Account WHERE Name = 'Jane Doe'];
            SiteLinkTestFactory.markLinked(ready, 'Account', new Map<String, Object>{ 'SiteLink_Site__c' => [SELECT Id FROM SiteLink_Site__c].Id });

            Test.startTest();
            SiteLinkPushService.Outcome out = push(null, new Set<Id>{ noStore.Id, noName.Id, ready.Id }, false);
            Test.stopTest();

            Assert.isTrue(out.results.get(noStore.Id).message.contains('Choose a SiteLink store'));
            Assert.isTrue(out.results.get(noName.Id).message.contains('last name'));
            Assert.areEqual(808, out.results.get(ready.Id).tenantId);
        }
    }

    @IsTest
    static void queueableAndFinalizerKeepRecordsMoving() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(101, '')))
                    .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(555, '')))
            );
            Opportunity o = opp();
            Test.startTest();
            Assert.isNotNull(SiteLinkPushQueueable.enqueue(new Set<Id>{ o.Id }, null, 0));
            Assert.isNull(SiteLinkPushQueueable.enqueue(null, null, 0));
            Test.stopTest();
            Assert.areEqual(555, [SELECT SiteLink_Reservation_Id__c FROM Opportunity].SiteLink_Reservation_Id__c);

            SiteLinkPushFinalizer.handleFailure(new Set<Id>{ o.Id }, new Set<Id>{ o.AccountId }, 'limit exceeded', null);
            Assert.areEqual('Retrying', [SELECT SiteLink_Sync_Status__c FROM Opportunity].SiteLink_Sync_Status__c);
            Assert.areEqual('Retrying', [SELECT SiteLink_Sync_Status__c FROM Account].SiteLink_Sync_Status__c);
        }
    }
}
