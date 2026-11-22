# 跨屏键鼠 / LAN KVM

给 DSH Web UI 加一个左侧栏入口：在同一局域网内，用这台 Mac 的键盘和鼠标直接操作旁边的 Windows 电脑。

**不传画面，不传视频。** Windows 显示器本来就在旁边，这个插件只负责把 Mac 的键鼠事件安全地发到 Windows。

## 当前能力

- DSH 左侧栏入口 + 独立主面板
- 全局捕获 Mac 键盘和鼠标：不要求 DSH 页面保持焦点
- 鼠标边缘跨屏：移到 Mac 屏幕边缘自动进入 Windows，移到 Windows 边缘自动回到 Mac
- 可设置 Windows 在 Mac 的右侧、左侧、两侧，或关闭边缘切换
- 边缘模式下点「连接」不会锁住 Mac；只有真正跨过去才接管输入
- 按 `⌃⌥⌘K`（Control+Option+Command+K）也可以立即把键鼠交还 Mac
- 面板里始终有一个「立即交还 Mac」按钮，跨屏状态下点它可以无条件夺回控制
- Windows 接收端是一个可以看见、可以关闭的窗口，点「Stop agent」或直接关窗口就停止接管
- 鼠标移动 1:1 对应（不经过 Windows 指针加速，避免两个光标越走越偏）
- 鼠标移动、左键/右键/中键、拖拽、滚轮
- 跨屏边缘带迟滞：进出边界时手抖不会来回弹跳
- 键盘按键、组合键、F1–F12、方向键等
- 没有截图、视频流或屏幕共享；只传输入事件和剪贴板
- 剪贴板双向同步：文字、图片，以及 Finder / 资源管理器里复制的**文件**
- 默认上限：文字 32MB、图片 64MB、单次文件复制 128MB（合计）；可在面板里关闭或调整
- 面板自带「扫描局域网」，自动发现同一 /24 网段里的接收端
- Windows 接收端带 Token 鉴权，默认只监听局域网
- 低延迟持久 TCP 输入通道（HTTP 端口 + 1，默认 7682）；不可用时自动回退 HTTP
- 自带 macOS 全局输入 Helper，首次使用时自动编译

## 安装（Mac / DSH）

插件包目录就是本目录。在 DSH 里安装本地 bundle：

```text
plugin_manager install_bundle target=/absolute/path/to/dsh-lan-kvm
```

安装后左侧栏会出现「跨屏键鼠」图标。

## 配置 Windows 接收端

