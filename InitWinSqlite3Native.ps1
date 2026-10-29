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
    Add-Type -TypeDefinition $csharpCode
}
