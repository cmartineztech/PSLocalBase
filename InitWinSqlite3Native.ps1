# ---------------------------------------------------------------------------
# InitWinSqlite3Native.ps1
# P/Invoke bridge targeting Windows native winsqlite3.dll
# ---------------------------------------------------------------------------

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
public class WinSqlite3 {
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

    public static int RegisterPsLike(IntPtr db) {
        // UTF16 native order. Registration belongs to the connection and is closed with it.
        return CreateFunction(db, "pslocalbase_like", 2, 4, IntPtr.Zero, PsLikeCallback, IntPtr.Zero, IntPtr.Zero);
    }

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
        if (data != IntPtr.Zero) GCHandle.FromIntPtr(data).Free();
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
