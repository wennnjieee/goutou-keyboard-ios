# 一键上云构建 iOS 包（Windows，无需 Mac / 无需装 git）
#
# 用法：
#   1. 去 https://github.com/settings/tokens 创建一个 classic token，勾选 repo + workflow 权限
#   2. 在本文件夹按住 Shift 右键 → “在此处打开 PowerShell 窗口”，执行：
#        powershell -ExecutionPolicy Bypass -File .\一键上云构建.ps1
#   3. 按提示粘贴 token，等 10-20 分钟，最后会把未签名 IPA 放到桌面
#
# 只做三件事：建仓库 → 上传源码（一个 commit）→ 等 GitHub 的 macOS 机器编译 → 下载 Artifact 里的 IPA。
# 不会读取你任何其他数据，token 只在内存里用。

[CmdletBinding()]
param(
    [string]$Token = "",
    [string]$RepoName = "goutou-keyboard-ios",
    [string]$SourceDir = "goutou-keyboard-ios-main",
    [switch]$Private,
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Write-Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    注意: $msg" -ForegroundColor Yellow }
function Fail($msg)       { Write-Host "`n[失败] $msg" -ForegroundColor Red; exit 1 }

# ---------- 0. 定位源码 ----------
if (-not (Test-Path $SourceDir)) {
    $cand = Get-ChildItem -Directory | Where-Object { Test-Path (Join-Path $_.FullName 'project.yml') } | Select-Object -First 1
    if ($cand) { $SourceDir = $cand.FullName } else { Fail "找不到源码目录（需要包含 project.yml 的文件夹，默认 $SourceDir）" }
}
$SourceDir = (Resolve-Path $SourceDir).Path
if (-not (Test-Path (Join-Path $SourceDir 'project.yml'))) { Fail "$SourceDir 里没有 project.yml，目录不对" }

Write-Step "源码目录：$SourceDir"

# ---------- 1. 收集文件 ----------
$files = Get-ChildItem -Path $SourceDir -Recurse -File -Force |
    Where-Object { $_.FullName -notmatch '\\\.git\\' -and $_.Name -ne '.DS_Store' }
$rel = @()
foreach ($f in $files) {
    $p = $f.FullName.Substring($SourceDir.Length).TrimStart('\', '/').Replace('\', '/')
    $rel += [pscustomobject]@{ Path = $p; Full = $f.FullName; Size = $f.Length }
}
if ($rel.Count -lt 50) { Fail "只找到 $($rel.Count) 个文件，源码看起来不完整" }
Write-Ok "共 $($rel.Count) 个文件，合计 $([math]::Round(($rel | Measure-Object Size -Sum).Sum / 1MB, 2)) MB"
foreach ($must in @('project.yml', '.github/workflows/build-ios.yml', 'App/Info.plist', 'Keyboard/Info.plist')) {
    if (-not ($rel.Path -contains $must)) { Fail "缺少关键文件：$must" }
}
Write-Ok "关键文件齐全（project.yml / workflow / App / Keyboard）"

if ($DryRun) {
    Write-Step "DryRun：只做本地准备，不联网"
    $sample = $rel | Select-Object -First 5
    foreach ($s in $sample) {
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($s.Full))
        Write-Ok ("{0}  ({1} bytes -> base64 {2} chars)" -f $s.Path, $s.Size, $b64.Length)
    }
    Write-Ok "本地检查通过，可以正式运行（去掉 -DryRun）"
    exit 0
}

# ---------- 2. Token ----------
if (-not $Token) {
    Write-Step "需要一个 GitHub Personal Access Token（repo + workflow 权限）"
    Write-Host "    创建地址: https://github.com/settings/tokens/new?scopes=repo,workflow&description=goutou-build" -ForegroundColor Gray
    $Token = Read-Host "    粘贴 token（输入时不显示，粘贴后回车）"
    if (-not $Token) { Fail "没有 token" }
}
$Token = $Token.Trim()

$H = @{
    Authorization          = "Bearer $Token"
    Accept                 = "application/vnd.github+json"
    'User-Agent'           = 'goutou-build-script'
    'X-GitHub-Api-Version' = '2022-11-28'
}
function Api($method, $uri, $obj = $null) {
    $p = @{ Method = $method; Uri = $uri; Headers = $H; TimeoutSec = 120 }
    if ($null -ne $obj) {
        $p.Body = [Text.Encoding]::UTF8.GetBytes(($obj | ConvertTo-Json -Depth 20 -Compress))
        $p.ContentType = 'application/json; charset=utf-8'
    }
    return Invoke-RestMethod @p
}

try { $me = Api 'GET' 'https://api.github.com/user' } catch { Fail "token 无效或没有权限：$($_.Exception.Message)" }
$owner = $me.login
Write-Ok "已登录 GitHub：$owner"

# ---------- 3. 建仓库 ----------
$repoFull = "$owner/$RepoName"
$repoUrl = "https://api.github.com/repos/$repoFull"
$exists = $false
try { $r = Api 'GET' $repoUrl; $exists = $true } catch { }
if (-not $exists) {
    Write-Step "创建仓库 $repoFull"
    try {
        $r = Api 'POST' 'https://api.github.com/user/repos' @{
            name        = $RepoName
            description = '狗头军师输入法 · iOS 键盘扩展（云端 macOS 构建）'
            private     = [bool]$Private
            auto_init   = $false
            has_issues  = $false
            has_wiki    = $false
        }
        Write-Ok "仓库已创建：$($r.html_url)"
    } catch {
        Fail "建仓库失败（token 可能没有 repo 权限）：$($_.Exception.Message)"
    }
    Start-Sleep -Seconds 2
} else {
    Write-Warn2 "仓库 $repoFull 已存在，将覆盖 main 分支内容"
}

# ---------- 4. 上传所有文件（一个 commit） ----------
Write-Step "上传 $($rel.Count) 个文件（Git Data API，一次提交）"
$treeEntries = New-Object System.Collections.ArrayList
$i = 0
try {
    foreach ($f in $rel) {
        $i++
        if ($i % 20 -eq 0 -or $i -eq $rel.Count) { Write-Host ("    {0}/{1}" -f $i, $rel.Count) -ForegroundColor DarkGray }
        $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($f.Full))
        $blob = Api 'POST' "https://api.github.com/repos/$repoFull/git/blobs" @{ content = $b64; encoding = 'base64' }
        [void]$treeEntries.Add(@{ path = $f.Path; mode = '100644'; type = 'blob'; sha = $blob.sha })
    }
} catch {
    Write-Host ''
    Write-Host "上传在 $i/$($rel.Count) 处失败：$($_.Exception.Message)" -ForegroundColor Red
    Write-Host '如果是 403 / 429：token 缺 repo 权限，或撞了频率限制。等一分钟重跑，或者用 GitHub Desktop 手动推（同一套流水线会自动跑）。' -ForegroundColor Yellow
    exit 1
}

