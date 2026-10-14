# validate.ps1 —— 文档机械一致性校验
#
# 【只做四件机器擅长的事】
#   1. 数量核对：正文声称的 N 与该表的实际行数是否一致
#   2. 引用完整：引用的错误码 / 文档 / 状态名是否真的存在
#   3. 结构完整：编号连续、条目不重复、Mermaid 语法、表格不串列与有空行、编码没坏
#   4. 硬约定：常量必须带 /// 且注明单位
#
# 【明确不做】—— 这些机器查不出，必须人眼，别指望本脚本：
#   - 内容本身写错（例：把 400 的码写成 409 —— 只要两张表一致，脚本就认为没问题）
#   - 该有的东西根本没写（脚本不知道某张表「本应存在」）
#   - 设计决策互相矛盾（两处措辞都对但冲突）
#   - 数值是否合理（默认 3 天还是 7 天）
#   经验：脚本全过后，人眼仍查出 12 处问题，其中 4 处是会导致写代码失败的语义矛盾，
#   11 处靠【跨文档交叉读】才发现 —— 交叉读才是真正有效的人工动作。
#
# 用法（PS 5.1 需绕执行策略）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/validate.ps1
# 退出码 0 = 全过，1 = 有 FAIL
#
# 本文件必须保存为「UTF-8 with BOM」：PS 5.1 对无 BOM 的 UTF-8 脚本按 ANSI 解析，
# 中文与中文正则全部乱码，校验结果不可信。

$ErrorActionPreference = 'Stop'
$bt = [char]0x60                      # 反引号。PowerShell 字符串里反引号是转义符，必须这样取
$docs = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\projects\trade-core\docs')).Path

$script:fail = 0
$script:pass = 0

$stateNames = @('PENDING_PAYMENT', 'PAID', 'SHIPPED', 'DELIVERED', 'COMPLETED',
    'REFUNDING', 'PARTIALLY_REFUNDED', 'REFUNDED', 'CANCELLED')

function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) { $script:pass++; Write-Host ("  PASS  " + $Name) -ForegroundColor Green }
    else {
        $script:fail++; Write-Host ("  FAIL  " + $Name) -ForegroundColor Red
        if ($Detail) { Write-Host ("        -> " + $Detail) -ForegroundColor Yellow }
    }
}

function Read-Doc {
    param([string]$File)
    $p = Join-Path $docs $File
    if (-not (Test-Path -LiteralPath $p)) { throw "文档不存在：$p" }
    return , @(Get-Content -LiteralPath $p -Encoding UTF8)
}

# 取二级章节正文：从 ^## N. 起到下一个 ^## 标题止（含 ### 子节）
function Get-Section {
    param([string[]]$Lines, [string]$From, [string]$StopPattern = '^## ')
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $From) { $start = $i; break } }
    if ($start -lt 0) { return , @() }
    $out = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($i -gt $start -and $Lines[$i] -match $StopPattern) { break }
        [void]$out.Add($Lines[$i])
    }
    return , $out.ToArray()
}

# 取一张表：表头行起，到第一个非表格行为止。
# 必须精确到「一张表」—— 同一章节常有多张表，只用 Get-Section 会把它们一起数进来。
function Get-Table {
    param([string[]]$Lines, [string]$HeaderPattern)
    $start = -1
    for ($i = 0; $i -lt $Lines.Count; $i++) { if ($Lines[$i] -match $HeaderPattern) { $start = $i; break } }
    if ($start -lt 0) { return , @() }
    $out = New-Object System.Collections.ArrayList
    for ($i = $start; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -notmatch '^\|') { break }
        [void]$out.Add($Lines[$i])
    }
    return , $out.ToArray()
}

function Get-Rows {
    param([string[]]$Table, [string]$RowPattern)
    return @($Table | Where-Object { $_ -match $RowPattern -and $_ -notmatch '^\|[\s\-:|]+\|$' })
}

