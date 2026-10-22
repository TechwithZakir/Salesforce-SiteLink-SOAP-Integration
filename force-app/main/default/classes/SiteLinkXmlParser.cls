/**
 * Streaming parser for SiteLink responses.
 *
 * Every SiteLink operation returns a .NET DataSet:
 *   <OpResult><xs:schema .../><diffgr:diffgram><NewDataSet>
 *       <RT><Ret_Code>123</Ret_Code><Ret_Msg/></RT>
 *       <Table><Col>value</Col>...</Table>
 *   </NewDataSet></diffgr:diffgram></OpResult>
 * Rows are the children of NewDataSet (or DocumentElement); columns are their children.
 * The inline schema and diffgr:before blocks are ignored. XmlStreamReader keeps heap
 * low for large lists, and wantedColumns lets callers drop columns they don't map.
 */
public class SiteLinkXmlParser {
    private static final Set<String> DATASET_ROOTS = new Set<String>{ 'newdataset', 'documentelement' };
    private static final Set<String> ALWAYS_KEEP = new Set<String>{ 'ret_code', 'ret_msg' };

    /**
     * @param wantedColumns lower-case column names to keep; null keeps every column
     */
    public static SiteLinkResponse parse(String operation, String body, Set<String> wantedColumns) {
        SiteLinkResponse result = new SiteLinkResponse();
        result.operation = operation;
        result.rawBody = body;
        if (String.isBlank(body)) {
            return result;
        }

        XmlStreamReader reader = new XmlStreamReader(body);
        reader.setCoalescing(true);

        Integer depth = 0;
        Integer dataSetDepth = -1;
        String tableName;
        Map<String, String> row;
        String columnName;
        String columnText;
        Boolean inFaultString = false;
        String faultText = '';

        while (reader.hasNext()) {
            reader.next();
            XmlTag event = reader.getEventType();

            if (event == XmlTag.START_ELEMENT) {
                depth++;
                String name = reader.getLocalName();
                String lower = name.toLowerCase();
                if (dataSetDepth == -1 && DATASET_ROOTS.contains(lower)) {
                    dataSetDepth = depth;
                } else if (dataSetDepth != -1 && depth == dataSetDepth + 1) {
                    tableName = name;
                    row = new Map<String, String>();
                } else if (dataSetDepth != -1 && depth == dataSetDepth + 2) {
                    columnName = name;
                    columnText = '';
                } else if (lower == 'faultstring') {
                    inFaultString = true;
                }
            } else if (event == XmlTag.CHARACTERS || event == XmlTag.CDATA) {
                if (columnName != null) {
                    columnText += reader.getText();
                } else if (inFaultString) {
                    faultText += reader.getText();
                }
            } else if (event == XmlTag.END_ELEMENT) {
                if (dataSetDepth != -1 && depth == dataSetDepth + 2 && columnName != null) {
                    String key = columnName.toLowerCase();
                    if (wantedColumns == null || wantedColumns.contains(key) || ALWAYS_KEEP.contains(key)) {
                        row.put(key, columnText);
                        rememberColumn(result, tableName, columnName);
                    }
                    columnName = null;
                } else if (dataSetDepth != -1 && depth == dataSetDepth + 1 && row != null) {
                    addRow(result, tableName, row);
                    row = null;
                } else if (depth == dataSetDepth) {
                    dataSetDepth = -1;
                } else if (inFaultString) {
                    inFaultString = false;
                }
                depth--;
            }
        }
        if (String.isNotBlank(faultText)) {
            result.faultMessage = faultText.trim();
        }
        return result;
    }

    private static void addRow(SiteLinkResponse result, String tableName, Map<String, String> row) {
        if (!result.tables.containsKey(tableName)) {
            result.tables.put(tableName, new List<Map<String, String>>());
        }
        result.tables.get(tableName).add(row);
        if (tableName == 'RT') {
            result.retCode = toInteger(row.get('ret_code'));
            result.retMsg = row.get('ret_msg');
        }
    }

    private static void rememberColumn(SiteLinkResponse result, String tableName, String columnName) {
        List<String> cols = result.columnNames.get(tableName);
        if (cols == null) {
            cols = new List<String>();
            result.columnNames.put(tableName, cols);
        }
        if (cols.size() < 500 && !cols.contains(columnName)) {
            cols.add(columnName);
        }
    }

    public static Integer toInteger(String value) {
        if (String.isBlank(value)) {
            return null;
        }
        try {
            return Decimal.valueOf(value.trim()).intValue();
        } catch (Exception e) {
            return null;
        }
    }
}
