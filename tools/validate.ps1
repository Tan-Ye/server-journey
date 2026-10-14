# validate.ps1 —— 文档「机械一致性」校验
#
# 【能力边界，务必知悉】
# 本脚本只兜机械错误：数量声称 vs 实际、条目重复、编号跳号、引用不存在、
# 跨文档名称不一致、Mermaid 语法、编码损坏、表格串列。
#
# 它【查不出】下面这些，必须靠人眼：
#   1. 内容本身写错（例：把 400 的错误码写成 409 —— 只要两张表一致，脚本就认为没问题）
#   2. 该有的东西根本没写（脚本不知道某张表「本应存在」）
#   3. 设计决策之间的语义矛盾（两处措辞都对，但意思冲突）
#   4. 数值本身是否合理（默认 3 天还是 7 天，脚本无权判断）
#
# 用法（PS 5.1 需绕执行策略）：
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/validate.ps1
# 退出码 0 = 全过，1 = 有 FAIL
#
# 本文件必须保存为「UTF-8 with BOM」，否则 Windows PowerShell 5.1 按 ANSI 解析，
# 中文与中文正则全部乱码，校验结果不可信。

$ErrorActionPreference = 'Stop'
$bt = [char]0x60                      # 反引号。PowerShell 字符串里反引号是转义符，必须这样取
$docs = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\projects\trade-core\docs')).Path
$roadmapPath = Join-Path $PSScriptRoot '..\ROADMAP.md'

$script:fail = 0
$script:pass = 0
$script:warn = 0

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

function Warn {
    param([string]$Name, [string]$Detail = '')
    $script:warn++; Write-Host ("  WARN  " + $Name) -ForegroundColor DarkYellow
    if ($Detail) { Write-Host ("        -> " + $Detail) -ForegroundColor DarkYellow }
}

function Read-Doc {
    param([string]$File)
    $p = Join-Path $docs $File
    if (-not (Test-Path -LiteralPath $p)) { throw "文档不存在：$p" }
    return , @(Get-Content -LiteralPath $p -Encoding UTF8)
}

# 取「二级章节」正文：从 ^## N. 起到下一个 ^## 标题止（含 ### 子节）
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

# 取「一张表」：从表头行起到第一个非表格行为止。
# 必须的这一层 —— 同一章节常有多张表，只用 Get-Section 会把它们一起数进来。
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

# 表内数据行（排除表头与 |---|---| 分隔行）
function Get-Rows {
    param([string[]]$Table, [string]$RowPattern)
    return @($Table | Where-Object { $_ -match $RowPattern -and $_ -notmatch '^\|[\s\-:|]+\|$' })
}

# 中文数字 → 阿拉伯数字
$script:cnNum = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9; '十' = 10 }

# 扁平化任意嵌套层数的结果，保证是一维数组。
# 踩过的坑：`return , $arr` 会把数组包成「单元素数组」，调用方 @(...) 也展不平，
# 结果 -contains 比的是数组本身而不是里面的数字。
function Flatten {
    param($Items)
    $flat = New-Object System.Collections.ArrayList
    foreach ($i in @($Items)) {
        if ($null -eq $i) { continue }
        if ($i -is [System.Array] -or ($i -is [System.Collections.IEnumerable] -and $i -isnot [string])) {
            foreach ($j in (Flatten $i)) { [void]$flat.Add($j) }
        } else {
            [void]$flat.Add($i)
        }
    }
    return $flat.ToArray()
}

# 用【精确正则】在指定范围里抓声称值。
# 不再做「量词归一化」—— 中文里「共 9 个状态」「9 个状态」「共 3 条」「三道闸门」
# 写法混用，试图用一套通用量词覆盖会不断踩正则元字符/捕获组/共字位置的坑。
# 每个检查写死自己的正则，最可预测。
# 支持中文数字（用 $script:cnNum 换算）与多个捕获组（正则里有 | 时每位都要有组）。
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

