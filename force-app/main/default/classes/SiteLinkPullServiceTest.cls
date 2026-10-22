@IsTest
private class SiteLinkPullServiceTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkTestFactory.site(SiteLinkTestFactory.LOC);
        }
    }

    private static SiteLinkMock storeMock() {
        return new SiteLinkMock()
            .reply(
                'SiteInformation',
                SiteLinkMock.dataSet(
                    'SiteInformation',
                    SiteLinkMock.row('Table', new Map<String, String>{ 'SiteID' => '11', 'sSiteName' => 'Calgary North', 'sSiteCity' => 'Calgary' })
                )
            )
            .reply(
                'UnitsInformation_v2',
                SiteLinkMock.dataSet(
                    'UnitsInformation_v2',
                    SiteLinkMock.row(
                        'Table',
                        new Map<String, String>{ 'UnitID' => '2001', 'sUnitName' => 'A101', 'dcWidth' => '10.0000', 'dcStdRate' => '100.0000', 'bRented' => 'false' }
                    )
                )
            )
            .reply(
                'TenantListComplete_v2',
                SiteLinkMock.dataSet(
                    'TenantListComplete_v2',
                    SiteLinkMock.row(
                        'Table',
                        new Map<String, String>{ 'TenantID' => '101', 'sFName' => 'Jane', 'sLName' => 'Doe', 'sEmail' => 'jane@example.com' }
                    )
                )
            )
            .reply(
                'ReservationList',
                SiteLinkMock.dataSet(
                    'ReservationList',
                    SiteLinkMock.row(
                        'Table',
                        new Map<String, String>{
                            'WaitingID' => '555',
                            'TenantID' => '101',
                            'UnitID' => '2001',
                            'dNeeded' => '2026-11-01T00:00:00',
                            'sComment' => 'From SiteLink',
                            'iStatus' => '0'
                        }
                    ) +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'WaitingID' => '556', 'TenantID' => '999', 'UnitID' => '2001' }) +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'WaitingID' => '557', 'TenantID' => '888' })
                )
            )
            .reply(
                'TenantInfoByTenantID',
                SiteLinkMock.dataSet(
                    'TenantInfoByTenantID',
                    SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '999', 'sFName' => '', 'sLName' => '', 'sCompany' => 'Acme Ltd' })
                )
            )
            .reply(
                'RentRoll',
                SiteLinkMock.dataSet('RentRoll', SiteLinkMock.row('Table', new Map<String, String>{ 'UnitID' => '2001', 'dcRent' => '95.00' }))
            );
    }

    private static SiteLinkPullService.SiteResult pull(Boolean full) {
        return new SiteLinkPullService(new SiteLinkApi()).pullSite([SELECT Id FROM SiteLink_Site__c].Id, full);
    }

    @IsTest
    static void fullPullCreatesStoreDataUnderTheRightLocation() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, storeMock());

            Test.startTest();
            SiteLinkPullService.SiteResult result = pull(true);
            Test.stopTest();

            Assert.areEqual(0, result.errors.size(), result.summary());
            SiteLink_Site__c site = [
                SELECT Name, City__c, Site_Id__c, Tenant_Cursor__c, Unit_Cursor__c, Last_Poll_Status__c, Last_Full_Sync_At__c
                FROM SiteLink_Site__c
            ];
            Assert.areEqual('Calgary North', site.Name);
            Assert.areEqual(11, site.Site_Id__c);
            Assert.areEqual('Success', site.Last_Poll_Status__c);
            Assert.isNotNull(site.Tenant_Cursor__c);
            Assert.isNotNull(site.Unit_Cursor__c);
            Assert.isNotNull(site.Last_Full_Sync_At__c);

            SiteLink_Unit__c unit = [SELECT Name, External_Key__c, Width__c, Standard_Rate__c, Current_Rent__c, Site__c FROM SiteLink_Unit__c];
            Assert.areEqual('A101', unit.Name);
            Assert.areEqual('L001:2001', unit.External_Key__c);
            Assert.areEqual(95, unit.Current_Rent__c, 'rent roll applied');

            Account jane = [SELECT Id, Name, Tenant_First_Name__c, SiteLink_Site__c, SiteLink_Sync_Status__c FROM Account WHERE SiteLink_Tenant_Key__c = 'L001:101'];
            Assert.areEqual('Jane Doe', jane.Name);
            Assert.areEqual(site.Id, [SELECT Id FROM SiteLink_Site__c].Id);
            Assert.areEqual('Synced', jane.SiteLink_Sync_Status__c);
            Assert.areEqual('Acme Ltd', [SELECT Name FROM Account WHERE SiteLink_Tenant_Key__c = 'L001:999'].Name, 'missing tenant fetched for its reservation');

            Opportunity res = [
                SELECT AccountId, SiteLink_Unit__c, SiteLink_Site__c, SiteLink_Date_Needed__c, CloseDate, Description, SiteLink_Reservation_Status__c
                FROM Opportunity
                WHERE SiteLink_Reservation_Key__c = 'L001:555'
            ];
            Assert.areEqual(jane.Id, res.AccountId);
            Assert.areEqual(unit.Id, res.SiteLink_Unit__c);
            Assert.areEqual(Date.newInstance(2026, 11, 1), res.SiteLink_Date_Needed__c);
            Assert.areEqual(Date.newInstance(2026, 11, 1), res.CloseDate);
            Assert.areEqual('From SiteLink', res.Description);
            Assert.areEqual('0', res.SiteLink_Reservation_Status__c);
            Assert.areEqual(2, [SELECT COUNT() FROM Opportunity], '557 skipped: its customer does not exist');
        }
    }

    @IsTest
    static void unchangedDataCausesNoWritesAndNoPushBack() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, storeMock());
            // Second poll runs as the real batch at stopTest, in its own transaction
            // (callouts can't follow the first pull's DML in this one).
            Test.startTest();
            SiteLinkPullService.SiteResult first = pull(true);
            Assert.isTrue(first.units + first.tenants + first.reservations > 0, first.summary());
            SiteLinkPullBatch.run(false);
            Test.stopTest();

            SiteLink_Site__c site = [SELECT Last_Poll_Status__c, Last_Poll_Message__c FROM SiteLink_Site__c];
            Assert.areEqual('Success', site.Last_Poll_Status__c, site.Last_Poll_Message__c);
            Assert.isTrue(site.Last_Poll_Message__c.startsWith('Units 0, customers 0, reservations 0 changed'), site.Last_Poll_Message__c);
            Account jane = (Account) Database.query(
                'SELECT SiteLink_Sync_Hash__c, ' + String.join(new List<String>(SiteLinkFieldMapper.fieldsToQuery('Account')), ',') +
                ' FROM Account WHERE SiteLink_Tenant_Key__c = \'L001:101\''
            );
            Assert.areEqual(
                jane.SiteLink_Sync_Hash__c,
                SiteLinkFieldMapper.fingerprint(jane, 'Account'),
                'inbound data is fingerprinted, so the trigger will not push it back'
            );
        }
    }

    @IsTest
    static void localChangesWaitingToGoOutWin() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account jane = new Account(Name = 'Jane', SiteLink_Tenant_Key__c = 'L001:101', SiteLink_Tenant_Id__c = 101, Tenant_First_Name__c = 'Janet');
            insert jane;
            SiteLinkTestFactory.markLinked(
                jane,
                'Account',
                new Map<String, Object>{ 'SiteLink_Tenant_Key__c' => 'L001:101', 'SiteLink_Tenant_Id__c' => 101, 'SiteLink_Sync_Status__c' => 'Pending' }
            );
            Test.setMock(HttpCalloutMock.class, storeMock());
            Test.startTest();
            SiteLinkPullService.SiteResult result = pull(false);
            Test.stopTest();
            Assert.isTrue(result.skipped >= 1);
            Assert.areEqual('Janet', [SELECT Tenant_First_Name__c FROM Account WHERE Id = :jane.Id].Tenant_First_Name__c);
        }
    }

    @IsTest
    static void oneFailedCallDoesNotStopTheRest() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = storeMock();
            mock.responses.remove('UnitsInformation_v2');
            mock.onTimeout('UnitsInformation_v2');
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            SiteLinkPullService.SiteResult result = pull(false);
            Test.stopTest();

            Assert.areEqual(1, result.errors.size());
            SiteLink_Site__c site = [SELECT Last_Poll_Status__c, Unit_Cursor__c, Tenant_Cursor__c FROM SiteLink_Site__c];
            Assert.areEqual('Partial', site.Last_Poll_Status__c);
            Assert.isNull(site.Unit_Cursor__c, 'cursor only advances when the call worked');
            Assert.isNotNull(site.Tenant_Cursor__c);
            Assert.areEqual(1, [SELECT COUNT() FROM Account WHERE SiteLink_Tenant_Key__c = 'L001:101']);
        }
    }

    @IsTest
    static void ticksMatchDotNetEpoch() {
        System.runAs(SiteLinkTestFactory.me()) {
            Assert.areEqual('621355968000000000', SiteLinkPullService.toTicks(Datetime.newInstanceGmt(1970, 1, 1, 0, 0, 0)));
            Assert.isNull(SiteLinkPullService.key('L001', ''));
            Assert.areEqual('L001:5', SiteLinkPullService.key('l001', '5'));
        }
    }
}
