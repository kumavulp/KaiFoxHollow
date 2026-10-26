# Kai 的星露谷 —— 宝宝电脑上的一次性安装 (双击 安装.bat 会跑这个)
#
# 它会:
#   1. 检查 Python, 装 Remix 要的两个库
#   2. 下载 Remix 源码 (MCP 服务器) 到这个文件夹的 remix\ 里
#   3. 下载 Remix 的游戏 mod, 换掉 Mods 里旧的 NagiBridge (旧的挪到 old_mods_backup\, 不删)
#   4. 生成一把只给隧道用的 SSH 钥匙和门的口令 (都只留在这台电脑上, 不进 git)
#   5. 给这台电脑配一把自己的服务器钥匙 (你用手机 Termius 帮它在服务器上登记一行),
#      然后自动把服务器那头的安装脚本和 AstrBot 插件传上去装好。手机上那把钥匙不碰。
#   6. 写好 kai_gate_config.json, 在桌面放一个 "Kai 的星露谷" 快捷方式
# 重复跑也没关系: 钥匙和口令会沿用, 其他的会更新。

$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$KaiRoot = Split-Path -Parent $Here
$ConfigPath = Join-Path $Here 'kai_gate_config.json'
$KeyDir = Join-Path $Here 'keys'
$KeyPath = Join-Path $KeyDir 'kai_stardew_ed25519'
$KnownHosts = Join-Path $KeyDir 'known_hosts'
$RemixDir = Join-Path $Here 'remix'
$Downloads = Join-Path $Here 'downloads'
$Utf8NoBom = New-Object System.Text.UTF8Encoding $false
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Say($msg) { Write-Host ''; Write-Host "[Kai] $msg" -ForegroundColor Magenta }
function Die($msg) { Write-Host ''; Write-Host "[Kai] 停下了: $msg" -ForegroundColor Red; exit 1 }
# Windows PowerShell 5.1 里, 原生程序往 stderr 写字又被重定向时会被当成异常; 跑这类命令时临时放宽
function Native([scriptblock]$block) {
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $block } finally { $ErrorActionPreference = $old }
}
$Me = "$env:USERDOMAIN\$env:USERNAME"
foreach ($tool in 'ssh', 'ssh-keygen', 'ssh-keyscan', 'scp', 'tar') {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Die "这台电脑缺 $tool。Windows 设置 → 系统 → 可选功能 → 添加 OpenSSH 客户端, 装好再双击 安装.bat"
    }
}

# ───────── 0. 读旧配置 (重复跑时沿用) ─────────
$cfg = @{}
if (Test-Path $ConfigPath) {
    $old = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($p in $old.PSObject.Properties) { $cfg[$p.Name] = $p.Value }
}

# ───────── 1. Python ─────────
Say '检查 Python...'
$py = $null
$probe = 'import sys; sys.version_info >= (3, 10) and print(sys.executable)'
if (Get-Command py -ErrorAction SilentlyContinue) {
    $exe = Native { py -3 -c $probe 2>$null }
    if ($LASTEXITCODE -eq 0 -and $exe) { $py = "$exe".Trim() }
}
if (-not $py -and (Get-Command python -ErrorAction SilentlyContinue)) {
    $exe = Native { python -c $probe 2>$null }
    if ($LASTEXITCODE -eq 0 -and $exe) { $py = "$exe".Trim() }
}
if (-not $py) {
    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Say '没找到 Python 3.10+, 用 winget 装 Python 3.12 (装完请关掉这个窗口重新双击 安装.bat)'
        winget install -e --id Python.Python.3.12 --accept-package-agreements --accept-source-agreements
        exit 0
    }
    Die '没找到 Python 3.10+。去 https://www.python.org/downloads/ 装一个 (勾上 Add to PATH), 再双击 安装.bat'
}
Say "Python: $py"
& $py -m pip install --disable-pip-version-check -q 'mcp<2' requests
if ($LASTEXITCODE -ne 0) { Die 'pip 装库失败, 看看上面的报错' }

