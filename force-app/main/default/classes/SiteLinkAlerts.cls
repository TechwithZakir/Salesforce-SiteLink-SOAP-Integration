/**
 * Emails a digest of failed syncs to SiteLink_Setting__mdt.Alert_Emails__c.
 * Alerting must never break a sync, so every failure here is swallowed into the log.
 */
public without sharing class SiteLinkAlerts {
    @TestVisible
    private static Integer sentCount = 0;

    public static void send(String subject, List<String> lines) {
        try {
            List<String> recipients = recipients();
            if (recipients.isEmpty() || lines == null || lines.isEmpty()) {
                return;
            }
            if (Limits.getEmailInvocations() >= Limits.getLimitEmailInvocations()) {
                return;
            }
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(recipients);
            mail.setSubject(subject);
            String body =
                'The Salesforce to SiteLink integration could not sync the following:\n\n- ' +
                String.join(lines, '\n- ') +
                '\n\nOpen the SiteLink Sync Logs tab in Salesforce for details. Records marked Failed will not retry on their own; ' +
                'fix the problem and save the record again, or use Push to SiteLink.';
            mail.setPlainTextBody(body.abbreviate(30000));
            Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ mail }, false);
            sentCount++;
        } catch (Exception e) {
            SiteLinkLogger.log('Outbound', 'Alert email', null, null, 'Error', 'Could not send alert email: ' + e.getMessage());
        }
    }

    private static List<String> recipients() {
        String raw = SiteLinkConfig.settings().Alert_Emails__c;
        List<String> result = new List<String>();
        if (String.isBlank(raw)) {
            return result;
        }
        for (String part : raw.split('[,;\\s]+')) {
            if (String.isNotBlank(part)) {
                result.add(part.trim());
            }
        }
        return result;
    }
}
