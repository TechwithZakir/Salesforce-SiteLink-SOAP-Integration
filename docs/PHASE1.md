# Phase 1: round trip and SiteLink assumptions

Phase 1 proves the approach on three fields: **Tenant First Name, Tenant Last Name, Tenant Email**
(Account ↔ SiteLink `sFName`, `sLName`, `sEmail`). It also checks which assumptions about
SiteLink's behaviour hold at the training location.

## A. Round trip in the UI (the acceptance test)

Use a sandbox with the package deployed, credentials set, and **Auto Push off**.

1. Open (or create) a **SiteLink Store** record for the training location and note its Location Code.
2. Create an Account with **Tenant First Name**, **Tenant Last Name**, **Tenant Email**, and
   **SiteLink Store** = the training store.
3. On the Account page, click **Push to SiteLink** in the SiteLink card.
   Expected: status **Synced**, a **Tenant ID** appears, and the tenant is visible in SiteLink with the same three values.
4. In SiteLink, change the tenant's first name, last name and email.
5. In Salesforce, click **Refresh from SiteLink**. Expected: the three fields show SiteLink's new values,
   and status stays **Synced**.
6. Click **Push to SiteLink** again without editing. Expected: no data changes in SiteLink (loop check).
   The **SiteLink Sync Logs** tab shows each call with its request and response.

## B. Scripted checks

Run these against the sandbox connected to SiteLink, using the training location code:

```bash
sf apex run --file scripts/apex/phase1-probe.apex     --target-org <sandbox>   # read-only
sf apex run --file scripts/apex/phase1-roundtrip.apex --target-org <sandbox>   # writes a test tenant
```

Each prints a report of `PASS` / `WARN` / `FAIL` / `INFO` lines that can go into the Phase 1 report.
The round trip leaves a test tenant (and optionally a test reservation) in the training location.
The report gives their IDs so they can be removed.

## C. Assumptions

### Already confirmed or corrected from SiteLink's live WSDLs

| # | Finding | Effect on the build |
|---|---|---|
| W1 | `TenantListDetailed`, `TenantNewDetailed_v3`, `TenantUpdate_v3`, `ReservationNewWithSource_v5`, `ReservationUpdate_v4`, `ReservationList`, `UnitsInformation_v2` and `SiteInformation` exist on **CallCenterWs** with the parameters used in `SiteLinkApi`. | Confirmed. Newer versions also exist (`TenantListDetailed_v3`, `ReservationNewWithSource_v6`, `UnitsInformation_v3`). |
| W2 | **`TenantListComplete_v2` and `RentRoll` are not on CallCenterWs.** They are on **ReportingWs** (`/ReportingWs.asmx`, SOAPAction namespace `http://tempuri.org/CallCenterWs/ReportingWs`). | A draft that calls them on CallCenterWs will fail. This build routes them to ReportingWs. |
| W3 | **SiteLink has no webhook or event API.** None of the 308 CallCenterWs or 63 ReportingWs operations is one. | Inbound is 15-minute polling plus a nightly reconciliation. No Apex REST endpoint was built, since nothing would call it. |
| W4 | `UnitsInformation_v2` (`lngLastTimePolled`, string) and `TenantListComplete_v2` (`lngLastTimePolled`, long) support incremental pulls. `ReservationList` has no such parameter. | Units and tenants poll incrementally; reservations are re-read each poll (unchanged rows cause no writes). |
| W5 | `TenantUpdate_v3` and `ReservationUpdate_v4` have no partial-update mode: every field is a parameter. | Updates read the current SiteLink record first and only change mapped fields (read-modify-write). |
| W6 | `ReservationUpdate_v4.iStatus` is a required int. | If SiteLink doesn't return the current status, the update is refused rather than risk cancelling or reopening the reservation. |
| W7 | `SiteListGlobal` needs a SiteLink-internal `sUsagePassword`. | Store discovery uses corp-level `SiteSearchByPostalCode('', -999)`, the method the PHP reference uses. |
| W8 | Responses are untyped .NET DataSets (inline schema + diffgram). The WSDL does not define response column names. | Column names can't be confirmed without a live call; see T3. Mappings are metadata, so fixes need no code. |

