@IsTest
private class SiteLinkFieldMapperTest {
    @TestSetup
    static void setup() {
        SiteLinkTestFactory.grantAccess();
    }

    @IsTest
    static void buildsOutboundParamsWithDefaultsAndValueMaps() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Field_Map__mdt status = SiteLinkTestFactory.fieldMap('Account', 'Industry', 'sTenNote', null, 'Outbound');
            status.Value_Map__c = 'Agriculture=Farm\nbad line\nBanking=Bank';
            SiteLink_Field_Map__mdt withDefault = SiteLinkTestFactory.fieldMap('Account', 'Fax', 'sFax', null, 'Outbound');
            withDefault.Default_Value__c = 'n/a';
            SiteLink_Field_Map__mdt inactive = SiteLinkTestFactory.fieldMap('Account', 'Website', 'sPager', null, 'Outbound');
            inactive.Active__c = false;
            SiteLinkConfig.mappingsOverride.addAll(new List<SiteLink_Field_Map__mdt>{ status, withDefault, inactive });

            Account a = new Account(Name = 'X', Tenant_First_Name__c = 'Jane', Tenant_Last_Name__c = 'Doe', Industry = 'Banking');
            Map<String, Object> params = SiteLinkFieldMapper.toParams(a, 'Account');

            Assert.areEqual('Jane', params.get('sFName'));
            Assert.areEqual('', params.get('sEmail'), 'blank values are sent as empty strings');
            Assert.areEqual('Bank', params.get('sTenNote'));
            Assert.areEqual('n/a', params.get('sFax'));
            Assert.isFalse(params.containsKey('sPager'));
            Assert.isFalse(params.containsKey('iStatus'));
        }
    }

    @IsTest
    static void appliesInboundValuesWithTypeConversion() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Unit__c u = new SiteLink_Unit__c(Name = 'old');
            Map<String, String> row = new Map<String, String>{
                'sunitname' => 'B12',
                'stypename' => 'Locker',
                'dcwidth' => '10.5000',
                'dcstdrate' => '120.00',
                'brented' => 'true',
                'ifloor' => '2'
            };
            Assert.isTrue(SiteLinkFieldMapper.applyInbound(u, row, 'SiteLink_Unit__c', null));
            Assert.areEqual('B12', u.Name);
            Assert.areEqual(10.5, u.Width__c);
            Assert.areEqual(120, u.Standard_Rate__c);
            Assert.isTrue(u.Rented__c);
            Assert.areEqual(2, u.Floor__c);
            Assert.isFalse(SiteLinkFieldMapper.applyInbound(u, row, 'SiteLink_Unit__c', null), 'same data again is not a change');

            Map<String, String> partial = new Map<String, String>{ 'brented' => '' };
            Assert.isTrue(SiteLinkFieldMapper.applyInbound(u, partial, 'SiteLink_Unit__c', null));
            Assert.isFalse(u.Rented__c, 'blank boolean becomes false');
            Assert.areEqual('B12', u.Name, 'missing columns are left alone');

            Assert.isTrue(SiteLinkFieldMapper.applyInbound(u, new Map<String, String>{ 'dcrent' => '150' }, 'SiteLink_Unit__c', 'RentRoll'));
            Assert.areEqual(150, u.Current_Rent__c);
        }
    }

    @IsTest
    static void convertsDatesAndInboundValueMaps() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            SiteLink_Field_Map__mdt stage = SiteLinkTestFactory.fieldMap('Opportunity', 'NextStep', null, 'iStatus', 'Inbound');
            stage.Value_Map__c = 'Open=0\nCancelled=2';
            SiteLinkConfig.mappingsOverride.add(stage);
            Opportunity o = new Opportunity();
            SiteLinkFieldMapper.applyInbound(o, new Map<String, String>{ 'dneeded' => '2026-05-01T00:00:00-04:00', 'istatus' => '2' }, 'Opportunity', null);
            Assert.areEqual(Date.newInstance(2026, 5, 1), o.SiteLink_Date_Needed__c);
            Assert.areEqual('Cancelled', o.NextStep);
            Assert.areEqual('2', o.SiteLink_Reservation_Status__c);

            Assert.areEqual(Datetime.newInstanceGmt(2026, 5, 1, 10, 0, 0), SiteLinkFieldMapper.parseDatetime('2026-05-01T10:00:00'));
            Assert.areEqual(Datetime.newInstanceGmt(2026, 5, 1, 14, 0, 0), SiteLinkFieldMapper.parseDatetime('2026-05-01T10:00:00-04:00'));
            Assert.areEqual(Datetime.newInstanceGmt(2026, 5, 1, 0, 0, 0), SiteLinkFieldMapper.parseDatetime('2026-05-01'));
            Assert.isNotNull(SiteLinkFieldMapper.convert('2026-05-01T10:00:00Z', SiteLinkFieldMapper.describe('Account').get('createddate')));
            Assert.areEqual(3, SiteLinkFieldMapper.convert('3.0', SiteLinkFieldMapper.describe('Account').get('numberofemployees')));
        }
    }

    @IsTest
    static void fingerprintChangesOnlyWithMappedFields() {
        System.runAs(SiteLinkTestFactory.me()) {
            SiteLinkTestFactory.configure(false);
            Account a = new Account(Name = 'X', Tenant_First_Name__c = 'Jane', Tenant_Last_Name__c = 'Doe');
            String first = SiteLinkFieldMapper.fingerprint(a, 'Account');
            a.Description = 'not mapped';
            Assert.areEqual(first, SiteLinkFieldMapper.fingerprint(a, 'Account'));
            a.Tenant_First_Name__c = 'Janet';
            Assert.areNotEqual(first, SiteLinkFieldMapper.fingerprint(a, 'Account'));
            Assert.areEqual(64, first.length());
            Assert.isTrue(SiteLinkFieldMapper.fieldsToQuery('Opportunity').contains('SiteLink_Unit__c'));
            Assert.isTrue(SiteLinkFieldMapper.inboundColumns('Account', null).contains('sfname'));
        }
    }

    @IsTest
    static void comparesValuesSensibly() {
        System.runAs(SiteLinkTestFactory.me()) {
            Assert.isTrue(SiteLinkFieldMapper.sameValue(null, ''));
            Assert.isTrue(SiteLinkFieldMapper.sameValue(10, 10.00));
            Assert.isFalse(SiteLinkFieldMapper.sameValue('a', null));
            Assert.isTrue(SiteLinkFieldMapper.sameValue('a ', 'a'));
            Assert.areEqual('x', SiteLinkFieldMapper.translate('x', null, true));
        }
    }
}
