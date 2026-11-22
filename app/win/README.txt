LanKvm - Windows receiver
=========================

WHAT THIS IS

  Lets your Mac use one keyboard and mouse to control this PC, when the two
  are on the same network. Your Windows monitor stays right where it is: this
  program only carries keyboard, mouse and clipboard, never video.


START IT

  Once per installation, run install.bat as administrator to configure the private LAN firewall.
  Then double-click run-lankvm.bat normally from Explorer.

  A small window opens showing an address and a token. Keep it open while you
  use the remote control.


CONNECT THE MAC

  In the LanKvm app on the Mac:

    menu bar icon  ->  Settings...  ->  enter the address and token  ->
    Save & Connect

  The address is the IPv4 one, for example 192.168.1.20.
  The port is 7681.


TAKE CONTROL BACK HERE

  Any of these returns you to this PC:

    - Click "Stop LanKvm" in the window
    - Close the window
    - Press Control+Option+Command+K on the Mac keyboard
    - Push the mouse back across the screen edge toward the Mac


THE WINDOW

  Stop LanKvm              stop being controlled and release the ports
  Disable pointer hiding   stop Windows hiding the pointer while typing
  Copy token               copy the token to the clipboard
  Start with Windows       launch LanKvm automatically at login


IF THE MAC CANNOT CONNECT

  Windows Firewall must allow inbound TCP 7681 and 7682.
  Run install.bat as administrator on a trusted private network to add the rule. To add it by hand, in an
  Administrator PowerShell:

    New-NetFirewallRule -DisplayName 'LanKvm' -Direction Inbound ^
      -Protocol TCP -LocalPort 7681,7682 -Action Allow ^
      -Profile Private -RemoteAddress LocalSubnet


COMMAND LINE (OPTIONAL)

  LanKvm.exe [-Port 7681] [-Token YOURTOKEN] [-Headless]

  -Port      change the listening port
  -Token     use a fixed token instead of the generated one
  -Headless  run without the window, for an unattended machine

  The token is remembered in %APPDATA%\LanKvm\token.txt, so a restart keeps
  the same token and the Mac does not need reconfiguring.


IF LanKvm.exe WILL NOT START

  install.bat builds the program from LanKvm.cs using the C# compiler that
  ships with Windows. Run it once with an internet connection not required.


SECURITY

  Every request must present the token. The port is opened on the local
  network only. Do not expose port 7681 or 7682 to the public internet.

  LanKvm runs with your user rights, so it cannot operate UAC elevation
  prompts. That is a Windows security boundary, not a bug.