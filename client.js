/**
 * LAN KVM — browser half.
 *
 * Input-only software KVM: the Mac helper captures the keyboard and mouse
 * globally while remote mode is active, and the Host sends input events to the
 * Windows agent. There is deliberately no screenshot or video stream here.
 */
window.__ModuleLoader__.load({
  id: '@local/dsh-lan-kvm',
  factory(require) {
    const React = require('react');
    const { createElement: h, useCallback, useEffect, useMemo, useRef, useState } = React;

    const NS = 'lan-kvm';
    const API = '/lan-kvm/api';
    const STORAGE_KEY = 'dsh.lan-kvm.settings.v2';
    let autoConnectAttempted = false;

    const EN = {
      nav: 'LAN KVM',
      title: 'Use this Mac keyboard and mouse on Windows',
      subtitle: 'No screen stream. Windows sits next to you; only input events cross the LAN.',
      statusIdle: 'Not connected',
      statusConnected: 'Connected',
      statusActive: 'Controlling Windows',
      statusPermission: 'Waiting for permission',
      edgeMode: 'Windows position',
      edgeRight: 'Windows is on the right',
      edgeLeft: 'Windows is on the left',
      edgeBoth: 'Both sides',
      edgeOff: 'Off (button / shortcut only)',
      edgeHintRight: 'Move to the Mac right edge to enter Windows; keep moving left at the Windows left edge to return.',
      edgeHintLeft: 'Move to the Mac left edge to enter Windows; keep moving right at the Windows right edge to return.',
      edgeHintBoth: 'Either Mac edge enters Windows; the matching Windows edge returns.',
      edgeHintOff: 'Edge crossing is off. Use the button or the return shortcut.',
      edgeChanged: 'Edge direction updated.',
      activeHintEdge: 'Keyboard and mouse are going to Windows. Move to the Windows edge or press the shortcut to return to the Mac.',
      address: 'Windows address',
      addressPlaceholder: '192.168.1.20',
      port: 'Port',
      token: 'Token',
      tokenPlaceholder: 'From the agent window',
      tokenHelp: 'The characters after "Token:" in the Windows agent window, at least 6 characters. It is not the IP or a Windows password.',
      tokenRequired: 'Enter the Token first. In the Windows agent window, copy the value after "Token:".',
      show: 'Show',
      hide: 'Hide',
      remember: 'Remember on this Mac',
      connect: 'Connect and take over',
      connectEdge: 'Connect (edge mode)',
      waitingEdge: 'Waiting for edge crossing',
      edgeReadyNotice: 'Connected. Move the pointer across the Mac edge to enter Windows.',
      manualTakeover: 'Take over now',
      returnNow: 'Return to Mac now',
      returning: 'Returning…',
      returnHint: 'Always available: the shortcut works on macOS even when the Windows side stops answering.',
      edgeStuck: 'Edge mode is armed. If the pointer will not come back, press {hotkey} or click Return to Mac now.',
      connecting: 'Connecting…',
      preparing: 'Preparing the Mac helper…',
      reconnect: 'Take over again',
      release: 'Return to Mac',
      releasing: 'Returning…',
      disconnect: 'Disconnect Windows',
      disconnecting: 'Disconnecting…',
      mac: 'Mac',
      windows: 'Windows',
      macControl: 'Mac input',
      windowsControl: 'Windows input',
      activeHint: 'Keyboard and mouse are going to Windows. Press the shortcut to return to the Mac.',
      readyHint: 'Ready. Take over again to send this keyboard and mouse to Windows.',
      permissionHint: 'macOS Accessibility permission is still required.',
      notConnectedHint: 'Connect the Windows agent first.',
      hotkey: 'Return shortcut',
      hotkeyNote: 'After taking over, press this combination to bring input back to the Mac.',
      permissionTitle: 'macOS Accessibility permission',
      permissionBody:
        'The helper needs Accessibility access to capture and forward the Mac keyboard and mouse. Add the helper below to Accessibility in System Settings.',
      openAccessibility: 'Open Accessibility settings',
      openInputMonitoring: 'Open Input Monitoring settings',
      revealHelper: 'Show helper in Finder',
      permissionAfter: 'After granting access, the helper detects it automatically; no DSH restart is needed.',
      permissionReady: 'Accessibility permission is ready.',
      helper: 'Mac helper',
      helperRunning: 'Running',
      helperStopped: 'Stopped',
      helperReady: 'Ready',
      helperWait: 'Waiting for permission',
      latency: 'Latency',
      channel: 'Input channel',
      channelStream: 'Persistent TCP',
      channelHttp: 'HTTP fallback',
      channelHint: 'After connecting, input uses the 7682 persistent TCP stream; if unavailable it falls back to HTTP.',
      clipboardSync: 'Clipboard sync',
      clipboardOn: 'On',
      clipboardOff: 'Off',
      clipboardHint: 'Text, images and copied files sync both ways automatically.',
      clipboardLimits: 'Current limits: {text} text, {image} image, {files} per file copy.',
      hostname: 'This Mac',
      noAddress: 'No LAN IPv4 address detected',
      setup: 'Set up the Windows side',
      setupIntro: 'Run one PowerShell script on the Windows PC. No install, no account, no cloud.',
      step1: 'Download the agent script below.',
      step2: 'Open PowerShell in the download folder and run the command below.',
      step3: 'Allow the firewall prompt for Private networks, then copy the printed IP and token here.',
      download: 'Download Windows agent',
      command: 'Run command',
      firewall: 'If the connection is refused, allow TCP {port} and {stream} for the Private profile in Windows Firewall.',
      security: 'Traffic stays on your LAN. The agent requires its token for every request. Do not forward the port from your router.',
      noScreen: 'No screenshots or video: only keyboard and mouse events leave this Mac.',
      scan: 'Scan LAN',
      scanning: 'Scanning…',
      scanHint: 'Find receivers on this Mac\'s /24 automatically.',
      scanEmpty: 'No receiver found. Check the Windows script, firewall, and that both computers are on the same LAN.',
      scanFound: 'Found {n} receiver(s). Click one to fill the address.',
      scanPicked: 'Address set to {host}. Enter the token, then connect.',
      legacyAgent: 'Receiver found (token required)',
      copy: 'Copy',
      copied: 'Copied',
      downloadHint: 'Save as dsh-lan-kvm-agent.ps1',
      invalidToken: 'The token was rejected. Copy the token printed in the agent window.',
      unreachable: 'Cannot reach the Windows agent. Check the IP, port, firewall, and that both computers are on the same LAN.',
      clipboardError: 'Clipboard access was refused by the browser.',
      helperCompile: 'The Mac helper is being compiled once. This can take a few seconds.',
      connectedTo: 'Connected to {host}',
      notRunningHint: 'The Mac helper is not running. Choose Take over again to start it.',
      permissionNeeded: 'The helper is running. Grant Accessibility permission, then it starts automatically.',
      takeOverStarted: 'Input is now going to Windows.',
      released: 'Input returned to this Mac.',
      disconnected: 'Windows connection closed.',
      openSettings: 'Settings opened.',
      helperPath: 'Helper path',
      startHint: 'Start with the button. The shortcut is the quick way back to the Mac.',
    };

    const ZH = {
      nav: '跨屏键鼠',
      title: 'Mac 键鼠，直接控制 Windows',
      subtitle: '不传画面。Windows 显示器就在旁边，只有键盘鼠标事件走局域网。',
      statusIdle: '未连接',
      statusConnected: '已连接',
      statusActive: '正在控制 Windows',
      statusPermission: '等待授权',
      edgeMode: 'Windows 位置',
      edgeRight: 'Windows 在右侧',
      edgeLeft: 'Windows 在左侧',
      edgeBoth: '左右两侧都可以',
      edgeOff: '关闭（只用按钮/快捷键）',
      edgeHintRight: '鼠标移到 Mac 屏幕右边缘进入 Windows；在 Windows 左侧边缘继续向左，回到 Mac。',
      edgeHintLeft: '鼠标移到 Mac 屏幕左边缘进入 Windows；在 Windows 右侧边缘继续向右，回到 Mac。',
      edgeHintBoth: 'Mac 左右边缘都能进入 Windows；从 Windows 对应侧边缘返回。',
      edgeHintOff: '已关闭边缘切换，只能用按钮或快捷键。',
      edgeChanged: '跨屏方向已更新。',
      activeHintEdge: '键盘鼠标正在发送到 Windows。把鼠标移到 Windows 边缘，或按快捷键，回到 Mac。',
      address: 'Windows 地址',
      addressPlaceholder: '192.168.1.20',
      port: '端口',
      token: 'Token',
      tokenPlaceholder: '填写 Windows 窗口里的 Token',
      tokenHelp: 'Windows 接收端窗口里 `Token:` 后面的字符，至少 6 位；不是 IP，也不是 Windows 密码。',
      tokenRequired: '请先填写 Token。在 Windows 接收端窗口里找到 `Token:`，复制它后面的那串字符。',
      show: '显示',
      hide: '隐藏',
      remember: '在这台 Mac 上记住',
      connect: '连接并接管',
      connectEdge: '连接（跨屏模式）',
      waitingEdge: '等待跨屏',
      edgeReadyNotice: '已连接。把鼠标移到 Mac 屏幕边缘即可进入 Windows。',
      manualTakeover: '立即接管',
      returnNow: '立即交还 Mac',
      returning: '正在交还…',
      returnHint: '随时可用：即使 Windows 端停止响应，macOS 上的快捷键仍然有效。',
      edgeStuck: '已进入跨屏状态。如果指针回不来，按 {hotkey} 或点「立即交还 Mac」。',
      connecting: '正在连接…',
      preparing: '正在准备 Mac 辅助程序…',
      reconnect: '重新接管',
      release: '交还 Mac',
      releasing: '正在交还…',
      disconnect: '断开 Windows',
      disconnecting: '正在断开…',
      mac: 'Mac',
      windows: 'Windows',
      macControl: 'Mac 键鼠',
      windowsControl: 'Windows 键鼠',
      activeHint: '键盘鼠标正在发送到 Windows。按快捷键立即交还 Mac。',
      readyHint: '已就绪。点「重新接管」把键盘鼠标交给 Windows。',
      permissionHint: '还需要 macOS 辅助功能权限。',
      notConnectedHint: '先连接 Windows 接收端。',
      hotkey: '交还快捷键',
      hotkeyNote: '接管后按这个组合键，键鼠立即回到 Mac。',
      permissionTitle: '需要 macOS 辅助功能权限',
      permissionBody:
        'Helper 需要辅助功能权限才能捕获并转发 Mac 的键盘鼠标。把下面的 Helper 加入系统设置里的「辅助功能」。',
      openAccessibility: '打开辅助功能设置',
      openInputMonitoring: '打开输入监控设置',
      revealHelper: '在 Finder 中显示 Helper',
      permissionAfter: '授权后不需要重启 DSH，Helper 会自动检测并开始接管。',
      permissionReady: '辅助功能权限已就绪。',
      helper: 'Mac 辅助程序',
      helperRunning: '运行中',
      helperStopped: '未运行',
      helperReady: '已就绪',
      helperWait: '等待授权',
      latency: '延迟',
      channel: '输入通道',
      channelStream: '持久 TCP',
      channelHttp: 'HTTP 回退',
      channelHint: '连接后自动使用 7682 持久 TCP 输入；如果不可用会回退 HTTP。',
      clipboardSync: '剪贴板同步',
      clipboardOn: '已开启',
      clipboardOff: '已关闭',
      clipboardHint: '文字、图片和复制的文件都会自动双向同步。',
      clipboardLimits: '当前上限：文字 {text}，图片 {image}，单次文件复制 {files}。',
      hostname: '这台 Mac',
      noAddress: '没有检测到局域网 IPv4 地址',
      setup: '配置 Windows 端',
      setupIntro: '只需在 Windows 上运行一个 PowerShell 脚本。不用安装软件，不用账号，不上云。',
      step1: '下载下面的接收端脚本。',
      step2: '在下载目录打开 PowerShell，运行下面的命令。',
      step3: '在防火墙提示里允许「专用网络」，然后把窗口打印的 IP 和 Token 填到这里。',
      download: '下载 Windows 接收端',
      command: '运行命令',
      firewall: '如果连接被拒绝，请在 Windows 防火墙的「专用」配置里放行 TCP {port} 和 {stream}。',
      security: '流量只在局域网内。接收端要求每个请求都带 Token。不要把端口映射到公网。',
      noScreen: '没有截图、没有视频流；只传输键盘和鼠标事件。',
      scan: '扫描局域网',
      scanning: '扫描中…',
      scanHint: '自动扫描这台 Mac 所在 /24 网段里的接收端。',
      scanEmpty: '没有发现接收端。请检查 Windows 脚本、防火墙，以及两台电脑是否在同一局域网。',
      scanFound: '发现 {n} 台接收端。点一下即可填入地址。',
      scanPicked: '地址已填为 {host}。填入 Token 后连接。',
      legacyAgent: '发现接收端（需要 Token）',
      copy: '复制',
      copied: '已复制',
      downloadHint: '保存为 dsh-lan-kvm-agent.ps1',
      invalidToken: 'Token 被拒绝。请复制 Windows 窗口里打印的 Token。',
      unreachable: '连不上 Windows 接收端。请检查 IP、端口、防火墙，以及两台电脑是否在同一局域网。',
      clipboardError: '浏览器拒绝了剪贴板访问。',
      helperCompile: '第一次使用会在本机编译 Mac 辅助程序，可能需要几秒。',
      connectedTo: '已连接到 {host}',
      notRunningHint: 'Mac 辅助程序未运行。点「重新接管」启动它。',
      permissionNeeded: 'Helper 已启动。请在系统设置里授予辅助功能权限，授权后会自动开始接管。',
      takeOverStarted: '键鼠现在已经发送到 Windows。',
      released: '键鼠已交还这台 Mac。',
      disconnected: '已断开 Windows 连接。',
      openSettings: '已打开系统设置。',
      helperPath: 'Helper 路径',
      startHint: '用按钮开始接管；接管后快捷键是回到 Mac 的最快方式。',
    };

    const CSS = `
.lk-page{height:100%;overflow:auto;box-sizing:border-box;padding:24px 28px 40px;color:var(--dsw-alias-label-primary);background:var(--dsw-alias-bg-base)}
.lk-inner{max-width:1180px;margin:0 auto;display:flex;flex-direction:column;gap:18px}
.lk-hero{display:flex;align-items:flex-start;gap:14px;min-width:0}
.lk-mark{width:44px;height:44px;flex:none;display:flex;align-items:center;justify-content:center;border-radius:12px;background:var(--dsw-alias-bg-layer-2);border:.5px solid var(--dsw-alias-border-l1);color:var(--dsw-alias-brand-primary)}
.lk-heading{min-width:0;flex:1}
.lk-title{margin:0;font-size:20px;line-height:28px;font-weight:600;letter-spacing:-.01em}
.lk-sub{margin:3px 0 0;font-size:13px;line-height:20px;color:var(--dsw-alias-label-secondary)}
.lk-status{display:inline-flex;align-items:center;gap:7px;flex:none;margin-top:5px;padding:4px 10px;border-radius:999px;border:.5px solid var(--dsw-alias-border-l2);font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary);background:var(--dsw-alias-bg-layer-1);white-space:nowrap}
.lk-dot{width:7px;height:7px;border-radius:50%;background:var(--dsw-alias-state-idle-primary)}
.lk-status.is-connected{color:var(--dsw-alias-state-success-primary);border-color:var(--dsw-alias-state-success-primary)}
.lk-status.is-connected .lk-dot{background:var(--dsw-alias-state-success-primary)}
.lk-status.is-active{color:var(--dsw-alias-brand-primary);border-color:var(--dsw-alias-brand-primary)}
.lk-status.is-active .lk-dot{background:var(--dsw-alias-brand-primary);box-shadow:0 0 0 3px color-mix(in srgb,var(--dsw-alias-brand-primary) 18%,transparent)}
.lk-status.is-wait{color:var(--dsw-alias-state-warn-primary);border-color:var(--dsw-alias-state-warn-primary)}
.lk-status.is-wait .lk-dot{background:var(--dsw-alias-state-warn-primary)}
.lk-status.is-error{color:var(--dsw-alias-state-error-primary);border-color:var(--dsw-alias-state-error-primary)}
.lk-status.is-error .lk-dot{background:var(--dsw-alias-state-error-primary)}
.lk-connect{display:flex;flex-wrap:wrap;align-items:flex-end;gap:12px;padding:14px 16px;border:.5px solid var(--dsw-alias-border-l1);border-radius:14px;background:var(--dsw-alias-bg-layer-1)}
.lk-field{display:flex;flex-direction:column;gap:6px;min-width:0}
.lk-field.grow{flex:1 1 220px}
.lk-field.port{width:96px;flex:none}
.lk-field.token{flex:1 1 260px}
.lk-field label{font-size:12px;line-height:17px;color:var(--dsw-alias-label-secondary)}
.lk-input{box-sizing:border-box;height:34px;width:100%;padding:0 10px;border-radius:8px;border:.5px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;outline:none}
.lk-input:focus{border-color:var(--dsw-alias-brand-primary);box-shadow:0 0 0 2px color-mix(in srgb,var(--dsw-alias-brand-primary) 16%,transparent)}
.lk-input:disabled{opacity:.6;cursor:not-allowed}
.lk-token-wrap{position:relative}
.lk-token-wrap .lk-input{padding-right:58px}
.lk-eye{position:absolute;right:4px;top:4px;height:26px;padding:0 8px;border:0;border-radius:6px;background:transparent;color:var(--dsw-alias-label-secondary);font:inherit;font-size:11px;cursor:pointer}
.lk-eye:hover{background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.lk-hint{font-size:10px;line-height:15px;color:var(--dsw-alias-label-secondary);max-width:360px}
.lk-remember{display:flex;align-items:center;gap:7px;height:34px;font-size:12px;color:var(--dsw-alias-label-secondary);cursor:pointer;white-space:nowrap}
.lk-remember input{accent-color:var(--dsw-alias-brand-primary)}
.lk-btn{box-sizing:border-box;height:34px;padding:0 13px;border-radius:8px;border:.5px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);-webkit-text-fill-color:var(--dsw-alias-label-primary);font:inherit;font-size:13px;line-height:32px;cursor:pointer;white-space:nowrap;text-decoration:none;display:inline-flex;align-items:center;justify-content:center;gap:6px}
.lk-btn:hover:not(:disabled){background:var(--dsw-alias-bg-layer-2)}
.lk-btn:disabled{opacity:.45;cursor:default}
.lk-btn.primary{background:#1f6feb;background-image:none;border-color:#1f6feb;color:#fff;-webkit-text-fill-color:#fff;font-weight:600}
.lk-btn.primary:hover:not(:disabled){background:#195ecf;border-color:#195ecf;opacity:1}
.lk-btn.danger{color:var(--dsw-alias-state-error-primary);-webkit-text-fill-color:var(--dsw-alias-state-error-primary);border-color:var(--dsw-alias-state-error-primary);background:transparent}
.lk-btn.subtle{background:transparent;border-color:transparent;color:var(--dsw-alias-label-secondary);-webkit-text-fill-color:var(--dsw-alias-label-secondary)}
.lk-btn.subtle:hover:not(:disabled){background:var(--dsw-alias-bg-layer-2);color:var(--dsw-alias-label-primary)}
.lk-btn.big{height:42px;line-height:40px;padding:0 20px;font-size:14px;border-radius:10px}
.lk-scan{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 16px;border:.5px solid var(--dsw-alias-border-l1);border-radius:12px;background:var(--dsw-alias-bg-layer-1)}
.lk-scan-hint{font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-channel-hint{margin:0;font-size:11px;line-height:17px;color:var(--dsw-alias-label-secondary);padding:0 2px}
.lk-found{display:flex;flex-direction:column;gap:6px}
.lk-found-row{display:flex;align-items:center;gap:10px;width:100%;padding:9px 12px;border-radius:9px;border:.5px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-label-primary);-webkit-text-fill-color:var(--dsw-alias-label-primary);font:inherit;font-size:12px;line-height:18px;text-align:left;cursor:pointer}
.lk-found-row:hover{background:var(--dsw-alias-bg-layer-2);border-color:var(--dsw-alias-brand-primary)}
.lk-found-row b{font-weight:600;min-width:110px}
.lk-found-row span{color:var(--dsw-alias-label-secondary);-webkit-text-fill-color:var(--dsw-alias-label-secondary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lk-alert{margin:0;padding:10px 12px;border-radius:10px;border:.5px solid var(--dsw-alias-state-error-primary);background:var(--dsw-alias-bg-layer-1);color:var(--dsw-alias-state-error-primary);font-size:12px;line-height:18px;word-break:break-word}
.lk-alert.warn{border-color:var(--dsw-alias-state-warn-primary);color:var(--dsw-alias-state-warn-primary)}
.lk-alert .lk-alert-title{font-weight:600;margin-bottom:4px}
.lk-notice{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-state-success-primary);word-break:break-word}
.lk-grid{display:grid;grid-template-columns:minmax(0,1fr) 350px;gap:16px;align-items:start}
.lk-card{min-width:0;border:.5px solid var(--dsw-alias-border-l1);border-radius:14px;background:var(--dsw-alias-bg-layer-1);overflow:hidden}
.lk-card-head{display:flex;align-items:center;gap:10px;min-height:44px;padding:8px 12px 8px 14px;border-bottom:.5px solid var(--dsw-alias-border-l1)}
.lk-card-title{font-size:13px;line-height:20px;font-weight:600;flex:1;min-width:0}
.lk-card-body{padding:16px}
.lk-control{display:flex;flex-direction:column;gap:16px}
.lk-machines{display:flex;align-items:stretch;gap:10px}
.lk-machine{flex:1;min-width:0;padding:14px;border-radius:12px;border:.5px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-base);display:flex;flex-direction:column;gap:4px;transition:border-color .15s ease,background .15s ease}
.lk-machine.is-active{border-color:var(--dsw-alias-brand-primary);background:var(--dsw-alias-bg-layer-2)}
.lk-machine-top{display:flex;align-items:center;gap:7px;font-size:11px;line-height:16px;color:var(--dsw-alias-label-secondary)}
.lk-machine-dot{width:7px;height:7px;border-radius:50%;background:var(--dsw-alias-state-idle-primary)}
.lk-machine.is-active .lk-machine-dot{background:var(--dsw-alias-brand-primary)}
.lk-machine-name{font-size:15px;line-height:22px;font-weight:600}
.lk-machine-sub{font-size:11px;line-height:16px;color:var(--dsw-alias-label-secondary);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.lk-switch{display:flex;align-items:center;justify-content:center;color:var(--dsw-alias-label-secondary);font-size:18px;flex:none;width:26px}
.lk-state-title{margin:0;font-size:16px;line-height:24px;font-weight:600}
.lk-state-text{margin:0;font-size:13px;line-height:20px;color:var(--dsw-alias-label-secondary)}
.lk-actions{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.lk-hotkey-box{display:flex;align-items:center;gap:10px;flex-wrap:wrap;padding:10px 12px;border-radius:10px;border:.5px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-base)}
.lk-hotkey-label{font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-label{font-size:12px;line-height:17px;color:var(--dsw-alias-label-secondary)}
.lk-edge{display:flex;align-items:center;gap:10px;flex-wrap:wrap}
.lk-select{box-sizing:border-box;height:30px;padding:0 8px;border-radius:7px;border:.5px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-base);color:var(--dsw-alias-label-primary);-webkit-text-fill-color:var(--dsw-alias-label-primary);font:inherit;font-size:12px;outline:none}
.lk-keys{display:flex;align-items:center;gap:4px;margin-left:auto}
.lk-key{display:inline-flex;align-items:center;justify-content:center;min-width:24px;height:24px;padding:0 6px;border-radius:6px;border:.5px solid var(--dsw-alias-border-l2);background:var(--dsw-alias-bg-layer-1);box-shadow:0 1px 0 var(--dsw-alias-border-l1);font-size:12px;line-height:22px;color:var(--dsw-alias-label-primary);-webkit-text-fill-color:var(--dsw-alias-label-primary)}
.lk-hotkey-note{margin:0;font-size:11px;line-height:17px;color:var(--dsw-alias-label-secondary)}
.lk-meta{display:flex;flex-wrap:wrap;gap:14px;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-meta b{color:var(--dsw-alias-label-primary);font-weight:500;font-variant-numeric:tabular-nums}
.lk-steps{margin:0;padding-left:18px;display:flex;flex-direction:column;gap:8px;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-steps li{padding-left:2px}
.lk-setup{display:flex;flex-direction:column;gap:12px}
.lk-setup p{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-code{position:relative;display:flex;align-items:flex-start;gap:8px;padding:8px 9px;border-radius:8px;border:.5px solid var(--dsw-alias-border-l1);background:var(--dsw-alias-bg-layer-2)}
.lk-code code{flex:1;min-width:0;font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:11px;line-height:17px;color:var(--dsw-alias-label-primary);white-space:pre-wrap;word-break:break-all}
.lk-code .lk-btn{height:26px;line-height:24px;padding:0 8px;font-size:11px;flex:none}
.lk-path{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:10px;line-height:16px;color:var(--dsw-alias-label-secondary);word-break:break-all}
.lk-permission{display:flex;flex-direction:column;gap:10px;padding:12px;border-radius:10px;border:.5px solid var(--dsw-alias-state-warn-primary);background:var(--dsw-alias-bg-base)}
.lk-permission-title{font-size:13px;line-height:20px;font-weight:600;color:var(--dsw-alias-state-warn-primary)}
.lk-permission p{margin:0;font-size:12px;line-height:18px;color:var(--dsw-alias-label-secondary)}
.lk-permission-actions{display:flex;gap:8px;flex-wrap:wrap}
.lk-security{padding-top:9px;border-top:.5px solid var(--dsw-alias-border-l1)}
.lk-foot{margin:0;font-size:11px;line-height:17px;color:var(--dsw-alias-label-secondary)}
.lk-noscreen{display:inline-flex;align-items:center;gap:6px;margin-top:7px;font-size:11px;line-height:17px;color:var(--dsw-alias-label-secondary)}
.lk-noscreen b{color:var(--dsw-alias-state-success-primary);font-weight:500}
@media(max-width:980px){.lk-grid{grid-template-columns:minmax(0,1fr)}}
@media(max-width:700px){.lk-page{padding:16px}.lk-hero{flex-wrap:wrap}.lk-status{margin-left:58px}.lk-connect{align-items:stretch}.lk-field.port{width:100%}.lk-connect .lk-btn{width:100%}.lk-machines{flex-direction:column}.lk-switch{width:auto;height:20px;transform:rotate(90deg)}}
`;

    /**
     * Human-readable size for the clipboard limit line.
     * @param {unknown} bytes
     */
    function formatBytes(bytes) {
      const value = Number(bytes);
      if (!Number.isFinite(value) || value <= 0) return '—';
      const units = ['B', 'KB', 'MB', 'GB'];
      let size = value;
      let unit = 0;
      while (size >= 1024 && unit < units.length - 1) {
        size /= 1024;
        unit += 1;
      }
      return `${size >= 10 || unit === 0 ? Math.round(size) : size.toFixed(1)} ${units[unit]}`;
    }

    function fill(template, values) {
      return template.replace(/\{(\w+)\}/g, (match, key) =>
        Object.prototype.hasOwnProperty.call(values, key) ? String(values[key]) : match,
      );
    }

    function useLocaleTick(locale) {
      const [, setRevision] = useState(0);
      useEffect(() => locale.subscribe(() => setRevision((value) => value + 1)), [locale]);
    }

    function KvmGlyph(props) {
      const size = Number(props.size ?? 24);
      return h(
        'svg',
        {
          width: size,
          height: size,
          viewBox: '0 0 64 64',
          fill: 'none',
          'aria-hidden': true,
          style: { display: 'block', opacity: props.active === false ? 0.72 : 1 },
        },
        h('rect', {
          x: 4,
          y: 4,
          width: 56,
          height: 56,
          rx: 14,
          stroke: 'currentColor',
          strokeWidth: 2.4,
          opacity: 0.28,
        }),
        h('rect', {
          x: 14,
          y: 16,
          width: 27,
          height: 18,
          rx: 3,
          stroke: 'currentColor',
          strokeWidth: 3,
        }),
        h('path', {
          d: 'M19 42h17M27.5 34v8',
          stroke: 'currentColor',
          strokeWidth: 3,
          strokeLinecap: 'round',
        }),
        h('path', {
          d: 'M37 31l14 13-6.7 1-3.2 6.2z',
          fill: 'currentColor',
          stroke: 'currentColor',
          strokeWidth: 1.5,
          strokeLinejoin: 'round',
        }),
      );
    }

    /** @param {{ size?: number, active?: boolean }} props */
    function SidebarIcon(props) {
      return h(KvmGlyph, { size: props.size ?? 20, active: props.active !== false });
    }

    function loadSettings() {
      const defaults = { host: '', port: '7681', token: '', remember: true, edge: 'right', clipboard: true };
      try {
        const stored = JSON.parse(localStorage.getItem(STORAGE_KEY) ?? '{}');
        return {
          ...defaults,
          ...stored,
          port: String(stored.port ?? defaults.port),
          remember: stored.remember !== false,
          edge: ['right', 'left', 'both', 'off'].includes(stored.edge) ? stored.edge : 'right',
          clipboard: stored.clipboard !== false,
        };
      } catch {
        return defaults;
      }
    }

    /** @param {{ t: (key: string, params?: Record<string, string|number>) => string }} props */
    function KvmView(props) {
      const t = props.t;
      const [settings, setSettings] = useState(loadSettings);
      const [status, setStatus] = useState(null);
      const [actionError, setActionError] = useState('');
      const [notice, setNotice] = useState('');
      const [busy, setBusy] = useState('');
      const [showToken, setShowToken] = useState(false);
      const [copied, setCopied] = useState('');
      const [hostInfo, setHostInfo] = useState(null);
      const [scanning, setScanning] = useState(false);
      const [scanResults, setScanResults] = useState([]);

      const aliveRef = useRef(true);
      const tokenRef = useRef(null);
      const startRef = useRef(null);

      useEffect(() => {
        aliveRef.current = true;
        return () => {
          aliveRef.current = false;
        };
      }, []);

      useEffect(() => {
        try {
          localStorage.setItem(
            STORAGE_KEY,
            JSON.stringify({ ...settings, token: settings.remember ? settings.token : '' }),
          );
        } catch {
          // Storage can be unavailable in a hardened browser profile.
        }
      }, [settings]);

      useEffect(() => {
        setScanResults([]);
      }, [settings.port]);

      useEffect(() => {
        let cancelled = false;
        fetch(`${API}/info`)
          .then((response) => (response.ok ? response.json() : null))
          .then((payload) => {
            if (!cancelled && payload !== null) setHostInfo(payload);
          })
          .catch(() => {});
        return () => {
          cancelled = true;
        };
      }, []);

      useEffect(() => {
        if (notice === '') return undefined;
        const timer = setTimeout(() => setNotice(''), 2800);
        return () => clearTimeout(timer);
      }, [notice]);

      useEffect(() => {
        if (copied === '') return undefined;
        const timer = setTimeout(() => setCopied(''), 1600);
        return () => clearTimeout(timer);
      }, [copied]);

      const call = useCallback(async (route, body) => {
        const response = await fetch(`${API}${route}`, {
          method: body === undefined ? 'GET' : 'POST',
          headers: body === undefined ? { accept: 'application/json' } : { 'content-type': 'application/json' },
          body: body === undefined ? undefined : JSON.stringify(body),
        });
        const text = await response.text();
        let payload = {};
        try {
          payload = text === '' ? {} : JSON.parse(text);
        } catch {
          throw new Error(text.slice(0, 300) || `HTTP ${response.status}`);
        }
        if (!response.ok) throw new Error(payload?.error ?? `HTTP ${response.status}`);
        return payload;
      }, []);

      useEffect(() => {
        let cancelled = false;
        let timer;
        const tick = async () => {
          try {
            const payload = await call('/status');
            if (cancelled || !aliveRef.current) return;
            setStatus(payload);
            if (payload?.connected === true && payload?.target) {
              setSettings((current) => {
                const sameHost = current.host === payload.target.host;
                const samePort = String(current.port) === String(payload.target.port);
                const sameEdge = !payload.edgeMode || current.edge === payload.edgeMode;
                const sameClipboard = typeof payload.clipboard !== 'boolean' || current.clipboard === payload.clipboard;
                return sameHost && samePort && sameEdge && sameClipboard
                  ? current
                  : {
                      ...current,
                      host: payload.target.host,
                      port: String(payload.target.port),
                      edge: payload.edgeMode ?? current.edge,
                      clipboard: typeof payload.clipboard === 'boolean' ? payload.clipboard : current.clipboard,
                    };
              });
            }
          } catch {
            // The next tick retries; a transient poll failure should not erase UI state.
          } finally {
            if (!cancelled) timer = setTimeout(tick, 1000);
          }
        };
        tick();
        return () => {
          cancelled = true;
          clearTimeout(timer);
        };
      }, [call]);

      const connected = status?.connected === true;
      const active = status?.helper?.active === true;
      const running = status?.helper?.running === true;
      const trusted = status?.helper?.trusted === true;
      const tapInstalled = status?.helper?.tapInstalled === true;
      const needsPermission = connected && running && !tapInstalled;
      const locked = connected || busy !== '';

      const errors = useMemo(() => {
        const list = [actionError, status?.helper?.error, status?.connectionError, status?.inputError, status?.clipboardError, status?.clipboardSkipped];
        return [...new Set(list.filter((value) => typeof value === 'string' && value.trim() !== ''))];
      }, [actionError, status]);

      const friendlyError = useCallback(
        (message) => {
          if (/Token is required|token.*required/i.test(message)) return t('tokenRequired');
          if (/token.*reject|reject.*token|unauthorized/i.test(message)) return t('invalidToken');
          if (/Cannot reach|Network error|did not answer|ECONN|EHOSTUNREACH|ENETUNREACH/i.test(message)) {
            return t('unreachable');
          }
          return message;
        },
        [t],
      );

      const statusClass = active
        ? 'is-active'
        : needsPermission
          ? 'is-wait'
          : connected
            ? 'is-connected'
            : errors.length > 0
              ? 'is-error'
              : 'is-idle';
      const edgeOn = settings.edge !== 'off';
      const edgeHintKey =
        settings.edge === 'left'
          ? 'edgeHintLeft'
          : settings.edge === 'both'
            ? 'edgeHintBoth'
            : settings.edge === 'off'
              ? 'edgeHintOff'
              : 'edgeHintRight';
      const edgeHintText = t(edgeHintKey);
      const statusText = active
        ? t('statusActive')
        : needsPermission
          ? t('statusPermission')
          : connected
            ? edgeOn && !active
              ? t('waitingEdge')
              : t('statusConnected')
            : t('statusIdle');

      const scan = async () => {
        if (scanning || busy !== '' || connected) return;
        setScanning(true);
        setActionError('');
        setNotice('');
        setScanResults([]);
        try {
          const payload = await call('/scan', { port: Number(settings.port) });
          const found = Array.isArray(payload?.found) ? payload.found : [];
          setScanResults(found);
          if (found.length === 1) {
            setSettings((value) => ({ ...value, host: found[0].host }));
            setNotice(t('scanPicked').replace('{host}', found[0].host));
          } else if (found.length > 1) {
            setNotice(t('scanFound').replace('{n}', String(found.length)));
          } else {
            setActionError(t('scanEmpty'));
          }
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        } finally {
          setScanning(false);
        }
      };

      const start = async () => {
        if (busy !== '' || scanning) return;
        if (settings.token.trim().length < 6) {
          setShowToken(true);
          setActionError(t('tokenRequired'));
          tokenRef.current?.focus();
          return;
        }
        setBusy('starting');
        setActionError('');
        setNotice('');
        try {
          const payload = await call('/start', {
            host: settings.host.trim(),
            port: Number(settings.port),
            token: settings.token.trim(),
            edge: settings.edge,
            clipboard: settings.clipboard,
          });
          setStatus(payload);
          if (payload?.helper?.trusted !== true) setNotice(t('permissionNeeded'));
          else if (payload?.edgeMode !== 'off' && payload?.helper?.active !== true) setNotice(t('edgeReadyNotice'));
          else setNotice(t('takeOverStarted'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        } finally {
          setBusy('');
        }
      };

      startRef.current = start;
      useEffect(() => {
        if (autoConnectAttempted) return undefined;
        const timer = setTimeout(() => {
          if (autoConnectAttempted) return;
          if (!settings.host.trim() || settings.token.trim().length < 6 || settings.edge === 'off') return;
          autoConnectAttempted = true;
          startRef.current?.();
        }, 350);
        return () => clearTimeout(timer);
      }, []);

      const activate = async () => {
        if (busy !== '') return;
        setBusy('activating');
        setActionError('');
        setNotice('');
        try {
          const payload = await call('/activate', {});
          setStatus(payload);
          setNotice(payload?.helper?.active === true ? t('takeOverStarted') : t('permissionNeeded'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        } finally {
          setBusy('');
        }
      };

      const release = async () => {
        if (busy !== '') return;
        setBusy('releasing');
        setActionError('');
        setNotice('');
        try {
          // /return also disarms edge mode, which is what rescues a stuck pointer.
          const payload = await call('/return', {});
          setStatus(payload);
          setNotice(t('released'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        } finally {
          setBusy('');
        }
      };

      const disconnect = async () => {
        if (busy !== '') return;
        setBusy('disconnecting');
        setActionError('');
        setNotice('');
        try {
          const payload = await call('/disconnect', {});
          setStatus(payload);
          setNotice(t('disconnected'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        } finally {
          setBusy('');
        }
      };

      const openSettings = async (route) => {
        try {
          await call(route, {});
          setNotice(t('openSettings'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        }
      };

      const changeEdge = async (mode) => {
        if (!['right', 'left', 'both', 'off'].includes(mode)) return;
        setSettings((value) => ({ ...value, edge: mode }));
        if (!connected) return;
        setActionError('');
        try {
          const payload = await call('/edge', { mode });
          setStatus(payload);
          setNotice(t('edgeChanged'));
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        }
      };

      const changeClipboard = async (enabled) => {
        setSettings((value) => ({ ...value, clipboard: enabled }));
        if (!connected) return;
        setActionError('');
        try {
          const payload = await call('/clipboard', { enabled });
          setStatus(payload);
        } catch (cause) {
          setActionError(String(cause?.message ?? cause));
        }
      };

      const copy = async (value, key) => {
        try {
          await navigator.clipboard.writeText(value);
          setCopied(key);
        } catch {
          setActionError(t('clipboardError'));
        }
      };

      const command = `powershell -ExecutionPolicy Bypass -File .\\dsh-lan-kvm-agent.ps1 -Port ${settings.port}`;
      const addressText = useMemo(() => {
        const addresses = Array.isArray(hostInfo?.addresses) ? hostInfo.addresses : [];
        return addresses.length > 0 ? addresses.join(', ') : t('noAddress');
      }, [hostInfo, t]);

      const stateTitle = active
        ? t('windowsControl')
        : needsPermission
          ? t('permissionTitle')
          : connected
            ? edgeOn && !active
              ? t('waitingEdge')
              : t('macControl')
            : t('statusIdle');
      const stateText = active
        ? edgeOn
          ? t('activeHintEdge')
          : t('activeHint')
        : needsPermission
          ? t('permissionHint')
          : connected
            ? edgeOn && !active
              ? edgeHintText
              : tapInstalled
                ? t('readyHint')
                : running
                  ? t('permissionHint')
                  : t('notRunningHint')
            : t('notConnectedHint');

      return h(
        'div',
        { className: 'lk-page' },
        h('style', { dangerouslySetInnerHTML: { __html: CSS } }),
        h(
          'div',
          { className: 'lk-inner' },
          h(
            'div',
            { className: 'lk-hero' },
            h('div', { className: 'lk-mark' }, h(KvmGlyph, { size: 28, active: true })),
            h(
              'div',
              { className: 'lk-heading' },
              h('h1', { className: 'lk-title' }, t('title')),
              h('p', { className: 'lk-sub' }, t('subtitle')),
              h('div', { className: 'lk-noscreen' }, h('b', null, '●'), t('noScreen')),
            ),
            h(
              'span',
              { className: `lk-status ${statusClass}`, role: 'status' },
              h('span', { className: 'lk-dot' }),
              statusText,
              connected && status?.latencyMs !== null && status?.latencyMs !== undefined
                ? ` · ${t('latency')} ${status.latencyMs} ms`
                : '',
            ),
          ),
          h(
            'form',
            {
              className: 'lk-connect',
              onSubmit: (event) => {
                event.preventDefault();
                if (connected) return;
                start();
              },
            },
            h(
              'div',
              { className: 'lk-field grow' },
              h('label', { htmlFor: 'lk-host' }, t('address')),
              h('input', {
                id: 'lk-host',
                className: 'lk-input',
                value: settings.host,
                placeholder: t('addressPlaceholder'),
                disabled: locked,
                autoComplete: 'off',
                spellCheck: false,
                onChange: (event) => setSettings((value) => ({ ...value, host: event.target.value })),
              }),
            ),
            h(
              'div',
              { className: 'lk-field port' },
              h('label', { htmlFor: 'lk-port' }, t('port')),
              h('input', {
                id: 'lk-port',
                className: 'lk-input',
                value: settings.port,
                inputMode: 'numeric',
                disabled: locked,
                onChange: (event) =>
                  setSettings((value) => ({ ...value, port: event.target.value.replace(/[^0-9]/g, '') })),
              }),
            ),
            h(
              'div',
              { className: 'lk-field token' },
              h('label', { htmlFor: 'lk-token' }, t('token')),
              h(
                'div',
                { className: 'lk-token-wrap' },
                h('input', {
                  id: 'lk-token',
                  ref: tokenRef,
                  className: 'lk-input',
                  type: showToken ? 'text' : 'password',
                  value: settings.token,
                  placeholder: t('tokenPlaceholder'),
                  disabled: locked,
                  autoComplete: 'off',
                  spellCheck: false,
                  onChange: (event) => setSettings((value) => ({ ...value, token: event.target.value })),
                }),
                h(
                  'button',
                  {
                    type: 'button',
                    className: 'lk-eye',
                    onClick: () => setShowToken((value) => !value),
                    'aria-label': showToken ? t('hide') : t('show'),
                  },
                  showToken ? t('hide') : t('show'),
                ),
                h('span', { className: 'lk-hint' }, t('tokenHelp')),
              ),
            ),
            h(
              'label',
              { className: 'lk-remember' },
              h('input', {
                type: 'checkbox',
                checked: settings.remember,
                disabled: locked,
                onChange: (event) => setSettings((value) => ({ ...value, remember: event.target.checked })),
              }),
              t('remember'),
            ),
            !connected
              ? h(
                  'button',
                  { type: 'submit', className: 'lk-btn primary', disabled: busy !== '' || scanning },
                  busy === 'starting'
                    ? t('preparing')
                    : status?.helper?.running
                      ? t('connecting')
                      : settings.edge !== 'off'
                        ? t('connectEdge')
                        : t('connect'),
                )
              : h(
                  'button',
                  { type: 'button', className: 'lk-btn danger', onClick: disconnect, disabled: busy !== '' },
                  busy === 'disconnecting' ? t('disconnecting') : t('disconnect'),
                ),
          ),
          !connected
            ? h(
                'div',
                { className: 'lk-scan' },
                h(
                  'button',
                  {
                    type: 'button',
                    className: 'lk-btn',
                    onClick: scan,
                    disabled: scanning || busy !== '',
                  },
                  scanning ? t('scanning') : t('scan'),
                ),
                h('span', { className: 'lk-scan-hint' }, t('scanHint')),
              )
            : null,
          !connected
            ? h('p', { className: 'lk-channel-hint' }, t('channelHint'))
            : null,
          !connected && scanResults.length > 0
            ? h(
                'div',
                { className: 'lk-found' },
                scanResults.map((device) =>
                  h(
                    'button',
                    {
                      key: device.host,
                      type: 'button',
                      className: 'lk-found-row',
                      onClick: () => {
                        setSettings((value) => ({ ...value, host: device.host }));
                        setNotice(t('scanPicked').replace('{host}', device.host));
                      },
                    },
                    h('b', null, device.host),
                    h(
                      'span',
                      null,
                      device.legacy
                        ? t('legacyAgent')
                        : device.machine
                          ? device.machine
                          : t('legacyAgent'),
                    ),
                  ),
                ),
              )
            : null,
          errors.length > 0
            ? h(
                'div',
                { className: 'lk-alert', role: 'alert' },
                errors.map((message, index) =>
                  h('div', { key: `${index}-${message}` }, friendlyError(message)),
                ),
              )
            : null,
          notice !== ''
            ? h('p', { className: 'lk-notice', role: 'status' }, notice)
            : null,
          h(
            'div',
            { className: 'lk-grid' },
            h(
              'div',
              { className: 'lk-card' },
              h('div', { className: 'lk-card-head' }, h('div', { className: 'lk-card-title' }, t('macControl'), ' ↔ ', t('windowsControl'))),
              h(
                'div',
                { className: 'lk-card-body lk-control' },
                h(
                  'div',
                  { className: 'lk-machines' },
                  h(
                    'div',
                    { className: `lk-machine ${active ? '' : 'is-active'}` },
                    h(
                      'div',
                      { className: 'lk-machine-top' },
                      h('span', { className: 'lk-machine-dot' }),
                      active ? t('statusConnected') : t('macControl'),
                    ),
                    h('div', { className: 'lk-machine-name' }, t('mac')),
                    h('div', { className: 'lk-machine-sub' }, hostInfo?.hostname ?? t('hostname')),
                  ),
                  h('div', { className: 'lk-switch', 'aria-hidden': true }, '⇄'),
                  h(
                    'div',
                    { className: `lk-machine ${active ? 'is-active' : ''}` },
                    h(
                      'div',
                      { className: 'lk-machine-top' },
                      h('span', { className: 'lk-machine-dot' }),
                      active ? t('statusActive') : connected ? t('statusConnected') : t('statusIdle'),
                    ),
                    h('div', { className: 'lk-machine-name' }, t('windows')),
                    h(
                      'div',
                      { className: 'lk-machine-sub' },
                      connected && status?.target
                        ? `${status.target.host}:${status.target.port}`
                        : t('notConnectedHint'),
                    ),
                  ),
                ),
                h('h2', { className: 'lk-state-title' }, stateTitle),
                h('p', { className: 'lk-state-text' }, stateText),
                h(
                  'div',
                  { className: 'lk-actions' },
                  connected
                    ? active
                      ? h(
                          'button',
                          {
                            type: 'button',
                            className: 'lk-btn primary big',
                            onClick: release,
                            disabled: busy !== '',
                          },
                          busy === 'releasing' ? t('releasing') : t('release'),
                        )
                      : edgeOn
                        ? h(
                            'button',
                            {
                              type: 'button',
                              className: 'lk-btn subtle',
                              onClick: activate,
                              disabled: busy !== '',
                            },
                            busy === 'activating' ? t('connecting') : t('manualTakeover'),
                          )
                        : h(
                            'button',
                            {
                              type: 'button',
                              className: 'lk-btn primary big',
                              onClick: activate,
                              disabled: busy !== '',
                            },
                            busy === 'activating' ? t('connecting') : t('reconnect'),
                          )
                    : null,
                  h(
                    'button',
                    {
                      type: 'button',
                      className: 'lk-btn',
                      onClick: release,
                      disabled: busy !== '' || !running,
                      title: t('returnHint'),
                    },
                    busy === 'releasing' ? t('returning') : t('returnNow'),
                  ),
                  h(
                    'button',
                    {
                      type: 'button',
                      className: 'lk-btn subtle',
                      onClick: () => openSettings('/open-accessibility'),
                    },
                    t('openAccessibility'),
                  ),
                ),
                h(
                  'div',
                  { className: 'lk-edge' },
                  h('label', { className: 'lk-label', htmlFor: 'lk-edge' }, t('edgeMode')),
                  h(
                    'select',
                    {
                      id: 'lk-edge',
                      className: 'lk-select',
                      value: settings.edge,
                      disabled: active || busy !== '',
                      onChange: (event) => changeEdge(event.target.value),
                    },
                    h('option', { value: 'right' }, t('edgeRight')),
                    h('option', { value: 'left' }, t('edgeLeft')),
                    h('option', { value: 'both' }, t('edgeBoth')),
                    h('option', { value: 'off' }, t('edgeOff')),
                  ),
                ),
                h(
                  'label',
                  { className: 'lk-remember' },
                  h('input', {
                    type: 'checkbox',
                    checked: settings.clipboard,
                    disabled: busy !== '',
                    onChange: (event) => changeClipboard(event.target.checked),
                  }),
                  t('clipboardSync'),
                  h(
                    'span',
                    { className: 'lk-hint' },
                    settings.clipboard ? t('clipboardOn') : t('clipboardOff'),
                  ),
                ),
                h('p', { className: 'lk-hotkey-note' }, t('clipboardHint')),
                h(
                  'p',
                  { className: 'lk-hotkey-note' },
                  t('clipboardLimits')
                    .replace('{text}', formatBytes(status?.clipboardTextLimit))
                    .replace('{image}', formatBytes(status?.clipboardImageLimit))
                    .replace('{files}', formatBytes(status?.clipboardFileLimit)),
                ),
                h('p', { className: 'lk-hotkey-note' }, edgeHintText),
                connected && edgeOn && status?.edgeArmed
                  ? h(
                      'p',
                      { className: 'lk-alert warn' },
                      t('edgeStuck').replace('{hotkey}', '⌃⌥⌘K'),
                    )
                  : null,
                h(
                  'div',
                  { className: 'lk-hotkey-box' },
                  h('span', { className: 'lk-hotkey-label' }, t('hotkey')),
                  h(
                    'span',
                    { className: 'lk-keys' },
                    h('kbd', { className: 'lk-key' }, '⌃'),
                    h('kbd', { className: 'lk-key' }, '⌥'),
                    h('kbd', { className: 'lk-key' }, '⌘'),
                    h('kbd', { className: 'lk-key' }, 'K'),
                  ),
                ),
                h('p', { className: 'lk-hotkey-note' }, t('hotkeyNote')),
                h('p', { className: 'lk-hotkey-note' }, t('startHint')),
                busy === 'starting' ? h('p', { className: 'lk-hotkey-note' }, t('helperCompile')) : null,
                h(
                  'div',
                  { className: 'lk-meta' },
                  h('span', null, t('helper'), ' ', h('b', null, !running ? t('helperStopped') : tapInstalled ? t('helperReady') : trusted ? t('helperRunning') : t('helperWait'))),
                  h('span', null, t('latency'), ' ', h('b', null, status?.latencyMs === null || status?.latencyMs === undefined ? '—' : `${status.latencyMs} ms`)),
                  connected
                    ? h(
                        'span',
                        null,
                        t('clipboardSync'),
                        ' ',
                        h('b', null, status?.clipboard ? t('clipboardOn') : t('clipboardOff')),
                      )
                    : null,
                  connected
                    ? h(
                        'span',
                        null,
                        t('channel'),
                        ' ',
                        h('b', null, status?.stream ? t('channelStream') : t('channelHttp')),
                      )
                    : null,
                  connected ? h('span', null, t('connectedTo').replace('{host}', status?.target?.host ?? '')) : null,
                ),
                needsPermission
                  ? h(
                      'div',
                      { className: 'lk-permission' },
                      h('div', { className: 'lk-permission-title' }, t('permissionTitle')),
                      h('p', null, t('permissionBody')),
                      h(
                        'p',
                        { className: 'lk-path' },
                        `${t('helperPath')}: ${status?.helper?.path ?? hostInfo?.helperPath ?? ''}`,
                      ),
                      h(
                        'div',
                        { className: 'lk-permission-actions' },
                        h(
                          'button',
                          {
                            type: 'button',
                            className: 'lk-btn primary',
                            onClick: () => openSettings('/open-accessibility'),
                          },
                          t('openAccessibility'),
                        ),
                        h(
                          'button',
                          {
                            type: 'button',
                            className: 'lk-btn',
                            onClick: () => openSettings('/open-input-monitoring'),
                          },
                          t('openInputMonitoring'),
                        ),
                        h(
                          'button',
                          {
                            type: 'button',
                            className: 'lk-btn subtle',
                            onClick: () => openSettings('/reveal-helper'),
                          },
                          t('revealHelper'),
                        ),
                      ),
                      h('p', null, t('permissionAfter')),
                    )
                  : null,
                running && trusted && tapInstalled
                  ? h('p', { className: 'lk-notice' }, t('permissionReady'))
                  : null,
              ),
            ),
            h(
              'div',
              { className: 'lk-card' },
              h('div', { className: 'lk-card-head' }, h('div', { className: 'lk-card-title' }, t('setup'))),
              h(
                'div',
                { className: 'lk-card-body lk-setup' },
                h('p', null, t('setupIntro')),
                h(
                  'ol',
                  { className: 'lk-steps' },
                  h('li', null, t('step1')),
                  h('li', null, t('step2')),
                  h('li', null, t('step3')),
                ),
                h(
                  'a',
                  {
                    className: 'lk-btn primary',
                    href: `${API}/agent.ps1`,
                    download: 'dsh-lan-kvm-agent.ps1',
                  },
                  t('download'),
                ),
                h('div', { className: 'lk-label' }, t('command')),
                h(
                  'div',
                  { className: 'lk-code' },
                  h('code', null, command),
                  h(
                    'button',
                    {
                      type: 'button',
                      className: 'lk-btn',
                      onClick: () => copy(command, 'command'),
                    },
                    copied === 'command' ? t('copied') : t('copy'),
                  ),
                ),
                h(
                  'p',
                  null,
                  t('firewall')
                    .replace('{port}', String(settings.port))
                    .replace('{stream}', String(Number(settings.port) + 1)),
                ),
                h(
                  'div',
                  { className: 'lk-meta' },
                  h('span', null, t('hostname')),
                  h('b', null, addressText),
                ),
                h('p', { className: 'lk-security' }, t('security')),
                h('p', null, t('downloadHint')),
              ),
            ),
          ),
          h('p', { className: 'lk-foot' }, t('noScreen')),
        ),
      );
    }

    function apply(ctx) {
      const locale = ctx.get('locale');
      const slots = ctx.get('slots');
      if (locale === undefined || slots === undefined) {
        console.error('dsh-lan-kvm: locale or slots service is unavailable');
        return;
      }
      ctx.effect(() => locale.register(NS, { zh: ZH, en: EN }), 'dsh-lan-kvm: dictionaries');
      const bound = locale.bind(NS);

      function KvmPanel() {
        useLocaleTick(locale);
        return h(KvmView, { t: bound });
      }

      slots.inject('sidebar.panellist', () =>
        slots.register(
          {
            name: 'sidebar.panellist',
            id: 'lan-kvm',
            order: 12,
            label: () => bound('nav'),
            locale: NS,
          },
          SidebarIcon,
        ),
      );
      slots.inject('main', () =>
        slots.register(
          {
            name: 'main',
            key: 'lan-kvm',
          },
          KvmPanel,
        ),
      );
    }

    return {
      inject: ['slots', 'locale'],
      apply,
      NS,
    };
  },
});