# 在一段文本里找「声称值」。
# 每个检查各写一条精确正则，而不是做通用量词匹配 —— 中文写法混用
# （「共 9 个状态」/「9 个状态」/「共 14 条」/「三道闸门」），通用方案会连环踩
# 「正则元字符」「捕获组冲突」「共字位置」三个坑，已实测浪费数轮。
$script:cnNum = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9; '十' = 10 }

function Get-Nums {
    param([string[]]$Lines, [string]$Pattern)
    $found = New-Object System.Collections.ArrayList
    foreach ($l in $Lines) {
        foreach ($m in [regex]::Matches($l, $Pattern)) {
            for ($g = 1; $g -lt $m.Groups.Count; $g++) {
                $raw = $m.Groups[$g].Value
                if (-not $raw) { continue }
                if ($raw -match '^[0-9]+$') { $v = [int]$raw }
                elseif ($script:cnNum.ContainsKey($raw)) { $v = $script:cnNum[$raw] }
                else { continue }
                if (-not $found.Contains($v)) { [void]$found.Add($v) }
            }
        }
    }
    return $found.ToArray()
}

# 声称值里包含实测值即算通过（同一量词可能出现在不同语境）
function CheckClaim {
    param([string]$Name, [string[]]$Scope, [string]$Pattern, [int]$Actual)
    $claims = @(Get-Nums -Lines $Scope -Pattern $Pattern)
    Check ("$Name（实际 $Actual）") ($claims -contains $Actual) `
        "该范围内声称：$(if ($claims.Count) { $claims -join ', ' } else { '(无)' })"
}

Write-Host ''
Write-Host '=== 文档机械一致性校验 ===' -ForegroundColor Cyan

# ================================================================ 02 状态机
Write-Host ''
Write-Host '[02-state-machine.md]' -ForegroundColor Cyan
$sm = Read-Doc '02-state-machine.md'

# Mermaid：块内不得有半角分号（会被当语句分隔符，导致整图解析失败）；顺便数边
$inBlock = $false; $semi = @(); $diagEdges = 0
foreach ($l in $sm) {
    if ($l -match '^```mermaid') { $inBlock = $true; continue }
    if ($inBlock -and $l -match '^```') { $inBlock = $false; continue }
    if ($inBlock -and $l -match ';') { $semi += $l.Trim() }
    if ($inBlock -and $l -match '-->') { $diagEdges++ }
}
Check 'Mermaid 块内无半角分号' ($semi.Count -eq 0) ($semi -join ' || ')

# 状态：Mermaid 声明 vs §2 状态集合表
$declaredNames = @($sm | Where-Object { $_ -match '^\s*state "' } |
    ForEach-Object { ([regex]::Match($_, 'as\s+([A-Z_]+)')).Groups[1].Value } | Sort-Object)