$tree = Api 'POST' "https://api.github.com/repos/$repoFull/git/trees" @{ tree = @($treeEntries) }
Write-Ok "tree: $($tree.sha)"

$parents = @()
try {
    $ref = Api 'GET' "https://api.github.com/repos/$repoFull/git/ref/heads/main"
    $parents = @($ref.object.sha)
} catch { }

$commitBody = @{
    message = "chore: upload goutou keyboard ios (cloud build trigger)"
    tree    = $tree.sha
    parents = $parents
}
$commit = Api 'POST' "https://api.github.com/repos/$repoFull/git/commits" $commitBody
Write-Ok "commit: $($commit.sha.Substring(0,10))"

if ($parents.Count -gt 0) {
    Api 'PATCH' "https://api.github.com/repos/$repoFull/git/refs/heads/main" @{ sha = $commit.sha; force = $true } | Out-Null
} else {
    Api 'POST' "https://api.github.com/repos/$repoFull/git/refs" @{ ref = 'refs/heads/main'; sha = $commit.sha } | Out-Null
}
Write-Ok "main 分支已指向新提交，Actions 会被自动触发"

# ---------- 5. 等构建 ----------
Write-Step "等待 GitHub Actions（首次会跑十几组冒烟测试 + 编译 + 模拟器单测 + 打包，约 10-20 分钟）"
$runId = $null
$deadline = (Get-Date).AddMinutes(40)
while (-not $runId) {
    if ((Get-Date) -gt $deadline) { Fail "等太久没看到 workflow 启动，去 $($r.html_url)/actions 手动点一下 Run workflow" }
    Start-Sleep -Seconds 10
    try {
        $runs = Api 'GET' "https://api.github.com/repos/$repoFull/actions/runs?per_page=10"
        $hit = $runs.workflow_runs | Where-Object { $_.head_sha -eq $commit.sha } | Select-Object -First 1
        if ($hit) { $runId = $hit.id; Write-Ok "已启动：$($hit.html_url)" }
        else { Write-Host "    还在排队列…" -ForegroundColor DarkGray }
    } catch { Write-Host "    查询中…" -ForegroundColor DarkGray }
}

