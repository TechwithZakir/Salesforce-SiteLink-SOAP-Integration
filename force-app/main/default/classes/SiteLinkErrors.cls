/**
 * Turns transport faults and SiteLink return codes into messages staff can act on,
 * and decides whether an automatic retry has a chance of succeeding.
 */
public class SiteLinkErrors {
    private static final List<String> LOGIN_HINTS = new List<String>{ 'login', 'password', 'credential', 'authenticat', 'corp', 'unauthori', 'license' };
    private static final List<String> TRANSIENT_HINTS = new List<String>{ 'timeout', 'timed out', 'deadlock', 'temporarily', 'try again', 'busy', 'unavailable' };

    public static SiteLinkException fromCalloutException(String operation, Exception e) {
        String msg = e.getMessage() == null ? '' : e.getMessage();
        String lower = msg.toLowerCase();
        if (lower.contains('unauthorized endpoint') || lower.contains('named credential') || lower.contains('callout:')) {
            return new SiteLinkException(
                    'The SiteLink connection in Salesforce is not set up correctly. Ask your admin to check the SiteLink Named Credential.'
                )
                .retryable(false)
                .detail(msg);
        }
        if (lower.contains('timed out') || lower.contains('timeout')) {
            return new SiteLinkException('SiteLink took too long to answer. Salesforce will try again automatically.')
                .retryable(true)
                .detail(msg);
        }
        return new SiteLinkException('Salesforce could not reach SiteLink. Salesforce will try again automatically.')
            .retryable(true)
            .detail(msg);
    }

    public static SiteLinkException fromHttpStatus(String operation, Integer status, String statusText) {
        Boolean retry = status >= 500 || status == 408 || status == 429;
        String message = retry
            ? 'SiteLink is having trouble right now (HTTP ' + status + '). Salesforce will try again automatically.'
            : 'SiteLink refused the request (HTTP ' + status + ' ' + statusText + '). Ask your admin to check the integration log.';
        return new SiteLinkException(message).retryable(retry).detail(operation + ' HTTP ' + status);
    }

    public static SiteLinkException fromFault(String operation, String locationCode, String fault) {
        String lower = fault.toLowerCase();
        if (containsAny(lower, LOGIN_HINTS)) {
            return new SiteLinkException(
                    'SiteLink rejected the integration login. Ask your admin to check the SiteLink username, password and corp code.'
                )
                .retryable(false)
                .detail(fault);
        }
        if (lower.contains('location')) {
            return new SiteLinkException(
                    'SiteLink did not accept the store location code "' + locationCode + '". Check the store on this record.'
                )
                .retryable(false)
                .detail(fault);
        }
        return new SiteLinkException('SiteLink reported a problem: ' + shorten(fault))
            .retryable(containsAny(lower, TRANSIENT_HINTS))
            .detail(fault);
    }

    /** For a negative / zero Ret_Code. "action" completes the sentence "SiteLink could not ...". */
    public static SiteLinkException fromRetCode(String operation, String action, Integer code, String retMsg) {
        String reason = String.isBlank(retMsg) ? 'it returned error code ' + code : retMsg.trim();
        String lower = reason.toLowerCase();
        return new SiteLinkException('SiteLink could not ' + action + ': ' + shorten(reason))
            .retryable(containsAny(lower, TRANSIENT_HINTS))
            .code(code)
            .detail(operation + ' Ret_Code=' + code + ' Ret_Msg=' + retMsg);
    }

    private static Boolean containsAny(String text, List<String> needles) {
        for (String n : needles) {
            if (text.contains(n)) {
                return true;
            }
        }
        return false;
    }

    private static String shorten(String text) {
        return text.abbreviate(180);
    }
}
