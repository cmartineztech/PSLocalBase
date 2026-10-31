$ErrorActionPreference='Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$passed=0; $failed=0
function Assert-True($condition,$message) { if(-not $condition){throw $message} }
function Test-Case($name,[scriptblock]$action) {
    $db=New-LocalBase
    try { & $action $db; $script:passed++; Write-Host "[PASS] $name" }
    catch {$script:failed++; Write-Host "[FAIL] $name : $($_.Exception.Message)"}
    finally {$db.close()}
}
foreach($pragma in @('trusted_schema','ignore_check_constraints','writable_schema')) {
    foreach($position in @('first','last')) {
        Test-Case "$pragma $position" {
            param($db)
            $null=$db.query("PRAGMA $pragma=OFF;")
            $sql=if($position -eq 'first'){"PRAGMA $pragma=ON; SELECT 1;"}else{"SELECT 1; PRAGMA $pragma=ON;"}
            $rejected=$false
            try {$null=$db.query($sql)}catch [System.InvalidOperationException] {$rejected=$true}
            Assert-True $rejected 'Compound SQL accepted'
            Assert-True (($db.query("PRAGMA $pragma;")).$pragma -eq 0) 'Rejected SQL changed pragma'
        }
    }
}
foreach($position in @('first','last')) {
    Test-Case "CHECK survives $position" {
        param($db)
        $null=$db.query("CREATE TABLE bounded(key TEXT PRIMARY KEY,doc TEXT CHECK(json_extract(doc,'$.n')>0));")
        $db.collection('bounded').doc('a').set(@{n=1})
        $sql=if($position -eq 'first'){'PRAGMA ignore_check_constraints=ON; SELECT 1;'}else{'SELECT 1; PRAGMA ignore_check_constraints=ON;'}
        $rejected=$false
        try {$null=$db.query($sql)}catch [System.InvalidOperationException] {$rejected=$true}
        Assert-True $rejected 'Compound accepted'
        $blocked=$false
        try {$db.collection('bounded').doc('a').set(@{n=-1})}catch [System.InvalidOperationException] {$blocked=$true}
        Assert-True $blocked 'CHECK disabled after rejected SQL'
        Assert-True ($db.collection('bounded').doc('a').get().n -eq 1) 'Document changed'
    }
}
Test-Case 'Quoted tokens and comments' {
    param($db)
    $r=$db.query("/* ; PRAGMA trusted_schema=ON; */ SELECT 'a;''b' AS [semi;colon]; -- ; SELECT 2;")
    Assert-True ($r.'semi;colon' -ceq "a;'b") 'Quoted content changed'
    $r=$db.query('SELECT 7 AS "a;b", 8 AS `c;d`; /* tail ; */')
    Assert-True ($r.'a;b' -eq 7 -and $r.'c;d' -eq 8) 'Quoted identifiers changed'
}
Test-Case 'Trigger body remains one statement' {
    param($db)
    $null=$db.query('CREATE TABLE src(n INTEGER);')
    $null=$db.query('CREATE TABLE dst(n INTEGER);')
    $null=$db.query("CREATE TEMP TRIGGER audit_insert AFTER INSERT ON src BEGIN INSERT INTO dst VALUES(NEW.n); INSERT INTO dst VALUES(CASE WHEN NEW.n>0 THEN 99 ELSE 0 END); END; -- tail")
    $null=$db.query('INSERT INTO src VALUES(1);')
    Assert-True (@($db.query('SELECT n FROM dst ORDER BY n;')).Count -eq 2) 'Trigger did not execute both statements'
    $blocked=$false
    try {$null=$db.query('CREATE TRIGGER bad AFTER INSERT ON src BEGIN SELECT 1; END; PRAGMA trusted_schema=ON;')}catch [System.InvalidOperationException] {$blocked=$true}
    Assert-True $blocked 'Trigger plus pragma accepted'
    Assert-True ($db.query('PRAGMA trusted_schema;').trusted_schema -eq 0) 'Trigger tail changed pragma'
    Assert-True (@($db.query("SELECT name FROM sqlite_master WHERE name='bad';")).Count -eq 0) 'Rejected trigger created'
}
Test-Case 'Single pragma and NUL contracts' {
    param($db)
    $null=$db.query('PRAGMA trusted_schema=ON;')
    Assert-True ($db.query('PRAGMA trusted_schema;').trusted_schema -eq 1) 'Single pragma lost effect'
    $blocked=$false
    try {$null=$db.query("SELECT 1;`0SELECT 2;")}catch [System.InvalidOperationException] {$blocked=$true}
    Assert-True $blocked 'NUL SQL accepted'
    Assert-True ($db.query('SELECT ? AS value;',@("a`0b")).value -ceq "a`0b") 'NUL parameter changed'
}
foreach($tail in @('INSERT INTO items VALUES(2);','UPDATE items SET n=2;','DELETE FROM items;','DROP TABLE items;','CREATE TABLE unexpected(n);')) {
    Test-Case "DML/DDL $tail" {
        param($db)
        $null=$db.query('CREATE TABLE items(n INTEGER);')
        $null=$db.query('INSERT INTO items VALUES(1);')
        $blocked=$false
        try {$null=$db.query("SELECT 1; $tail")}catch [System.InvalidOperationException] {$blocked=$true}
        Assert-True $blocked 'Compound SQL accepted'
        $rows=@($db.query('SELECT n FROM items;'))
        Assert-True ($rows.Count -eq 1 -and $rows[0].n -eq 1) 'Rows changed'
        Assert-True (@($db.query("SELECT name FROM sqlite_master WHERE name='unexpected';")).Count -eq 0) 'Table created'
    }
}
Test-Case 'Repeated rejection releases native memory' {
    param($db)
    Add-Type 'using System.Runtime.InteropServices; public class PrepareMemory { [DllImport("winsqlite3.dll",EntryPoint="sqlite3_memory_used",CallingConvention=CallingConvention.Cdecl)] public static extern long Used(); }'
    try {$null=$db.query('SELECT 1; PRAGMA trusted_schema=ON;')}catch [System.InvalidOperationException] {}
    $before=[PrepareMemory]::Used()
    for($i=0;$i -lt 100;$i++) {
        $blocked=$false
        try {$null=$db.query('SELECT 1; PRAGMA trusted_schema=ON;')}catch [System.InvalidOperationException] {$blocked=$true}
        Assert-True $blocked 'Compound accepted'
    }
    Assert-True ([PrepareMemory]::Used() -eq $before) 'Native allocations retained'
}
Write-Host "PrepareIsolation: passed=$passed; failed=$failed"
if($failed -gt 0){exit 1}
