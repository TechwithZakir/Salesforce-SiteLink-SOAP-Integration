/**
 * Raised for any SiteLink failure. Carries a plain-language message for staff
 * (written to the record) and whether an automatic retry could succeed.
 */
public class SiteLinkException extends Exception {
    public Boolean isRetryable = false;
    public String technicalDetail;
    public Integer retCode;

    public SiteLinkException retryable(Boolean value) {
        this.isRetryable = value;
        return this;
    }

    public SiteLinkException detail(String value) {
        this.technicalDetail = value;
        return this;
    }

    public SiteLinkException code(Integer value) {
        this.retCode = value;
        return this;
    }
}
