@IsTest
private class SiteLinkDiagnosticsTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
    }

    private static String table(Map<String, String> columns) {
        return SiteLinkMock.row('Table', columns);
    }

    @IsTest
    static void probeReportsEachAssumption() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock()
                .reply('SiteInformation', SiteLinkMock.dataSet('SiteInformation', table(new Map<String, String>{ 'SiteID' => '1', 'sSiteName' => 'Calgary' })))
                .reply('SiteSearchByPostalCode', SiteLinkMock.dataSet('SiteSearchByPostalCode', table(new Map<String, String>{ 'sLocationCode' => 'L001' })))
                .reply('UnitsInformation_v2', SiteLinkMock.dataSet('UnitsInformation_v2', table(new Map<String, String>{ 'UnitID' => '1' }) + table(new Map<String, String>{ 'UnitID' => '2' })))
                .reply('UnitsInformation_v2', SiteLinkMock.dataSet('UnitsInformation_v2', table(new Map<String, String>{ 'UnitID' => '2' })))
                .reply('TenantListComplete_v2', SiteLinkMock.dataSet('TenantListComplete_v2', table(new Map<String, String>{ 'TenantID' => '5', 'sFName' => 'A' })))
                .reply('ReservationList', SiteLinkMock.dataSet('ReservationList', table(new Map<String, String>{ 'WaitingID' => '9', 'TenantID' => '5' })))
                .onStatus('RentRoll', 500, SiteLinkMock.fault('Access denied to report'));
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            SiteLinkDiagnostics d = new SiteLinkDiagnostics(new SiteLinkApi());
            d.runProbe('L001');
            String report = d.finish();
            Test.stopTest();

            Assert.isTrue(report.contains('PASS Login works'), report);
            Assert.isTrue(report.contains('lists 1 store(s): L001'), report);
            Assert.isTrue(report.contains('PASS UnitsInformation_v2: lngLastTimePolled=0 -> 2 row(s)'), report);
            Assert.isTrue(report.contains('WARN TenantListComplete_v2: lngLastTimePolled=0 -> 1 row(s)'), report);
            Assert.isTrue(report.contains('mapped columns NOT returned'), report);
            Assert.isTrue(report.contains('FAIL ReservationList: key columns missing UnitID, iStatus'), report);
            Assert.isTrue(report.contains('TenantUpdate_v3:'), report);
            Assert.isTrue(report.contains('WARN RentRoll failed'), report);
        }
    }

    @IsTest
    static void probeStopsWhenLoginFails() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock().onStatus('SiteInformation', 500, SiteLinkMock.fault('Invalid login')));
            Test.startTest();
            SiteLinkDiagnostics d = new SiteLinkDiagnostics(new SiteLinkApi());
            d.runProbe('L001');
            String report = d.finish();
            Test.stopTest();
            Assert.isTrue(report.contains('FAIL Login / SiteInformation failed'), report);
        }
    }

    @IsTest
    static void roundTripCreatesReadsAndUpdates() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Map<String, String> created = new Map<String, String>{ 'TenantID' => '900', 'sFName' => 'Probe', 'sAddr1' => '1 Probe St', 'sMobile' => '4035550100' };
            Map<String, String> afterRaw = new Map<String, String>{ 'TenantID' => '900', 'sFName' => 'Probe3', 'sAddr1' => '' };
            SiteLinkMock mock = new SiteLinkMock()
                .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(900, '')))
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', table(created)))
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', table(created)))
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', table(created)))
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', table(afterRaw)))
                .reply('TenantListDetailed', SiteLinkMock.dataSet('TenantListDetailed', table(new Map<String, String>{ 'TenantID' => '900' })))
                .reply('TenantUpdate_v3', SiteLinkMock.dataSet('TenantUpdate_v3', SiteLinkMock.rt(900, '')))
                .reply('UnitsInformation_v2', SiteLinkMock.dataSet('UnitsInformation_v2', table(new Map<String, String>{ 'UnitID' => '7', 'bRented' => 'false' })))
                .reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(31, '')))
                .reply(
                    'ReservationList_v3',
                    SiteLinkMock.dataSet('ReservationList_v3', table(new Map<String, String>{ 'WaitingID' => '31', 'iStatus' => '0', 'sComment' => 'Salesforce probe 2' }))
                )
                .reply('ReservationUpdate_v4', SiteLinkMock.dataSet('ReservationUpdate_v4', SiteLinkMock.rt(31, '')));
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            SiteLinkDiagnostics d = new SiteLinkDiagnostics(new SiteLinkApi());
            d.runRoundTrip('L001', true);
            String report = d.finish();
            Test.stopTest();

            Assert.isTrue(report.contains('PASS TenantNewDetailed_v3 returned Ret_Code 900'), report);
            Assert.isTrue(report.contains('PASS Phase 1 field sFName'), report);
            Assert.isTrue(report.contains('PASS Read-modify-write update keeps sAddr1'), report);
            Assert.isTrue(report.contains('Omitted elements are CLEARED'), report);
            Assert.isTrue(report.contains('PASS ReservationNewWithSource_v5 returned Ret_Code 31 (used as WaitingID) for unit 7'), report);
            Assert.isTrue(report.contains('PASS ReservationUpdate_v4 changes sComment'), report);
        }
    }

    @IsTest
    static void roundTripReportsSiteLinkErrors() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock().reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(-3, 'Invalid region')))
            );
            Test.startTest();
            String report = SiteLinkDiagnostics.roundTrip('L001', false);
            Test.stopTest();
            Assert.isTrue(report.contains('FAIL SiteLink could not create the customer: Invalid region'), report);
        }
    }
}
