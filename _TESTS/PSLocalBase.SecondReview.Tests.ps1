$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:failed = 0
function Assert($ok, $message) { if (-not $ok) { throw $message } }
function Reject([scriptblock]$body, $pattern = '.') {
    $errorRecord = $null
    try { & $body | Out-Null } catch { $errorRecord = $_ }
    Assert ($null -ne $errorRecord -and $errorRecord.Exception.Message -match $pattern) "Expected rejection ($pattern), got $errorRecord"
}
function Case($name, [scriptblock]$body) {
    $db = Connect-LocalBase ':memory:' -PassThru
    try { & $body $db; Write-Host "[PASS] $name" }
    catch { $script:failed++; Write-Host "[FAIL] ${name}: $_`n$($_.ScriptStackTrace)" }
    finally { Disconnect-LocalBase; $db.close() }
}
Case 'Unsafe existing numbers: comparisons, membership, deletion rollback and indexes' {
    param($db)
    $db.collection('x').doc('safe').set(@{ v = 1; a = @(1) })
    # Simulate legacy/external data, including an existing approximate index.
    $null = $db.query('INSERT INTO x VALUES (''a'', ''{"v":18446744073709551614,"a":[18446744073709551614]}'');')
    $null = $db.query('INSERT INTO x VALUES (''b'', ''{"v":18446744073709551615,"a":[18446744073709551615]}'');')
    $null = $db.query('CREATE INDEX legacy_numeric ON x(json_extract(doc, ''$.v''));')
    foreach ($op in @('==','!=','>','>=','<','<=','in','not-in')) {
        Reject { $db.collection('x').where('v', $op, 1).count() } 'Numeric precision'
        Reject { $db.collection('x').where('v', $op, 1).delete() } 'Numeric precision'
        Assert ($db.collection('x').count() -eq 3) "Partial delete for $op"
    }
    foreach ($op in @('array-contains','array-contains-any')) {
        Reject { $db.collection('x').where('a', $op, 1).delete() } 'Numeric precision'
        Assert ($db.collection('x').count() -eq 3) 'Partial array delete'
    }
    foreach ($value in @([uint64]::MaxValue, [decimal]::MaxValue, [decimal]::Parse('0.10000000000000001', [cultureinfo]::InvariantCulture))) {
        Reject { $db.collection('x').where('v','==',$value).delete() } 'Numeric precision'
        Reject { $db.collection('x').where('a','array-contains-any',@($value)).delete() } 'Numeric precision'
        Assert ($db.collection('x').count() -eq 3) 'Unsafe parameter deleted rows'
    }
    Reject { $db.collection('x').createIndex('v', $true) } 'Numeric precision'
    Reject { $db.collection('x').doc('c').set(@{v=[uint64]::MaxValue}) } 'Numeric precision'
    Assert (-not $db.collection('x').doc('c').exists()) 'Unsafe indexed write persisted'
    $db.collection('d').doc('a').set(@{v=0.1})
    $null = $db.query('INSERT INTO d VALUES (''b'', ''{"v":0.10000000000000001}'');')
    Reject { $db.collection('d').where('v','==',0.1).delete() } 'Numeric precision'
    Assert ($db.collection('d').count() -eq 2) 'Decimal collision lost data'
}
Case 'Supported Int64, uint64 within range, decimals and doubles remain distinct' {
    param($db)
    foreach ($entry in @(@('lo',[long]::MinValue), @('hi',[long]::MaxValue), @('prev',([long]::MaxValue-1)), @('fraction',[decimal]0.1), @('next',[double]::Parse('1.0000000000000002',[cultureinfo]::InvariantCulture)))) {
        $db.collection('x').doc($entry[0]).set(@{v=$entry[1]})
    }
    Assert ($db.collection('x').where('v','==',[uint64][long]::MaxValue).count() -eq 1) 'Int64 boundary rounded'
    Assert ($db.collection('x').where('v','==',[decimal][long]::MaxValue).count() -eq 1) 'Integral decimal parameter rounded'
    Assert ($db.collection('x').where('v','in',@([long]::MinValue,[long]::MaxValue)).count() -eq 2) 'IN lost Int64 precision'
    Assert ($db.collection('x').where('v','==',[decimal]0.1).count() -eq 1) 'Supported decimal failed'
    Assert ($db.collection('x').where('v','==',1.0).count() -eq 0) 'Adjacent double collapsed'
    $db.collection('x').where('v','==',[long]::MaxValue).delete()
    Assert ($db.collection('x').doc('prev').exists()) 'Adjacent Int64 removed'
}
Case 'Reconnect failure preserves ambient connection, data and transaction' {
    param($db)
    $db.beginTransaction()
    $db.collection('x').doc('a').set(@{v=1})
    Reject { Connect-LocalBase -Path ([string][char]0) }
    Reject { Connect-LocalBase ':memory:' -BusyTimeoutMs -1 }
    Reject { Connect-LocalBase ':memory:' -JournalMode INVALID }
    Assert ([object]::ReferenceEquals((Get-LocalBaseConnection), $db)) 'Ambient changed on failure'
    Assert ($db.collection('x').count() -eq 1) 'Pending data lost'
    $db.rollback()
    Assert ($db.collection('x').count() -eq 0) 'Transaction no longer active'
    $replacement = Connect-LocalBase ':memory:' -PassThru
    Assert ($db.DbHandle -eq [IntPtr]::Zero) 'Successful replacement did not close original'
    Assert ($replacement.DbHandle -ne [IntPtr]::Zero) 'New connection closed'
}
Case 'Same file and different file reconnects are validated before replacement' {
    param($db)
    $paths = @((Join-Path $env:TEMP ('pslb-r2-' + [guid]::NewGuid().ToString('N') + '.db')), (Join-Path $env:TEMP ('pslb-r2-' + [guid]::NewGuid().ToString('N') + '.db')))
    try {
        $first = Connect-LocalBase $paths[0] -PassThru
        $first.collection('x').doc('a').set(@{v=1})
        $second = Connect-LocalBase $paths[0] -PassThru
        Assert ($first.DbHandle -eq [IntPtr]::Zero -and $second.collection('x').count() -eq 1) 'Same-file replacement failed'
        $third = Connect-LocalBase $paths[1] -PassThru
        Assert ($second.DbHandle -eq [IntPtr]::Zero -and $third.collection('x').count() -eq 0) 'Different-file replacement failed'
    } finally {
        Disconnect-LocalBase
        foreach ($path in $paths) { foreach ($file in @($path,"$path-wal","$path-shm")) { if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file -Force } } }
    }
}
Case 'Top-level JSON documents preserve shape and trusted identity in point/query pipelines' {
    param($db)
    $jsons = @('[]','[1]','[1,2]','[[1,2],[],[3]]','null','false','42','"text"','{"Value":"business","id":"business"}')
    for ($i=0; $i -lt $jsons.Count; $i++) {
        $db.createCollection('x') | Out-Null
        $null = $db.query("INSERT INTO x VALUES ('$i', '$($jsons[$i])');")
        Get-LocalBaseDocument x -Id "$i" | Set-LocalBaseDocument
        $raw = $db.query("SELECT doc FROM x WHERE key='$i';")
        Assert ($raw[0].doc -ceq $jsons[$i]) "Point pipeline changed $($jsons[$i]) to $($raw[0].doc)"
        Get-LocalBaseDocument x -Id "$i" | Set-LocalBaseDocument x -Id "$i"
        Get-LocalBaseDocument x -Id "$i" | Add-LocalBaseDocument copies -Id "$i" | Out-Null
        Assert (($db.query("SELECT doc FROM copies WHERE key='$i';"))[0].doc -ceq $jsons[$i]) 'Add changed shape'
    }
    Get-LocalBaseDocument x | Set-LocalBaseDocument
    for ($i=0; $i -lt $jsons.Count; $i++) { Assert (($db.query("SELECT doc FROM x WHERE key='$i';"))[0].doc -ceq $jsons[$i]) 'Query pipeline changed shape' }
    Assert (@(Get-LocalBaseDocument x).Count -eq $jsons.Count) 'Array documents enumerated'
    Get-LocalBaseDocument x | Remove-LocalBaseDocument -Confirm:$false
    Assert ($db.collection('x').count() -eq 0) 'Trusted non-object identity lost'
    Assert (@(Get-LocalBaseDocument x -Id missing).Count -eq 0) 'Missing point emitted a document'
    Set-LocalBaseDocument c -Id a -Data @(1,2)
    Get-LocalBaseDocument c -Id a | Set-LocalBaseDocument c -Id a
    Assert (($db.query('SELECT doc FROM c;'))[0].doc -eq '[1,2]') 'Explicit array reproduction failed'
    foreach ($json in @('[]','[1]')) {
        $value = (ConvertFrom-Json ('{"value":'+$json+'}')).value
        $db.collection('c').doc('a').set($value)
        $db.collection('c').doc('b').set($db.collection('c').doc('a').get())
        Assert (($db.query("SELECT doc FROM c WHERE key='b';"))[0].doc -eq $json) 'Fluent array shape lost'
    }
    Set-LocalBaseDocument c -Id explicitNull -Data $null
    Add-LocalBaseDocument c -Id addedNull -Data $null | Out-Null
    Set-LocalBaseDocument c -Id empty -Data @()
    Assert (($db.query("SELECT doc FROM c WHERE key='explicitNull';"))[0].doc -eq 'null') 'Explicit null Set lost'
    Assert (($db.query("SELECT doc FROM c WHERE key='addedNull';"))[0].doc -eq 'null') 'Explicit null Add lost'
    Assert (($db.query("SELECT doc FROM c WHERE key='empty';"))[0].doc -eq '[]') 'Explicit empty array lost'
}
Case 'Distinct rejects modifiers and respects point/filter scope' {
    param($db)
    $db.collection('x').doc('a').set(@{v=1})
    $db.collection('x').doc('b').set(@{v=2})
    Reject { $db.collection('x').limit(0).distinct('v') } 'limit'
    Reject { $db.collection('x').skip(1).distinct('v') } 'skip'
    Reject { $db.collection('x').orderBy('v').distinct('v') } 'orderBy'
    Assert ($db.collection('x').doc('a').where('v','==',1).distinct('v')[0] -eq 1) 'Point/filter distinct scope lost'
    Assert ($db.collection('x').doc('a').where('v','==',2).distinct('v').Count -eq 0) 'Distinct ignored point/filter intersection'
}
Case 'WhatIf collection, index, set and begin transaction have no effects' {
    param($db)
    New-LocalBaseCollection x -WhatIf
    New-LocalBaseIndex x v -WhatIf
    Set-LocalBaseDocument x a -Data @{v=1} -WhatIf
    Start-LocalBaseTransaction -WhatIf
    Assert ($db.getCollections().Count -eq 0) 'WhatIf created schema'
    $db.beginTransaction(); $db.rollback()
}
if ($script:failed) { exit 1 }
exit 0
