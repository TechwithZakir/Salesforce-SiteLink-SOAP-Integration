/**
 * Transaction-scoped flag set while the integration itself writes Account/Opportunity
 * records, so triggers don't treat those writes as user edits to push back to SiteLink.
 */
public class SiteLinkSyncContext {
    private static Integer depth = 0;

    public static void suppress() {
        depth++;
    }

    public static void release() {
        depth = Math.max(0, depth - 1);
    }

    public static Boolean isSuppressed() {
        return depth > 0;
    }
}