function ClaimsMatch { param($Claims, [int]$Actual) return ((Flatten $Claims) -contains $Actual) }
function Fmt {
    param($Claims)
    $flat = Flatten $Claims
    if ($flat.Count -eq 0) { return '(无)' }
    return (($flat | Sort-Object -Unique) -join ', ')
}

# 统一断言：用 Pattern 找到的声称值里必须包含实测值 Actual
function CheckClaim {
    param([string]$Name, [string[]]$Scope, [string]$Pattern, [int]$Actual)
    $claims = Flatten (Get-Nums -Lines $Scope -Pattern $Pattern)
    Check ("$Name（实际 $Actual）") (ClaimsMatch $claims $Actual) "该范围内声称：$(Fmt $claims)"
}

Write-Host ''
Write-Host '=== 文档机械一致性校验 ===' -ForegroundColor Cyan
Write-Host "docs: $docs"

# ================================================================ 02 状态机
Write-Host ''
Write-Host '[02-state-machine.md]' -ForegroundColor Cyan
$sm = Read-Doc '02-state-machine.md'

# Mermaid 块：取语法问题与边
$inBlock = $false; $semi = @(); $diagEdges = 0; $ln = 0
$diagPairs = New-Object System.Collections.ArrayList
foreach ($l in $sm) {
    $ln++
    if ($l -match '^```mermaid') { $inBlock = $true; continue }
    if ($inBlock -and $l -match '^```') { $inBlock = $false; continue }
    if (-not $inBlock) { continue }
    if ($l -match ';') { $semi += "L$ln" }
    if ($l -match '-->') {
        $diagEdges++
        $m = [regex]::Match($l, '^\s*([A-Z_]+)\s*-->\s*([A-Z_\[\]\*]+)')
        if ($m.Success) { [void]$diagPairs.Add($m) }
    }
}
Check 'Mermaid 块内无半角分号' ($semi.Count -eq 0) ("位置：" + ($semi -join ', '))