### From the PHP reference client (worked for its author; needs confirming here)

| # | Assumption | Checked by |
|---|---|---|
| P1 | `sCorpUserName` is `user:::APILicenseKey`. | probe: "Login works" |
| P2 | `Ret_Code` > 0 means success and is the new TenantID / WaitingID; errors are ≤ 0 with `Ret_Msg`. | roundTrip: "TenantNewDetailed_v3 returned Ret_Code …" |
| P3 | Store columns `SiteID`, `sLocationCode`, `sSiteName`, `sSiteAddr1`, `sSiteCity`, `sSiteRegion`, `sSitePostalCode`, `sSitePhone`; unit columns `sTypeName`, `dcWidth`, `dcLength`, `iFloor`, `dcStdRate`. | probe: SiteInformation / UnitsInformation_v2 column check |
| P4 | Reservation source `iSource = 5`. | Inspect the test reservation in SiteLink (setting: Reservation Source Id) |

### To verify at the training location

| # | Assumption | Risk if wrong | Checked by |
|---|---|---|---|
| T1 | Named Credential merge fields (with `HTMLENCODE`) resolve inside the SOAP body. | No call can log in. | probe: "Login works" |
| T2 | `lngLastTimePolled` is .NET ticks. The SiteLink server's time zone is unknown, so cursors go back 12 h (**Poll Overlap Minutes**) to be safe. | Missed or repeated changes. Repeats are harmless; misses are caught nightly. | probe: delta row counts |
| T3 | Response columns match the mapped names (`sFName`, `sLName`, `sEmail`, `WaitingID`, `TenantID`, `UnitID`, `iStatus`, `dNeeded`, `sComment`, `dcQuotedRate`, `sUnitName`, `dcWebRate`, `bRented`, `dcRent`, …). | A field silently never syncs. | probe: "mapped columns NOT returned" |
| T4 | `ReservationList` with `iGlobalWaitingNum = 0` returns the store's reservations, and we still need to learn whether cancelled or converted ones are included. | Missing or extra opportunities. | probe: row count; compare with SiteLink UI |
| T5 | Update operations also return `Ret_Code` > 0 on success. | Successful updates reported as failures (loud, not silent). | roundTrip |
| T6 | **Does `TenantUpdate_v3` clear fields that are left out?** | If yes, any field SiteLink doesn't echo back (see T7) is wiped on update. | roundTrip: "Omitted elements are CLEARED / KEPT" |
| T7 | Tenant read columns match `TenantUpdate_v3` parameter names, so read-modify-write preserves them. Likely gaps: `sWebPassword`, `sSSN`, `sGateCode` (never echoed by design), `bSMSOptIn`, `dDOB`. | Those values reset on update. | probe: "parameter(s) … not preserved on update" |
| T8 | Defaults for unmapped reservation values: `QTRentalTypeID = 2` (reservation, not quote), `iInquiryType = 0`, `ConcessionID` omitted (0), expiry = date needed + 7 days, follow-up = tomorrow. | Wrong type/source shown in SiteLink. | roundTrip with reservation, then inspect in SiteLink; all are settings |
| T9 | `TenantListDetailed` filtered by email and last name finds an existing tenant; "no match" is a negative `Ret_Code` with no rows. | Duplicate tenants. | roundTrip: "duplicate guard" |
| T10 | The API user can run `RentRoll` (reporting rights). | No current-rent values (off by default: **Pull Rent Roll**). | probe: RentRoll line |

Anything in T1–T10 that comes back `WARN` or `FAIL` is either a settings or field-map change
(no code), or a targeted change in `SiteLinkApi` / `SiteLinkPushService`.
