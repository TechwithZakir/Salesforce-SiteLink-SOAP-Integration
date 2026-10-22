/**
 * Test configuration and records. Tests never depend on the org's own SiteLink
 * custom metadata: configure() injects settings and the default field mappings.
 */
@IsTest
public class SiteLinkTestFactory {
    public static final String LOC = 'L001';

    /**
     * New fields have no field-level security until a permission set grants it, and DML/SOQL
     * on inaccessible fields fails. Call first in @TestSetup; create data inside runAs(me()).
     */
    public static void grantAccess() {
        Id userId = UserInfo.getUserId();
        Id permSetId = [SELECT Id FROM PermissionSet WHERE Name = 'SiteLink_Integration_Admin'].Id;
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :userId AND PermissionSetId = :permSetId] == 0) {
            System.runAs(me()) {
                insert new PermissionSetAssignment(AssigneeId = userId, PermissionSetId = permSetId);
            }
        }
    }

    public static User me() {
        return new User(Id = UserInfo.getUserId());
    }

    public static SiteLink_Setting__mdt configure(Boolean autoPush) {
        SiteLink_Setting__mdt s = new SiteLink_Setting__mdt(
            Active__c = true,
            Named_Credential__c = 'SiteLink',
            External_Credential__c = 'SiteLink',
            Corp_Code__c = 'CCTST',
            CallCenter_Path__c = '/CallCenterWs.asmx',
            Reporting_Path__c = '/ReportingWs.asmx',
            Timeout_Ms__c = 60000,
            Auto_Push__c = autoPush,
            Inbound_Enabled__c = true,
            Match_Existing_Tenants__c = true,
            Pull_Rent_Roll__c = true,
            Log_Payloads__c = true,
            Push_Batch_Size__c = 10,
            Max_Retries__c = 3,
            Retry_Base_Minutes__c = 5,
            Poll_Overlap_Minutes__c = 60,
            Log_Retention_Days__c = 30,
            Reservation_Source_Id__c = 5,
            Reservation_Source_Name__c = 'Salesforce',
            Reservation_Rental_Type_Id__c = 2,
            Reservation_Inquiry_Type__c = 0,
            Reservation_Expiry_Days__c = 7,
            Default_Opportunity_Stage__c = openStage(),
            Alert_Emails__c = 'ops@example.com'
        );
        SiteLinkConfig.settingsOverride = s;
        SiteLinkConfig.mappingsOverride = new List<SiteLink_Field_Map__mdt>{
            fieldMap('Account', 'Tenant_First_Name__c', 'sFName', 'sFName', 'Both'),
            fieldMap('Account', 'Tenant_Last_Name__c', 'sLName', 'sLName', 'Both'),
            fieldMap('Account', 'Tenant_Email__c', 'sEmail', 'sEmail', 'Both'),
            fieldMap('Account', 'Phone', 'sPhone', 'sPhone', 'Both'),
            fieldMap('Opportunity', 'SiteLink_Date_Needed__c', 'dNeeded', 'dNeeded', 'Both'),
            fieldMap('Opportunity', 'Description', 'sComment', 'sComment', 'Both'),
            fieldMap('Opportunity', 'SiteLink_Quoted_Rate__c', 'dcQuotedRate', 'dcQuotedRate', 'Both'),
            fieldMap('Opportunity', 'SiteLink_Reservation_Status__c', null, 'iStatus', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Name', null, 'sUnitName', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Unit_Type__c', null, 'sTypeName', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Width__c', null, 'dcWidth', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Standard_Rate__c', null, 'dcStdRate', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Rented__c', null, 'bRented', 'Inbound'),
            fieldMap('SiteLink_Unit__c', 'Floor__c', null, 'iFloor', 'Inbound'),
            rentRollMap(),
            fieldMap('SiteLink_Site__c', 'Name', null, 'sSiteName', 'Inbound'),
            fieldMap('SiteLink_Site__c', 'City__c', null, 'sSiteCity', 'Inbound'),
            fieldMap('SiteLink_Site__c', 'Site_Id__c', null, 'SiteID', 'Inbound')
        };
        return s;
    }

    public static SiteLink_Field_Map__mdt fieldMap(String obj, String field, String outParam, String inColumn, String direction) {
        return new SiteLink_Field_Map__mdt(
            Object__c = obj,
            Field__c = field,
            Outbound_Param__c = outParam,
            Inbound_Column__c = inColumn,
            Direction__c = direction,
            Active__c = true
        );
    }

    private static SiteLink_Field_Map__mdt rentRollMap() {
        SiteLink_Field_Map__mdt m = fieldMap('SiteLink_Unit__c', 'Current_Rent__c', null, 'dcRent', 'Inbound');
        m.Source_Operation__c = 'RentRoll';
        return m;
    }

    public static String openStage() {
        return [SELECT ApiName FROM OpportunityStage WHERE IsActive = TRUE AND IsClosed = FALSE ORDER BY SortOrder LIMIT 1].ApiName;
    }

    public static SiteLink_Site__c site(String code) {
        SiteLink_Site__c s = new SiteLink_Site__c(Name = 'Store ' + code, Location_Code__c = code, Sync_Enabled__c = true);
        insert s;
        return s;
    }

    public static SiteLink_Unit__c unit(SiteLink_Site__c site, Integer unitId) {
        SiteLink_Unit__c u = new SiteLink_Unit__c(
            Name = 'A' + unitId,
            Site__c = site.Id,
            Unit_Id__c = unitId,
            External_Key__c = site.Location_Code__c + ':' + unitId
        );
        insert u;
        return u;
    }

    public static Account customer(Id siteId) {
        Account a = new Account(
            Name = 'Jane Doe',
            Tenant_First_Name__c = 'Jane',
            Tenant_Last_Name__c = 'Doe',
            Tenant_Email__c = 'jane@example.com',
            SiteLink_Site__c = siteId
        );
        insert a;
        return a;
    }

    public static Opportunity reservation(Account acc, SiteLink_Site__c site, SiteLink_Unit__c unit) {
        Opportunity o = new Opportunity(
            Name = 'Jane - A101',
            AccountId = acc.Id,
            StageName = openStage(),
            CloseDate = Date.today().addDays(10),
            SiteLink_Site__c = site.Id,
            SiteLink_Unit__c = unit?.Id,
            SiteLink_Date_Needed__c = Date.today().addDays(10),
            Description = 'Needs ground floor',
            SiteLink_Quoted_Rate__c = 99.5
        );
        insert o;
        return o;
    }

    /** Links a record as already synced (as the integration would) without firing a push. */
    public static void markLinked(SObject record, String objectName, Map<String, Object> fields) {
        SObject row = record.getSObjectType().newSObject(record.Id);
        for (String f : fields.keySet()) {
            row.put(f, fields.get(f));
        }
        SiteLinkSyncContext.suppress();
        update row;
        SiteLinkSyncContext.release();
    }

    public static String okRt(Integer code) {
        return SiteLinkMock.rt(code, '');
    }
}