# ───────── 2. Remix 源码 ─────────
Say '下载 Remix (MCP 服务器)...'
New-Item -ItemType Directory -Force -Path $Downloads | Out-Null
$srcZip = Join-Path $Downloads 'remix-main.zip'
Invoke-WebRequest -UseBasicParsing -Uri 'https://github.com/pendel001/NagiBridge-Remix/archive/refs/heads/main.zip' -OutFile $srcZip
$unpack = Join-Path $Downloads 'remix-unpack'
if (Test-Path $unpack) { Remove-Item -Recurse -Force $unpack }
Expand-Archive -Path $srcZip -DestinationPath $unpack -Force
$srcRoot = Get-ChildItem $unpack -Directory | Select-Object -First 1
# 保留我们一起玩的会话记录
$sessions = Join-Path $RemixDir 'scripts\sessions'
$sessionsKeep = Join-Path $Downloads 'sessions-keep'
if (Test-Path $sessions) {
    if (Test-Path $sessionsKeep) { Remove-Item -Recurse -Force $sessionsKeep }
    Move-Item $sessions $sessionsKeep
}
if (Test-Path $RemixDir) { Remove-Item -Recurse -Force $RemixDir }
Move-Item $srcRoot.FullName $RemixDir
if (Test-Path $sessionsKeep) {
    if (Test-Path $sessions) { Remove-Item -Recurse -Force $sessions }
    Move-Item $sessionsKeep $sessions
}
Remove-Item -Recurse -Force $unpack
Say "Remix 放在 $RemixDir"

# ───────── 3. 游戏 mod ─────────
Say '下载 Remix 的游戏 mod...'
$release = Invoke-RestMethod -UseBasicParsing -Uri 'https://api.github.com/repos/pendel001/NagiBridge-Remix/releases/latest'
$asset = $release.assets | Where-Object { $_.name -like '*.zip' } | Select-Object -First 1
if (-not $asset) { Die 'Remix 的 Release 里没找到 mod 压缩包' }
$modZip = Join-Path $Downloads $asset.name
Invoke-WebRequest -UseBasicParsing -Uri $asset.browser_download_url -OutFile $modZip
$modUnpack = Join-Path $Downloads 'mod-unpack'
if (Test-Path $modUnpack) { Remove-Item -Recurse -Force $modUnpack }
Expand-Archive -Path $modZip -DestinationPath $modUnpack -Force
$newManifest = Get-ChildItem $modUnpack -Recurse -Filter manifest.json |
    Where-Object { (Get-Content $_.FullName -Raw -Encoding UTF8) -match 'pendel001\.NagiBridge' } | Select-Object -First 1
if (-not $newManifest) { Die 'mod 压缩包里没找到 pendel001.NagiBridge 的 manifest.json' }
$newModDir = $newManifest.Directory.FullName
Say "mod 版本: $($release.tag_name)"