1. 在面板里点「下载 Windows 接收端」，得到 `dsh-lan-kvm-agent.ps1`。
2. 把脚本放到 Windows 电脑上，打开 PowerShell，在脚本所在目录运行：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\dsh-lan-kvm-agent.ps1 -Port 7681
   ```

3. 运行后会弹出一个控制窗口，里面显示端口、Token 和已处理的事件数。窗口上有：
   - **Stop agent**：立即停止接管，Mac 恢复完全本地控制
   - **Disable pointer hiding**：关闭 Windows「打字时隐藏指针」，避免远程光标看不见
   - **Copy token**：复制 Token

   关闭窗口等同于停止。窗口右上角可以最小化，最小化后仍在运行。

   如果只是想后台运行（例如开机自启），加 `-Headless`：

   ```powershell
   powershell -ExecutionPolicy Bypass -File .\dsh-lan-kvm-agent.ps1 -Port 7681 -Headless
   ```

4. 如果浏览器下载后 Windows 提示脚本被阻止，先执行 `Unblock-File .\dsh-lan-kvm-agent.ps1`，或右键文件 → 属性 → 解除锁定。
5. 如果防火墙弹出提示，允许「专用网络」。没有弹窗但 Mac 连不上时，用管理员 PowerShell 执行：

   ```powershell
   New-NetFirewallRule -DisplayName 'DSH LAN KVM' -Direction Inbound -Protocol TCP -LocalPort 7681,7682 -Action Allow -Profile Private
   ```

6. 记下控制窗口里显示的 IPv4 地址和 Token（每次启动随机生成；也可用 `-Token 你的固定Token` 固定）。

> Windows 端只需要系统自带的 Windows PowerShell 5.1，不需要 Node.js、Python 或 npm。
>
> 如果之前运行过旧版接收端，请先关掉旧窗口，重新下载并运行这一版；新版本增加了批量输入、相对鼠标移动和 7682 持久输入通道，旧版不兼容。

## 授权 macOS 辅助功能

第一次点「连接并接管」时，DSH 会编译并启动一个很小的原生 Helper，macOS 会要求辅助功能权限：

1. 面板会显示 Helper 的完整路径，并提供「打开辅助功能设置」和「在 Finder 中显示 Helper」。
2. 在「系统设置 → 隐私与安全性 → 辅助功能」里点 `+`，把 Helper 加进去并勾选。
3. 如果 Helper 仍然无法创建事件捕获，再到「输入监控」里加入同一个 Helper。
4. 授权后 Helper 会自动检测并开始接管，一般不需要重启 DSH。如果授权后状态没有变化，点「断开 Windows」再重新连接一次。

Helper 路径固定在：

```text
~/Library/Application Support/dsh-lan-kvm/bin/dsh-lan-kvm-helper
```

插件升级后如果 Helper 被重新编译，macOS 可能要求重新授权一次；这是 TCC 的安全机制。

## 使用

1. 填 Windows 地址、端口、Token，或点「扫描局域网」自动发现接收端，再点「连接（跨屏模式）」。
2. 首次使用先完成辅助功能授权；面板会显示进度。
3. 在面板里选择 Windows 相对 Mac 的位置：右侧、左侧、两侧，或关闭边缘切换。默认是右侧。
4. 连接后 Mac 仍可正常操作；把鼠标移到对应边缘才会进入 Windows；接管期间 Helper 会临时成为前台应用并隐藏所有 Mac 显示器上的光标。这可能会让 Dock/菜单栏短暂出现，返回 Mac 后会恢复之前的前台应用。
5. 把鼠标移到 Windows 对应边缘并继续向外移动，键鼠自动回到 Mac；也可以按 `⌃⌥⌘K` 或点「交还 Mac」。
6. 文字/图片复制会自动双向同步；密码管理器标记为 concealed/transient 的内容会跳过。
7. 「断开 Windows」会停止 Helper 并释放连接。

接管期间建议先记住快捷键，因为 Mac 的输入会被锁定。

## 关于手感

鼠标移动按绝对坐标 1:1 发送，不乘 Windows 的指针加速曲线，所以 Mac 上移动多少、Windows 上就移动多少。

实测增益（实际位移 / 请求位移）：

| 一步位移 | 绝对定位（现在） | 相对事件（旧实现） |
|---|---|---|
| 4 px | 1.00x | 0.75x |
| 25 px | 1.00x | 1.84x |
| 60 px | 1.00x | 2.33x |
| 150 px | 1.00x | 2.55x |

旧的相对事件方式会让 Windows 指针越走越快，两个光标很快对不上。

Windows 端如果开启了「打字时隐藏指针」，远程光标会在打字后消失。控制窗口里的 **Disable pointer hiding** 可以关掉它；键鼠移动时也会自动把指针唤醒。

## 如果指针回不到 Mac

按优先级依次尝试，任意一个都有效：

1. 把鼠标继续往 Mac 的方向推：到达 Windows 屏幕对应边缘时会自动回到 Mac。
2. 按 `⌃⌥⌘K`：这是 macOS 上的全局快捷键，即使 Windows 端完全没响应也能返回。
3. 在 DSH 面板点「立即交还 Mac」。
4. 在 Windows 上关闭控制窗口，或点「Stop agent」。

返回逻辑不依赖 Windows 的实时反馈：Helper 会在本地推算 Windows 光标位置，所以网络卡顿、探针失败或输入通道断开都不会把你困在 Windows 里。同理，如果 DSH 退出或 Helper 进程消失，Mac 会自动恢复光标和前台应用。

## 安全边界

- 默认只适合可信局域网。Token 会保存在当前浏览器的 `localStorage`（可取消“记住”）。
- 不要把接收端端口映射到公网。
- Windows 端以当前用户权限运行，无法操作 UAC 提权窗口；这是 Windows 的安全边界。
- macOS 的系统级快捷键（例如 `Cmd+Tab`）由 macOS 在事件到达 Helper 之前拦截，无法转发。
- 当前有鼠标边缘自动穿越和文字/图片/文件剪贴板同步；还没有原生拖动、文件夹递归传输或音频。

## 结构

- `client.js`：左侧栏图标、主面板、连接状态、授权引导、文案。
- `index.js`：同源 Host 路由、Helper 生命周期、输入批处理、Windows 连接。
- `remote.js`：目标校验、探测、输入转发。
- `mac-helper.swift`：macOS 全局键鼠捕获 Helper（CGEventTap）。
- `win-agent.ps1`：Windows 接收端（PowerShell + C# P/Invoke）。
- `locale/*.json`：插件管理器里的标题/描述。
- `icon.svg`：插件图标。

## 已知限制

- 只支持 IPv4 或主机名，暂不支持 IPv6。
- 键盘映射按 US 键位处理；非 US 键盘布局的特殊字符可能有差异。
- Mac 的 `Command` 映射为 Windows `Ctrl`；右侧 `Command` 映射为 Windows `Win`。
- 中文输入建议在 Windows 端启用中文输入法；Mac 输入法的候选词不会跨系统同步。
- Windows 接收端未在真实 Windows 机器上由本次构建验证；需要在目标机器上跑一次连接、点击、键盘输入验收。
