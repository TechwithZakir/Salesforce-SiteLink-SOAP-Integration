/**
 * Typed facade over the SiteLink operations this integration uses.
 *
 * Parameter lists are copied in WSDL order from
 *   https://www.smdservers.net/ccws_3.5/CallCenterWs.asmx?WSDL
 *   https://www.smdservers.net/ccws_3.5/ReportingWs.asmx?WSDL
 * Unannotated parameters are xsd:string. Elements whose value is null are omitted.
 *
 * TenantUpdate_v3 and ReservationUpdate_v4 replace every field, so updates read the
 * current SiteLink row first and only overlay the mapped values (read-modify-write).
 */
public inherited sharing class SiteLinkApi {
    private static final String AUTH = 'sCorpCode,sLocationCode,sCorpUserName,sCorpPassword,';
    private static final String TENANT_FIELDS =
        'sWebPassword,sMrMrs,sFName,sMI,sLName,sCompany,sAddr1,sAddr2,sCity,sRegion,sPostalCode,sCountry,sPhone,' +
        'sMrMrsAlt,sFNameAlt,sMIAlt,sLNameAlt,sAddr1Alt,sAddr2Alt,sCityAlt,sRegionAlt,sPostalCodeAlt,sCountryAlt,sPhoneAlt,' +
        'sMrMrsBus,sFNameBus,sMIBus,sLNameBus,sCompanyBus,sAddr1Bus,sAddr2Bus,sCityBus,sRegionBus,sPostalCodeBus,sCountryBus,sPhoneBus,' +
        'sFax,sEmail,sPager,sMobile,bCommercial:boolean,bCompanyIsTenant:boolean,dDOB:dateTime,sTenNote,sLicense,sLicRegion,sSSN';

    public static final Map<String, String> SIGNATURES = new Map<String, String>{
        'TenantListDetailed' => AUTH +
        'sTenantFirstName,sTenantLastName,sAddressLine1,sAddressLine2,sCity,sState,sZipCode,sEmailAddress,sPhoneNumber',
        'TenantInfoByTenantID' => AUTH + 'iTenantID:int',
        'TenantNewDetailed_v3' => AUTH +
        TENANT_FIELDS +
        ',sGateCode,sEmailAlt,sRelationshipAlt,sTaxID,bSMSOptIn:boolean,sCountryCode',
        'TenantUpdate_v3' => AUTH +
        'iTenantID:int,sGateCode,' +
        TENANT_FIELDS +
        ',sEmailAlt,sRelationshipAlt,sTaxID,bSMSOptIn:boolean,sCountryCode',
        'ReservationNewWithSource_v5' => AUTH +
        'sTenantID,sUnitID,dNeeded:dateTime,sComment,iSource:int,sSource,QTRentalTypeID:int,iInquiryType:int,' +
        'dcQuotedRate:decimal,dExpires:dateTime,dFollowUp:dateTime,sTrackingCode,sCallerID,ConcessionID:int',
        'ReservationUpdate_v4' => AUTH +
        'WaitingID:int,sTenantID,sUnitID,dNeeded:dateTime,sComment,iStatus:int,bFollowup:boolean,dFollowup:dateTime,' +
        'dFollowupLast:dateTime,iInquiryType:int,dcQuotedRate:decimal,dExpires:dateTime,QTRentalTypeID:int,' +
        'QTCancellationTypeID:int,sCancellationReason,ConcessionID:int',
        'ReservationList' => AUTH + 'iGlobalWaitingNum:int',
        'ReservationList_v3' => AUTH + 'iGlobalWaitingNum:int,WaitingID:int',
        'UnitsInformation_v2' => AUTH + 'lngLastTimePolled',
        'SiteInformation' => AUTH.removeEnd(','),
        'SiteSearchByPostalCode' => 'sCorpCode,sCorpUserName,sCorpPassword,sPostalCode,iCountry:int,bMiles:boolean',
        'TenantListComplete_v2' => AUTH + 'lngLastTimePolled:long',
        'RentRoll' => AUTH + 'dReportDateStart:dateTime,dReportDateEnd:dateTime'
    };

    private static final Set<String> REPORTING_OPERATIONS = new Set<String>{ 'TenantListComplete_v2', 'RentRoll' };

    /** Never echoed back on read-modify-write: SiteLink may return them masked or not at all. */
    private static final Set<String> NEVER_ECHO = new Set<String>{ 'swebpassword', 'sssn', 'sgatecode' };

    private SiteLinkSoapClient client;

    public SiteLinkApi() {
        this(new SiteLinkSoapClient());
    }

    public SiteLinkApi(SiteLinkSoapClient client) {
        this.client = client;
    }

    // ------------------------------------------------------------------ tenants

    /** TenantListDetailed. Blank criteria are sent as empty strings (match anything). */
    public List<Map<String, String>> findTenants(String locationCode, String firstName, String lastName, String email, String phone) {
        Map<String, Object> values = new Map<String, Object>{
            'sTenantFirstName' => nz(firstName),
            'sTenantLastName' => nz(lastName),
            'sAddressLine1' => '',
            'sAddressLine2' => '',
            'sCity' => '',
            'sState' => '',
            'sZipCode' => '',
            'sEmailAddress' => nz(email),
            'sPhoneNumber' => nz(phone)
        };
        SiteLinkResponse res = call('TenantListDetailed', locationCode, values, null);
        checkList(res, 'look up customers');
        return res.rowsWith('TenantID');
    }

    public Map<String, String> getTenant(String locationCode, Integer tenantId) {
        SiteLinkResponse res = call('TenantInfoByTenantID', locationCode, new Map<String, Object>{ 'iTenantID' => tenantId }, null);
        checkList(res, 'read customer ' + tenantId);
        return matchingRow(res.rowsWith('TenantID'), 'tenantid', tenantId);
    }

    /** TenantNewDetailed_v3. Unmapped text fields go as empty strings, as the reference PHP client does. Returns the new TenantID. */
    public Integer createTenant(String locationCode, Map<String, Object> mappedValues) {
        Map<String, Object> values = blankStrings('TenantNewDetailed_v3');
        values.put('bcommercial', false);
        values.put('bcompanyistenant', false);
        values.put('bsmsoptin', false);
        values.putAll(lowerKeys(mappedValues));
        SiteLinkResponse res = call('TenantNewDetailed_v3', locationCode, values, null);
        return requireId(res, 'create the customer');
    }

    public void updateTenant(String locationCode, Integer tenantId, Map<String, Object> mappedValues) {
        Map<String, String> current = getTenant(locationCode, tenantId);
        if (current == null) {
            throw new SiteLinkException(
                    'SiteLink has no customer with tenant ID ' + tenantId + ' at store ' + locationCode + '. It may have been deleted or merged in SiteLink.'
                )
                .retryable(false);
        }
        Map<String, Object> values = echoCurrent('TenantUpdate_v3', current);
        values.putAll(lowerKeys(mappedValues));
        values.put('itenantid', tenantId);
        SiteLinkResponse res = call('TenantUpdate_v3', locationCode, values, null);
        requireId(res, 'update the customer');
    }

    // ------------------------------------------------------------- reservations

    /** ReservationNewWithSource_v5. Returns the new WaitingID. */
    public Integer createReservation(String locationCode, Map<String, Object> values) {
        Map<String, Object> all = new Map<String, Object>{ 'scomment' => '', 'ssource' => '', 'strackingcode' => '', 'scallerid' => '' };
        all.putAll(lowerKeys(values));
        SiteLinkResponse res = call('ReservationNewWithSource_v5', locationCode, all, null);
        return requireId(res, 'create the reservation');
    }

    public Map<String, String> getReservation(String locationCode, Integer waitingId) {
        SiteLinkResponse res = call(
            'ReservationList_v3',
            locationCode,
            new Map<String, Object>{ 'iGlobalWaitingNum' => 0, 'WaitingID' => waitingId },
            null
        );
        checkList(res, 'read reservation ' + waitingId);
        return matchingRow(res.rowsWith('WaitingID'), 'waitingid', waitingId);
    }

    public void updateReservation(String locationCode, Integer waitingId, Map<String, Object> mappedValues) {
        Map<String, String> current = getReservation(locationCode, waitingId);
        if (current == null) {
            throw new SiteLinkException(
                    'SiteLink has no reservation ' + waitingId + ' at store ' + locationCode + '. It may have been cancelled or converted to a move-in.'
                )
                .retryable(false);
        }
        if (String.isBlank(current.get('istatus'))) {
            // ReservationUpdate_v4 requires iStatus; sending a default could silently cancel or reopen it.
            throw new SiteLinkException(
                    'SiteLink did not return the reservation\'s current status, so the update was stopped to avoid changing it by mistake.'
                )
                .retryable(false);
        }
        Map<String, Object> values = echoCurrent('ReservationUpdate_v4', current);
        values.putAll(lowerKeys(mappedValues));
        values.put('waitingid', waitingId);
        SiteLinkResponse res = call('ReservationUpdate_v4', locationCode, values, null);
        requireId(res, 'update the reservation');
    }

    /** ReservationList with iGlobalWaitingNum = 0 (all reservations at the store). */
    public SiteLinkResponse listReservations(String locationCode, Set<String> wantedColumns) {
        SiteLinkResponse res = call('ReservationList', locationCode, new Map<String, Object>{ 'iGlobalWaitingNum' => 0 }, wantedColumns);
        checkList(res, 'list reservations');
        return res;
    }

    // ------------------------------------------------------ units, sites, reports

    public SiteLinkResponse unitsSince(String locationCode, String cursor, Set<String> wantedColumns) {
        SiteLinkResponse res = call(
            'UnitsInformation_v2',
            locationCode,
            new Map<String, Object>{ 'lngLastTimePolled' => String.isBlank(cursor) ? '0' : cursor },
            wantedColumns
        );
        checkList(res, 'list units');
        return res;
    }

    public SiteLinkResponse tenantsSince(String locationCode, String cursor, Set<String> wantedColumns) {
        SiteLinkResponse res = call(
            'TenantListComplete_v2',
            locationCode,
            new Map<String, Object>{ 'lngLastTimePolled' => String.isBlank(cursor) ? '0' : cursor },
            wantedColumns
        );
        checkList(res, 'list customers');
        return res;
    }

    public SiteLinkResponse siteInformation(String locationCode) {
        SiteLinkResponse res = call('SiteInformation', locationCode, new Map<String, Object>(), null);
        checkList(res, 'read store details');
        return res;
    }

    /** SiteSearchByPostalCode with no postal code and iCountry -999 returns every site in the corp (as in the PHP reference). */
    public SiteLinkResponse searchSites() {
        SiteLinkResponse res = call(
            'SiteSearchByPostalCode',
            null,
            new Map<String, Object>{ 'sPostalCode' => '', 'iCountry' => -999, 'bMiles' => false },
            null
        );
        checkList(res, 'list store locations');
        return res;
    }

    public SiteLinkResponse rentRoll(String locationCode, Date startDate, Date endDate, Set<String> wantedColumns) {
        SiteLinkResponse res = call(
            'RentRoll',
            locationCode,
            new Map<String, Object>{ 'dReportDateStart' => startDate, 'dReportDateEnd' => endDate },
            wantedColumns
        );
        checkList(res, 'run the rent roll');
        return res;
    }

    // ------------------------------------------------------------------ plumbing

    /** Builds the parameter list in WSDL order. Value keys are matched case-insensitively. */
    public SiteLinkResponse call(String operation, String locationCode, Map<String, Object> values, Set<String> wantedColumns) {
        String signature = SIGNATURES.get(operation);
        if (signature == null) {
            throw new SiteLinkException('Unknown SiteLink operation ' + operation);
        }
        Map<String, Object> byLower = lowerKeys(values);
        List<SiteLinkSoapClient.Param> params = new List<SiteLinkSoapClient.Param>();
        for (String entry : signature.split(',')) {
            String name = entry.substringBefore(':');
            String xsdType = entry.contains(':') ? entry.substringAfter(':') : 'string';
            SiteLinkSoapClient.Param p = new SiteLinkSoapClient.Param(name, xsdType, null);
            if (name == 'sCorpCode') {
                p.value = nz(SiteLinkConfig.settings().Corp_Code__c);
            } else if (name == 'sLocationCode') {
                p.value = nz(locationCode);
            } else if (name == 'sCorpUserName') {
                p.value = SiteLinkSoapClient.credentialToken('CorpUserName');
                p.raw = true;
            } else if (name == 'sCorpPassword') {
                p.value = SiteLinkSoapClient.credentialToken('CorpPassword');
                p.raw = true;
            } else {
                p.value = byLower.get(name.toLowerCase());
                // An empty element for an int/decimal/dateTime/boolean fails .NET deserialization.
                if (xsdType != 'string' && p.value instanceof String && String.isBlank((String) p.value)) {
                    p.value = null;
                }
            }
            params.add(p);
        }
        SiteLinkSoapClient.Service svc = REPORTING_OPERATIONS.contains(operation)
            ? SiteLinkSoapClient.Service.REPORTING
            : SiteLinkSoapClient.Service.CALL_CENTER;
        return client.send(svc, operation, locationCode, params, wantedColumns);
    }

    /** Lower-cased names of an operation's business (non-auth) parameters. */
    public static Set<String> parameterNames(String operation) {
        Set<String> names = new Set<String>();
        for (String entry : SIGNATURES.get(operation).split(',')) {
            String name = entry.substringBefore(':').toLowerCase();
            if (!name.startsWith('scorp') && name != 'slocationcode') {
                names.add(name);
            }
        }
        return names;
    }

    private static Map<String, Object> blankStrings(String operation) {
        Map<String, Object> values = new Map<String, Object>();
        for (String entry : SIGNATURES.get(operation).split(',')) {
            if (!entry.contains(':')) {
                values.put(entry.toLowerCase(), '');
            }
        }
        return values;
    }

    /** Current SiteLink values for every parameter of the operation that SiteLink returned a column for. */
    private static Map<String, Object> echoCurrent(String operation, Map<String, String> current) {
        Map<String, Object> values = new Map<String, Object>();
        for (String name : parameterNames(operation)) {
            if (NEVER_ECHO.contains(name) || !current.containsKey(name)) {
                continue;
            }
            String value = current.get(name);
            Boolean isString = name.startsWith('s');
            if (isString || String.isNotBlank(value)) {
                values.put(name, value);
            }
        }
        return values;
    }

    private static Map<String, String> matchingRow(List<Map<String, String>> rows, String idColumn, Integer id) {
        for (Map<String, String> row : rows) {
            if (SiteLinkXmlParser.toInteger(row.get(idColumn)) == id) {
                return row;
            }
        }
        return null;
    }

    private static Integer requireId(SiteLinkResponse res, String action) {
        if (res.retCode == null) {
            throw new SiteLinkException('SiteLink did not confirm the request to ' + action + '. Ask your admin to check the integration log.')
                .retryable(false)
                .detail(res.operation + ' returned no RT/Ret_Code');
        }
        if (res.retCode <= 0) {
            throw SiteLinkErrors.fromRetCode(res.operation, action, res.retCode, res.retMsg);
        }
        return res.retCode;
    }

    /**
     * List calls: a negative Ret_Code with no rows usually just means "nothing found",
     * unless the message is about the login, which must not be swallowed.
     */
    private static void checkList(SiteLinkResponse res, String action) {
        if (res.retCode == null || res.retCode >= 0) {
            return;
        }
        String msg = res.retMsg == null ? '' : res.retMsg.toLowerCase();
        if (msg.contains('login') || msg.contains('password') || msg.contains('corp') || msg.contains('location') || res.rowCount() > 0) {
            throw SiteLinkErrors.fromRetCode(res.operation, action, res.retCode, res.retMsg);
        }
    }

    private static Map<String, Object> lowerKeys(Map<String, Object> values) {
        Map<String, Object> result = new Map<String, Object>();
        if (values != null) {
            for (String k : values.keySet()) {
                result.put(k.toLowerCase(), values.get(k));
            }
        }
        return result;
    }

    private static String nz(String value) {
        return value == null ? '' : value;
    }
}
