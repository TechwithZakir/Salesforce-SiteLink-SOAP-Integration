/**
 * A parsed SiteLink DataSet response. Rows are keyed by lower-cased column name;
 * the original column spelling is kept in columnNames for diagnostics.
 */
public class SiteLinkResponse {
    public String operation;
    public Integer httpStatus;
    public String rawBody;
    public Integer retCode;
    public String retMsg;
    public String faultMessage;
    public Map<String, List<Map<String, String>>> tables = new Map<String, List<Map<String, String>>>();
    public Map<String, List<String>> columnNames = new Map<String, List<String>>();

    public Boolean hasRetCode() {
        return retCode != null;
    }

    /** Data rows (any table except RT) that contain the given column. */
    public List<Map<String, String>> rowsWith(String column) {
        String key = column.toLowerCase();
        List<Map<String, String>> result = new List<Map<String, String>>();
        for (String tableName : tables.keySet()) {
            if (tableName == 'RT') {
                continue;
            }
            for (Map<String, String> row : tables.get(tableName)) {
                if (row.containsKey(key)) {
                    result.add(row);
                }
            }
        }
        return result;
    }

    public Map<String, String> firstRowWith(String column) {
        List<Map<String, String>> rows = rowsWith(column);
        return rows.isEmpty() ? null : rows[0];
    }

    public Integer rowCount() {
        Integer count = 0;
        for (String tableName : tables.keySet()) {
            if (tableName != 'RT') {
                count += tables.get(tableName).size();
            }
        }
        return count;
    }
}