# 状态：Mermaid 声明 vs §2 状态集合表
$stateDecls = @($sm | Where-Object { $_ -match '^\s*state "' })
$declaredNames = @($stateDecls | ForEach-Object { ([regex]::Match($_, 'as\s+([A-Z_]+)')).Groups[1].Value } | Sort-Object)
$sec2 = Get-Section -Lines $sm -From '^## 2\. 状态集合'
$stateTable = Get-Table -Lines $sec2 -HeaderPattern '^\| 状态 \|'
$stateRows = Get-Rows -Table $stateTable -RowPattern ('^\| ' + $bt + '[A-Z_]+' + $bt)
$tableStates = @($stateRows | ForEach-Object { ([regex]::Match($_, '^\| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value } | Sort-Object -Unique)
$onlyTable = @($tableStates | Where-Object { $declaredNames -notcontains $_ })
$onlyDiag = @($declaredNames | Where-Object { $tableStates -notcontains $_ })
Check ("状态集合表 vs Mermaid 声明（各 $($tableStates.Count) 个）") (($onlyTable.Count -eq 0) -and ($onlyDiag.Count -eq 0)) `
    "表中未声明：$($onlyTable -join ',') / 图中未定义：$($onlyDiag -join ',')"
CheckClaim '状态数声称一致' $sec2 '([0-9]+) 个状态' $tableStates.Count

# 图中出现的状态都必须已声明
$diagStates = @{}
foreach ($m in $diagPairs) {
    $diagStates[$m.Groups[1].Value] = $true
    if ($m.Groups[2].Value -ne '[*]') { $diagStates[$m.Groups[2].Value] = $true }
}
$undeclared = @($diagStates.Keys | Where-Object { $declaredNames -notcontains $_ })
Check '图中出现的状态均已声明' ($undeclared.Count -eq 0) "未声明：$($undeclared -join ', ')"

# 事件：§3（表头形如 | 事件 | 触发者 | 载体 | 可能来源 |）
$sec3 = Get-Section -Lines $sm -From '^## 3\. 事件清单'
$evTable = Get-Table -Lines $sec3 -HeaderPattern '^\| 事件 \|'
$evRows = Get-Rows -Table $evTable -RowPattern ('^\| ' + $bt + '[A-Z_]+' + $bt)
CheckClaim '事件数声称一致' $sec3 '([0-9]+) 个事件' $evRows.Count

# 转移表：§4，只数「| T1 | `…」格式（副作用表的行是「| T1 | 内容」无反引号）
$sec4 = Get-Section -Lines $sm -From '^## 4\. 转移表'
$edges = @($sec4 | Where-Object { $_ -match ('^\| T\d+[a-z]? \| ' + $bt) })
CheckClaim '转移表边数 = 声称值' $sec4 '([0-9]+) 条(?:合法)?转移' $edges.Count

# 图边数 = 转移表边数 + 1（图多一条入口边 [*] -->）
Check ("图中边数 = 转移表 + 入口边（图 $diagEdges / 表 $($edges.Count)）") ($diagEdges -eq ($edges.Count + 1)) `
    "差 $($diagEdges - $edges.Count) 条，期望差 1"

# 被拒绝转移：§5
$sec5 = Get-Section -Lines $sm -From '^## 5\. 被拒绝的转移'
$rejTable = Get-Table -Lines $sec5 -HeaderPattern '^\| 意图 \|'
$rejRows = Get-Rows -Table $rejTable -RowPattern '^\| '
CheckClaim '被拒绝转移条数一致' $sec5 '([0-9]+) 条' $rejRows.Count

# 幂等闸门：§6（标题写「三道闸门」，用中文数字）
$sec6 = Get-Section -Lines $sm -From '^## 6\. 幂等'
$gateRows = @($sec6 | Where-Object { $_ -match '^\| 闸门 [0-9]' })
CheckClaim '幂等闸门数一致' $sec6 '([一二三四五六七八九十]+)\s?道闸门' $gateRows.Count

# 副作用清单覆盖全部转移编号：§7
$sec7 = Get-Section -Lines $sm -From '^## 7\. 状态迁移的副作用清单'
$sideText = ($sec7 -join ' ')
$edgeIds = @($edges | ForEach-Object { ([regex]::Match($_, '^\| (T\d+[a-z]?)')).Groups[1].Value })
$notCovered = @()
foreach ($g in ($edgeIds | Group-Object { $_ -replace '[a-z]$', '' } | ForEach-Object { $_.Name })) {
    if ($sideText -notmatch [regex]::Escape($g)) { $notCovered += $g }
}
Check '副作用清单覆盖全部转移编号' ($notCovered.Count -eq 0) "未在 §7 出现：$($notCovered -join ', ')"

# 人工介入：§10（声称写法是「（共 11 项）」，故量词要覆盖「共 N 项」）
$sec10 = Get-Section -Lines $sm -From '^## 10\.'
$manTable = Get-Table -Lines $sec10 -HeaderPattern '^\| # \|'
$manRows = Get-Rows -Table $manTable -RowPattern '^\| \d+ \|'
CheckClaim '人工介入清单条数一致' $sec10 '共 ([0-9]+) 项|([0-9]+) 个场景' $manRows.Count

# ================================================================ 03 契约
Write-Host ''
Write-Host '[03-api-contract.md]' -ForegroundColor Cyan
$ac = Read-Doc '03-api-contract.md'

# HTTP 状态码：§4
$sec4ac = Get-Section -Lines $ac -From '^## 4\. HTTP 状态码规范'
$httpTable = Get-Table -Lines $sec4ac -HeaderPattern '^\| 状态码 \|'
$httpRows = Get-Rows -Table $httpTable -RowPattern ('^\| ' + $bt + '\d{3} ')
$definedHttp = @{}
foreach ($r in $httpRows) { $definedHttp[([regex]::Match($r, '^\| ' + $bt + '(\d{3})')).Groups[1].Value] = $true }
CheckClaim 'HTTP 状态码数量声称一致' $sec4ac '([0-9]+) 个状态码' $httpRows.Count

# 错误码：§5
$sec5ac = Get-Section -Lines $ac -From '^## 5\. 错误码总表'
$errRows = @($sec5ac | Where-Object { $_ -match ('^\| \d{5} \| ' + $bt + '[A-Z_]+' + $bt) })
$nums = @($errRows | ForEach-Object { ([regex]::Match($_, '^\| (\d{5})')).Groups[1].Value })
$codes = @($errRows | ForEach-Object { ([regex]::Match($_, '^\| \d{5} \| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value })
$dupNum = @($nums | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$dupCode = @($codes | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
Check ("错误码表无重复（$($errRows.Count) 个）") (($dupNum.Count -eq 0) -and ($dupCode.Count -eq 0)) `
    "重复数字码：$($dupNum -join ',') / 重复字符串码：$($dupCode -join ',')"
CheckClaim '错误码数量声称一致' $sec5ac '共 ([0-9]+) 个错误码' $errRows.Count

$mismatch = @($errRows | Where-Object {
        $n = [regex]::Match($_, '^\| (\d{5})').Groups[1].Value
        $h = [regex]::Match($_, '^\| \d{5} \| ' + $bt + '[A-Z_]+' + $bt + ' \| (\d{3})').Groups[1].Value
        $n.Substring(0, 3) -ne $h
    })
Check '错误码数字前缀 = HTTP 状态码' ($mismatch.Count -eq 0) `
    "不一致：$(($mismatch | ForEach-Object { ($_ -split '\|')[1].Trim() }) -join ',')"
Check '每个错误码都标注了可否重试' (@($errRows | Where-Object { $_ -notmatch '(✗|✓)' }).Count -eq 0) ''

# 常量：§7
$sec7ac = Get-Section -Lines $ac -From '^## 7\. 常量清单'
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
Check '常量名无重复' (@($consts | Group-Object Name | Where-Object { $_.Count -gt 1 }).Count -eq 0) ''
CheckClaim '常量数量声称一致' $sec7ac '共 ([0-9]+) 个常量' $consts.Count
Check '常量章节说明环境变量覆盖方式' ((($sec7ac -join ' ') -match '环境变量')) ''

# 端点：§8
$sec8 = Get-Section -Lines $ac -From '^## 8\. 端点契约'
$epErrLines = @($sec8 | Where-Object { $_ -match '^\| (错误|失败) \|' })
$defined = @{}; foreach ($c in $codes) { $defined[$c] = $true }
# 端点错误行里的码名可能是裸写（400 VALIDATION_ERROR）或带反引号，两种都要认
$codeAlt = ($codes | Sort-Object -Descending { $_.Length } | ForEach-Object { [regex]::Escape($_) }) -join '|'
$referenced = @{}
if ($codeAlt) {
    foreach ($l in $epErrLines) {
        foreach ($m in [regex]::Matches($l, '\b(' + $codeAlt + ')\b')) { $referenced[$m.Groups[1].Value] = $true }
    }
}
$unknown = @($referenced.Keys | Where-Object { (-not $defined.ContainsKey($_)) -and ($stateNames -notcontains $_) })
Check '端点引用的错误码全部已定义' ($unknown.Count -eq 0) "未定义：$($unknown -join ', ')"
$badEpErr = @($epErrLines | Where-Object { $_ -notmatch '端点特有|仅验签失败' })
Check '端点错误行均声明为「端点特有」' ($badEpErr.Count -eq 0) "$($badEpErr.Count) 行未声明"

$usedHttp = @{}
foreach ($l in $ac) {
    foreach ($m in [regex]::Matches($l, $bt + '(\d{3}) (OK|Created|Accepted|Bad Request|Unauthorized|Forbidden|Not Found|Conflict|Too Many Requests|Internal Server Error|Service Unavailable)' + $bt)) {
        $usedHttp[$m.Groups[1].Value] = $true
    }
}
$undefHttp = @($usedHttp.Keys | Where-Object { -not $definedHttp.ContainsKey($_) })
Check '全文使用的状态码均在 §4 定义' ($undefHttp.Count -eq 0) "未定义：$($undefHttp -join ', ')"

$detailEps = @($sec8 | Where-Object { $_ -match ('^#### ' + $bt) })
$adminEps = @($sec8 | Where-Object { $_ -match ('^\| ' + $bt + '(GET|POST) /admin|^\| ' + $bt + 'GET /healthz') })
Check ("端点详述（$($detailEps.Count)）+ 管理表格（$($adminEps.Count)）= 16") (($detailEps.Count + $adminEps.Count) -eq 16) `
    "合计 $($detailEps.Count + $adminEps.Count)"

# 「总表定义但端点未引用」的裁决。只有两类是合理的，其余视为漏写端点错误清单：
#   1) 通用错误：已在 §8 开头的「通用错误」隐含表里声明，本就不该逐端点重复列出
#   2) 回调专用：金额不符按设计返回 200 + 落 payment_events，故不进「错误」列
$legitUnlisted = @('UNAUTHORIZED', 'RATE_LIMITED', 'INTERNAL_ERROR', 'SERVICE_UNAVAILABLE', 'AMOUNT_MISMATCH')
$neverUsed = @($codes | Where-Object { (-not $referenced.ContainsKey($_)) -and ($legitUnlisted -notcontains $_) })
Check "总表定义的错误码都被端点引用（$($legitUnlisted.Count) 个已登记豁免）" ($neverUsed.Count -eq 0) `
    "未引用且未登记豁免：$($neverUsed -join ', ')"

# ================================================================ 01 用例
Write-Host ''
Write-Host '[01-usecases.md]' -ForegroundColor Cyan
$uc = Read-Doc '01-usecases.md'

$cnNum = @{ '一' = 1; '二' = 2; '三' = 3; '四' = 4; '五' = 5; '六' = 6; '七' = 7; '八' = 8; '九' = 9; '十' = 10 }
$cases = @($uc | Where-Object { $_ -match '^## 用例 \d+' })
# 文档用中文数字表述（「用例 6 · …」标题 + 开头声明）。两种写法都接受：
#   「六个用例」  或  「共 6 个用例」
$claimedCases = $null
foreach ($l in $uc) {
    $m = [regex]::Match($l, '([一二三四五六七八九十]+)个用例')
    if ($m.Success) { $claimedCases = $cnNum[$m.Groups[1].Value]; break }
    $m2 = [regex]::Match($l, '([0-9]+)\s*个用例')
    if ($m2.Success) { $claimedCases = [int]$m2.Groups[1].Value; break }
}
if ($null -eq $claimedCases) {
    Warn "用例数未在 01 中声明（实际 $($cases.Count) 个）" '建议在开头写明「共 N 个用例」，否则无法机械核对'
} else {
    Check ("用例数一致（实际 $($cases.Count)）") ($claimedCases -eq $cases.Count) "声称 '$claimedCases'"
}
$caseNums = @($cases | ForEach-Object { [int]([regex]::Match($_, '^## 用例 (\d+)').Groups[1].Value) })
$caseSeqOk = $true; for ($i = 0; $i -lt $caseNums.Count; $i++) { if ($caseNums[$i] -ne ($i + 1)) { $caseSeqOk = $false } }
Check '用例编号连续' $caseSeqOk "编号：$($caseNums -join ',')"

$routeRows = @($uc | Where-Object { $_ -match ('^\| \d+ \| ' + $bt + '(GET|POST) ') })
$routeNums = @($routeRows | ForEach-Object { [int]([regex]::Match($_, '^\| (\d+) \|')).Groups[1].Value })
$dupRoute = @($routeNums | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
$routeSeqOk = $true; for ($i = 0; $i -lt $routeNums.Count; $i++) { if ($routeNums[$i] -ne ($i + 1)) { $routeSeqOk = $false } }
Check ("端点编号连续无重复（$($routeRows.Count) 个）") (($dupRoute.Count -eq 0) -and $routeSeqOk) "重复：$($dupRoute -join ',')"
CheckClaim '端点数量声称一致' $uc '([0-9]+) 个端点' $routeRows.Count

# 路径风格：出现 /{参数}/ 后面还有别的段 => 资源在前、动作在后，风格错误
$badStyle = @($routeRows | Where-Object {
        $p = [regex]::Match($_, $bt + '(?:GET|POST) ([^' + $bt + ']+)' + $bt).Groups[1].Value
        $p -match '/\{[a-z_]+\}/'
    })
Check '路径风格统一为「动词在前、ID 在后」' ($badStyle.Count -eq 0) `
    "不符合：$(($badStyle | ForEach-Object { ($_ -split '\|')[2].Trim() }) -join ',')"

$invRows = @($uc | Where-Object { $_ -match '^\| INV-\d+ \|' })
$secInv = Get-Section -Lines $uc -From '^### 全局不变量'
CheckClaim '不变量数量声称一致' $secInv '共 ([0-9]+) 条' $invRows.Count
$invIds = @($invRows | ForEach-Object { ([regex]::Match($_, '^\| (INV-\d+)')).Groups[1].Value })
Check '不变量编号无重复' (@($invIds | Group-Object | Where-Object { $_.Count -gt 1 }).Count -eq 0) ''

# ================================================================ 跨文档
Write-Host ''
Write-Host '[跨文档一致性]' -ForegroundColor Cyan

$evNames = @{}
foreach ($r in $evRows) { $evNames[([regex]::Match($r, '^\| ' + $bt + '([A-Z_]+)' + $bt)).Groups[1].Value] = $true }

$ucStates = @{}
foreach ($l in $uc) { foreach ($n in $stateNames) { if ($l -match ($bt + $n + $bt)) { $ucStates[$n] = $true } } }
$badStates = @($ucStates.Keys | Where-Object { $declaredNames -notcontains $_ })
Check '01 中的状态名均在 02 有定义' ($badStates.Count -eq 0) "未定义：$($badStates -join ', ')"
$notInUc = @($declaredNames | Where-Object { -not $ucStates.ContainsKey($_) })
if ($notInUc.Count -gt 0) { Warn "02 定义但 01 未提及的状态：$($notInUc -join ', ')" '确认是否有用例覆盖' }

# 01/02 引用的错误码必须在 03 定义。
# 三处豁免：事件名（定义在 02 §3）、状态名、以及「被讨论但有意不定义」的标识符。
# 最后一项必须显式登记理由 —— 否则这个豁免会变成掩盖漏定义的漏洞。
$acknowledged = @{
    'REFUND_SUCCESS' = '支付方回调的 result 取值，属外部协议枚举，非本服务错误码'
    'REFUND_MANUAL'  = '02 §9 明确说明「不引入该状态」，属有意不定义'
    'PAY_SUCCESS'    = '支付方回调的 result 取值，属外部协议枚举'
    'PAY_FAILED'     = '支付方回调的 result 取值，属外部协议枚举'
}
$allCodes = @{}; foreach ($c in $codes) { $allCodes[$c] = $true }
$cited = @{}
foreach ($doc in @($uc, $sm)) {
    foreach ($l in $doc) {
        foreach ($m in [regex]::Matches($l, $bt + '([A-Z][A-Z0-9_]{5,})' + $bt)) {
            $tok = $m.Groups[1].Value
            if ($tok -match '^(VALIDATION|PARTIAL|PRODUCT|ORDER|UNAUTHORIZED|INVALID|FORBIDDEN|STOCK|IDEMPOTENCY|AMOUNT|REFUND|RETURN|RATE|INTERNAL|SERVICE|PAY)_') {
                $cited[$tok] = $true
            }
        }
    }
}
$orphan = @($cited.Keys | Where-Object {
        (-not $allCodes.ContainsKey($_)) -and (-not $evNames.ContainsKey($_)) -and
        ($stateNames -notcontains $_) -and (-not $acknowledged.ContainsKey($_))
    })
Check '01/02 引用的错误码均在 03 定义（豁免项已登记）' ($orphan.Count -eq 0) "未定义：$($orphan -join ', ')"

$planned = @()
if (Test-Path -LiteralPath $roadmapPath) {
    foreach ($l in (Get-Content -LiteralPath $roadmapPath -Encoding UTF8)) {
        foreach ($m in [regex]::Matches($l, $bt + 'docs/(\d{2}-[a-z\-]+\.md)' + $bt)) { $planned += $m.Groups[1].Value }
    }
    $planned = @($planned | Sort-Object -Unique)
}
$broken = @(); $pending = @()
foreach ($d in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    foreach ($l in (Get-Content -LiteralPath $d.FullName -Encoding UTF8)) {
        foreach ($m in [regex]::Matches($l, $bt + '(\d{2}-[a-z\-]+\.md)' + $bt)) {
            $name = $m.Groups[1].Value
            if (-not (Test-Path -LiteralPath (Join-Path $docs $name))) {
                if ($planned -contains $name) { $pending += "$($d.Name)->$name" } else { $broken += "$($d.Name)->$name" }
            }
        }
    }
}
Check '交叉引用无死链' ($broken.Count -eq 0) ($broken -join '; ')
if ($pending.Count -gt 0) { Warn "引用到尚未产出的计划文档：$(($pending | Sort-Object -Unique) -join ', ')" '产出后自动消失' }

$existing = @(Get-ChildItem -LiteralPath $docs -Filter '*.md' | ForEach-Object { $_.Name })
$notYet = @($planned | Where-Object { $existing -notcontains $_ })
if ($notYet.Count -gt 0) { Warn "ROADMAP 计划未产出：$($notYet -join ', ')" }

$numbered = @(Get-ChildItem -LiteralPath $docs -Filter '*.md' | Where-Object { $_.Name -match '^(\d{2})-' } | Sort-Object Name)
$gaps = @(); $expected = 1
foreach ($f in $numbered) {
    $n = [int]([regex]::Match($f.Name, '^(\d{2})').Groups[1].Value)
    if ($n -ne $expected) { $gaps += $f.Name }
    $expected++
}
Check ("文档编号前缀连续（$($numbered.Count) 个）") ($gaps.Count -eq 0) "跳号：$($gaps -join ', ')"

$badEnc = @()
foreach ($f in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    if ((Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8) -match [char]0xFFFD) { $badEnc += $f.Name }
}
Check '文档无编码损坏字符' ($badEnc.Count -eq 0) "含 U+FFFD：$($badEnc -join ', ')"

$badTables = @()
foreach ($d in (Get-ChildItem -LiteralPath $docs -Filter '*.md')) {
    $lines = @(Get-Content -LiteralPath $d.FullName -Encoding UTF8)
    for ($i = 1; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\|[\s\-:|]+\|$') { continue }
        if (([regex]::Matches($lines[$i - 1], '\|')).Count -ne ([regex]::Matches($lines[$i], '\|')).Count) {
            $badTables += "$($d.Name):L$($i + 1)"
        }
    }
}
Check 'Markdown 表格分隔行列数与表头一致' ($badTables.Count -eq 0) ($badTables -join ', ')

Write-Host ''
Write-Host ("=== PASS $($script:pass) / FAIL $($script:fail) / WARN $($script:warn) ===") `
    -ForegroundColor $(if ($script:fail -eq 0) { 'Green' } else { 'Red' })
Write-Host ''
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
