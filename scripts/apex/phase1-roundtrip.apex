// Phase 1 - step 2 (WRITES TO SITELINK - TRAINING LOCATION ONLY).
// Creates a test tenant, reads the three Phase 1 fields back (sFName, sLName, sEmail),
// updates it, and tests whether TenantUpdate_v3 clears fields that are left out.
// Set includeReservation = true to also create, read and update a test reservation.
// Run: sf apex run --file scripts/apex/phase1-roundtrip.apex --target-org <sandbox>
String trainingLocation = 'L001'; // <-- SiteLink training location code
Boolean includeReservation = false;
System.debug(LoggingLevel.ERROR, SiteLinkDiagnostics.roundTrip(trainingLocation, includeReservation));
