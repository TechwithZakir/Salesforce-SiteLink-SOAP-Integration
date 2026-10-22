# Salesforce ↔ SiteLink Integration

Native Salesforce (Apex + LWC) integration with SiteLink Web Edition's SOAP API
(`https://www.smdservers.net/ccws_3.5/`). No middleware. Customers and reservations
entered in either system appear in the other, at every store location.

- **Salesforce → SiteLink:** Account → SiteLink tenant; Opportunity → SiteLink reservation.
  Changes push automatically in the background, or on demand with the **Push to SiteLink** button.
- **SiteLink → Salesforce:** tenants, reservations, units, pricing and store details are polled per store
  every 15 minutes, with a full reconciliation every night.

The design follows the request/response pattern of the
[sitelink-php](https://github.com/madurapa/sitelink-php) reference client (corp-level auth on every call,
`Ret_Code` > 0 = success/new ID, DataSet responses), rebuilt for Salesforce's governor limits and
transaction rules.

---

## How it works

```
                Salesforce                                         SiteLink (SOAP / ASMX)
 ┌─────────────────────────────────────────────┐
 │ Account / Opportunity trigger               │
 │   fingerprint changed? → status Pending     │
 │        │                                    │
 │        ▼                                    │   TenantListDetailed       (duplicate check)
 │ SiteLinkPushQueueable ──► SiteLinkPushService ─► TenantNewDetailed_v3 / TenantUpdate_v3
 │ (or Push button → SiteLinkController)       │   ReservationNewWithSource_v5 / ReservationUpdate_v4
 │                                             │
 │ SiteLinkScheduler (every 15 min)            │   SiteInformation
 │   ├─ retry sweep for due pushes             │   UnitsInformation_v2     (lngLastTimePolled cursor)
 │   └─ SiteLinkPullBatch (1 store per chunk) ─┼─► TenantListComplete_v2   (lngLastTimePolled cursor)
 │         └─ SiteLinkPullService              │   ReservationList
 │ Nightly: SiteLinkDiscoveryQueueable ────────┼─► SiteSearchByPostalCode  (all stores in the corp)
 │          then full SiteLinkPullBatch        │   RentRoll                (optional)
 └─────────────────────────────────────────────┘
```

| Layer | Classes |
|---|---|
| Transport | `SiteLinkSoapClient` (hand-built SOAP 1.1 envelopes), `SiteLinkXmlParser` (streaming DataSet parser), `SiteLinkResponse` |
| Operations | `SiteLinkApi`: one method per SiteLink operation, parameters in WSDL order |
| Mapping | `SiteLinkFieldMapper` driven by the **SiteLink Field Map** custom metadata |
| Outbound | `SiteLinkTriggerHandler`, `SiteLinkPushQueueable` (+ `SiteLinkPushFinalizer`), `SiteLinkPushService` |
| Inbound | `SiteLinkScheduler`, `SiteLinkPullBatch`, `SiteLinkPullService`, `SiteLinkDiscoveryQueueable` |
| Cross-cutting | `SiteLinkConfig`, `SiteLinkLogger`, `SiteLinkAlerts`, `SiteLinkErrors`, `SiteLinkSyncContext` |
| UI | `siteLinkPush` LWC + `SiteLinkController` |
| Phase 1 | `SiteLinkDiagnostics` + `scripts/apex/phase1-*.apex` |

### Key design decisions

- **No WSDL import.** CallCenterWs has 308 operations and ~900 KB of WSDL. Only the operations used are
  described, as parameter lists in `SiteLinkApi.SIGNATURES`.
- **Credentials never touch Apex.** `sCorpUserName` / `sCorpPassword` are sent as Named Credential
  merge fields (`{!HTMLENCODE($Credential.SiteLink.CorpUserName)}`), resolved by Salesforce at send time.
  Logged requests therefore contain the merge-field text, never the password.
- **Callouts first, DML last.** Every job and the button make all callouts, then do all writes,
  so Salesforce's "uncommitted work pending" rule is never hit.
- **Loop prevention by fingerprint.** `SiteLink_Sync_Hash__c` is a SHA-256 of the mapped fields at the
  last sync, in either direction. A record is pushed only when its fingerprint changes. Inbound writes
  store the new fingerprint, so data that arrived from SiteLink is never sent back. Integration writes
  also run with triggers suppressed (`SiteLinkSyncContext`).
- **Updates never blank SiteLink data.** `TenantUpdate_v3` and `ReservationUpdate_v4` replace every
  field, so the integration reads the current SiteLink record first and changes only the mapped fields.
  A reservation update is refused if SiteLink does not return its current status.
- **Conflicts:** if a record has local edits still waiting to go out (Pending or Retrying), an inbound
  change for it is skipped. The local edit is pushed and wins.
- **Duplicates:** before creating a tenant, the integration searches the store by email and last name.
  It links one match, and stops with a plain message when there are several. Cloned records drop
  their SiteLink IDs on insert. External IDs are `LOCATIONCODE:ID` and unique.
- **One SiteLink tenant per store.** SiteLink keeps a separate tenant record per location, so an Account
  is linked to one store (`SiteLink_Site__c`). Pushing an opportunity at a different store for that
  customer is stopped with a message asking for a separate account.
- **No webhooks.** None of SiteLink's 371 CallCenterWs + ReportingWs operations is an event or
  subscription API, so near-real-time is 15-minute polling. Polling is incremental where SiteLink
  supports it (`lngLastTimePolled` on units and tenants).

