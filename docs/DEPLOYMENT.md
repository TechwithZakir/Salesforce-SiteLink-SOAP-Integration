# Deployment, test results and execution process

Salesforce ↔ SiteLink integration · deployment record of 22 Oct 2026

| | |
|---|---|
| Target org | `dev-zakir` (, Org ID `00D2w000000n9XXXXX`), Developer Edition |
| API version | 68.0 |
| Deploy ID | `0AfdL00000hbfufSAA` (Succeeded, 18:16–18:17 UTC) |
| Components | 182 / 182 deployed, 0 errors |
| Apex tests | 58 / 58 passed, 94% coverage of integration code |
| LWC (Jest) tests | 7 / 7 passed, 98% statement coverage |

---

## 1. Deployment steps

### 1.1 Prerequisites
- Salesforce CLI (`sf`) 2.x, Node.js 18+ (for Jest only)
- An authenticated org: `sf org login web --alias <alias>` (use `--instance-url https://test.salesforce.com` for a sandbox)

### 1.2 What is deployed (`force-app/`)

| Type | Items |
|---|---|
| Custom objects | `SiteLink_Site__c` (Store), `SiteLink_Unit__c` (Unit), `SiteLink_Sync_Log__c` (Sync Log), each with a tab |
| Fields | 12 on Account, 13 on Opportunity, plus the custom objects' fields |
| Custom metadata types | `SiteLink_Setting__mdt` (1 record: **Default**), `SiteLink_Field_Map__mdt` (35 records) |
| Credentials | External Credential **SiteLink** (Custom auth, principal `SiteLinkCorp`), Named Credential **SiteLink** → `https://www.smdservers.net/ccws_3.5` |
| Apex | 21 classes, 8 test classes + 2 test utilities (`SiteLinkMock`, `SiteLinkTestFactory`), 2 triggers (`SiteLinkAccountTrigger`, `SiteLinkOpportunityTrigger`) |
| LWC | `siteLinkPush` (SiteLink card with Push / Refresh buttons) |
| Permission sets | `SiteLink_Integration_Admin`, `SiteLink_User` |

### 1.3 Commands

```bash
# 1. Check-only validation (nothing is saved). Run first in every new org.
sf project deploy validate --source-dir force-app --target-org <alias> \
  --test-level RunSpecifiedTests \
  --tests SiteLinkTransportTest --tests SiteLinkFieldMapperTest --tests SiteLinkPushServiceTest \
  --tests SiteLinkTriggerHandlerTest --tests SiteLinkPullServiceTest --tests SiteLinkJobsTest \
  --tests SiteLinkControllerTest --tests SiteLinkDiagnosticsTest --wait 30

# 2. Deploy (same test list). For production, use --test-level RunLocalTests if org policy requires it.
sf project deploy start --source-dir force-app --target-org <alias> \
  --test-level RunSpecifiedTests --tests <same 8 classes> --wait 30

# 3. Give the admin access (and staff, after go-live)
sf org assign permset --name SiteLink_Integration_Admin --target-org <alias>
sf org assign permset --name SiteLink_User --target-org <alias> --on-behalf-of <user1> <user2>
```

Done on `dev-zakir`: steps 1–3 (validation `0AfdL00000hbeTxSAI`, deploy `0AfdL00000hbfufSAA`, admin
permission set assigned to m.zakir.bd@gmail.com).

### 1.4 Post-deploy checks (all passed on `dev-zakir`)

| Check | Result |
|---|---|
| `SiteLink_Setting__mdt` **Default** | Present. Active = true, Auto Push = false, Named Credential = SiteLink, Timeout 60 000 ms, Corp Code blank (to be set) |
| `SiteLink_Field_Map__mdt` | 35 records: Account 3 active (Phase 1) + 6 inactive, Opportunity 5, Store 8, Unit 13 |
| Named Credential `SiteLink` | Present |
| Triggers | `SiteLinkAccountTrigger`, `SiteLinkOpportunityTrigger`: Active |
| Apex classes `SiteLink*` | 31 |
| LWC `siteLinkPush` | Present |