$lastStatus = ''
while ($true) {
    if ((Get-Date) -gt $deadline) { Fail "构建超时（40 分钟）。去 Actions 看日志：$($r.html_url)/actions" }
    Start-Sleep -Seconds 20
    $run = Api 'GET' "https://api.github.com/repos/$repoFull/actions/runs/$runId"
    $line = "$($run.status)/$($run.conclusion)"
    if ($line -ne $lastStatus) { Write-Host "    状态: $line" -ForegroundColor DarkGray; $lastStatus = $line }
    if ($run.status -eq 'completed') { break }
}

if ($run.conclusion -ne 'success') {
    Write-Host ""
    Write-Host "构建没有成功：$($run.conclusion)" -ForegroundColor Red
    Write-Host "日志在这里，红色那一步就是原因：$($run.html_url)" -ForegroundColor Yellow
    Write-Host "常见原因：仓库是私有且 Actions 额度用完 / Node 版本 / 网络抖动，重跑一次通常就好。" -ForegroundColor Yellow
    exit 1
}
Write-Ok "构建成功"

# ---------- 6. 下载 IPA ----------
Write-Step "下载未签名 IPA"
$arts = Api 'GET' "https://api.github.com/repos/$repoFull/actions/runs/$runId/artifacts"
$art = $arts.artifacts | Where-Object { $_.name -like '*unsigned*' } | Select-Object -First 1
if (-not $art) { $art = $arts.artifacts | Select-Object -First 1 }
if (-not $art) { Fail "这次运行没有 artifact（去页面看看）：$($run.html_url)" }

$zipPath = Join-Path $env:TEMP "$($art.name).zip"
$location = $null
try {
    $resp = Invoke-WebRequest -Uri $art.archive_download_url -Headers $H -MaximumRedirection 0 -UseBasicParsing -ErrorAction Stop
    $location = $resp.Headers.Location
} catch {
    $r2 = $_.Exception.Response
    if ($r2 -and $r2.Headers['Location']) { $location = $r2.Headers['Location'] }
}
if (-not $location) { Fail "拿不到下载地址（artifact 已过期？90 天有效）：$($run.html_url)" }
Invoke-WebRequest -Uri $location -OutFile $zipPath -UseBasicParsing
Write-Ok "已下载：$zipPath"

$outDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'goutou-ipa'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
Expand-Archive -Path $zipPath -DestinationPath $outDir -Force
$ipa = Get-ChildItem -Path $outDir -Filter *.ipa -Recurse | Select-Object -First 1
if (-not $ipa) { Fail "解压后没有 .ipa，看看 $outDir" }

Write-Host ""
Write-Host "================ 完成 ================" -ForegroundColor Green
Write-Host "未签名 IPA：$($ipa.FullName)" -ForegroundColor Green
Write-Host "大小：$([math]::Round($ipa.Length/1MB,2)) MB"
Write-Host ""
Write-Host "下一步（你有 p12，自己签）：" -ForegroundColor Cyan
Write-Host "  1) 用 Sideloadly / 爱思助手 / 轻松签 载入这个 ipa，用你的 p12 + 描述文件重签"
Write-Host "  2) 两个扩展必须一起签：主 App、GoutouKeyboard.appex、GoutouCaptureWidget.appex"
Write-Host "  3) 你的证书要有 App Group：组名要和工程里一致（默认 group.GDK748UUB7.pOgtZpt），"
Write-Host "     不一致就把 App/Keyboard 两个 entitlements 和 Shared/SharedConstants.swift 第 6 行改成你的组名再构建"
Write-Host "  4) 装完：设置 → 通用 → 键盘 → 键盘 → 添加新键盘 → 狗头军师 → 打开「允许完全访问」"
Write-Host "=====================================" -ForegroundColor Green