$sec2 = Get-Section -Lines $sm -From '^## 2\. 状态集合'
$stateRows = Get-Rows -Table (Get-Table -Lines $sec2 -HeaderPattern '^\| 状态 \|') -RowPattern ('^\| ' + $bt + '[A-Z_]+' + $bt)
$tableStates = @($stateRows | ForEach-Object { ([regex]::Match($_, '^\| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value } | Sort-Object -Unique)
$onlyTable = @($tableStates | Where-Object { $declaredNames -notcontains $_ })
$onlyDiag = @($declaredNames | Where-Object { $tableStates -notcontains $_ })
Check ("状态集合表 vs Mermaid 声明（各 $($tableStates.Count)）") (($onlyTable.Count -eq 0) -and ($onlyDiag.Count -eq 0)) `
    "表中未声明：$($onlyTable -join ',') / 图中未定义：$($onlyDiag -join ',')"
CheckClaim '状态数声称一致' $sec2 '([0-9]+) 个状态' $tableStates.Count

# 事件：§3
$sec3 = Get-Section -Lines $sm -From '^## 3\. 事件清单'
$evRows = Get-Rows -Table (Get-Table -Lines $sec3 -HeaderPattern '^\| 事件 \|') -RowPattern ('^\| ' + $bt + '[A-Z_]+' + $bt)
CheckClaim '事件数声称一致' $sec3 '([0-9]+) 个事件' $evRows.Count

# 转移表：§4（副作用表的行是「| T1 | 内容」，无反引号紧跟，故用反引号区分）
$sec4 = Get-Section -Lines $sm -From '^## 4\. 转移表'
$edges = @($sec4 | Where-Object { $_ -match ('^\| T\d+[a-z]? \| ' + $bt) })
CheckClaim '转移表边数 = 声称值' $sec4 '([0-9]+) 条(?:合法)?转移' $edges.Count
# 图边数 = 表边数 + 1（图多一条入口边 [*] -->）
Check ("图中边数 = 转移表 + 入口边（图 $diagEdges / 表 $($edges.Count)）") ($diagEdges -eq ($edges.Count + 1)) `
    "差 $($diagEdges - $edges.Count) 条，期望差 1"

# 被拒绝转移：§5（按 R 编号数行 —— 列名会随文档演进变，编号不会）
$sec5 = Get-Section -Lines $sm -From '^## 5\. 被拒绝的转移'
$rejIds = @($sec5 | Where-Object { $_ -match '^\| R\d+ \|' } |
    ForEach-Object { ([regex]::Match($_, '^\| (R\d+)')).Groups[1].Value })
CheckClaim '被拒绝转移条数一致' $sec5 '([0-9]+) 条' $rejIds.Count
$dupRej = @($rejIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$rejSeqOk = $true
for ($i = 0; $i -lt $rejIds.Count; $i++) { if ($rejIds[$i] -ne ('R' + ($i + 1))) { $rejSeqOk = $false } }
Check ("被拒绝转移编号连续无重复（$($rejIds.Count) 条）") (($dupRej.Count -eq 0) -and $rejSeqOk) "重复：$($dupRej -join ',')"

# 幂等闸门：§6
$sec6 = Get-Section -Lines $sm -From '^## 6\. 幂等'
$gateRows = @($sec6 | Where-Object { $_ -match '^\| 闸门 [0-9]' })
CheckClaim '幂等闸门数一致' $sec6 '([一二三四五六七八九十]+)\s?道闸门' $gateRows.Count

# 副作用清单必须覆盖全部转移编号：§7
$sec7 = Get-Section -Lines $sm -From '^## 7\. 状态迁移的副作用清单'
$sideText = ($sec7 -join ' ')
$edgeIds = @($edges | ForEach-Object { ([regex]::Match($_, '^\| (T\d+[a-z]?)')).Groups[1].Value })
$notCovered = @()
foreach ($g in ($edgeIds | Group-Object { $_ -replace '[a-z]$', '' } | ForEach-Object { $_.Name })) {
    if ($sideText -notmatch [regex]::Escape($g)) { $notCovered += $g }
}
Check '副作用清单覆盖全部转移编号' ($notCovered.Count -eq 0) "未在 §7 出现：$($notCovered -join ', ')"

# 人工介入：§10
$sec10 = Get-Section -Lines $sm -From '^## 10\.'
$manRows = Get-Rows -Table (Get-Table -Lines $sec10 -HeaderPattern '^\| # \|') -RowPattern '^\| \d+ \|'
CheckClaim '人工介入清单条数一致' $sec10 '共 ([0-9]+) 项' $manRows.Count

# ================================================================ 03 契约
Write-Host ''
Write-Host '[03-api-contract.md]' -ForegroundColor Cyan
$ac = Read-Doc '03-api-contract.md'

# HTTP 状态码：§4
$sec4ac = Get-Section -Lines $ac -From '^## 4\. HTTP 状态码规范'
$httpRows = Get-Rows -Table (Get-Table -Lines $sec4ac -HeaderPattern '^\| 状态码 \|') -RowPattern ('^\| ' + $bt + '\d{3} ')
$definedHttp = @{}
foreach ($r in $httpRows) { $definedHttp[([regex]::Match($r, '^\| ' + $bt + '(\d{3})')).Groups[1].Value] = $true }
CheckClaim 'HTTP 状态码数量声称一致' $sec4ac '([0-9]+) 个状态码' $httpRows.Count

# 全文使用的状态码写法必须都在 §4 定义
$usedHttp = @{}
foreach ($l in $ac) {
    foreach ($m in [regex]::Matches($l, $bt + '(\d{3}) (OK|Created|Accepted|Bad Request|Unauthorized|Forbidden|Not Found|Conflict|Too Many Requests|Internal Server Error|Service Unavailable)' + $bt)) {
        $usedHttp[$m.Groups[1].Value] = $true
    }
}
$undefHttp = @($usedHttp.Keys | Where-Object { -not $definedHttp.ContainsKey($_) })
Check '全文使用的状态码均在 §4 定义' ($undefHttp.Count -eq 0) "未定义：$($undefHttp -join ', ')"

# 错误码：§5
$sec5ac = Get-Section -Lines $ac -From '^## 5\. 错误码总表'
$errRows = @($sec5ac | Where-Object { $_ -match ('^\| \d{5} \| ' + $bt + '[A-Z_]+' + $bt) })
$nums = @($errRows | ForEach-Object { ([regex]::Match($_, '^\| (\d{5})')).Groups[1].Value })
$codes = @($errRows | ForEach-Object { ([regex]::Match($_, '^\| \d{5} \| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value })
$dupN = @($nums | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$dupC = @($codes | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Check ("错误码表无重复（$($errRows.Count) 个）") (($dupN.Count -eq 0) -and ($dupC.Count -eq 0)) `
    "重复数字码：$($dupN -join ',') / 重复码名：$($dupC -join ',')"
CheckClaim '错误码数量声称一致' $sec5ac '共 ([0-9]+) 个错误码' $errRows.Count
# 数字码前缀必须等于 HTTP 列（40001 -> 400）
$mismatch = @($errRows | Where-Object {
        $n = [regex]::Match($_, '^\| (\d{5})').Groups[1].Value
        $h = [regex]::Match($_, '^\| \d{5} \| ' + $bt + '[A-Z_]+' + $bt + ' \| (\d{3})').Groups[1].Value
        $n.Substring(0, 3) -ne $h
    })
Check '错误码数字前缀 = HTTP 状态码' ($mismatch.Count -eq 0) `
    "不一致：$(($mismatch | ForEach-Object { ($_ -split '\|')[1].Trim() }) -join ',')"

# 常量：§7 —— 必须带 /// 且注明单位（硬约定，属机械可查部分）
$consts = @()
for ($i = 0; $i -lt $ac.Count; $i++) {
    if ($ac[$i] -match '^pub const ([A-Z_]+)') { $consts += [pscustomobject]@{ Name = $Matches[1]; Line = $i } }
}
$noDoc = @($consts | Where-Object { $_.Line -lt 1 -or $ac[$_.Line - 1] -notmatch '^\s*///' })
Check ("常量全部带 ///（$($consts.Count) 个）") ($noDoc.Count -eq 0) "缺：$((@($noDoc | ForEach-Object { $_.Name })) -join ', ')"
$noUnit = @($consts | Where-Object {
        $from = [Math]::Max(0, $_.Line - 3)
        (($ac[$from..$_.Line]) -join ' ') -notmatch '单位：'
    })
Check '常量注明单位' ($noUnit.Count -eq 0) "缺：$((@($noUnit | ForEach-Object { $_.Name })) -join ', ')"
CheckClaim '常量数量声称一致' (Get-Section -Lines $ac -From '^## 7\. 常量清单') '共 ([0-9]+) 个常量' $consts.Count

# 端点引用的错误码必须都已定义（防臆造码名），且错误行都声明为「端点特有」
$sec8 = Get-Section -Lines $ac -From '^## 8\. 端点契约'
$epErrLines = @($sec8 | Where-Object { $_ -match '^\| (错误|失败) \|' })
$codeAlt = ($codes | Sort-Object -Descending { $_.Length } | ForEach-Object { [regex]::Escape($_) }) -join '|'
$referenced = @{}
if ($codeAlt) {
    foreach ($l in $epErrLines) {
        foreach ($m in [regex]::Matches($l, '\b(' + $codeAlt + ')\b')) { $referenced[$m.Groups[1].Value] = $true }
    }
}
$unknown = @($referenced.Keys | Where-Object { $codes -notcontains $_ })
Check '端点引用的错误码全部已定义' ($unknown.Count -eq 0) "未定义：$($unknown -join ', ')"
$badEpErr = @($epErrLines | Where-Object { $_ -notmatch '端点特有|仅验签失败' })
Check '端点错误行均声明为「端点特有」' ($badEpErr.Count -eq 0) "$($badEpErr.Count) 行未声明"

# 端点总数 = 详述块 + 管理表格
$detailEps = @($sec8 | Where-Object { $_ -match ('^#### ' + $bt) })
$adminEps = @($sec8 | Where-Object { $_ -match ('^\| ' + $bt + '(GET|POST) /admin|^\| ' + $bt + 'GET /healthz') })
Check ("端点详述 + 管理表格 = 16（$($detailEps.Count) + $($adminEps.Count)）") (($detailEps.Count + $adminEps.Count) -eq 16) `
    "合计 $($detailEps.Count + $adminEps.Count)"

# ================================================================ 01 用例
Write-Host ''
Write-Host '[01-usecases.md]' -ForegroundColor Cyan
$uc = Read-Doc '01-usecases.md'

$cases = @($uc | Where-Object { $_ -match '^## 用例 \d+' })
CheckClaim '用例数声称一致' $uc '([0-9]+) 个用例' $cases.Count
$caseNums = @($cases | ForEach-Object { [int]([regex]::Match($_, '^## 用例 (\d+)').Groups[1].Value) })
$caseSeqOk = $true; for ($i = 0; $i -lt $caseNums.Count; $i++) { if ($caseNums[$i] -ne ($i + 1)) { $caseSeqOk = $false } }
Check '用例编号连续' $caseSeqOk "编号：$($caseNums -join ',')"

$routeRows = @($uc | Where-Object { $_ -match ('^\| \d+ \| ' + $bt + '(GET|POST) ') })
$routeNums = @($routeRows | ForEach-Object { [int]([regex]::Match($_, '^\| (\d+) \|')).Groups[1].Value })
$routeSeqOk = $true; for ($i = 0; $i -lt $routeNums.Count; $i++) { if ($routeNums[$i] -ne ($i + 1)) { $routeSeqOk = $false } }
Check ("端点编号连续无重复（$($routeRows.Count) 个）") `
    ((@($routeNums | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) -and $routeSeqOk) ''
CheckClaim '端点数量声称一致' $uc '([0-9]+) 个端点' $routeRows.Count

# 路径风格：出现 /{参数}/ 后面还有段 => 资源在前、动作在后，违反约定
$badStyle = @($routeRows | Where-Object {
        $p = [regex]::Match($_, $bt + '(?:GET|POST) ([^' + $bt + ']+)' + $bt).Groups[1].Value
        $p -match '/\{[a-z_]+\}/'
    })
Check '路径风格统一为「动词在前、ID 在后」' ($badStyle.Count -eq 0) `
    "不符合：$(($badStyle | ForEach-Object { ($_ -split '\|')[2].Trim() }) -join ',')"

$invRows = @($uc | Where-Object { $_ -match '^\| INV-\d+ \|' })
CheckClaim '不变量数量声称一致' $uc '共 ([0-9]+) 条' $invRows.Count

# ================================================================ 跨文档
Write-Host ''
Write-Host '[跨文档一致性]' -ForegroundColor Cyan

# 01 用到的状态名必须在 02 有定义
$ucStates = @{}
foreach ($l in $uc) { foreach ($n in $stateNames) { if ($l -match ($bt + $n + $bt)) { $ucStates[$n] = $true } } }
$badStates = @($ucStates.Keys | Where-Object { $declaredNames -notcontains $_ })
Check '01 中的状态名均在 02 有定义' ($badStates.Count -eq 0) "未定义：$($badStates -join ', ')"

# 01/02 引用的错误码必须在 03 定义。
# 豁免：事件名（定义在 02 §3）、状态名、外部协议枚举（支付方回调 result 等）、
# 以及文档里明确说明「有意不定义」的标识符。
$evNames = @{}
foreach ($r in $evRows) { $evNames[([regex]::Match($r, '^\| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value] = $true }
$external = @('PAY_SUCCESS', 'PAY_FAILED', 'REFUND_SUCCESS', 'REFUND_MANUAL', 'REFUND_REVOKED', 'LATE_CALLBACK')
$cited = @{}
foreach ($doc in @($uc, $sm)) {
    foreach ($l in $doc) {
        foreach ($m in [regex]::Matches($l, $bt + '([A-Z][A-Z0-9_]{5,})' + $bt)) {
            $tok = $m.Groups[1].Value
            if ($tok -match '^(VALIDATION|PARTIAL|PRODUCT|ORDER|UNAUTHORIZED|INVALID|FORBIDDEN|STOCK|IDEMPOTENCY|AMOUNT|REFUND|RETURN|RATE|INTERNAL|SERVICE)_') {
                $cited[$tok] = $true
            }
        }
    }
}
$orphan = @($cited.Keys | Where-Object {
        ($codes -notcontains $_) -and (-not $evNames.ContainsKey($_)) -and
        ($stateNames -notcontains $_) -and ($external -notcontains $_)
    })
Check '01/02 引用的错误码均在 03 定义（事件名与外部枚举已豁免）' ($orphan.Count -eq 0) "未定义：$($orphan -join ', ')"

# 交叉引用：指向的 md 文件必须存在
$broken = @()
foreach ($d in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    foreach ($l in (Get-Content -LiteralPath $d.FullName -Encoding UTF8)) {
        foreach ($m in [regex]::Matches($l, $bt + '(\d{2}-[a-z\-]+\.md)' + $bt)) {
            if (-not (Test-Path -LiteralPath (Join-Path $docs $m.Groups[1].Value))) {
                $broken += "$($d.Name)->$($m.Groups[1].Value)"
            }
        }
    }
}
Check '文档间交叉引用无死链' ($broken.Count -eq 0) ($broken -join '; ')

# 编号前缀连续（01 / 02 / 03 …）
$numbered = @(Get-ChildItem -LiteralPath $docs -Filter '*.md' |
    Where-Object { $_.Name -match '^(\d{2})-' } | Sort-Object Name)
$gaps = @(); $expected = 1
foreach ($f in $numbered) {
    if ([int]([regex]::Match($f.Name, '^(\d{2})').Groups[1].Value) -ne $expected) { $gaps += $f.Name }
    $expected++
}
Check ("文档编号前缀连续（$($numbered.Count) 个）") ($gaps.Count -eq 0) "跳号：$($gaps -join ', ')"

# 编码没坏
$badEnc = @()
foreach ($f in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    if ((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) -match [char]0xFFFD) { $badEnc += $f.Name }
}
Check '文档无编码损坏字符' ($badEnc.Count -eq 0) "含 U+FFFD：$($badEnc -join ', ')"

# 表格：分隔行列数与表头一致（防串列）；分隔行前必须是空行（否则不渲染）
$badTables = @(); $noBlank = @()
foreach ($d in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    $lines = @(Get-Content -LiteralPath $d.FullName -Encoding UTF8)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\|[\s\-:|]+\|$') { continue }
        if (([regex]::Matches($lines[$i - 1], '\|')).Count -ne ([regex]::Matches($lines[$i], '\|')).Count) {
            $badTables += "$($d.Name):L$($i + 1)"
        }
        if ($i -ge 2 -and $lines[$i -2] -notmatch '^\s*$') { $noBlank += "$($d.Name):L$($i - 1)" }
    }
}
Check 'Markdown 表格分隔行列数与表头一致' ($badTables.Count -eq 0) ($badTables -join ', ')
Check '表格前有空行（否则不渲染）' ($noBlank.Count -eq 0) ($noBlank -join ', ')

Write-Host ''
Write-Host ("=== PASS $($script:pass) / FAIL $($script:fail) ===") -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
