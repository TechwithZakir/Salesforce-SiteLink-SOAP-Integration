// Manual runs, e.g. right after go-live.
System.enqueueJob(new SiteLinkDiscoveryQueueable(true)); // discover all stores, then full reconciliation
// SiteLinkPullBatch.run(false);                         // incremental pull of every enabled store
// SiteLinkScheduler.retryDuePushes();                   // push records waiting to retry