### 1.5 Rollback
Turn the integration off without removing anything: Setup → Custom Metadata Types → SiteLink Setting →
Default → uncheck **Active**. Triggers, jobs and the button all stop. To stop the scheduled jobs too:
Setup → Scheduled Jobs → delete the `SiteLink …` jobs.

---

## 2. Test results

### 2.1 Apex (in-org run `707dL00001T05Ba`, 22 Oct 2026 18:17 UTC)

**Outcome: Passed. 58 test methods, 0 failures** (the run lists 66 rows, which includes the 8
`@TestSetup` methods). Execution time 16.9 s. Coverage of integration code: **94%**.
Raw results: `docs/test-results/apex/` (JUnit XML, JSON, coverage JSON).

| Class | Coverage | | Class | Coverage |
|---|---|---|---|---|
| SiteLinkAccountTrigger | 100% | | SiteLinkLogger | 89% |
| SiteLinkAlerts | 90% | | SiteLinkOpportunityTrigger | 100% |
| SiteLinkApi | 96% | | SiteLinkPullBatch | 91% |
| SiteLinkConfig | 86% | | SiteLinkPullService | 93% |
| SiteLinkController | 94% | | SiteLinkPushFinalizer | 94% |
| SiteLinkDiagnostics | 88% | | SiteLinkPushQueueable | 86% |
| SiteLinkDiscoveryQueueable | 100% | | SiteLinkPushService | 95% |
| SiteLinkErrors | 100% | | SiteLinkResponse | 91% |
| SiteLinkException | 100% | | SiteLinkScheduler | 98% |
| SiteLinkFieldMapper | 96% | | SiteLinkSoapClient | 98% |
| | | | SiteLinkSyncContext | 100% |
| | | | SiteLinkTriggerHandler | 95% |
| | | | SiteLinkXmlParser | 100% |

Every class is at 86% or above (target was 85%). The org-wide figure (69%) includes code that was
already in the org before this project.

What the test classes prove:

| Test class | Methods | Covers |
|---|---|---|
| SiteLinkTransportTest | 14 | SOAP envelope (WSDL order, credential merge fields, XML escaping), CallCenterWs vs ReportingWs routing, DataSet parsing, faults, timeouts, HTTP 5xx, Ret_Code errors, plain-language messages, logging |
| SiteLinkFieldMapperTest | 6 | Outbound params, defaults, value maps, inbound type conversion, change fingerprint |
| SiteLinkPushServiceTest | 13 | Create tenant + reservation, duplicate-tenant match, ambiguous match, read-modify-write updates, "unchanged → no call", refused unsafe reservation update, retry back-off, exhausted retries + alert, missing store / unit / wrong store, queueable + finalizer |
| SiteLinkTriggerHandlerTest | 7 | Background push on save, unrelated edits and integration writes don't push (loop prevention), clone protection, kill switch, retry sweep |
| SiteLinkPullServiceTest | 6 | Store, units, rent roll, tenants and reservations upserted under the right store; a second poll of unchanged data writes nothing; local pending edits win; one failed call doesn't stop the rest; .NET ticks |
| SiteLinkJobsTest | 10 | Store discovery, batch poll per enabled store, scheduler poll and reconcile, scheduling, log purge, alerts |
| SiteLinkControllerTest | 5 | Push button, Refresh from SiteLink (the Phase 1 "bring back"), Account page, clear errors when it can't run |
| SiteLinkDiagnosticsTest | 5 | Phase 1 probe and round-trip reports |

All SiteLink responses in tests come from `SiteLinkMock`, which returns real-shaped .NET DataSet
envelopes. No test calls SiteLink.

### 2.2 LWC (Jest, `npm run test:unit:coverage`)

**7 / 7 passed.** Coverage for `siteLinkPush.js`: statements 98.1%, branches 85.3%, functions 100%,
lines 97.9%. Report: `docs/test-results/lwc-coverage/lcov-report/index.html`.

