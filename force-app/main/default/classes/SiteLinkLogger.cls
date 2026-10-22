/**
 * Buffers SiteLink_Sync_Log__c rows in memory and inserts them with flush().
 * Buffering keeps log DML out of the way of callouts: call flush() only after the
 * transaction's last callout.
 */
public without sharing class SiteLinkLogger {
    private static final Integer LONG_TEXT_LIMIT = 131072;
    private static final Integer MESSAGE_LIMIT = 32768;
    private static List<SiteLink_Sync_Log__c> buffer = new List<SiteLink_Sync_Log__c>();

    /** Set by services so call logs are tied to the record being synced. */
    public static String currentRecordId;
    public static String currentDirection = 'Outbound';
    public static String currentJobId;

    public static SiteLink_Sync_Log__c logCall(
        String operation,
        String locationCode,
        String status,
        String message,
        String request,
        String response,
        Long durationMs,
        String retCode
    ) {
        SiteLink_Sync_Log__c row = log(currentDirection, operation, locationCode, currentRecordId, status, message);
        if (logPayloads()) {
            row.Request__c = truncate(request, LONG_TEXT_LIMIT);
            row.Response__c = truncate(response, LONG_TEXT_LIMIT);
        }
        row.Duration_Ms__c = durationMs;
        row.Ret_Code__c = retCode;
        return row;
    }

    public static SiteLink_Sync_Log__c log(String direction, String operation, String locationCode, String recordId, String status, String message) {
        SiteLink_Sync_Log__c row = new SiteLink_Sync_Log__c(
            Direction__c = direction,
            Operation__c = truncate(operation, 100),
            Location_Code__c = truncate(locationCode, 20),
            Record_Id__c = truncate(recordId, 18),
            Status__c = status,
            Message__c = truncate(message, MESSAGE_LIMIT),
            Job_Id__c = truncate(currentJobId, 18)
        );
        buffer.add(row);
        return row;
    }

    public static void flush() {
        if (buffer.isEmpty()) {
            return;
        }
        List<SiteLink_Sync_Log__c> toInsert = buffer;
        buffer = new List<SiteLink_Sync_Log__c>();
        Database.insert(toInsert, false);
    }

    @TestVisible
    private static List<SiteLink_Sync_Log__c> pending() {
        return buffer;
    }

    public static String truncate(String value, Integer max) {
        return value == null || value.length() <= max ? value : value.left(max);
    }

    private static Boolean logPayloads() {
        try {
            return SiteLinkConfig.settings().Log_Payloads__c == true;
        } catch (Exception e) {
            return false;
        }
    }
}
