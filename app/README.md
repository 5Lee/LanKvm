# LanKvm

一个键盘鼠标，控制两台电脑。Mac 和 Windows **各自是一个独立程序**，不需要 DSH，也不需要任何插件框架。

Windows 显示器就在旁边，所以软件只传输入事件和剪贴板，不传画面、不推流。

## 关于辅助功能权限

Mac 首次使用时，请在「系统设置 → 隐私与安全性 → 辅助功能」中授权 LanKvm。macOS 会核对应用的签名身份，从发布版切换到自行编译的版本时可能需要重新授权。自行编译时，`build.sh` 优先使用钥匙串中的 `LanKvm Local Signing` 身份，也支持通过 `LANKVM_SIGN_IDENTITY` 指定已有身份。

## 界面语言

两端的界面都是**中文**。

## 下载安装

从 [GitHub Releases](https://github.com/5Lee/LanKvm/releases/latest) 下载 Mac 的 DMG 和 Windows 的 ZIP。源码构建命令在下方。

**Mac**：双击 dmg，把 `LanKvm.app` 拖到「应用程序」，然后推出安装镜像。以后在「应用程序」中打开蓝紫色双屏、白色指针图标的 LanKvm 即可。

**Windows**：解压 zip，以管理员身份运行 `install.bat` 配置防火墙，然后双击 `run-lankvm.bat`。exe 已经编译好在里面，**不需要装任何东西**。

两边互不依赖。Windows 端不需要 PowerShell、Node.js 或 .NET SDK。

## 快速开始

### 1. Windows 端

1. 解压 `LanKvm-win.zip`
2. 以管理员身份运行 `install.bat` 配置专用网络防火墙
3. 回到资源管理器，双击 `run-lankvm.bat`

接收端会以日常用户权限运行。窗口里会显示**地址和 Token**。

之后日常使用直接双击 `run-lankvm.bat` 即可。

- **Stop LanKvm**：立刻停止接管，键鼠回到 Windows 本机
- **Start with Windows**：开机自启
- **Disable pointer hiding**：关掉「打字时隐藏指针」
- **Copy token**：复制 Token

关掉窗口等同于停止。Token 会记住，重启不用重新配置。

### 2. Mac 端

1. 打开 dmg，把 `LanKvm.app` 拖到 Applications
2. 启动后菜单栏出现图标 → `Settings…`
3. 填入 Windows 窗口里显示的地址和 Token → `Save & Connect`

> 发布包使用项目的本地签名，未经过 Apple 公证。macOS 可能显示开发者验证提示，也可以按下方说明从源码构建。

首次运行会请求**辅助功能**权限，必须在「系统设置 → 隐私与安全性 → 辅助功能」里勾选，否则无法捕获键鼠。

## 首次运行：必须授予辅助功能权限

这是 macOS 的硬性要求，**不授予就完全不能用**——虽然界面会显示「已连接」。

macOS 把子进程的权限算在**父进程**头上。输入的 helper 是 LanKvm.app 的子进程，所以必须是 **LanKvm.app** 拿到权限，helper 才能捕获键鼠。

首次启动时应用会弹出提示，点 **Open Settings**，然后在「隐私与安全性 → 辅助功能」里**打开 LanKvm 的开关**。

授予后**不需要重启**，应用会自动检测并重新加载，然后立刻就能用。

如果误点了 Later：

- 菜单栏图标 → `⚠︎ Grant Accessibility to LanKvm…`
- 或者手动打开「系统设置 → 隐私与安全性 → 辅助功能」，添加 LanKvm.app

菜单栏会显示 **Needs Accessibility permission** 时，就是还没授权。

## 怎么用

- **鼠标移到 Mac 屏幕边缘** → 自动进入 Windows
- **移到 Windows 屏幕对应边缘** → 自动回到 Mac
- 菜单栏可以切换 Windows 在左边/右边/两边，或关闭边缘切换
- 「Windows 纵向滚轮与 Mac 相反」默认勾选。同样向前转动滚轮，两边页面的上下滚动方向相反。取消勾选即可跟随 Mac，选项即时生效并自动保存。横向滚动沿用原方向。
- **`⌃⌥⌘K`**（Control+Option+Command+K）→ 立刻交还 Mac
- 菜单栏 **Return to Mac now** → 同样立刻交还

### 游戏与视角控制

在 Windows 上按住左键或右键转动视角时，指针会留在 Windows。松开最后一个鼠标键后，先把指针移离返回边缘，再向外推即可正常回到 Mac。独立版 1.1 的 Windows 接收端会在识别到前台《魔兽世界》窗口时发送相对鼠标移动。

希望整场游戏都留在 Windows，可先勾选 Mac 菜单栏的「游戏锁屏（快捷键返回 Mac）」，再移到 Windows。此模式也会为其他游戏的左右键拖动发送相对移动。随时可按 `⌃⌥⌘K` 返回，普通桌面使用时取消勾选即可。请同时更新两端以启用接收端的游戏适配和断线松键。

### Mac 键位怎么对应 Windows

| Mac | Windows | 例子 |
|---|---|---|
| Control | **Ctrl** | `Ctrl+C` 复制 |
| Option | **Alt** | `Alt+Tab` 切换窗口 |
| 右 Command (⌘) | **Win** | **右⌘ + D** = `Win+D` 显示桌面 |
| Shift | Shift | |
| 左 Command (⌘) | Ctrl | 兼容 Mac 习惯 |

**注意 `Win` 键是右边的 ⌘**（左 ⌘ 映射成 Ctrl）。所以「显示桌面」= **右⌘ + D**。

`Alt+Tab`、`Ctrl+Shift+Esc`、`Win+E`、`Win+R` 这些都可用。

> 早期版本把右 ⌘ 映射成 **右 Win 键**（`VK_RWIN`），而 Windows 不认右 Win 的组合键，
> 导致 `Win+D` 之类的快捷键失效。已改为标准的左 Win 键（`VK_LWIN`）。

Mac 鼠标在控制 Windows 时会自动隐藏，不会出现两个指针。

## 诊断日志

Mac 独立版 1.3.1 在开启调试（`LANKVM_DEBUG=1`）时，把连接、重试、助手状态及超过 250 毫秒的输入回执等待写到 `~/Library/Logs/LanKvm/`。慢回执只记发生时间和毫秒数，每 30 秒最多记录一次。写入使用后台队列。每个 UTC 日期最多 256 KiB，保留当天及之前六天。启动时和运行期间每小时都会检查过期日志。旧版的 `/tmp/lankvm-app.log` 超过 256 KiB 或七天未更新时会自动清理。Windows 1.3.0 接收端默认不写诊断日志文件。

## 剪贴板

Mac 独立版 1.1.1 使用单独的后台进程传输剪贴板内容。大文件的读取、编码和收发与键鼠捕获分开运行，沿用 Windows 接收端现有的传输协议。

双向自动同步：

- 文字
- 图片
- **文件、图片文件和文件夹**。两端 1.2.0 支持在 Finder 或资源管理器中多选、混选，递归保留目录结构、空目录和空文件。Mac 应用一次提供多张独立位图时，会按顺序生成图片文件。

文件会真正写入对面系统的临时目录并放进剪贴板，可以在访达/资源管理器里直接粘贴。

两端均为 1.3.0 或更高版本时，文件、文件夹和多选图片文件使用独立的分块连接，支持 64 位文件长度，不设单次总大小或项目数上限。接收端需要足够的临时磁盘空间。旧版文件协议仍限 128 MiB 和 10,000 个项目。文字和单张剪贴板位图分别限 32 MiB、64 MiB。包含符号链接、Windows 重解析点或目标系统无法保留的文件名时，会跳过整次选择并在菜单栏提示。

## 退路

如果指针回不到 Mac，按优先级试：

1. 继续往 Mac 方向推鼠标
2. `⌃⌥⌘K`
3. 菜单栏 **Return to Mac now**
4. 关掉 Windows 上的 LanKvm 窗口

返回逻辑**不依赖网络反馈**：Mac 端在本地推算 Windows 光标位置，所以网络卡顿或输入通道断开都不会把指针困住。macOS 上的快捷键也是本地处理的。

如果 Mac 端程序退出或崩溃，光标会自动恢复。

## 安全

- 局域网发现使用匿名设备介绍；输入与剪贴板请求需要 Token
- Windows 安装脚本将 7681（HTTP）和 7682（输入流）的入站规则限制在专用网络的本地子网
- Token 首次启动随机生成并保存在 `%APPDATA%\LanKvm\token.txt`，可用 `-Token 你的Token` 指定

**不要把这个端口暴露到公网。**

Windows 端以当前用户权限运行，无法操作 UAC 提权窗口——这是 Windows 的安全边界。

## 从源码构建

### Mac

```bash
cd app/mac
./build.sh      # 编译 LanKvm.app
./make-dmg.sh   # 打包成 LanKvm.dmg
```

复用 `mac-helper.swift`（输入捕获、跨屏、剪贴板），所以和 DSH 插件的输入行为完全一致。

### Windows

改了 `LanKvm.cs` 之后：

```bat
cd app\win
build-on-windows.bat
```

然后回到 Mac 重新打包分发包：

```bash
cd app/win && ./make-zip.sh
```

`make-zip.sh` 会把已经编译好的 `LanKvm.exe` 打进 zip，用户端不需要编译器。

## 目录

```
app/
├── mac/
│   ├── Sources/          # 菜单栏界面、网络层、局域网发现、设置
│   ├── build.sh          # 编译 app
│   ├── make-dmg.sh       # 打包 dmg
│   └── build/
│       ├── products.noindex/LanKvm.app
│       └── LanKvm.dmg    # ← 分发包
└── win/
    ├── LanKvm.cs         # 全部 Windows 逻辑
    ├── LanKvm.exe        # 构建产物，包含在发布 ZIP 中
    ├── install.bat       # 防火墙设置（含兜底编译）
    ├── run-lankvm.bat    # 日常启动
    ├── build-on-windows.bat
    ├── make-zip.sh       # 在 Mac 上打包 zip
    └── build/
        └── LanKvm-win.zip  # ← 分发包
```

## 和 DSH 插件的关系

根目录下的 `package.json` / `index.js` / `client.js` 是**旧的 DSH 插件版本**，仍在 `dsh-lan-kvm@0.7.0` 可用。

独立版和插件版可以共存，但不能同时控制同一台 Windows（会抢输入）。日常使用建议只开独立版。

## 已知限制

- 没有画面传输（这是设计选择，显示器就在旁边）
- 中文输入建议在 Windows 端启用中文输入法；Mac 输入法的候选词不会跨系统同步
- 没有原生拖动文件到另一个屏幕