| Test | Result |
|---|---|
| loads and shows the current sync status | ✓ |
| pushes, shows a success toast and refreshes the record page | ✓ |
| warns when the push did not fully succeed | ✓ |
| shows server errors as an error toast | ✓ |
| explains why the push button is disabled | ✓ |
| shows a load error | ✓ |
| formats every error shape | ✓ |

ESLint (`npx eslint force-app/main/default/lwc`): clean.

### 2.3 Not yet tested
Nothing has called the real SiteLink service yet: no SiteLink credentials are configured. That is the
purpose of Phase 1 (section 3.3).

---

## 3. Execution process

### 3.1 One-time configuration (admin, in Setup)

1. **SiteLink credentials:** Setup → Named Credentials → **External Credentials** tab → **SiteLink** →
   Principals → **SiteLinkCorp** → Edit → Authentication Parameters:
   - `CorpUserName` = `<corp API username>:::<API license key>`
   - `CorpPassword` = `<corp API password>`
2. **Settings:** Setup → Custom Metadata Types → **SiteLink Setting** → Manage Records → **Default** → Edit:
   - **Corp Code**: SiteLink corporate code
   - **Default Opportunity Stage**: an open stage that exists in this org (default `Prospecting`)
   - **Alert Emails**: who gets failure alerts
   - Leave **Auto Push** unchecked until Phase 1 is signed off
3. **Record pages:** open an Opportunity → ⚙ → Edit Page → drag **SiteLink Sync** (custom component)
   onto the page → Save → Activate. Repeat on Account if wanted. Add the SiteLink fields to page layouts
   (Opportunity: SiteLink Store, SiteLink Unit, Date Needed, Quoted Rate; Account: SiteLink Store,
   Tenant First/Last Name, Tenant Email).
4. **Permissions:** `SiteLink_Integration_Admin` for the admin who schedules jobs (already assigned on
   `dev-zakir`). `SiteLink_User` for staff who save Accounts/Opportunities or use the button.

### 3.2 Smoke test without SiteLink
Open the **SiteLink Stores** tab, create a store (Location Code = training location), then open an
Opportunity. The SiteLink card should show **Not Synced**, with the Push button enabled once a store
and an account are set.

### 3.3 Phase 1 (training location)

```bash
sf apex run --file scripts/apex/phase1-probe.apex     --target-org <alias>   # read-only checks
sf apex run --file scripts/apex/phase1-roundtrip.apex --target-org <alias>   # creates a test tenant
```
Edit `trainingLocation` in each script first. Each prints PASS/WARN/FAIL lines in the debug log.
Then do the UI round trip in `docs/PHASE1.md` §A: Push 3 fields → change them in SiteLink →
**Refresh from SiteLink**.

### 3.4 Go-live

```bash
sf apex run --file scripts/apex/run-now.apex       --target-org <alias>   # discover all stores + full sync
sf apex run --file scripts/apex/schedule-jobs.apex --target-org <alias>   # 15-min poll + nightly reconcile
```
Then check **Auto Push** on the SiteLink Setting.

| Scheduled job | When | Does |
|---|---|---|
| SiteLink Poll :00 / :15 / :30 / :45 | every 15 min | retries due pushes, then pulls changes for every enabled store |
| SiteLink Nightly Reconcile | 02:30 daily | purges old logs, discovers new stores, full pull of every store |

### 3.5 Day-to-day flow

1. Staff save an Account or Opportunity linked to a SiteLink Store. If mapped fields changed, the status
   becomes **Pending** and a background job sends it to SiteLink within seconds. Status becomes
   **Synced**, and the Tenant ID / Reservation ID are filled in.
2. Or staff press **Push to SiteLink** on the record for an immediate result.
3. Changes made in SiteLink arrive within 15 minutes (or immediately with **Refresh from SiteLink**).
4. Failures show on the record (**SiteLink Sync Status / Message**). Temporary problems retry
   automatically (5, 10, 20, 40, 80 min). After that the record is **Failed** and an alert email is sent.
5. Investigate in the **SiteLink Sync Logs** tab (request and response for every call) and the store's
   **Last Poll Status / Message**.
