# Seeded randomized comparison of query results against an independent PowerShell model.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PSLocalBase.psd1') -Force
$script:passed = 0; $script:failed = 0
$seed = 20261029
$random = [System.Random]::new($seed)

function Check([string]$Name, [scriptblock]$Body) {
    try { & $Body; $script:passed++; Write-Host "[PASS] $Name" }
    catch { $script:failed++; Write-Host "[FAIL] ${Name}: $($_.Exception.Message)" }
}

# Documents: n is an integer, null, or missing; u is unique per collection and drives ordering.
function New-Docs([string]$Prefix, [int]$Count, [int[]]$UniqueValues) {
    $docs = [System.Collections.Generic.List[object]]::new()
    for ($i = 0; $i -lt $Count; $i++) {
        $doc = [ordered]@{ u = $UniqueValues[$i] }
        $roll = $random.Next(10)
        if ($roll -lt 7) { $doc['n'] = $random.Next(0, 20) } elseif ($roll -lt 9) { $doc['n'] = $null }
        $doc['s'] = @('red', 'green', 'blue')[$random.Next(3)]
        $docs.Add([pscustomobject]@{ Key = "$Prefix$i"; Doc = $doc })
    }
    return $docs
}

function Test-Predicate($Doc, [string]$Op, $Value) {
    $has = $Doc.Contains('n') -and $null -ne $Doc['n']
    switch ($Op) {
        '='      { return ($has -and $Doc['n'] -eq $Value) }
        '!='     { return ($has -and $Doc['n'] -ne $Value) }
        '>'      { return ($has -and $Doc['n'] -gt $Value) }
        '<'      { return ($has -and $Doc['n'] -lt $Value) }
        '>='     { return ($has -and $Doc['n'] -ge $Value) }
        '<='     { return ($has -and $Doc['n'] -le $Value) }
        'in'     {
            $hit = $has -and (@($Value | Where-Object { $null -ne $_ }) -contains $Doc['n'])
            return ($hit -or (-not $has -and @($Value | Where-Object { $null -eq $_ }).Count -gt 0))
        }
        'not-in' { return ($has -and -not (@($Value | Where-Object { $null -ne $_ }) -contains $Doc['n'])) }
    }
    throw "Unknown operator $Op"
}

function Get-Page([object[]]$Rows, [object]$Skip, [object]$Limit) {
    $ordered = @($Rows | Sort-Object { $_.Doc['u'] })
    $start = if ($null -ne $Skip) { [int]$Skip } else { 0 }
    if ($start -ge $ordered.Count) { return @() }
    $end = if ($null -ne $Limit) { [Math]::Min($ordered.Count, $start + [int]$Limit) } else { $ordered.Count }
    if ($end -le $start) { return @() }
    return $ordered[$start..($end - 1)]
}

function Format-Keys($Rows) { return (@($Rows | ForEach-Object { $_.Key }) -join ',') }

