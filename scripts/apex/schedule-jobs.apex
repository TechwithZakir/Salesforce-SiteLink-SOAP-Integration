// Run once, as the integration admin (who holds the SiteLink Integration Admin permission set).
// Creates: SiteLink Poll :00/:15/:30/:45 (retry sweep + incremental pull) and SiteLink Nightly Reconcile (02:30).
System.debug(SiteLinkScheduler.scheduleDefaults());
