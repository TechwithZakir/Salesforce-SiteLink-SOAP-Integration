/**
 * Phase 1 checks against a real SiteLink location. Run from Anonymous Apex
 * (see scripts/apex/phase1-*.apex) and read the report in the debug log.
 *
 *   probe(loc)      read-only: login, store discovery, response columns vs. field
 *                   mappings, lngLastTimePolled delta behaviour, update-safety gaps.
 *   roundTrip(loc)  WRITES to SiteLink - training location only: creates a test
 *                   tenant, reads it back, updates it, and tests whether
 *                   TenantUpdate_v3 clears fields that are left out.
 *
 * Each line starts PASS / WARN / FAIL / INFO so the result can be pasted into the
 * Phase 1 report as-is.
 */
public without sharing class SiteLinkDiagnostics {
    private List<String> lines = new List<String>();
    private SiteLinkApi api;

    @TestVisible
    private SiteLinkDiagnostics(SiteLinkApi api) {
        this.api = api;
    }

    public static String probe(String locationCode) {
        SiteLinkDiagnostics d = new SiteLinkDiagnostics(new SiteLinkApi());
        d.runProbe(locationCode);
        return d.finish();
    }

    public static String roundTrip(String locationCode, Boolean includeReservation) {
        SiteLinkDiagnostics d = new SiteLinkDiagnostics(new SiteLinkApi());
        d.runRoundTrip(locationCode, includeReservation == true);
        return d.finish();
    }

    // ------------------------------------------------------------------- probe

    @TestVisible
    private void runProbe(String loc) {
        SiteLinkLogger.currentDirection = 'Inbound';
        add('INFO', 'Probe of location ' + loc + ' at ' + System.now().formatGmt('yyyy-MM-dd HH:mm') + ' GMT');

        SiteLinkResponse site = attempt('SiteInformation', loc);
        if (site == null) {
            add('FAIL', 'Login / SiteInformation failed; nothing else can be checked. Check corp code, CorpUserName (user:::APIKey), CorpPassword.');
            return;
        }
        add('PASS', 'Login works and Named Credential merge fields resolve (SiteInformation returned ' + site.rowCount() + ' row).');
        compareColumns('SiteLink_Site__c', null, site, 'SiteInformation');

        try {
            List<Map<String, String>> sites = api.searchSites().rowsWith('sLocationCode');
            List<String> codes = new List<String>();
            for (Map<String, String> row : sites) {
                codes.add(row.get('slocationcode'));
            }
            add(sites.isEmpty() ? 'FAIL' : 'PASS', 'SiteSearchByPostalCode(\'\', -999) lists ' + sites.size() + ' store(s): ' + String.join(codes, ', '));
        } catch (SiteLinkException e) {
            add('FAIL', 'Store discovery (SiteSearchByPostalCode) failed: ' + e.getMessage());
        }

        String recent = SiteLinkPullService.toTicks(System.now().addDays(-1));
        deltaCheck('UnitsInformation_v2', loc, recent, 'SiteLink_Unit__c', 'UnitID');
        deltaCheck('TenantListComplete_v2', loc, recent, 'Account', 'TenantID');

        try {
            SiteLinkResponse reservations = api.listReservations(loc, null);
            add('INFO', 'ReservationList(iGlobalWaitingNum=0) returned ' + reservations.rowsWith('WaitingID').size() + ' reservation(s).');
            compareColumns('Opportunity', null, reservations, 'ReservationList');
            requireColumns(reservations, 'ReservationList', new List<String>{ 'WaitingID', 'TenantID', 'UnitID', 'iStatus' });
            gapsForUpdate('ReservationUpdate_v4', reservations.firstRowWith('WaitingID'));
        } catch (SiteLinkException e) {
            add('FAIL', 'ReservationList failed: ' + e.getMessage());
        }

        try {
            SiteLinkResponse roll = api.rentRoll(loc, Date.today(), Date.today(), null);
            add('INFO', 'RentRoll returned ' + roll.rowCount() + ' row(s).');
            compareColumns('SiteLink_Unit__c', 'RentRoll', roll, 'RentRoll');
        } catch (SiteLinkException e) {
            add('WARN', 'RentRoll failed (the API user may lack reporting rights): ' + e.getMessage());
        }
    }

    private SiteLinkResponse attempt(String what, String loc) {
        try {
            return api.siteInformation(loc);
        } catch (SiteLinkException e) {
            add('FAIL', what + ': ' + e.getMessage() + (e.technicalDetail == null ? '' : ' [' + e.technicalDetail + ']'));
            return null;
        }
    }

    /** lngLastTimePolled: a full pull (0) vs. "changed in the last day" should differ. */
    private void deltaCheck(String operation, String loc, String recent, String objectName, String keyColumn) {
        try {
            SiteLinkResponse full = operation == 'UnitsInformation_v2' ? api.unitsSince(loc, null, null) : api.tenantsSince(loc, null, null);
            SiteLinkResponse delta = operation == 'UnitsInformation_v2' ? api.unitsSince(loc, recent, null) : api.tenantsSince(loc, recent, null);
            Integer fullCount = full.rowsWith(keyColumn).size();
            Integer deltaCount = delta.rowsWith(keyColumn).size();
            String verdict = deltaCount < fullCount ? 'PASS' : 'WARN';
            add(
                verdict,
                operation + ': lngLastTimePolled=0 -> ' + fullCount + ' row(s); .NET ticks for 24h ago -> ' + deltaCount +
                ' row(s). ' + (verdict == 'PASS' ? 'Delta polling works with ticks.' : 'Delta did not shrink: ticks may be the wrong unit, or everything changed today. Re-check before relying on the cursor.')
            );
            compareColumns(objectName, null, full, operation);
            if (objectName == 'Account') {
                gapsForUpdate('TenantUpdate_v3', full.firstRowWith('TenantID'));
            }
        } catch (SiteLinkException e) {
            add('FAIL', operation + ' failed: ' + e.getMessage());
        }
    }

    /** Mapped inbound columns that SiteLink does not return would silently never sync. */
    private void compareColumns(String objectName, String source, SiteLinkResponse res, String operation) {
        Set<String> returned = new Set<String>();
        for (List<String> cols : res.columnNames.values()) {
            for (String c : cols) {
                returned.add(c.toLowerCase());
            }
        }
        if (returned.isEmpty()) {
            add('WARN', operation + ' returned no data rows, so its columns could not be checked.');
            return;
        }
        List<String> missing = new List<String>();
        for (SiteLink_Field_Map__mdt m : SiteLinkConfig.mappings(objectName, SiteLinkConfig.DIRECTION_INBOUND, source)) {
            if (!returned.contains(m.Inbound_Column__c.toLowerCase())) {
                missing.add(m.Inbound_Column__c + ' -> ' + objectName + '.' + m.Field__c);
            }
        }
        add(
            missing.isEmpty() ? 'PASS' : 'WARN',
            operation + ': ' + (missing.isEmpty() ? 'all mapped inbound columns are present.' : 'mapped columns NOT returned: ' + String.join(missing, '; ') + '.')
        );
        add('INFO', operation + ' columns: ' + String.join(new List<String>(returned), ', '));
    }

    private void requireColumns(SiteLinkResponse res, String operation, List<String> needed) {
        Map<String, String> row = res.rowCount() == 0 ? null : res.firstRowWith(needed[0]);
        if (row == null) {
            add('WARN', operation + ': no rows, cannot confirm columns ' + String.join(needed, ', ') + '.');
            return;
        }
        List<String> missing = new List<String>();
        for (String c : needed) {
            if (!row.containsKey(c.toLowerCase())) {
                missing.add(c);
            }
        }
        add(missing.isEmpty() ? 'PASS' : 'FAIL', operation + ': key columns ' + (missing.isEmpty() ? 'present.' : 'missing ' + String.join(missing, ', ') + '.'));
    }

    /** Update parameters with no matching read column cannot be preserved by read-modify-write. */
    private void gapsForUpdate(String operation, Map<String, String> sampleRow) {
        if (sampleRow == null) {
            return;
        }
        List<String> gaps = new List<String>();
        for (String p : SiteLinkApi.parameterNames(operation)) {
            if (!sampleRow.containsKey(p)) {
                gaps.add(p);
            }
        }
        gaps.sort();
        add(
            gaps.isEmpty() ? 'PASS' : 'WARN',
            operation + ': ' + (gaps.isEmpty() ? 'every parameter has a matching column to preserve.' : gaps.size() +
            ' parameter(s) have no column with the same name and are not preserved on update: ' + String.join(gaps, ', ') + '. Run roundTrip to see whether SiteLink clears them.')
        );
    }

    // --------------------------------------------------------------- round trip

    @TestVisible
    private void runRoundTrip(String loc, Boolean includeReservation) {
        SiteLinkLogger.currentDirection = 'Outbound';
        String stamp = String.valueOf(System.currentTimeMillis());
        String last = 'Roundtrip' + stamp.right(6);
        String email = 'sitelink.probe+' + stamp + '@example.com';
        add('INFO', 'Round trip at location ' + loc + ' (test tenant ' + last + ', ' + email + ')');
        try {
            Integer tenantId = api.createTenant(
                loc,
                new Map<String, Object>{ 'sFName' => 'Probe', 'sLName' => last, 'sEmail' => email, 'sAddr1' => '1 Probe St', 'sMobile' => '4035550100' }
            );
            add('PASS', 'TenantNewDetailed_v3 returned Ret_Code ' + tenantId + ' (used as TenantID).');

            Map<String, String> row = api.getTenant(loc, tenantId);
            add(row == null ? 'FAIL' : 'PASS', 'TenantInfoByTenantID finds the new tenant by that ID.');
            if (row == null) {
                return;
            }
            same('Phase 1 field sFName', 'Probe', row.get('sfname'));
            same('Phase 1 field sLName', last, row.get('slname'));
            same('Phase 1 field sEmail', email, row.get('semail'));

            List<Map<String, String>> found = api.findTenants(loc, '', last, email, '');
            add(found.size() == 1 ? 'PASS' : 'WARN', 'TenantListDetailed by email + last name finds ' + found.size() + ' tenant(s) (duplicate guard).');

            api.updateTenant(loc, tenantId, new Map<String, Object>{ 'sFName' => 'Probe2' });
            row = api.getTenant(loc, tenantId);
            same('Read-modify-write update changes sFName', 'Probe2', row.get('sfname'));
            same('Read-modify-write update keeps sAddr1', '1 Probe St', row.get('saddr1'));
            same('Read-modify-write update keeps sMobile', '4035550100', row.get('smobile'));

            SiteLinkResponse raw = api.call('TenantUpdate_v3', loc, new Map<String, Object>{ 'iTenantID' => tenantId, 'sFName' => 'Probe3', 'sLName' => last }, null);
            row = api.getTenant(loc, tenantId);
            Boolean cleared = String.isBlank(row.get('saddr1'));
            add(
                'INFO',
                'TenantUpdate_v3 with sAddr1/sEmail left out (Ret_Code ' + raw.retCode + '): sAddr1 is now "' + row.get('saddr1') + '", sEmail "' +
                row.get('semail') + '". Omitted elements are ' + (cleared ? 'CLEARED, so read-modify-write is required.' : 'KEPT.')
            );
            add('INFO', 'Test tenant ' + tenantId + ' was left in SiteLink. Delete or deactivate it there when done.');

            if (includeReservation) {
                reservationRoundTrip(loc, tenantId);
            }
        } catch (SiteLinkException e) {
            add('FAIL', e.getMessage() + (e.technicalDetail == null ? '' : ' [' + e.technicalDetail + ']'));
        }
    }

    private void reservationRoundTrip(String loc, Integer tenantId) {
        Integer unitId;
        for (Map<String, String> u : api.unitsSince(loc, null, null).rowsWith('UnitID')) {
            if (u.get('brented') == 'false' && u.get('brentable') != 'false') {
                unitId = SiteLinkXmlParser.toInteger(u.get('unitid'));
                break;
            }
        }
        if (unitId == null) {
            add('WARN', 'No vacant rentable unit found; reservation round trip skipped.');
            return;
        }
        Map<String, Object> params = new Map<String, Object>{
            'sTenantID' => String.valueOf(tenantId),
            'sUnitID' => String.valueOf(unitId),
            'dNeeded' => Date.today().addDays(14),
            'sComment' => 'Salesforce probe'
        };
        SiteLinkPushService.applyReservationDefaults(params);
        Integer waitingId = api.createReservation(loc, params);
        add('PASS', 'ReservationNewWithSource_v5 returned Ret_Code ' + waitingId + ' (used as WaitingID) for unit ' + unitId + '.');
        Map<String, String> res = api.getReservation(loc, waitingId);
        add(res == null ? 'FAIL' : 'PASS', 'ReservationList_v3 finds it by WaitingID.');
        if (res == null) {
            return;
        }
        add('INFO', 'Reservation columns: ' + String.join(new List<String>(res.keySet()), ', '));
        api.updateReservation(loc, waitingId, new Map<String, Object>{ 'sComment' => 'Salesforce probe 2' });
        same('ReservationUpdate_v4 changes sComment', 'Salesforce probe 2', api.getReservation(loc, waitingId).get('scomment'));
        add('INFO', 'Test reservation ' + waitingId + ' was left in SiteLink. Cancel it there when done.');
    }

    // ----------------------------------------------------------------- helpers

    private void same(String label, String expected, String actual) {
        Boolean ok = expected == actual || (expected != null && actual != null && expected.trim().equalsIgnoreCase(actual.trim()));
        add(ok ? 'PASS' : 'FAIL', label + ': sent "' + expected + '", read back "' + actual + '".');
    }

    private void add(String level, String text) {
        lines.add(level.rightPad(5) + text);
    }

    @TestVisible
    private String finish() {
        SiteLinkLogger.flush();
        String report = String.join(lines, '\n');
        System.debug(LoggingLevel.ERROR, '\n===== SiteLink Phase 1 report =====\n' + report + '\n===================================');
        return report;
    }
}
