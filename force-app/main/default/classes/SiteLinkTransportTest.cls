@IsTest
private class SiteLinkTransportTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
    }

    @IsTest
    static void parsesDataSetRowsAndReturnCode() {
        System.runAs(SiteLinkTestFactory.me()) {
            String body = SiteLinkMock.dataSet(
                'TenantListDetailed',
                SiteLinkMock.rt(1, 'ok') +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '42', 'sFName' => 'Jane', 'sMI' => null }) +
                    SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '43', 'sFName' => 'A &amp; B' })
            );
            SiteLinkResponse res = SiteLinkXmlParser.parse('TenantListDetailed', body, null);

            Assert.areEqual(1, res.retCode);
            Assert.areEqual('ok', res.retMsg);
            Assert.areEqual(2, res.rowCount());
            Assert.areEqual('Jane', res.firstRowWith('TenantID').get('sfname'));
            Assert.areEqual('', res.firstRowWith('TenantID').get('smi'), 'empty element becomes empty string');
            Assert.areEqual('A &amp; B', res.rowsWith('tenantid')[1].get('sfname'), 'entities are decoded once');
            Assert.isTrue(res.columnNames.get('Table').contains('sFName'), 'original column case kept for diagnostics');
            Assert.isNull(res.firstRowWith('NoSuchColumn'));
        }
    }

    @IsTest
    static void wantedColumnsDropsUnmappedColumns() {
        System.runAs(SiteLinkTestFactory.me()) {
            String body = SiteLinkMock.dataSet(
                'UnitsInformation_v2',
                SiteLinkMock.row('Table', new Map<String, String>{ 'UnitID' => '7', 'sUnitName' => 'A7', 'sNotes' => 'big' })
            );
            SiteLinkResponse res = SiteLinkXmlParser.parse('UnitsInformation_v2', body, new Set<String>{ 'unitid', 'sunitname' });
            Map<String, String> row = res.firstRowWith('UnitID');
            Assert.areEqual('A7', row.get('sunitname'));
            Assert.isFalse(row.containsKey('snotes'));
        }
    }

    @IsTest
    static void parsesSoapFaultAndBlankBody() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkResponse res = SiteLinkXmlParser.parse('X', SiteLinkMock.fault('Invalid login'), null);
            Assert.areEqual('Invalid login', res.faultMessage);
            Assert.areEqual(0, SiteLinkXmlParser.parse('X', '', null).rowCount());
            Assert.isNull(SiteLinkXmlParser.toInteger('abc'));
            Assert.areEqual(12, SiteLinkXmlParser.toInteger(' 12.0 '));
        }
    }

    @IsTest
    static void envelopeUsesCredentialMergeFieldsAndWsdlOrder() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock()
                .reply('TenantInfoByTenantID', SiteLinkMock.dataSet('TenantInfoByTenantID', SiteLinkMock.row('Table', new Map<String, String>{ 'TenantID' => '9' })));
            Test.setMock(HttpCalloutMock.class, mock);

            Test.startTest();
            Map<String, String> row = new SiteLinkApi().getTenant('L001', 9);
            Test.stopTest();

            Assert.areEqual('9', row.get('tenantid'));
            HttpRequest req = mock.requests[0];
            Assert.areEqual('callout:SiteLink/CallCenterWs.asmx', req.getEndpoint());
            Assert.areEqual('"http://tempuri.org/CallCenterWs/CallCenterWs/TenantInfoByTenantID"', req.getHeader('SOAPAction'));
            String body = req.getBody();
            Assert.isTrue(body.contains('<sCorpUserName>{!HTMLENCODE($Credential.SiteLink.CorpUserName)}</sCorpUserName>'), body);
            Assert.isTrue(body.contains('<sCorpPassword>{!HTMLENCODE($Credential.SiteLink.CorpPassword)}</sCorpPassword>'), body);
            Assert.isTrue(body.indexOf('<sCorpCode>CCTST</sCorpCode>') < body.indexOf('<sLocationCode>L001</sLocationCode>'));
            Assert.isTrue(body.contains('<iTenantID>9</iTenantID>'));
            SiteLinkLogger.flush();
            Assert.areEqual(1, [SELECT COUNT() FROM SiteLink_Sync_Log__c WHERE Operation__c = 'TenantInfoByTenantID' AND Status__c = 'Success']);
        }
    }

    @IsTest
    static void reportingOperationsGoToReportingService() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock();
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            new SiteLinkApi().tenantsSince('L001', null, null);
            new SiteLinkApi().rentRoll('L001', Date.newInstance(2026, 1, 2), Date.newInstance(2026, 1, 3), null);
            Test.stopTest();
            Assert.areEqual('callout:SiteLink/ReportingWs.asmx', mock.requests[0].getEndpoint());
            Assert.isTrue(mock.requests[0].getBody().contains('<lngLastTimePolled>0</lngLastTimePolled>'));
            Assert.isTrue(mock.requests[1].getBody().contains('<dReportDateStart>2026-01-02T00:00:00</dReportDateStart>'));
        }
    }

    @IsTest
    static void formatsValuesByXsdType() {
        System.runAs(SiteLinkTestFactory.me()) {
            Assert.areEqual('a &amp; &lt;b&gt;', SiteLinkSoapClient.formatValue('string', 'a & <b>'));
            Assert.areEqual('true', SiteLinkSoapClient.formatValue('boolean', true));
            Assert.areEqual('12', SiteLinkSoapClient.formatValue('int', 12.0));
            Assert.areEqual('12.50', SiteLinkSoapClient.formatValue('decimal', 12.50));
            Assert.areEqual('2026-03-04T00:00:00', SiteLinkSoapClient.formatValue('dateTime', Date.newInstance(2026, 3, 4)));
            Assert.areEqual(
                Datetime.newInstance(2026, 3, 4, 5, 6, 7).format('yyyy-MM-dd\'T\'HH:mm:ss'),
                SiteLinkSoapClient.formatValue('dateTime', Datetime.newInstance(2026, 3, 4, 5, 6, 7))
            );
            Assert.areEqual('7', SiteLinkSoapClient.formatValue('int', ' 7 '));
            Assert.areEqual('5', SiteLinkSoapClient.formatValue('long', 5L));
        }
    }

    @IsTest
    static void blankNonStringParamsAreOmitted() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLinkMock mock = new SiteLinkMock().reply('ReservationNewWithSource_v5', SiteLinkMock.dataSet('ReservationNewWithSource_v5', SiteLinkMock.rt(77, '')));
            Test.setMock(HttpCalloutMock.class, mock);
            Test.startTest();
            Integer id = new SiteLinkApi().createReservation('L001', new Map<String, Object>{ 'dcQuotedRate' => '', 'sComment' => 'x' });
            Test.stopTest();
            Assert.areEqual(77, id);
            String body = mock.lastBody('ReservationNewWithSource_v5');
            Assert.isFalse(body.contains('dcQuotedRate'), body);
            Assert.isTrue(body.contains('<sComment>x</sComment>'));
            Assert.isTrue(body.contains('<sTrackingCode></sTrackingCode>'));
        }
    }

    @IsTest
    static void loginFaultIsNotRetryable() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(HttpCalloutMock.class, new SiteLinkMock().onStatus('SiteInformation', 500, SiteLinkMock.fault('Invalid corporate login')));
            SiteLinkException caught;
            Test.startTest();
            try {
                new SiteLinkApi().siteInformation('L001');
            } catch (SiteLinkException e) {
                caught = e;
            }
            Test.stopTest();
            Assert.isNotNull(caught);
            Assert.isFalse(caught.isRetryable);
            Assert.isTrue(caught.getMessage().contains('rejected the integration login'), caught.getMessage());
        }
    }

    @IsTest
    static void transientFailuresAreRetryable() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .onStatus('SiteInformation', 503, 'Service Unavailable')
                    .onTimeout('UnitsInformation_v2')
                    .reply('ReservationList', 'not xml <<<')
                    .onStatus('SiteSearchByPostalCode', 500, SiteLinkMock.fault('Location code XYZ not found'))
            );
            List<SiteLinkException> errors = new List<SiteLinkException>();
            Test.startTest();
            SiteLinkApi api = new SiteLinkApi();
            try {
                api.siteInformation('L001');
            } catch (SiteLinkException e) {
                errors.add(e);
            }
            try {
                api.unitsSince('L001', '123', null);
            } catch (SiteLinkException e) {
                errors.add(e);
            }
            try {
                api.listReservations('L001', null);
            } catch (SiteLinkException e) {
                errors.add(e);
            }
            try {
                api.searchSites();
            } catch (SiteLinkException e) {
                errors.add(e);
            }
            Test.stopTest();
            Assert.areEqual(4, errors.size());
            Assert.isTrue(errors[0].isRetryable, 'HTTP 503');
            Assert.isTrue(errors[1].isRetryable, 'timeout');
            Assert.isTrue(errors[1].getMessage().contains('too long'));
            Assert.isTrue(errors[2].isRetryable, 'unreadable reply');
            Assert.isFalse(errors[3].isRetryable, 'bad location');
        }
    }

    @IsTest
    static void retCodeErrorsAndListSemantics() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Test.setMock(
                HttpCalloutMock.class,
                new SiteLinkMock()
                    .reply('TenantNewDetailed_v3', SiteLinkMock.dataSet('TenantNewDetailed_v3', SiteLinkMock.rt(-2, 'Duplicate tenant')))
                    .reply('TenantListDetailed', SiteLinkMock.dataSet('TenantListDetailed', SiteLinkMock.rt(-1, 'No tenants found')))
                    .reply('UnitsInformation_v2', SiteLinkMock.dataSet('UnitsInformation_v2', SiteLinkMock.rt(-5, 'Invalid location')))
                    .reply('SiteInformation', SiteLinkMock.dataSet('SiteInformation', ''))
            );
            Test.startTest();
            SiteLinkApi api = new SiteLinkApi();
            try {
                api.createTenant('L001', new Map<String, Object>());
                Assert.fail('expected error');
            } catch (SiteLinkException e) {
                Assert.isTrue(e.getMessage().contains('Duplicate tenant'));
                Assert.areEqual(-2, e.retCode);
            }
            Assert.areEqual(0, api.findTenants('L001', null, 'Doe', 'x@y.z', null).size(), 'not found is an empty list');
            try {
                api.unitsSince('L001', null, null);
                Assert.fail('expected error');
            } catch (SiteLinkException e) {
                Assert.isTrue(e.getMessage().contains('Invalid location'));
            }
            try {
                api.call('NoSuchOperation', 'L001', null, null);
                Assert.fail('expected error');
            } catch (SiteLinkException e) {
                Assert.isTrue(e.getMessage().contains('Unknown'));
            }
            try {
                // Update ops require a positive Ret_Code; an empty DataSet has none.
                api.call('SiteInformation', 'L001', null, null);
            } catch (SiteLinkException e) {
                Assert.fail('list call should not need a Ret_Code');
            }
            Test.stopTest();
            Assert.isTrue(SiteLinkApi.parameterNames('TenantUpdate_v3').contains('itenantid'));
            Assert.isFalse(SiteLinkApi.parameterNames('TenantUpdate_v3').contains('scorpcode'));
        }
    }

    @IsTest
    static void errorTranslatorCoversEveryKind() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkException setup = SiteLinkErrors.fromCalloutException('Op', new CalloutException('Unauthorized endpoint, please check Setup'));
            Assert.isFalse(setup.isRetryable);
            Assert.isTrue(setup.getMessage().contains('Named Credential'));

            SiteLinkException network = SiteLinkErrors.fromCalloutException('Op', new CalloutException('Connection reset'));
            Assert.isTrue(network.isRetryable);
            Assert.isTrue(network.getMessage().contains('could not reach'));

            SiteLinkException notFound = SiteLinkErrors.fromHttpStatus('Op', 404, 'Not Found');
            Assert.isFalse(notFound.isRetryable);
            Assert.isTrue(notFound.getMessage().contains('404'));
            Assert.isTrue(SiteLinkErrors.fromHttpStatus('Op', 429, 'Too Many').isRetryable);

            SiteLinkException busy = SiteLinkErrors.fromFault('Op', 'L001', 'Server busy, try again');
            Assert.isTrue(busy.isRetryable);
            Assert.isTrue(busy.getMessage().startsWith('SiteLink reported a problem'));

            SiteLinkException noMsg = SiteLinkErrors.fromRetCode('Op', 'create the customer', -9, null);
            Assert.areEqual('SiteLink could not create the customer: it returned error code -9', noMsg.getMessage());
            Assert.areEqual(-9, noMsg.retCode);
            Assert.isTrue(SiteLinkErrors.fromRetCode('Op', 'x', -1, 'Database deadlock').isRetryable);
        }
    }

    @IsTest
    static void missingSettingsGiveAPlainMessage() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkConfig.resetCache();
            SiteLinkConfig.settingsOverride = null;
            // Either the org has a Default record (deployed with the package) or a clear error is thrown.
            try {
                SiteLinkConfig.settings();
            } catch (SiteLinkException e) {
                Assert.isTrue(e.getMessage().contains('not set up'));
            }
            Assert.areEqual(5, SiteLinkConfig.intSetting(null, 5));
            Assert.areEqual('x', SiteLinkConfig.strSetting(' ', 'x'));
        }
    }

    @IsTest
    static void loggerTruncatesAndRespectsPayloadSetting() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLink_Setting__mdt s = SiteLinkTestFactory.configure(false);
            s.Log_Payloads__c = false;
            SiteLink_Sync_Log__c row = SiteLinkLogger.logCall('Op', 'L001', 'Success', 'm', 'req', 'res', 5, '1');
            Assert.isNull(row.Request__c);
            Assert.areEqual('ab', SiteLinkLogger.truncate('abc', 2));
            SiteLinkLogger.flush();
            Assert.areEqual(1, [SELECT COUNT() FROM SiteLink_Sync_Log__c]);
            SiteLinkLogger.flush(); // no-op when empty
        }
    }
}
