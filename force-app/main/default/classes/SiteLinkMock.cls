/**
 * HttpCalloutMock for SiteLink. Routes on the SOAPAction operation name and returns
 * .NET DataSet envelopes shaped like the real service (inline schema + diffgram).
 * Several responses queued for one operation are returned in order; the last repeats.
 * Unconfigured operations answer RT Ret_Code 1 with no rows.
 */
@IsTest
public class SiteLinkMock implements HttpCalloutMock {
    public Map<String, List<Object>> responses = new Map<String, List<Object>>();
    public List<HttpRequest> requests = new List<HttpRequest>();
    public Map<String, Integer> calls = new Map<String, Integer>();

    public class CannedReply {
        public Integer status;
        public String body;
        public CannedReply(Integer status, String body) {
            this.status = status;
            this.body = body;
        }
    }

    public SiteLinkMock reply(String operation, String body) {
        return add(operation, new CannedReply(200, body));
    }

    public SiteLinkMock onStatus(String operation, Integer status, String body) {
        return add(operation, new CannedReply(status, body));
    }

    public SiteLinkMock onTimeout(String operation) {
        return add(operation, new CalloutException('Read timed out'));
    }

    private SiteLinkMock add(String operation, Object reply) {
        if (!responses.containsKey(operation)) {
            responses.put(operation, new List<Object>());
        }
        responses.get(operation).add(reply);
        return this;
    }

    public HttpResponse respond(HttpRequest req) {
        requests.add(req);
        String operation = req.getHeader('SOAPAction').remove('"').substringAfterLast('/');
        calls.put(operation, count(operation) + 1);

        Object reply;
        List<Object> queue = responses.get(operation);
        if (queue != null && !queue.isEmpty()) {
            reply = queue.size() > 1 ? queue.remove(0) : queue[0];
        }
        if (reply instanceof CalloutException) {
            throw (CalloutException) reply;
        }
        CannedReply r = reply == null ? new CannedReply(200, dataSet(operation, rt(1, ''))) : (CannedReply) reply;
        HttpResponse res = new HttpResponse();
        res.setStatusCode(r.status);
        res.setStatus(r.status == 200 ? 'OK' : 'Error');
        res.setHeader('Content-Type', 'text/xml; charset=utf-8');
        res.setBody(r.body);
        return res;
    }

    public Integer count(String operation) {
        return calls.containsKey(operation) ? calls.get(operation) : 0;
    }

    /** Body of the last request sent for an operation. */
    public String lastBody(String operation) {
        for (Integer i = requests.size() - 1; i >= 0; i--) {
            if (requests[i].getHeader('SOAPAction').contains('/' + operation + '"')) {
                return requests[i].getBody();
            }
        }
        return null;
    }

    // ----------------------------------------------------------- body builders

    public static String dataSet(String operation, String rows) {
        String ns = operation == 'TenantListComplete_v2' || operation == 'RentRoll'
            ? SiteLinkSoapClient.NS_REPORTING
            : SiteLinkSoapClient.NS_CALL_CENTER;
        return '<?xml version="1.0" encoding="utf-8"?>' +
            '<soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" ' +
            'xmlns:xsd="http://www.w3.org/2001/XMLSchema"><soap:Body>' +
            '<' + operation + 'Response xmlns="' + ns + '"><' + operation + 'Result>' +
            '<xs:schema id="NewDataSet" xmlns="" xmlns:xs="http://www.w3.org/2001/XMLSchema" xmlns:msdata="urn:schemas-microsoft-com:xml-msdata">' +
            '<xs:element name="NewDataSet" msdata:IsDataSet="true"><xs:complexType><xs:choice minOccurs="0" maxOccurs="unbounded">' +
            '<xs:element name="Table"><xs:complexType><xs:sequence><xs:element name="TenantID" type="xs:int" minOccurs="0" />' +
            '</xs:sequence></xs:complexType></xs:element></xs:choice></xs:complexType></xs:element></xs:schema>' +
            '<diffgr:diffgram xmlns:msdata="urn:schemas-microsoft-com:xml-msdata" xmlns:diffgr="urn:schemas-microsoft-com:xml-diffgram-v1">' +
            '<NewDataSet xmlns="">' + rows + '</NewDataSet></diffgr:diffgram>' +
            '</' + operation + 'Result></' + operation + 'Response></soap:Body></soap:Envelope>';
    }

    public static String rt(Integer code, String message) {
        return '<RT diffgr:id="RT1" msdata:rowOrder="0"><Ret_Code>' + code + '</Ret_Code><Ret_Msg>' +
            (message == null ? '' : message.escapeXml()) + '</Ret_Msg></RT>';
    }

    public static String row(String table, Map<String, String> columns) {
        String xml = '<' + table + ' diffgr:id="' + table + '1" msdata:rowOrder="0">';
        for (String col : columns.keySet()) {
            String value = columns.get(col);
            xml += value == null ? '<' + col + ' />' : '<' + col + '>' + value.escapeXml() + '</' + col + '>';
        }
        return xml + '</' + table + '>';
    }

    public static String fault(String message) {
        return '<?xml version="1.0" encoding="utf-8"?><soap:Envelope xmlns:soap="http://schemas.xmlsoap.org/soap/envelope/">' +
            '<soap:Body><soap:Fault><faultcode>soap:Server</faultcode><faultstring>' + message.escapeXml() +
            '</faultstring><detail /></soap:Fault></soap:Body></soap:Envelope>';
    }
}