$db = New-LocalBase
try {
    $uniqueA = @(1..120 | Sort-Object { $random.Next() })
    $uniqueB = @(121..200 | Sort-Object { $random.Next() })
    $docsA = New-Docs 'a' 120 $uniqueA
    $docsB = New-Docs 'b' 80 $uniqueB
    # Shared keys with identical documents exercise UNION de-duplication.
    for ($i = 0; $i -lt 15; $i++) { $docsB[$i] = [pscustomobject]@{ Key = $docsA[$i].Key; Doc = $docsA[$i].Doc } }
    foreach ($d in $docsA) { $db.collection('pa').doc($d.Key).set($d.Doc) }
    foreach ($d in $docsB) { $db.collection('pb').doc($d.Key).set($d.Doc) }
    $ops = @('=', '!=', '>', '<', '>=', '<=', 'in', 'not-in')

    Check "where() operators match the model (seed $seed)" {
        for ($round = 0; $round -lt 80; $round++) {
            $op = $ops[$random.Next($ops.Count)]
            $value = if ($op -in @('in', 'not-in')) {
                $list = @(for ($k = 0; $k -lt $random.Next(0, 5); $k++) { $random.Next(0, 20) })
                if ($random.Next(3) -eq 0) { $list += $null }
                , $list
            } else { $random.Next(0, 20) }
            $expected = @($docsA | Where-Object { Test-Predicate $_.Doc $op $value } | ForEach-Object { $_.Key } | Sort-Object)
            $actual = @($db.collection('pa').where('n', $op, $value).get(@{ keys = $true }) | ForEach-Object { $_.key } | Sort-Object)
            if (($expected -join ',') -cne ($actual -join ',')) { throw "round $round op=$op value=$($value -join '|') expected=$($expected.Count) actual=$($actual.Count)" }
            $count = $db.collection('pa').where('n', $op, $value).count()
            if ($count -ne $expected.Count) { throw "round $round count=$count expected=$($expected.Count)" }
        }
    }

    Check "orderBy/skip/limit pages match the model (seed $seed)" {
        for ($round = 0; $round -lt 40; $round++) {
            $op = $ops[$random.Next(6)]
            $value = $random.Next(0, 20)
            $skip = if ($random.Next(2) -eq 0) { $random.Next(0, 30) } else { $null }
            $limit = if ($random.Next(2) -eq 0) { $random.Next(0, 30) } else { $null }
            $q = $db.collection('pa').where('n', $op, $value).orderBy('u')
            if ($null -ne $skip) { $q = $q.skip($skip) }
            if ($null -ne $limit) { $q = $q.limit($limit) }
            $expected = Get-Page @($docsA | Where-Object { Test-Predicate $_.Doc $op $value }) $skip $limit
            $actual = @($q.get(@{ keys = $true }) | ForEach-Object { [pscustomobject]@{ Key = $_.key } })
            if ((Format-Keys $expected) -cne (Format-Keys $actual)) { throw "round $round op=$op value=$value skip=$skip limit=$limit" }
            if ($q.count() -ne @($expected).Count) { throw "round $round count mismatch" }
            if ($q.exists() -ne (@($expected).Count -gt 0)) { throw "round $round exists mismatch" }
        }
    }

    Check "union/unionAll with branch filters and global paging match the model (seed $seed)" {
        for ($round = 0; $round -lt 40; $round++) {
            $leftValue = $random.Next(0, 20); $rightValue = $random.Next(0, 20); $globalValue = $random.Next(0, 10)
            $all = $random.Next(2) -eq 0
            $skip = $random.Next(0, 20); $limit = $random.Next(1, 25)
            $left = @($docsA | Where-Object { Test-Predicate $_.Doc '>=' $leftValue })
            $right = @($docsB | Where-Object { Test-Predicate $_.Doc '<=' $rightValue })
            $combined = if ($all) { @($left) + @($right) } else {
                $seen = @{}
                @(foreach ($row in (@($left) + @($right))) {
                    $id = $row.Key + '|' + ($row.Doc | ConvertTo-Json -Compress)
                    if (-not $seen.ContainsKey($id)) { $seen[$id] = $true; $row }
                })
            }
            $filtered = @($combined | Where-Object { Test-Predicate $_.Doc '>' $globalValue })
            $expected = Get-Page $filtered $skip $limit
            $lq = $db.collection('pa').where('n', '>=', $leftValue)
            $rq = $db.collection('pb').where('n', '<=', $rightValue)
            $composite = if ($all) { $lq.unionAll($rq) } else { $lq.union($rq) }
            $page = $composite.where('n', '>', $globalValue).orderBy('u').skip($skip).limit($limit)
            $actual = @($page.get(@{ keys = $true }) | ForEach-Object { [pscustomobject]@{ Key = $_.key } })
            if ((Format-Keys $expected) -cne (Format-Keys $actual)) { throw "round $round all=$all left=$leftValue right=$rightValue global=$globalValue skip=$skip limit=$limit" }
            if ($page.count() -ne @($expected).Count) { throw "round $round composite count mismatch" }
        }
    }
} finally { $db.close() }

Write-Host "Property (seed $seed): passed=$script:passed; failed=$script:failed"
if ($script:failed -gt 0) { exit 1 }