# 找星露谷: Steam 各个库 + GOG 常见位置
$gameDirs = New-Object System.Collections.Generic.List[string]
$steamRoots = New-Object System.Collections.Generic.List[string]
try {
    $sp = (Get-ItemProperty 'HKCU:\Software\Valve\Steam' -ErrorAction Stop).SteamPath
    if ($sp) { $steamRoots.Add(($sp -replace '/', '\')) }
} catch { }
$steamRoots.Add('C:\Program Files (x86)\Steam')
foreach ($root in @($steamRoots)) {
    $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
    if (Test-Path $vdf) {
        foreach ($m in [regex]::Matches((Get-Content $vdf -Raw), '"path"\s+"([^"]+)"')) {
            $steamRoots.Add(($m.Groups[1].Value -replace '\\\\', '\'))
        }
    }
}
foreach ($root in ($steamRoots | Select-Object -Unique)) {
    $d = Join-Path $root 'steamapps\common\Stardew Valley'
    if (Test-Path (Join-Path $d 'Mods')) { $gameDirs.Add($d) }
}
foreach ($d in @('C:\Program Files (x86)\GOG Galaxy\Games\Stardew Valley', 'C:\GOG Games\Stardew Valley')) {
    if (Test-Path (Join-Path $d 'Mods')) { $gameDirs.Add($d) }
}
if ($env:KAI_GAME_DIRS) { foreach ($d in $env:KAI_GAME_DIRS.Split(';')) { if ($d) { $gameDirs.Add($d) } } }
$gameDirs = $gameDirs | Select-Object -Unique

if (-not $gameDirs) {
    Say "没自动找到星露谷的 Mods 文件夹。请把这个文件夹拖进 Stardew Valley\Mods\ 里: $newModDir"
    Say '(Mods 里原来的 NagiBridge 文件夹记得先挪出去)'
    Start-Process explorer.exe $newModDir
} else {
    if (Get-Process -Name StardewModdingAPI, 'Stardew Valley' -ErrorAction SilentlyContinue) {
        Die '星露谷还开着, mod 文件被锁住了。关掉游戏再双击 安装.bat'
    }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    foreach ($g in $gameDirs) {
        $mods = Join-Path $g 'Mods'
        foreach ($mf in Get-ChildItem $mods -Recurse -Depth 2 -Filter manifest.json -ErrorAction SilentlyContinue) {
            $txt = Get-Content $mf.FullName -Raw -Encoding UTF8
            if ($txt -match '"UniqueID"\s*:\s*"(Nagi\.NagiBridge|pendel001\.NagiBridge)"') {
                $backup = Join-Path $Here "old_mods_backup\$stamp"
                New-Item -ItemType Directory -Force -Path $backup | Out-Null
                Move-Item $mf.Directory.FullName (Join-Path $backup ("{0}-{1}" -f $mf.Directory.Name, (Get-Random)))
                Say "旧的 $($mf.Directory.Name) 挪到了 $backup"
            }
        }
        Copy-Item -Recurse $newModDir (Join-Path $mods 'NagiBridge')
        Say "新 mod 装进 $mods\NagiBridge"
    }
}

# ───────── 4. 钥匙和口令 ─────────
New-Item -ItemType Directory -Force -Path $KeyDir | Out-Null
if (-not (Test-Path $KeyPath)) {
    Say '生成隧道专用钥匙...'
    Start-Process -FilePath 'ssh-keygen' -ArgumentList "-q -t ed25519 -C kai-stardew -N `"`" -f `"$KeyPath`"" -Wait -NoNewWindow
    if (-not (Test-Path $KeyPath)) { Die '钥匙没生成出来' }
}
# Windows 的 ssh 要求私钥只有你自己能读, 否则拒绝使用
& icacls $KeyPath /inheritance:r /grant:r "${Me}:(R,W)" | Out-Null
$pubkey = (Get-Content "$KeyPath.pub" -Raw).Trim()

if (-not $cfg.token -or $cfg.token.Length -lt 32) {
    $bytes = New-Object byte[] 32
    [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    $cfg.token = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# ───────── 5. 服务器 ─────────
function Ask($prompt, $default) {
    $hint = if ($default) { " (直接回车 = $default)" } else { '' }
    $v = Read-Host "$prompt$hint"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v.Trim() }
}
Say '接下来装服务器那头 (就是跑 AstrBot 的那台)'
$cfg.server_host = Ask '服务器 IP (手机 Termius 里那台服务器的地址)' $cfg.server_host
$cfg.ssh_port = [int](Ask 'SSH 端口 (手机 Termius 里那台服务器填的端口)' $cfg.ssh_port)
if (-not $cfg.ssh_port) { Die '没填 SSH 端口' }
$cfg.login_user = Ask '手机 Termius 里登录这台服务器用的用户名' $(if ($cfg.login_user) { $cfg.login_user } else { 'root' })
$herQQ = Ask '你的 QQ 号 (耳朵用: 你在游戏里说话会当成这个号发给我)' $cfg.her_qq
if (-not $cfg.server_host) { Die '没填服务器 IP' }
if ($herQQ -and $herQQ -notmatch '^\d{5,12}$') { Die "QQ 号看起来不对: $herQQ" }
$cfg.her_qq = $herQQ

# 钉住服务器指纹: 以后指纹变了 (被人冒充), 这台电脑就拒绝连接
$scan = Native { ssh-keyscan -p $cfg.ssh_port -t ed25519,ecdsa,rsa $cfg.server_host 2>$null }
if (-not $scan) { Die "连不上 $($cfg.server_host):$($cfg.ssh_port), 检查 IP 和端口" }
[IO.File]::WriteAllText($KnownHosts, (($scan -join "`n") + "`n"), $Utf8NoBom)

# 这台电脑自己的服务器钥匙。服务器只认钥匙, 宝宝原来只有手机上那一把;
# 这把放进服务器以后, 电脑能自己装东西, 手机丢了也还有它能进门。私钥不离开这台电脑。
$AdminKey = Join-Path $KeyDir 'pc_admin_ed25519'
$adminIsNew = -not (Test-Path $AdminKey)
if ($adminIsNew) {
    Start-Process -FilePath 'ssh-keygen' -ArgumentList "-q -t ed25519 -C kai-pc -N `"`" -f `"$AdminKey`"" -Wait -NoNewWindow
    if (-not (Test-Path $AdminKey)) { Die '电脑钥匙没生成出来' }
}
& icacls $AdminKey /inheritance:r /grant:r "${Me}:(R,W)" | Out-Null
$adminPub = (Get-Content "$AdminKey.pub" -Raw).Trim()
$target = "$($cfg.login_user)@$($cfg.server_host)"
$AdminSsh = @('-i', $AdminKey, '-o', 'IdentitiesOnly=yes', '-o', "UserKnownHostsFile=$KnownHosts", '-o', 'StrictHostKeyChecking=yes')

function AdminWorks {
    $null = Native { ssh @AdminSsh -p $cfg.ssh_port -o BatchMode=yes -o ConnectTimeout=15 $target true 2>&1 }
    return ($LASTEXITCODE -eq 0)
}

# 服务器开着 fail2ban, 钥匙连错几次会封 IP。所以: 新钥匙肯定还没登记, 不去白撞; 每次试之前都要她确认; 最多试 3 次。
if ($adminIsNew -or -not (AdminWorks)) {
    $line = "mkdir -p ~/.ssh && echo '$adminPub' >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys && echo KAI-OK"
    Set-Clipboard -Value $line
    Say '要让服务器认识这台电脑。只需要你搬运一行字, 已经复制好了:'
    Write-Host ''
    Write-Host '   1. 打开电脑 QQ, 点开 "我的手机" (用微信就点 "文件传输助手"), 按 Ctrl+V 粘贴, 发送'
    Write-Host '   2. 拿起手机, 在 QQ 的 "我的电脑" (微信的 "文件传输助手") 里长按这条消息, 复制'
    Write-Host '   3. 打开手机 Termius, 连上你的服务器'
    Write-Host '   4. 在黑色的命令行里长按, 粘贴, 按回车'
    Write-Host '   5. 看到 KAI-OK 就成了, 回到电脑这个窗口按回车'
    Write-Host ''
    Write-Host '   (这一行只是告诉服务器 "这台电脑也是宝宝的", 发到 QQ 微信里被人看到也没关系)' -ForegroundColor DarkGray
    $tries = 0
    while ($true) {
        $ans = Read-Host "`n手机上看到 KAI-OK 了就按回车 (输入 q 先退出, 以后重新双击 安装.bat 接着来)"
        if ($ans -eq 'q') { exit 1 }
        if (AdminWorks) { break }
        $tries++
        if ($tries -ge 3) {
            Die '试了 3 次服务器都不认。先停一下, 不然 fail2ban 会把你的 IP 封掉。过 15 分钟再双击 安装.bat, 把这个窗口拍给 Kai'
        }
        Say '服务器还不认识这台电脑。看看手机上是不是没出现 KAI-OK, 或者用户名填的跟 Termius 里不一样'
        Set-Clipboard -Value $line
        Write-Host '   (那一行又复制进剪贴板了, 可以从第 1 步重来)'
    }
    Set-Clipboard -Value ' '
}
Say '服务器认识这台电脑了'

# 打包: 服务器脚本 + 插件 + 隧道公钥/口令/QQ
$stage = Join-Path $Downloads 'bundle'
if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path (Join-Path $stage 'server') | Out-Null
Copy-Item (Join-Path $KaiRoot 'server\setup_server.sh') (Join-Path $stage 'server\setup_server.sh')
Copy-Item -Recurse (Join-Path $KaiRoot 'astrbot_plugin_kai_stardew') (Join-Path $stage 'astrbot_plugin_kai_stardew')
Get-ChildItem $stage -Recurse -Directory -Filter __pycache__ | Remove-Item -Recurse -Force
[IO.File]::WriteAllText((Join-Path $stage 'secrets.env'), "PUBKEY=$pubkey`nTOKEN=$($cfg.token)`nHER_QQ=$herQQ`n", $Utf8NoBom)
$bundle = Join-Path $Downloads 'kai_stardew_bundle.tgz'
if (Test-Path $bundle) { Remove-Item -Force $bundle }
& tar -czf $bundle -C $stage .
if ($LASTEXITCODE -ne 0) { Die '打包失败 (Windows 10 1803 以上才自带 tar)' }
Remove-Item -Recurse -Force $stage

Say '把服务器要的东西传上去装好 (不是 root 的话 sudo 可能问一次密码)...'
& scp @AdminSsh -P $cfg.ssh_port $bundle "${target}:kai_stardew_bundle.tgz"
$scpCode = $LASTEXITCODE
Remove-Item -Force $bundle
if ($scpCode -ne 0) { Die '上传失败, 看上面的报错' }
# 包里有口令: 放在登录用户自己的家目录 (别人读不到), 解开在 umask 077 的临时目录里, 装完连包一起删
$remote = 'umask 077; d=$(mktemp -d) && tar xzf ~/kai_stardew_bundle.tgz -C $d && rm -f ~/kai_stardew_bundle.tgz && tr -d ''\r'' < $d/server/setup_server.sh > $d/setup.sh && if [ $(id -u) = 0 ]; then bash $d/setup.sh $d; else sudo bash $d/setup.sh $d; fi; s=$?; rm -rf $d ~/kai_stardew_bundle.tgz; exit $s'
& ssh @AdminSsh -t -p $cfg.ssh_port $target $remote
if ($LASTEXITCODE -ne 0) { Die '服务器那头没装成, 把上面的红字发给 Kai' }

# ───────── 6. 本机配置 + 自检 + 快捷方式 ─────────
$cfg.python = $py
$cfg.remix_dir = 'remix'
$cfg.ssh_user = 'kaitunnel'
$cfg.ssh_key = 'keys\kai_stardew_ed25519'
$cfg.known_hosts = 'keys\known_hosts'
if (-not $cfg.game_port) { $cfg.game_port = 7843 }
[IO.File]::WriteAllText($ConfigPath, ($cfg | ConvertTo-Json), $Utf8NoBom)
& icacls $ConfigPath /inheritance:r /grant:r "${Me}:(R,W)" | Out-Null

Say '试一下隧道钥匙...'
$info = Native { ssh -i $KeyPath -p $cfg.ssh_port -o IdentitiesOnly=yes -o BatchMode=yes -o "UserKnownHostsFile=$KnownHosts" -o StrictHostKeyChecking=yes -T "kaitunnel@$($cfg.server_host)" 2>&1 }
if (($info -join "`n") -notmatch 'KAI_LISTEN=') { Die "隧道钥匙没通: $info" }
Say "通了: $($info -join ' ')"

$lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Kai 的星露谷.lnk'
$sh = New-Object -ComObject WScript.Shell
$s = $sh.CreateShortcut($lnk)
$s.TargetPath = Join-Path $Here '启动Kai.bat'
$s.WorkingDirectory = $Here
$s.Save()

Say '全部装好了。以后玩的时候: 先开两个星露谷 (你是房主, 我进来当农场工), 再双击桌面上的 "Kai 的星露谷" (就是这个文件夹里的 启动Kai.bat)。'
Say '关掉那个黑窗口, 我就碰不到你的电脑了。'
