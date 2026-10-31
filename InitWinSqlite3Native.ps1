# ---------------------------------------------------------------------------
# InitWinSqlite3Native.ps1
# P/Invoke bridge targeting Windows native winsqlite3.dll
# ---------------------------------------------------------------------------

# Runs as ScriptsToProcess in the caller's scope; the script block keeps its variables out of that scope.
& {
# Platform pre-flight check: ensure running on Windows
if ($PSVersionTable.PSEdition -eq 'Core') {
    $isWin = if (Get-Variable -Name 'IsWindows' -ErrorAction SilentlyContinue) { $IsWindows } else { [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows) }
    if (-not $isWin) {
        throw [System.PlatformNotSupportedException]::new("PSLocalBase relies on Windows native winsqlite3.dll and is supported exclusively on Windows operating systems.")
    }
}

# WinSqlite3 P/Invoke definition loaded before module classes are parsed
if (-not ('WinSqlite3' -as [type])) {
    $csharpCode = @'
using System;
using System.Runtime.InteropServices;
using System.Management.Automation;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

// Owns one sqlite3* connection. The finalizer closes connections whose wrapper was never disposed.
public sealed class PSLocalBaseConnectionHandle : SafeHandle {
    public PSLocalBaseConnectionHandle(IntPtr db) : base(IntPtr.Zero, true) { SetHandle(db); }
    public override bool IsInvalid { get { return handle == IntPtr.Zero; } }
    protected override bool ReleaseHandle() { return WinSqlite3.CloseV2(handle) == WinSqlite3.SQLITE_OK; }
}

public class WinSqlite3 {
    public const int BridgeVersion = 4;
    public const int SQLITE_OK = 0;
    public const int SQLITE_BUSY = 5;
    public const int SQLITE_ROW = 100;
    public const int SQLITE_DONE = 101;
    public const int SQLITE_INTEGER = 1;
    public const int SQLITE_FLOAT = 2;
    public const int SQLITE_TEXT = 3;
    public const int SQLITE_BLOB = 4;
    public const int SQLITE_NULL = 5;

    public static readonly IntPtr SQLITE_TRANSIENT = new IntPtr(-1);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void ScalarFunction(IntPtr context, int argc, IntPtr argv);
    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    private delegate void AuxDestructor(IntPtr data);

    // Static roots keep callbacks alive while any connection/statement uses them.
    private static readonly ScalarFunction PsLikeCallback = EvaluatePsLike;
    private static readonly AuxDestructor PatternDestructor = ReleasePattern;

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_create_function16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    private static extern int CreateFunction(IntPtr db, string name, int argc, int encoding, IntPtr data, ScalarFunction callback, IntPtr step, IntPtr final);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_value_type", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ValueType(IntPtr value);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_value_text16", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr ValueText(IntPtr value);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_value_bytes16", CallingConvention = CallingConvention.Cdecl)]
    private static extern int ValueBytes(IntPtr value);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_result_int", CallingConvention = CallingConvention.Cdecl)]
    private static extern void ResultInt(IntPtr context, int value);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_result_null", CallingConvention = CallingConvention.Cdecl)]
    private static extern void ResultNull(IntPtr context);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_result_error16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    private static extern void ResultError(IntPtr context, string message, int bytes);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_get_auxdata", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr GetAuxData(IntPtr context, int argument);
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_set_auxdata", CallingConvention = CallingConvention.Cdecl)]
    private static extern void SetAuxData(IntPtr context, int argument, IntPtr data, AuxDestructor destructor);

    private const int SQLITE_UTF16 = 4;
    private const int SQLITE_DIRECTONLY = 0x000080000;

    public static int RegisterPsLike(IntPtr db) {
        // DIRECTONLY keeps triggers and views stored in an untrusted database file from invoking the callback.
        return CreateFunction(db, "pslocalbase_like", 2, SQLITE_UTF16 | SQLITE_DIRECTONLY, IntPtr.Zero, PsLikeCallback, IntPtr.Zero, IntPtr.Zero);
    }

    // Returns the deepest object/array nesting level, ignoring brackets inside double-quoted strings.
    // Input that this scanner cannot measure reliably (JSON5 quotes or comments, unbalanced
    // brackets, an unterminated string) reports int.MaxValue so callers reject it.
    public static int JsonNestingDepth(string json) {
        if (json == null) return 0;
        int depth = 0, max = 0;
        bool inString = false;
        for (int i = 0; i < json.Length; i++) {
            char c = json[i];
            if (inString) {
                if (c == '\\') { i++; }
                else if (c == '"') { inString = false; }
            } else if (c == '"') {
                inString = true;
            } else if (c == '{' || c == '[') {
                depth++;
                if (depth > max) max = depth;
            } else if (c == '}' || c == ']') {
                depth--;
                if (depth < 0) return int.MaxValue;
            } else if (c == '\'' || c == '/') {
                return int.MaxValue;
            }
        }
        if (inString || depth != 0) return int.MaxValue;
        return max;
    }

    // Variadic sqlite3_db_config with one int argument and an optional int* result.
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_db_config", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NativeDbConfig(IntPtr db, int op, int value, IntPtr result);

    public const int SQLITE_DBCONFIG_ENABLE_TRIGGER = 1003;
    public const int SQLITE_DBCONFIG_DEFENSIVE = 1010;
    public const int SQLITE_DBCONFIG_ENABLE_VIEW = 1015;

    public static int DbConfig(IntPtr db, int op, int value) {
        return NativeDbConfig(db, op, value, IntPtr.Zero);
    }

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_limit", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Limit(IntPtr db, int id, int newValue);

    public const int SQLITE_LIMIT_LENGTH = 0;

    private static string ReadValue(IntPtr value) {
        IntPtr text = ValueText(value);
        return text == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUni(text, ValueBytes(value) / 2);
    }

    private static void EvaluatePsLike(IntPtr context, int argc, IntPtr argv) {
        try {
            IntPtr value = Marshal.ReadIntPtr(argv, 0);
            IntPtr patternValue = Marshal.ReadIntPtr(argv, IntPtr.Size);
            // Preserve SQL NULL behavior for both positive and negated predicates.
            if (ValueType(value) == SQLITE_NULL || ValueType(patternValue) == SQLITE_NULL) {
                ResultNull(context);
                return;
            }
            WildcardPattern matcher;
            IntPtr cached = GetAuxData(context, 1);
            if (cached != IntPtr.Zero) {
                matcher = (WildcardPattern)GCHandle.FromIntPtr(cached).Target;
            } else {
                matcher = new WildcardPattern(ReadValue(patternValue), WildcardOptions.IgnoreCase);
                GCHandle handle = GCHandle.Alloc(matcher);
                // SQLite releases this handle when the argument changes or the statement ends.
                SetAuxData(context, 1, GCHandle.ToIntPtr(handle), PatternDestructor);
            }
            ResultInt(context, matcher.IsMatch(ReadValue(value)) ? 1 : 0);
        } catch (Exception) {
            // Never let managed exceptions cross the unmanaged callback boundary.
            ResultError(context, "PSLocalBase -like pattern evaluation failed.", -1);
        }
    }

    private static void ReleasePattern(IntPtr data) {
        try {
            if (data != IntPtr.Zero) GCHandle.FromIntPtr(data).Free();
        } catch (Exception) {
            // Never let managed exceptions cross the unmanaged callback boundary.
        }
    }

    // Connection lifecycle
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_open16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int Open(string filename, out IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Close(IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_close_v2", CallingConvention = CallingConvention.Cdecl)]
    public static extern int CloseV2(IntPtr db);

    // Command lifecycle
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int Prepare(IntPtr db, string sql, int numBytes, out IntPtr stmt, IntPtr pzTail);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_prepare16_v2", CallingConvention = CallingConvention.Cdecl)]
    private static extern int PrepareRaw(IntPtr db, IntPtr sql, int numBytes, out IntPtr stmt, out IntPtr pzTail);

    // Pure SQL text recognition, including internal CREATE TRIGGER semicolons.
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_complete16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    private static extern int Complete(string sql);

    private static int SkipSqlTrivia(string sql, int offset) {
        while (offset < sql.Length) {
            char c = sql[offset];
            if (c == ' ' || (c >= '\t' && c <= '\r') || c == '\uFEFF' || c == ';') {
                offset++;
            } else if (c == '-' && offset + 1 < sql.Length && sql[offset + 1] == '-') {
                offset += 2;
                while (offset < sql.Length && sql[offset] != '\n') offset++;
            } else if (c == '/' && offset + 1 < sql.Length && sql[offset + 1] == '*') {
                int end = sql.IndexOf("*/", offset + 2, StringComparison.Ordinal);
                offset = end < 0 ? sql.Length : end + 2;
            } else {
                break;
            }
        }
        return offset;
    }

    // Reject compound SQL before preparing even the first statement: PRAGMA
    // can change connection state during preparation, before sqlite3_step.
    public static int PrepareSingle(IntPtr db, string sql, out IntPtr stmt, out bool hasTrailingStatement) {
        stmt = IntPtr.Zero;
        hasTrailingStatement = false;
        // SQLite stops reading at NUL, which would silently drop the rest of the text.
        if (sql != null && sql.IndexOf('\0') >= 0) {
            hasTrailingStatement = true;
            return SQLITE_OK;
        }
        sql = sql ?? string.Empty;
        int start = SkipSqlTrivia(sql, 0);
        for (int i = start; i < sql.Length; i++) {
            if (sql[i] != ';') continue;
            int complete = Complete(sql.Substring(start, i - start + 1));
            if (complete != 0 && complete != 1) return complete;
            if (complete == 0) continue;
            hasTrailingStatement = SkipSqlTrivia(sql, i + 1) < sql.Length;
            if (hasTrailingStatement) return SQLITE_OK;
            break;
        }
        IntPtr buffer = Marshal.StringToHGlobalUni(sql);
        try {
            IntPtr tail;
            return PrepareRaw(db, buffer, -1, out stmt, out tail);
        } finally {
            Marshal.FreeHGlobal(buffer);
        }
    }

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_db_filename", CallingConvention = CallingConvention.Cdecl)]
    private static extern IntPtr NativeDbFilename(IntPtr db, byte[] dbName);

    public static string DbFilename(IntPtr db) {
        IntPtr ptr = NativeDbFilename(db, System.Text.Encoding.UTF8.GetBytes("main\0"));
        return GetUtf8String(ptr);
    }

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_step", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Step(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_finalize", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Finalize(IntPtr stmt);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_reset", CallingConvention = CallingConvention.Cdecl)]
    public static extern int Reset(IntPtr stmt);

    // Parameter binding
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_text16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern int BindText(IntPtr stmt, int index, string val, int nLength, IntPtr destructor);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_null", CallingConvention = CallingConvention.Cdecl)]
    public static extern int BindNull(IntPtr stmt, int index);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_int64", CallingConvention = CallingConvention.Cdecl)]
    public static extern int BindInt64(IntPtr stmt, int index, long val);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_double", CallingConvention = CallingConvention.Cdecl)]
    public static extern int BindDouble(IntPtr stmt, int index, double val);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_bind_parameter_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int BindParameterCount(IntPtr stmt);

    // Data extraction
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_type", CallingConvention = CallingConvention.Cdecl)]
    public static extern int ColumnType(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_bytes16", CallingConvention = CallingConvention.Cdecl)]
    public static extern int ColumnBytes16(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_int64", CallingConvention = CallingConvention.Cdecl)]
    public static extern long ColumnInt64(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_double", CallingConvention = CallingConvention.Cdecl)]
    public static extern double ColumnDouble(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_text16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ColumnText(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_name16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr ColumnName(IntPtr stmt, int colIndex);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_column_count", CallingConvention = CallingConvention.Cdecl)]
    public static extern int ColumnCount(IntPtr stmt);

    // Transaction autocommit status
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_get_autocommit", CallingConvention = CallingConvention.Cdecl)]
    public static extern int GetAutocommit(IntPtr db);

    // Error and execution helpers
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_errmsg16", CharSet = CharSet.Unicode, CallingConvention = CallingConvention.Cdecl)]
    public static extern IntPtr Errmsg(IntPtr db);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_busy_timeout", CallingConvention = CallingConvention.Cdecl)]
    public static extern int BusyTimeout(IntPtr db, int ms);

    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_exec", CallingConvention = CallingConvention.Cdecl)]
    private static extern int NativeExec(IntPtr db, byte[] sqlUtf8, IntPtr callback, IntPtr arg, out IntPtr errmsg);

    public static int Exec(IntPtr db, string sql, IntPtr callback, IntPtr arg, out IntPtr errmsg) {
        string text = sql ?? string.Empty;
        int byteCount = System.Text.Encoding.UTF8.GetByteCount(text);
        byte[] utf8Bytes = new byte[byteCount + 1];
        System.Text.Encoding.UTF8.GetBytes(text, 0, text.Length, utf8Bytes, 0);
        return NativeExec(db, utf8Bytes, callback, arg, out errmsg);
    }

    // Memory reclamation
    [DllImport("winsqlite3.dll", EntryPoint = "sqlite3_free", CallingConvention = CallingConvention.Cdecl)]
    public static extern void Free(IntPtr ptr);

    // UTF-16 string conversion from unmanaged memory (sqlite3_*16 APIs)
    public static string GetString(IntPtr ptr) {
        if (ptr == IntPtr.Zero) return null;
        return Marshal.PtrToStringUni(ptr);
    }

    public static string GetString(IntPtr ptr, int charLen) {
        if (ptr == IntPtr.Zero) return null;
        return Marshal.PtrToStringUni(ptr, charLen);
    }

    // UTF-8 string conversion from unmanaged memory (sqlite3_exec errmsg)
    public static string GetUtf8String(IntPtr ptr) {
        if (ptr == IntPtr.Zero) return null;
        int len = 0;
        while (Marshal.ReadByte(ptr, len) != 0) {
            len++;
        }
        if (len == 0) return string.Empty;
        byte[] buffer = new byte[len];
        Marshal.Copy(ptr, buffer, 0, len);
        return System.Text.Encoding.UTF8.GetString(buffer);
    }

    public static string GetErrorMessage(IntPtr db) {
        if (db == IntPtr.Zero) return "Invalid SQLite database pointer (IntPtr.Zero)";
        IntPtr err = Errmsg(db);
        return GetString(err);
    }
}
'@
    Add-Type -TypeDefinition $csharpCode -ReferencedAssemblies ([System.Management.Automation.PSObject].Assembly.Location)
}
}
