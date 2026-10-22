/**
 * Low-level SOAP 1.1 transport for SiteLink's ASMX services.
 *
 * Envelopes are hand-built (no WSDL2Apex). Credentials are never handled in Apex:
 * sCorpUserName / sCorpPassword are emitted as Named Credential merge fields that
 * Salesforce resolves at send time from the "SiteLink" External Credential.
 */
public inherited sharing class SiteLinkSoapClient {
    public enum Service {
        CALL_CENTER,
        REPORTING
    }

    public static final String NS_CALL_CENTER = 'http://tempuri.org/CallCenterWs/CallCenterWs';
    public static final String NS_REPORTING = 'http://tempuri.org/CallCenterWs/ReportingWs';
    private static final Integer MAX_TIMEOUT_MS = 120000;

    public class Param {
        public String name;
        public String xsdType;
        public Object value;
        /** Raw values (merge-field tokens) are written without XML escaping. */
        public Boolean raw = false;

        public Param(String name, String xsdType, Object value) {
            this.name = name;
            this.xsdType = xsdType;
            this.value = value;
        }
    }

    public static String namespaceFor(Service svc) {
        return svc == Service.REPORTING ? NS_REPORTING : NS_CALL_CENTER;
    }

    /** Merge field resolved by the Named Credential, XML-encoded so passwords with & or < stay valid. */
    public static String credentialToken(String parameterName) {
        String externalCredential = SiteLinkConfig.strSetting(SiteLinkConfig.settings().External_Credential__c, 'SiteLink');
        return '{!HTMLENCODE($Credential.' + externalCredential + '.' + parameterName + ')}';
    }

    public SiteLinkResponse send(Service svc, String operation, String locationCode, List<Param> params, Set<String> wantedColumns) {
        SiteLink_Setting__mdt cfg = SiteLinkConfig.settings();
        String path = svc == Service.REPORTING
            ? SiteLinkConfig.strSetting(cfg.Reporting_Path__c, '/ReportingWs.asmx')
            : SiteLinkConfig.strSetting(cfg.CallCenter_Path__c, '/CallCenterWs.asmx');
        String namespace = namespaceFor(svc);

        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + SiteLinkConfig.strSetting(cfg.Named_Credential__c, 'SiteLink') + path);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=utf-8');
        req.setHeader('SOAPAction', '"' + namespace + '/' + operation + '"');
        req.setTimeout(Math.min(SiteLinkConfig.intSetting(cfg.Timeout_Ms__c, MAX_TIMEOUT_MS), MAX_TIMEOUT_MS));
        String envelope = buildEnvelope(namespace, operation, params);
        req.setBody(envelope);

        Long started = System.currentTimeMillis();
        HttpResponse res;
        try {
            res = new Http().send(req);
        } catch (Exception e) {
            SiteLinkException error = SiteLinkErrors.fromCalloutException(operation, e);
            SiteLinkLogger.logCall(operation, locationCode, 'Error', error.getMessage(), envelope, e.getMessage(), elapsed(started), null);
            throw error;
        }

        String body = res.getBody();
        SiteLinkResponse parsed;
        try {
            parsed = SiteLinkXmlParser.parse(operation, body, wantedColumns);
        } catch (Exception e) {
            SiteLinkException error = new SiteLinkException('SiteLink sent a reply Salesforce could not read. The sync will be retried.')
                .retryable(true)
                .detail(e.getMessage());
            SiteLinkLogger.logCall(operation, locationCode, 'Error', error.getMessage() + ' ' + e.getMessage(), envelope, body, elapsed(started), null);
            throw error;
        }
        parsed.httpStatus = res.getStatusCode();

        SiteLinkException failure;
        if (String.isNotBlank(parsed.faultMessage)) {
            failure = SiteLinkErrors.fromFault(operation, locationCode, parsed.faultMessage);
        } else if (res.getStatusCode() != 200) {
            failure = SiteLinkErrors.fromHttpStatus(operation, res.getStatusCode(), res.getStatus());
        }
        String retCode = parsed.retCode == null ? null : String.valueOf(parsed.retCode);
        if (failure != null) {
            SiteLinkLogger.logCall(operation, locationCode, 'Error', failure.getMessage(), envelope, body, elapsed(started), retCode);
            throw failure;
        }
        SiteLinkLogger.logCall(
            operation,
            locationCode,
            'Success',
            parsed.rowCount() + ' row(s)' + (parsed.retMsg == null ? '' : '; Ret_Msg: ' + parsed.retMsg),
            envelope,
            body,
            elapsed(started),
            retCode
        );
        return parsed;
    }

    @TestVisible
    private static String buildEnvelope(String namespace, String operation, List<Param> params) {
        String xml =
            '<?xml version="1.0" encoding="utf-8"?>' +
            '<soap:Envelope xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
            'xmlns:xsd="http://www.w3.org/2001/XMLSchema" ' +
            'xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">' +
            '<soap:Body><' +
            operation +
            ' xmlns="' +
            namespace +
            '">';
        for (Param p : params) {
            if (p.value == null) {
                continue;
            }
            String text = p.raw ? String.valueOf(p.value) : formatValue(p.xsdType, p.value);
            xml += '<' + p.name + '>' + text + '</' + p.name + '>';
        }
        return xml + '</' + operation + '></soap:Body></soap:Envelope>';
    }

    @TestVisible
    private static String formatValue(String xsdType, Object value) {
        if (value instanceof String) {
            String s = (String) value;
            return (xsdType == 'string' ? s : s.trim()).escapeXml();
        }
        if (value instanceof Date) {
            return formatDate((Date) value) + 'T00:00:00';
        }
        if (value instanceof Datetime) {
            return ((Datetime) value).format('yyyy-MM-dd\'T\'HH:mm:ss');
        }
        if (value instanceof Boolean) {
            return ((Boolean) value) ? 'true' : 'false';
        }
        if (value instanceof Decimal) {
            Decimal d = (Decimal) value;
            return xsdType == 'int' || xsdType == 'long' ? String.valueOf(d.longValue()) : d.toPlainString();
        }
        return String.valueOf(value).escapeXml();
    }

    private static String formatDate(Date d) {
        return Datetime.newInstance(d.year(), d.month(), d.day()).format('yyyy-MM-dd');
    }

    private static Long elapsed(Long started) {
        return System.currentTimeMillis() - started;
    }
}