---

## Data model

| Object | Purpose | External ID |
|---|---|---|
| **SiteLink Store** `SiteLink_Site__c` | One per SiteLink location; created automatically by store discovery. `Sync Enabled` controls polling. | `Location_Code__c` |
| **SiteLink Unit** `SiteLink_Unit__c` | Units, sizes, rates, occupancy | `External_Key__c` = `L001:2001` |
| **Account** | Tenant. `Tenant_First_Name__c`, `Tenant_Last_Name__c`, `Tenant_Email__c`, `SiteLink_Site__c` | `SiteLink_Tenant_Key__c` = `L001:101` |
| **Opportunity** | Reservation. `SiteLink_Site__c`, `SiteLink_Unit__c`, `SiteLink_Date_Needed__c`, `SiteLink_Quoted_Rate__c` | `SiteLink_Reservation_Key__c` = `L001:555` |
| **SiteLink Sync Log** `SiteLink_Sync_Log__c` | One row per SiteLink call / sync step, with request and response | — |

Account and Opportunity both carry the sync fields **SiteLink Sync Status** (Not Synced, Pending, Synced,
Retrying, Failed), **SiteLink Sync Message** (plain language), **Last Synced**, **Retry Count** and
**Next Attempt**.

---

## Setup (sandbox first, then production)

1. **Deploy**
   ```bash
   sf project deploy start --source-dir force-app --target-org <sandbox> --test-level RunLocalTests
   ```
2. **Credentials:** Setup → Named Credentials → External Credentials → **SiteLink** → principal
   **SiteLinkCorp** → Authentication Parameters:
   - `CorpUserName` = `<corp API user>:::<API license key>` (the format the reference PHP client uses)
   - `CorpPassword` = corp API user's password
3. **Settings:** Setup → Custom Metadata Types → **SiteLink Setting** → **Default**: set **Corp Code**.
   Leave **Auto Push** off until Phase 1 is signed off. Set **Default Opportunity Stage** to an open stage
   in your org, and **Alert Emails**.
4. **Permissions:** assign **SiteLink Integration Admin** to the admin who schedules the jobs.
   Assign **SiteLink User** to staff: background pushes call SiteLink *as the user who saved the
   record*, so they need access to the SiteLink credential.
5. **Page layout:** add the **SiteLink Sync** component (`siteLinkPush`) to the Opportunity (and optionally
   Account) record pages, and the new fields to layouts.
6. **Phase 1:** run the two scripts in `scripts/apex/` (see `docs/PHASE1.md`).
7. **Go live:** run `scripts/apex/run-now.apex` (discover stores + full sync), then
   `scripts/apex/schedule-jobs.apex`. Turn **Auto Push** on.

## Field mapping (admin-maintained, no code)

Custom Metadata **SiteLink Field Map**, one record per field:

| Field | Meaning |
|---|---|
| Object | `Account`, `Opportunity`, `SiteLink_Unit__c`, `SiteLink_Site__c` |
| Field | Salesforce field API name |
| Outbound Param | SiteLink request parameter (e.g. `sFName`); blank = not sent |
| Inbound Column | SiteLink response column (e.g. `sFName`); blank = not read |
| Direction | Both / Outbound / Inbound |
| Default Value | Used when the source value is blank |
| Value Map | Lines `SalesforceValue=SiteLinkValue`, e.g. picklist ↔ status code |
| Source Operation | Inbound only; e.g. `RentRoll` for rent-roll columns |
| Active | Turn a mapping on or off |

Shipped active for Phase 1: Account first name / last name / email (`sFName`, `sLName`, `sEmail`), plus
the reservation, unit and store mappings. Phone and billing address mappings ship **inactive**.
A mapped column that SiteLink does not return is simply skipped: it never blanks a field.
`SiteLinkDiagnostics.probe` lists any such columns.

## Operations

- **Where to look:** the **SiteLink Sync Logs** tab (filter by Status = Error/Failed), the record's
  **SiteLink Sync Message**, and the store's **Last Poll Status / Message**.
- **Retries:** network errors, timeouts and SiteLink 5xx responses retry automatically with back-off
  (5, 10, 20, 40, 80 min by default; **Max Retries** and **Retry Base Minutes** in settings). After the
  last retry the record is **Failed** and an alert email goes out. Data errors (e.g. missing store or unit)
  fail straight away with an explanation; fix the record and save it, or press **Push to SiteLink**.
- **Kill switch:** uncheck **Active** on the SiteLink Setting. Triggers, jobs and the button all stop.
- **Pause one store:** uncheck **Sync Enabled** on that SiteLink Store.
- **Log retention:** logs older than **Log Retention Days** are deleted nightly. **Log Payloads** controls
  whether request/response XML is stored.

## Tests

```bash
sf apex run test --class-names SiteLinkTransportTest,SiteLinkFieldMapperTest,SiteLinkPushServiceTest,SiteLinkTriggerHandlerTest,SiteLinkPullServiceTest,SiteLinkJobsTest,SiteLinkControllerTest,SiteLinkDiagnosticsTest --code-coverage --target-org <org>
npm install && npm run test:unit:coverage
```

Apex tests use `SiteLinkMock`, which returns real-shaped .NET DataSet envelopes routed by SOAPAction, and
inject their own settings and mappings (`SiteLinkTestFactory.configure`), so they don't depend on the
org's custom metadata.
