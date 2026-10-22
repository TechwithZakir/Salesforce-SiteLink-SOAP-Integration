// Phase 1 - step 1 (READ-ONLY). Checks the draft's assumptions against SiteLink.
// Run: sf apex run --file scripts/apex/phase1-probe.apex --target-org <sandbox>
// The report is printed in the debug log between the ===== markers.
String trainingLocation = 'L001'; // <-- SiteLink training location code
System.debug(LoggingLevel.ERROR, SiteLinkDiagnostics.probe(trainingLocation));
