$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:failed = 0
$script:passed = 0
function Assert-Contract($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Rejected([scriptblock]$Body, [string]$Pattern = '.') {
    $failure = $null
    try { & $Body } catch { $failure = $_ }
    if (-not $failure -or $failure.Exception.Message -notmatch $Pattern) { throw "Expected rejection matching '$Pattern'; got '$failure'" }
}
function Test-Contract([string]$Name, [scriptblock]$Body) {
    $db = Connect-LocalBase ':memory:' -PassThru
    try { & $Body $db; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $_`n$($_.ScriptStackTrace)" }
    finally { Disconnect-LocalBase; $db.close() }
}

Test-Contract 'Identity: point/query Get, collection/id collisions, Set/Update/Remove streaming' {
    param($db)
    foreach ($lookup in @('point', 'query')) {
        foreach ($verb in @('Set', 'Update', 'Remove')) {
            foreach ($key in @('a', 'b')) {
                $db.collection('x').doc($key).set(@{ id = 'business'; Collection = 'other'; v = 1 })
                $db.collection('other').doc($key).set(@{ v = 99 })
            }
            $docs = if ($lookup -eq 'point') { foreach ($key in @('a','b')) { Get-LocalBaseDocument x -Id $key } } else { Get-LocalBaseDocument x }
            switch ($verb) {
                Set { $docs | ForEach-Object { $_.v = 2; $_ } | Set-LocalBaseDocument }
                Update { $docs | Update-LocalBaseDocument -Data @{ v = 2 } }
                Remove { $docs | Remove-LocalBaseDocument -Confirm:$false }
            }
            foreach ($key in @('a', 'b')) {
                Assert-Contract ($db.collection('other').doc($key).get().v -eq 99) 'Payload Collection redirected operation'
                if ($verb -eq 'Remove') { Assert-Contract (-not $db.collection('x').doc($key).exists()) 'Real key was not removed' }
                else {
                    $raw = $db.collection('x').doc($key).get()
                    Assert-Contract ($raw.v -eq 2 -and $raw.id -eq 'business') 'Real key not updated or business id lost'
                    Assert-Contract (-not $raw.PSObject.Properties['_localbase_key']) 'Synthetic metadata persisted'
                }
            }
            Assert-Contract (-not $db.collection('x').doc('business').exists()) 'Payload id became storage key'
        }
    }
}

Test-Contract 'Identity: explicit overrides, fallback objects, metadata collisions and synthetic id' {
    param($db)
    $db.collection('x').doc('a').set(@{ Collection='other'; id='business'; _localbase_key='payload-key'; _localbase_collection='payload-col'; v=1 })
    $doc = Get-LocalBaseDocument x -Id a
    $doc._localbase_key = 'tampered'
    $doc._localbase_collection = 'tampered'
    $doc | Set-LocalBaseDocument
    $raw = $db.collection('x').doc('a').get()
    Assert-Contract ($raw._localbase_key -eq 'payload-key' -and $raw._localbase_collection -eq 'payload-col') 'Collision data was lost'
    $doc | Set-LocalBaseDocument -Collection dest -Id explicit
    $doc | Update-LocalBaseDocument -Collection dest -Id explicit -Data @{ v=3 }
    Assert-Contract ($db.collection('dest').doc('explicit').get().v -eq 3) 'Explicit update override ignored'
    $doc | Remove-LocalBaseDocument -Collection dest -Id explicit -Confirm:$false
    Assert-Contract ($db.collection('x').doc('a').exists() -and -not $db.collection('dest').doc('explicit').exists()) 'Explicit remove override ignored'
    $doc | Set-LocalBaseDocument -Id new
    $doc | Set-LocalBaseDocument -Collection dest
    Assert-Contract ($db.collection('x').doc('new').exists() -and $db.collection('dest').doc('a').exists()) 'Partial explicit override ignored'
    @([pscustomobject]@{ Collection='fallback'; id='one'; v=1 }, [pscustomobject]@{ Collection='fallback'; id='two'; v=2 }) | Set-LocalBaseDocument
    Get-LocalBaseDocument fallback | Update-LocalBaseDocument -Data @{ v=4 }
    Assert-Contract ($db.collection('fallback').count() -eq 2 -and $db.collection('fallback').sum('v') -eq 8) 'Content fallback or streaming failed'
    $db.collection('plain').doc('real').set(@{ v=1 })
    Get-LocalBaseDocument plain -Id real | Set-LocalBaseDocument
    Get-LocalBaseDocument plain | Add-LocalBaseDocument -Collection copies | Out-Null
    foreach ($raw in @($db.collection('plain').doc('real').get(), $db.collection('copies').first())) {
        Assert-Contract (-not $raw.PSObject.Properties['id'] -and -not $raw.PSObject.Properties['_localbase_collection']) 'Artificial id/metadata persisted'
    }
}

Test-Contract 'Key AND filters: both orders, all read terminals, delete and write rejection' {
    param($db)
    $c = $db.collection('c')
    $c.doc('a').set(@{ role='admin'; n=10; tags=@(1,2); ref='f' })
    $c.doc('b').set(@{ role='guest'; n=20; tags=@(1); ref='f' })
    $db.collection('foreign').doc('f').set(@{ label='joined' })
    foreach ($q in @($c.doc('a').where('role','==','guest'), $c.where('role','==','guest').doc('a'))) {
        Assert-Contract ($null -eq $q.get() -and $q.count() -eq 0 -and -not $q.exists()) 'Key and filter did not intersect'
        Assert-Contract ($q.sum('n') -eq 0 -and @($q.distinct('role')).Count -eq 0 -and $null -eq $q.first()) 'Read helper ignored intersection'
        Assert-Contract ($null -eq $q.select(@('role')).get() -and $null -eq $q.populate('ref','foreign').get()) 'Projection/populate ignored filter'
        $q.delete()
        Assert-Contract ($c.count() -eq 2) 'Mismatching filter deleted a document'
        Assert-Rejected { $q.set(@{ n=9 }) } 'filters'
        Assert-Rejected { $q.update(@{ n=9 }) } 'filters'
        Assert-Rejected { $q.upsert(@{ n=9 }) } 'filters'
    }
    foreach ($q in @($c.doc('a').whereExists('tags'), $c.whereExists('tags').doc('a'), $c.doc('a').whereLength('tags',2), $c.doc('a').whereType('role','text'))) {
        Assert-Contract ($q.count() -eq 1 -and $q.get().n -eq 10 -and $q.exists()) 'Filter helper lost key'
    }
    Assert-Contract (-not $c.doc('a').whereMissing('tags').exists()) 'whereMissing ignored key/filter'
    $union = $c.unionAll($db.collection('empty')).doc('a').where('role','==','guest')
    Assert-Contract ($union.count() -eq 0 -and @($union.get()).Count -eq 0 -and -not $union.exists()) 'Union outer key/filter mismatch'
    $match = $c.where('role','==','guest').doc('b')
    Assert-Contract ($match.get(@{keys=$true}).key -eq 'b' -and $match.sum('n') -eq 20) 'Matching key/filter read failed'
    $match.delete()
    Assert-Contract ($c.count() -eq 1 -and $c.doc('a').exists()) 'Matching delete broadened selection'
}

Test-Contract 'Transactions: scoped database, success/error restoration, both errors and nesting' {
    param($db)
    $b = New-LocalBase
    try {
        $ErrorActionPreference = 'Continue'
        foreach ($kind in @('terminating', 'nonterminating')) {
            Assert-Rejected {
                Invoke-LocalBaseTransaction -Database $b {
                    Add-LocalBaseDocument tx -Id item -Data @{ v=1 }
                    if ($kind -eq 'terminating') { throw 'tx failure' } else { Write-Error 'tx failure' }
                }
            } 'tx failure'
            Assert-Contract ($b.collection('tx').count() -eq 0 -and $db.collection('tx').count() -eq 0) 'Transaction leaked writes'
            Assert-Contract ((Get-LocalBaseConnection) -eq $db -and $ErrorActionPreference -eq 'Continue') 'Ambient state not restored after failure'
        }
        $output = Invoke-LocalBaseTransaction -Database $b { Add-LocalBaseDocument tx -Id ok -Data @{ v=2 } }
        Assert-Contract ($output -eq 'ok' -and $b.collection('tx').doc('ok').exists() -and $db.collection('tx').count() -eq 0) 'Success routed incorrectly'
        Assert-Contract ((Get-LocalBaseConnection) -eq $db -and $ErrorActionPreference -eq 'Continue') 'State not restored on success'
        Invoke-LocalBaseTransaction {
            Add-LocalBaseDocument tx -Id outer -Data @{ v=3 } | Out-Null
            Assert-Rejected { Invoke-LocalBaseTransaction { throw 'must not run' } } 'transaction'
            Assert-Contract $db.InTransaction 'Nested rejection rolled back outer transaction'
            Invoke-LocalBaseTransaction -Database $b { Add-LocalBaseDocument tx -Id inner -Data @{ v=4 } | Out-Null }
            Assert-Contract ((Get-LocalBaseConnection) -eq $db) 'Cross-database nested scope not restored'
        }
        Assert-Contract ($db.collection('tx').doc('outer').exists() -and $b.collection('tx').doc('inner').exists()) 'Nested behavior damaged connections'
    } finally { $b.close() }
}

Test-Contract 'Add explicit key rejects duplicate without overwrite and streams generated keys' {
    param($db)
    Assert-Contract ((Add-LocalBaseDocument c -Id a -Data @{ v=1 }) -eq 'a') 'Custom key output changed'
    Assert-Rejected { [pscustomobject]@{v=2} | Add-LocalBaseDocument c -Id a } 'UNIQUE|constraint'
    Assert-Contract ($db.collection('c').doc('a').get().v -eq 1 -and $db.collection('c').count() -eq 1) 'Duplicate overwrote original'
    $keys = @(@{v=3}, @{v=4}) | Add-LocalBaseDocument c
    Assert-Contract ($keys.Count -eq 2 -and $keys[0] -ne $keys[1] -and $db.collection('c').count() -eq 3) 'Add pipeline contract changed'
    Add-LocalBaseDocument arrays -Id empty -Data @() | Out-Null
    Set-LocalBaseDocument arrays -Id single -Data @(1)
    $raw = $db.query('SELECT key, doc FROM arrays ORDER BY key;')
    Assert-Contract ($raw[0].doc -eq '[]' -and $raw[1].doc -eq '[1]') 'Payload cleanup enumerated array documents'
}

Test-Contract 'Write limits: UTF16 boundary, depth, set/add/update/upsert and bulk rollback' {
    param($db)
    foreach ($kind in @('bytes', 'depth')) {
        $options = if ($kind -eq 'bytes') { @{ maxDocumentBytes=64 } } else { @{ maxReadDepth=2 } }
        $limited = New-LocalBase -Options $options
        try {
            $c = $limited.collection('c')
            $c.doc('old').set(@{v=1})
            $bad = if ($kind -eq 'bytes') { @{v=('x'*100)} } else { @{v=@{child=@{leaf=1}}} }
            foreach ($write in @({ $c.doc('old').set($bad) }, { $c.add($bad,'new') }, { $c.doc('old').update($bad) }, { $c.upsert($bad,'old') })) {
                Assert-Rejected $write 'maxDocumentBytes|maxReadDepth'
                Assert-Contract ($c.count() -eq 1 -and $c.doc('old').get().v -eq 1) 'Failed write mutated documents'
            }
            foreach ($outer in @($false,$true)) {
                if ($outer) { $limited.beginTransaction(); $c.doc('outer').set(@{v=2}) }
                Assert-Rejected { $c.replaceAll(@(@{v=2}, $bad)) } 'maxDocumentBytes|maxReadDepth'
                Assert-Contract ($c.doc('old').get().v -eq 1) 'Bulk failure lost previous data'
                if ($outer) {
                    Assert-Contract ($limited.InTransaction -and $c.doc('outer').exists()) 'Bulk savepoint damaged outer transaction'
                    $limited.rollback()
                }
                Assert-Contract ($c.count() -eq 1) 'Bulk failure retained partial writes'
            }
            if ($kind -eq 'bytes') {
                # {"v":"..."} uses eight UTF-16 code units plus the value.
                $c.doc('edge').set(@{v=([string][char]0x00e9 * 24)})
                Assert-Contract ($c.doc('edge').get().v.Length -eq 24) 'Exact UTF16 byte limit rejected'
                Assert-Rejected { $c.doc('edge').set(@{v=('x'*25)}) } 'maxDocumentBytes'
            } else {
                $c.doc('edge').set(@{v=@{leaf=1}})
                Assert-Contract ($c.doc('edge').get().v.leaf -eq 1) 'Exact nesting limit rejected'
            }
        } finally { $limited.close() }
    }
    $db.collection('default').doc('ok').set(@{v=('x'*1000); nested=@{leaf=1}})
    Assert-Contract ($db.collection('default').doc('ok').get().v.Length -eq 1000) 'Default write/read contract changed'
    Assert-Rejected { $db.collection('default').doc('ok').set(@{v=('x'*8MB)}) } 'maxDocumentBytes'
    Assert-Contract ($db.collection('default').doc('ok').get().v.Length -eq 1000) 'Default limit failure overwrote prior data'
}

Test-Contract 'Journal readback and removal: active handles, WhatIf, Force, errors and sidecars' {
    param($db)
    $path = Join-Path ([IO.Path]::GetTempPath()) ('pslb-contract-' + [guid]::NewGuid().ToString('N') + '.db')
    $explicit = $null
    try {
        foreach ($mode in @('WAL','DELETE')) {
            $connection = Connect-LocalBase $path -JournalMode $mode -PassThru
            Assert-Contract ($connection.query('PRAGMA journal_mode;')[0].journal_mode -eq $mode) 'Actual journal mode differs'
            foreach ($force in @($false,$true)) { Assert-Rejected { Remove-LocalBaseDatabase $path -Force:$force -Confirm:$false } 'Close all connections' }
            Remove-LocalBaseDatabase $path -WhatIf
            Assert-Contract ($connection.collection('c').count() -eq 0 -and (Test-Path -LiteralPath $path)) 'Removal closed active connection or ignored WhatIf'
            foreach ($unsupported in @('TRUNCATE','PERSIST','MEMORY','OFF')) {
                Assert-Rejected { Connect-LocalBase $path -JournalMode $unsupported } 'ValidateSet|does not belong|not part'
            }
            Assert-Contract ((Get-LocalBaseConnection) -eq $connection) 'Rejected mode disconnected ambient database'
            Disconnect-LocalBase
        }
        $explicit = New-LocalBase $path
        Assert-Rejected { Remove-LocalBaseDatabase $path -Force -Confirm:$false } 'Close all connections'
        $explicit.close()
        $stream = [IO.File]::Open($path, 'Open', 'Read', 'None')
        try { Assert-Rejected { Remove-LocalBaseDatabase $path -Confirm:$false } 'Close all connections' } finally { $stream.Dispose() }
        [IO.File]::SetAttributes($path, [IO.FileAttributes]::ReadOnly)
        Assert-Rejected { Remove-LocalBaseDatabase $path -Confirm:$false } 'read-only'
        Remove-LocalBaseDatabase $path -Force -WhatIf
        Assert-Contract (Test-Path -LiteralPath $path) 'Force bypassed WhatIf'
        foreach ($suffix in @('-wal','-shm','-journal')) { [IO.File]::WriteAllText($path+$suffix, 'test sidecar') }
        Remove-LocalBaseDatabase $path -Force -Confirm:$false
        foreach ($target in @($path, "$path-wal", "$path-shm", "$path-journal")) { Assert-Contract (-not (Test-Path -LiteralPath $target)) "File was not removed: $target" }
        Remove-LocalBaseDatabase $path -Confirm:$false
        [void][IO.Directory]::CreateDirectory($path)
        Assert-Rejected { Remove-LocalBaseDatabase $path -Force -Confirm:$false } 'directory'
        [IO.Directory]::Delete($path)
    } finally {
        if ($explicit) { $explicit.close() }
        Disconnect-LocalBase
        foreach ($target in @($path, "$path-wal", "$path-shm", "$path-journal")) {
            if ([IO.File]::Exists($target)) { [IO.File]::SetAttributes($target, [IO.FileAttributes]::Normal); [IO.File]::Delete($target) }
        }
        if ([IO.Directory]::Exists($path)) { [IO.Directory]::Delete($path) }
    }
}

Write-Host "Contracts: $script:passed passed, $script:failed failed"
if ($script:failed) { exit 1 }
exit 0
