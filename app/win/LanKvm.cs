using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;

[assembly: System.Reflection.AssemblyVersion("1.3.0.0")]
[assembly: System.Reflection.AssemblyFileVersion("1.3.0.0")]

namespace LanKvm
{
    public static class Native
    {
        public const uint MOUSEEVENTF_MOVE = 0x0001;
        public const uint MOUSEEVENTF_MOVE_NOCOALESCE = 0x2000;
        public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
        public const uint MOUSEEVENTF_LEFTUP = 0x0004;
        public const uint MOUSEEVENTF_RIGHTDOWN = 0x0008;
        public const uint MOUSEEVENTF_RIGHTUP = 0x0010;
        public const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020;
        public const uint MOUSEEVENTF_MIDDLEUP = 0x0040;
        public const uint MOUSEEVENTF_WHEEL = 0x0800;
        public const uint MOUSEEVENTF_HWHEEL = 0x1000;
        public const uint KEYEVENTF_EXTENDEDKEY = 0x0001;
        public const uint KEYEVENTF_KEYUP = 0x0002;
        public const uint KEYEVENTF_UNICODE = 0x0004;
        public const uint KEYEVENTF_SCANCODE = 0x0008;
        public const uint INPUT_KEYBOARD = 1;

        [DllImport("user32.dll")]
        public static extern IntPtr GetForegroundWindow();

        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint processId);

        internal static bool IsWarcraftProcess(string name)
        {
            return Array.Exists(new string[] { "Wow", "WowClassic", "WowClassicT", "WowClassicB",
                "WowT", "WowB", "Wow-64", "WowClassic-64" },
                delegate(string candidate) { return String.Equals(candidate, name, StringComparison.OrdinalIgnoreCase); });
        }

        public static bool IsWarcraftWindow(IntPtr window)
        {
            uint pid;
            if (window == IntPtr.Zero || GetWindowThreadProcessId(window, out pid) == 0) return false;
            try
            {
                using (System.Diagnostics.Process process = System.Diagnostics.Process.GetProcessById((int)pid))
                    return IsWarcraftProcess(process.ProcessName);
            }
            catch (ArgumentException) { return false; }
            catch (InvalidOperationException) { return false; }
            catch (System.ComponentModel.Win32Exception) { return false; }
        }

        // Re-evaluate the monitor layout on entry: a Windows logon can report a
        // provisional resolution before the monitor is fully awake.
        internal static Point EntryPoint(Rectangle desktop, Rectangle[] screens, string side, double ratio)
        {
            int aimX = side == "right" ? desktop.Left : desktop.Right - 1;
            int aimY = desktop.Top + (int)Math.Round(Math.Max(0, Math.Min(1,ratio)) * (desktop.Height - 1));
            long best = Int64.MaxValue;
            Point point = new Point(aimX,aimY);
            foreach (Rectangle screen in screens)
            {
                int x = Math.Max(screen.Left,Math.Min(screen.Right-1,aimX));
                int y = Math.Max(screen.Top,Math.Min(screen.Bottom-1,aimY));
                long dx = (long)x - aimX, dy = (long)y - aimY;
                long distance = dx*dx + dy*dy;
                if (distance >= best) continue;
                best = distance;
                int inset = Math.Min(12, (screen.Width - 1) / 2);
                point = new Point(Math.Max(screen.Left+inset,Math.Min(screen.Right-1-inset,x)),y);
            }
            return point;
        }

        public static void EnterDesktop(string side, double ratio)
        {
            Rectangle desktop = SystemInformation.VirtualScreen;
            Rectangle[] screens = Array.ConvertAll(Screen.AllScreens,delegate(Screen s){return s.Bounds;});
            if (screens.Length == 0 || desktop.Width < 1 || desktop.Height < 1)
                throw new InvalidOperationException("Windows display is not ready");
            Point point = EntryPoint(desktop,screens,side,ratio);
            INPUT[] inputs = new INPUT[1];
            inputs[0].U.mi.dx = (int)(((long)(point.X-desktop.Left)*65536 + 32768)/desktop.Width);
            inputs[0].U.mi.dy = (int)(((long)(point.Y-desktop.Top)*65536 + 32768)/desktop.Height);
            inputs[0].U.mi.dwFlags = MOUSEEVENTF_MOVE | 0x8000 | 0x4000; // ABSOLUTE | VIRTUALDESK
            if (SendInput(1,inputs,Marshal.SizeOf(typeof(INPUT))) != 1)
                throw new InvalidOperationException("Windows desktop cannot receive the pointer yet");
        }

        public static void MoveRelative(int dx, int dy)
        {
            INPUT[] inputs = new INPUT[1];
            inputs[0].U.mi.dx = dx;
            inputs[0].U.mi.dy = dy;
            inputs[0].U.mi.dwFlags = MOUSEEVENTF_MOVE | MOUSEEVENTF_MOVE_NOCOALESCE;
            if (SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT))) != 1)
                throw new InvalidOperationException("Windows could not apply mouse movement");
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct MOUSEINPUT
        {
            public int dx;
            public int dy;
            public uint mouseData;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct KEYBDINPUT
        {
            public ushort wVk;
            public ushort wScan;
            public uint dwFlags;
            public uint time;
            public IntPtr dwExtraInfo;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct HARDWAREINPUT
        {
            public uint uMsg;
            public ushort wParamL;
            public ushort wParamH;
        }

        [StructLayout(LayoutKind.Explicit)]
        public struct InputUnion
        {
            [FieldOffset(0)] public MOUSEINPUT mi;
            [FieldOffset(0)] public KEYBDINPUT ki;
            [FieldOffset(0)] public HARDWAREINPUT hi;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct INPUT
        {
            public uint type;
            public InputUnion U;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X;
            public int Y;
        }

        [DllImport("user32.dll")]
        public static extern bool SetProcessDPIAware();

        [DllImport("user32.dll")]
        public static extern bool GetCursorPos(out POINT point);

        [DllImport("user32.dll")]
        public static extern uint GetClipboardSequenceNumber();

        [DllImport("user32.dll")]
        public static extern bool OpenClipboard(IntPtr owner);

        [DllImport("user32.dll")]
        public static extern bool CloseClipboard();

        [DllImport("user32.dll")]
        public static extern bool EmptyClipboard();

        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        public static extern uint RegisterClipboardFormat(string format);

        [DllImport("user32.dll")]
        public static extern IntPtr GetClipboardData(uint format);

        [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
        public static extern uint DragQueryFile(IntPtr drop, uint index, StringBuilder file, uint length);

        [DllImport("user32.dll")]
        public static extern IntPtr SetClipboardData(uint format, IntPtr memory);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalAlloc(uint flags, UIntPtr bytes);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalLock(IntPtr memory);

        [DllImport("kernel32.dll")]
        public static extern bool GlobalUnlock(IntPtr memory);

        [DllImport("kernel32.dll")]
        public static extern IntPtr GlobalFree(IntPtr memory);

        [DllImport("kernel32.dll")]
        public static extern UIntPtr GlobalSize(IntPtr memory);

        [DllImport("gdi32.dll")]
        public static extern bool DeleteObject(IntPtr handle);

        public const uint CF_BITMAP = 2;
        public const uint CF_DIB = 8;
        public const uint CF_DIBV5 = 17;
        public const uint CF_UNICODETEXT = 13;
        public const uint CF_HDROP = 15;
        public const uint GMEM_MOVEABLE = 0x0002;
        /// <summary>DROPFILES header, as stored in a CF_HDROP clipboard block.</summary>
        [StructLayout(LayoutKind.Sequential)]
        public struct DROPFILES
        {
            public uint pFiles;
            public int x;
            public int y;
            public int fNC;
            public int fWide;
        }

        [DllImport("user32.dll")]
        public static extern bool SetCursorPos(int x, int y);

        [DllImport("user32.dll")]
        public static extern void mouse_event(uint flags, uint dx, uint dy, int data, UIntPtr extraInfo);

        [DllImport("user32.dll")]
        public static extern uint MapVirtualKey(uint code, uint mapType);

        [DllImport("user32.dll", SetLastError = true)]
        public static extern uint SendInput(uint count, INPUT[] inputs, int size);

        public const uint SPI_SETMOUSEVANISH = 0x1021;
        public const uint SPIF_UPDATEINIFILE = 0x01;
        public const uint SPIF_SENDCHANGE = 0x02;

        [DllImport("user32.dll", SetLastError = true)]
        public static extern bool SystemParametersInfo(uint action, uint param, ref int value, uint winIni);

        /// <summary>
        /// Windows hides the pointer while typing by default. Injected keystrokes
        /// count as typing, so the cursor can stay invisible on the remote
        /// desktop. Exposed to the user instead of changed silently.
        /// </summary>
        public static bool SetPointerVanish(bool enabled)
        {
            int value = enabled ? 1 : 0;
            return SystemParametersInfo(SPI_SETMOUSEVANISH, 0, ref value, SPIF_UPDATEINIFILE | SPIF_SENDCHANGE);
        }

        public static void SendUnicodeChar(char value)
        {
            INPUT[] inputs = new INPUT[1];
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].U.ki.wVk = 0;
            inputs[0].U.ki.wScan = (ushort)value;
            inputs[0].U.ki.dwFlags = KEYEVENTF_UNICODE;
            SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));

            inputs[0].U.ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;
            SendInput(1, inputs, Marshal.SizeOf(typeof(INPUT)));
        }
    }

    public sealed class AgentServer
    {
        private readonly int _port;
        private readonly int _inputPort;
        private readonly string _token;
        private volatile bool _running;
        private TcpListener _listener;
        private long _inputEvents;
        private long _clipboardOps;
        private long _clipboardPolls;
        private volatile bool _backgroundStarted;
        private readonly object _inputLock = new object();
        private readonly HashSet<int> _heldKeys = new HashSet<int>();
        private readonly HashSet<string> _heldButtons = new HashSet<string>();
        private TcpClient _ownerStream;
        private TcpListener _inputListener;
        private string _owner;
        private readonly Queue<string> _endedSessions = new Queue<string>();
        private int _lastInputTick;
        private volatile int _lastMotionTick = unchecked(Environment.TickCount - 1000);
        private bool _leasedInput;
        private IntPtr _gameWindow;
        private System.Threading.Timer _leaseTimer;
        private static readonly JavaScriptSerializer Serializer = CreateSerializer();

        private static JavaScriptSerializer CreateSerializer()
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            // Clipboard images travel as multi-megabyte base64 in one JSON
            // document, far past the 2 MB default.
            serializer.MaxJsonLength = Int32.MaxValue;
            serializer.RecursionLimit = 64;
            return serializer;
        }

        public int Port { get { return _port; } }
        public int InputPort { get { return _inputPort; } }
        public string Token { get { return _token; } }
        public bool IsRunning { get { return _running; } }
        public long InputEvents { get { return Interlocked.Read(ref _inputEvents); } }
        public long ClipboardOps { get { return Interlocked.Read(ref _clipboardOps); } }
        public long ClipboardPolls { get { return Interlocked.Read(ref _clipboardPolls); } }

        /// <summary>Turn off the "hide pointer while typing" behaviour.</summary>
        public bool DisablePointerVanish()
        {
            try { return Native.SetPointerVanish(false); }
            catch { return false; }
        }

        public AgentServer(int port, string token)
        {
            _port = port;
            _inputPort = port < 65535 ? port + 1 : 0;
            _token = token;
            try { Native.SetProcessDPIAware(); }
            catch { }
        }

        public void Run()
        {
            _listener = new TcpListener(IPAddress.Any, _port);
            _listener.Start();
            _running = true;
            _leaseTimer = new System.Threading.Timer(ExpireInput, null, 1000, 1000);
            Console.WriteLine("DSH LAN KVM agent listening on TCP " + _port);
            if (_inputPort > 0)
            {
                Thread inputThread = new Thread(InputListenerLoop);
                inputThread.IsBackground = true;
                inputThread.Start();
            }
            AcceptLoop();
        }

        /// <summary>
        /// Start listening without blocking, so a foreground window can own the
        /// main thread and stay closable from the Windows desktop.
        /// </summary>
        public void StartInBackground()
        {
            if (_backgroundStarted) return;
            _backgroundStarted = true;
            _listener = new TcpListener(IPAddress.Any, _port);
            _listener.Start();
            _running = true;
            _leaseTimer = new System.Threading.Timer(ExpireInput, null, 1000, 1000);
            Thread acceptThread = new Thread(AcceptLoop);
            acceptThread.IsBackground = true;
            acceptThread.Start();
            if (_inputPort > 0)
            {
                Thread inputThread = new Thread(InputListenerLoop);
                inputThread.IsBackground = true;
                inputThread.Start();
            }
        }

        private void AcceptLoop()
        {
            while (_running)
            {
                TcpClient client = null;
                try
                {
                    client = _listener.AcceptTcpClient();
                }
                catch (SocketException)
                {
                    if (!_running) break;
                    throw;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                ThreadPool.QueueUserWorkItem(HandleClient, client);
            }
        }

        private void InputListenerLoop()
        {
            TcpListener listener = null;
            try
            {
                lock (_inputLock)
                {
                    if (!_running) return;
                    listener = new TcpListener(IPAddress.Any, _inputPort);
                    listener.Start();
                    _inputListener = listener;
                }
                Console.WriteLine("DSH LAN KVM input stream listening on TCP " + _inputPort);
                while (_running)
                {
                    TcpClient client = listener.AcceptTcpClient();
                    ThreadPool.QueueUserWorkItem(HandleInputClient, client);
                }
            }
            catch (Exception error)
            {
                if (_running) Console.Error.WriteLine("input listener failed: " + error.Message);
            }
            finally
            {
                try { if (listener != null) listener.Stop(); } catch { }
            }
        }

        private void HandleInputClient(object state)
        {
            TcpClient client = (TcpClient)state;
            try
            {
                client.NoDelay = true;
                client.ReceiveTimeout = 0;
                client.SendTimeout = 15000;
                NetworkStream stream = client.GetStream();
                StreamReader reader = new StreamReader(stream, Encoding.UTF8, false, 4096, true);
                StreamWriter writer = new StreamWriter(stream, new UTF8Encoding(false), 4096, true);
                writer.NewLine = "\n";
                writer.AutoFlush = true;

                string handshake = reader.ReadLine();
                if (handshake == null || !handshake.StartsWith("TOKEN ", StringComparison.Ordinal))
                {
                    writer.WriteLine("{\"ok\":false,\"error\":\"unauthorized\"}");
                    return;
                }
                string supplied = handshake.Substring(6).Trim();
                if (!String.Equals(supplied, _token, StringComparison.Ordinal))
                {
                    writer.WriteLine("{\"ok\":false,\"error\":\"unauthorized\"}");
                    return;
                }

                writer.WriteLine("{\"ok\":true,\"stream\":1}");
                string line;
                while ((line = reader.ReadLine()) != null)
                {
                    if (line.Length == 0) continue;
                    try
                    {
                        if (ApplyInput(line, client, client)) Interlocked.Increment(ref _inputEvents);
                        writer.WriteLine(CursorJson());
                    }
                    catch (Exception error)
                    {
                        writer.WriteLine("{\"ok\":false,\"error\":" + Quote(error.Message) + "}");
                    }
                }
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("input stream failed: " + error.Message);
            }
            finally
            {
                lock (_inputLock)
                {
                    if (Object.ReferenceEquals(_ownerStream, client)) ReleaseHeldInput();
                }
                try { client.Close(); } catch { }
            }
        }

        public void Stop()
        {
            lock (_inputLock)
            {
                _running = false;
                if (_leaseTimer != null) _leaseTimer.Dispose();
                if (_inputListener != null) _inputListener.Stop();
                TcpClient stream = _ownerStream;
                ReleaseHeldInput();
                if (stream != null) stream.Close();
            }
            try
            {
                if (_listener != null) _listener.Stop();
            }
            catch { }
        }

        private void HandleClient(object state)
        {
            TcpClient client = (TcpClient)state;
            NetworkStream stream = null;
            try
            {
                client.NoDelay = true;
                client.ReceiveTimeout = 30000;
                client.SendTimeout = 60000;
                stream = client.GetStream();

                // Read with bulk copies: a clipboard image can be tens of
                // megabytes, and per-byte List<byte> adds would be quadratic.
                MemoryStream received = new MemoryStream();
                int headerEnd = -1;
                byte[] scratch = new byte[64 * 1024];
                while (received.Length < 64 * 1024)
                {
                    int read = stream.Read(scratch, 0, scratch.Length);
                    if (read <= 0) break;
                    received.Write(scratch, 0, read);
                    headerEnd = FindHeaderEnd(received.GetBuffer(), (int)received.Length);
                    if (headerEnd >= 0) break;
                }
                if (headerEnd < 0)
                {
                    WriteResponse(stream, 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("bad request"));
                    return;
                }

                string headerText = Encoding.ASCII.GetString(received.GetBuffer(), 0, headerEnd);
                string[] lines = headerText.Split(new string[] { "\r\n" }, StringSplitOptions.None);
                string[] requestLine = lines[0].Split(' ');
                if (requestLine.Length < 2)
                {
                    WriteResponse(stream, 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("bad request"));
                    return;
                }

                string method = requestLine[0].ToUpperInvariant();
                string rawUrl = requestLine[1];
                int contentLength = 0;
                string headerToken = null;

                for (int index = 1; index < lines.Length; index++)
                {
                    int colon = lines[index].IndexOf(':');
                    if (colon <= 0) continue;
                    string name = lines[index].Substring(0, colon).Trim();
                    string value = lines[index].Substring(colon + 1).Trim();
                    if (name.Equals("content-length", StringComparison.OrdinalIgnoreCase))
                    {
                        int.TryParse(value, out contentLength);
                    }
                    else if (name.Equals("x-kvm-token", StringComparison.OrdinalIgnoreCase))
                    {
                        headerToken = value;
                    }
                }

                if (contentLength < 0 || contentLength > 192 * 1024 * 1024)
                {
                    WriteResponse(stream, 413, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("body too large"));
                    return;
                }

                int bodyStart = headerEnd + 4;
                while (received.Length < bodyStart + contentLength)
                {
                    int read = stream.Read(scratch, 0, scratch.Length);
                    if (read <= 0) break;
                    int room = bodyStart + contentLength - (int)received.Length;
                    received.Write(scratch, 0, Math.Min(read, room));
                }
                string body = "";
                byte[] all = received.GetBuffer();
                if (contentLength > 0 && all.Length >= bodyStart + contentLength)
                {
                    body = Encoding.UTF8.GetString(all, bodyStart, contentLength);
                }

                Uri uri;
                if (!Uri.TryCreate("http://localhost" + rawUrl, UriKind.Absolute, out uri))
                {
                    WriteResponse(stream, 400, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("bad url"));
                    return;
                }

                if (method == "OPTIONS")
                {
                    WriteResponse(stream, 204, "text/plain; charset=utf-8", new byte[0]);
                    return;
                }

                string path = uri.AbsolutePath;
                if (method == "GET" && path == "/api/hello")
                {
                    WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(HelloJson()));
                    return;
                }

                string suppliedToken = headerToken;
                if (String.IsNullOrEmpty(suppliedToken)) suppliedToken = QueryValue(uri.Query, "token");
                if (!String.Equals(suppliedToken, _token, StringComparison.Ordinal))
                {
                    WriteResponse(stream, 401, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":\"unauthorized\"}"));
                    return;
                }

                if (method == "GET" && path == "/api/file-stream")
                {
                    HandleFileStream(client, stream, uri);
                    return;
                }
                if (method == "GET" && path == "/api/clipboard")
                {
                    uint since = 0;
                    string sinceValue = QueryValue(uri.Query, "since");
                    if (sinceValue != null) UInt32.TryParse(sinceValue, out since);
                    try
                    {
                        // A poll is not a transfer: only count when the Mac
                        // actually takes this clipboard. Counting every request
                        // made the figure climb on its own.
                        Interlocked.Increment(ref _clipboardPolls);
                        bool sequenceOnly = QueryValue(uri.Query, "sequenceOnly") == "1";
                        string json = sequenceOnly ? "{\"ok\":true,\"unchanged\":true,\"seq\":" +
                            Native.GetClipboardSequenceNumber() + "}" : ClipboardJson(since, QueryValue(uri.Query, "fileTrees") == "1", QueryValue(uri.Query,"streamFiles") == "1");
                        bool unchanged = json.IndexOf("\"unchanged\":true", StringComparison.Ordinal) >= 0;
                        bool hasPayload = json.IndexOf("\"kind\":\"none\"", StringComparison.Ordinal) < 0;
                        if (!unchanged && hasPayload)
                        {
                            Interlocked.Increment(ref _clipboardOps);
                        }
                        WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(json));
                    }
                    catch (Exception error)
                    {
                        WriteResponse(stream, 500, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":" + Quote(error.Message) + "}"));
                    }
                    return;
                }
                if (method == "POST" && path == "/api/clipboard")
                {
                    try
                    {
                        SetClipboardFromJson(body);
                        Interlocked.Increment(ref _clipboardOps);
                        uint sequence = Native.GetClipboardSequenceNumber();
                        WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":true,\"seq\":" + sequence + "}"));
                    }
                    catch (Exception error)
                    {
                        WriteResponse(stream, 400, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":" + Quote(error.Message) + "}"));
                    }
                    return;
                }
                if (method == "GET" && path == "/api/ping")
                {
                    WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(PingJson()));
                    return;
                }
                if (method == "POST" && path == "/api/input")
                {
                    try
                    {
                        if (ApplyInput(body, client, null)) Interlocked.Increment(ref _inputEvents);
                        WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(CursorJson()));
                    }
                    catch (Exception error)
                    {
                        WriteResponse(stream, 400, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":" + Quote(error.Message) + "}"));
                    }
                    return;
                }
                if (method == "GET" && (path == "/" || path == "/health"))
                {
                    byte[] text = Encoding.UTF8.GetBytes("DSH LAN KVM agent is running. Use the DSH panel to connect.\r\n");
                    WriteResponse(stream, 200, "text/plain; charset=utf-8", text);
                    return;
                }

                WriteResponse(stream, 404, "application/json; charset=utf-8", Encoding.UTF8.GetBytes("{\"ok\":false,\"error\":\"not found\"}"));
            }
            catch (Exception error)
            {
                Console.Error.WriteLine("request failed: " + error.Message);
                try
                {
                    if (stream != null)
                    {
                        WriteResponse(stream, 500, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("server error"));
                    }
                }
                catch { }
            }
            finally
            {
                try { client.Close(); }
                catch { }
            }
        }

        private static int FindHeaderEnd(byte[] data, int length)
        {
            for (int index = 0; index <= length - 4; index++)
            {
                if (data[index] == 13 && data[index + 1] == 10 && data[index + 2] == 13 && data[index + 3] == 10)
                    return index;
            }
            return -1;
        }

        private static string QueryValue(string query, string key)
        {
            if (String.IsNullOrEmpty(query)) return null;
            string text = query.StartsWith("?") ? query.Substring(1) : query;
            string[] parts = text.Split('&');
            for (int index = 0; index < parts.Length; index++)
            {
                string part = parts[index];
                int equal = part.IndexOf('=');
                string name = equal < 0 ? part : part.Substring(0, equal);
                string value = equal < 0 ? "" : part.Substring(equal + 1);
                if (Uri.UnescapeDataString(name) == key) return Uri.UnescapeDataString(value);
            }
            return null;
        }

        private static void WriteResponse(NetworkStream stream, int status, string contentType, byte[] body)
        {
            if (body == null) body = new byte[0];
            string reason = status == 200 ? "OK" :
                status == 204 ? "No Content" :
                status == 400 ? "Bad Request" :
                status == 401 ? "Unauthorized" :
                status == 404 ? "Not Found" :
                status == 413 ? "Payload Too Large" :
                status == 500 ? "Internal Server Error" :
                status == 503 ? "Service Unavailable" : "OK";

            StringBuilder head = new StringBuilder();
            head.Append("HTTP/1.1 ").Append(status).Append(' ').Append(reason).Append("\r\n");
            head.Append("Content-Type: ").Append(contentType).Append("\r\n");
            head.Append("Content-Length: ").Append(body.Length).Append("\r\n");
            head.Append("Cache-Control: no-store\r\n");
            head.Append("Connection: close\r\n");
            head.Append("Access-Control-Allow-Origin: *\r\n");
            head.Append("Access-Control-Allow-Headers: content-type,x-kvm-token\r\n");
            head.Append("Access-Control-Allow-Methods: GET,POST,OPTIONS\r\n");
            head.Append("\r\n");
            byte[] headerBytes = Encoding.ASCII.GetBytes(head.ToString());
            stream.Write(headerBytes, 0, headerBytes.Length);
            if (body.Length > 0) stream.Write(body, 0, body.Length);
            stream.Flush();
        }

        private static string HelloJson()
        {
            StringBuilder json = new StringBuilder();
            json.Append("{\"ok\":true,\"agent\":\"lankvm\",\"version\":4,\"fileTrees\":true,\"fileStream\":true,");
            json.Append("\"machine\":").Append(Quote(Environment.MachineName)).Append('}');
            return json.ToString();
        }

        private static string PingJson()
        {
            Rectangle bounds = SystemInformation.VirtualScreen;
            StringBuilder json = new StringBuilder();
            json.Append("{\"ok\":true,\"agent\":\"lankvm\",\"version\":4,\"fileTrees\":true,\"fileStream\":true,");
            json.Append("\"machine\":").Append(Quote(Environment.MachineName)).Append(',');
            json.Append("\"left\":").Append(bounds.Left).Append(',');
            json.Append("\"top\":").Append(bounds.Top).Append(',');
            json.Append("\"width\":").Append(bounds.Width).Append(',');
            json.Append("\"height\":").Append(bounds.Height).Append('}');
            return json.ToString();
        }

        private static string Quote(string value)
        {
            if (value == null) return "\"\"";
            StringBuilder builder = new StringBuilder("\"");
            for (int index = 0; index < value.Length; index++)
            {
                char current = value[index];
                switch (current)
                {
                    case '\"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (current < 32) builder.Append("\\u").Append(((int)current).ToString("x4"));
                        else builder.Append(current);
                        break;
                }
            }
            builder.Append('\"');
            return builder.ToString();
        }

        private static bool OpenClipboardWithRetry(IntPtr owner)
        {
            for (int attempt = 0; attempt < 30; attempt++)
            {
                if (Native.OpenClipboard(owner)) return true;
                Thread.Sleep(10);
            }
            return false;
        }

        private static string ReadClipboardText()
        {
            IntPtr data = Native.GetClipboardData(Native.CF_UNICODETEXT);
            if (data == IntPtr.Zero) return null;
            IntPtr locked = Native.GlobalLock(data);
            if (locked == IntPtr.Zero) return null;
            try { return Marshal.PtrToStringUni(locked); }
            finally { Native.GlobalUnlock(data); }
        }

        /// <summary>Paths currently on the clipboard as a file list, or null.</summary>
        private static string[] ReadClipboardFiles()
        {
            IntPtr handle = Native.GetClipboardData(Native.CF_HDROP);
            if (handle == IntPtr.Zero) return null;
            uint count = Native.DragQueryFile(handle, 0xFFFFFFFF, null, 0);
            if (count == 0) return null;
            string[] paths = new string[count];
            for (uint index = 0; index < count; index++)
            {
                uint length = Native.DragQueryFile(handle, index, null, 0);
                if (length == 0) continue;
                StringBuilder buffer = new StringBuilder((int)length + 1);
                Native.DragQueryFile(handle, index, buffer, (uint)buffer.Capacity);
                paths[index] = buffer.ToString();
            }
            return paths;
        }

        private const int FileByteLimit = 128 * 1024 * 1024;
        private const int MaxFileEntries = 10000;

        private static void ValidateName(string name)
        {
            if (String.IsNullOrEmpty(name) || name.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0 ||
                name.EndsWith(".") || name.EndsWith(" "))
                throw new InvalidDataException("Invalid clipboard file name");
            string stem = name.Split('.')[0].TrimEnd(' ').ToUpperInvariant();
            if (stem == "CON" || stem == "PRN" || stem == "AUX" || stem == "NUL" ||
                stem == "CONIN$" || stem == "CONOUT$" ||
                (stem.Length == 4 && (stem.StartsWith("COM") || stem.StartsWith("LPT")) &&
                 "123456789¹²³".IndexOf(stem[3]) >= 0))
                throw new InvalidDataException("Reserved clipboard file name");
        }

        private static void AppendClipboardPath(string path, int parent, bool allowTrees, StringBuilder json,
            ref int count, ref int remaining, ref bool hasDirectory)
        {
            if (count >= MaxFileEntries) throw new InvalidDataException("所选项目超过文件数量上限");
            FileAttributes attr = File.GetAttributes(path);
            if ((attr & FileAttributes.ReparsePoint) != 0)
                throw new InvalidDataException("所选目录含有链接或重解析点");
            string name = Path.GetFileName(path);
            ValidateName(name);
            int index = count++;
            if (index != 0) json.Append(',');
            json.Append("{\"name\":").Append(Quote(name));
            if (parent >= 0) json.Append(",\"parent\":").Append(parent);
            if ((attr & FileAttributes.Directory) != 0)
            {
                if (!allowTrees) throw new InvalidDataException("请更新 Mac 端以复制文件夹");
                hasDirectory = true;
                json.Append(",\"directory\":true}");
                foreach (string child in Directory.EnumerateFileSystemEntries(path))
                    AppendClipboardPath(child, index, allowTrees, json, ref count, ref remaining, ref hasDirectory);
                return;
            }
            using (FileStream input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (input.Length > remaining) throw new InvalidDataException("文件总大小超过传输上限");
                byte[] data = new byte[(int)input.Length];
                int offset = 0;
                while (offset < data.Length)
                {
                    int n = input.Read(data, offset, data.Length - offset);
                    if (n == 0) throw new EndOfStreamException();
                    offset += n;
                }
                remaining -= data.Length;
                json.Append(",\"data\":\"").Append(Convert.ToBase64String(data)).Append("\"}");
            }
        }

        private static string ReadClipboardImagePng()
        {
            uint pngFormat = Native.RegisterClipboardFormat("PNG");
            if (pngFormat != 0)
            {
                IntPtr pngData = Native.GetClipboardData(pngFormat);
                if (pngData != IntPtr.Zero)
                {
                    ulong pngSize = Native.GlobalSize(pngData).ToUInt64();
                    if (pngSize > 0 && pngSize <= 64 * 1024 * 1024)
                    {
                        IntPtr pngLocked = Native.GlobalLock(pngData);
                        if (pngLocked != IntPtr.Zero)
                        {
                            try
                            {
                                byte[] png = new byte[(int)pngSize];
                                Marshal.Copy(pngLocked, png, 0, png.Length);
                                if (png.Length >= 8 && png[0] == 137 && png[1] == 80 && png[2] == 78 && png[3] == 71)
                                {
                                    return Convert.ToBase64String(png);
                                }
                            }
                            finally { Native.GlobalUnlock(pngData); }
                        }
                    }
                }
            }

            IntPtr bitmap = Native.GetClipboardData(Native.CF_BITMAP);
            if (bitmap != IntPtr.Zero)
            {
                try
                {
                    using (Image picture = Image.FromHbitmap(bitmap))
                    using (MemoryStream output = new MemoryStream())
                    {
                        picture.Save(output, ImageFormat.Png);
                        if (output.Length <= 64 * 1024 * 1024) return Convert.ToBase64String(output.ToArray());
                    }
                }
                catch { }
            }

            IntPtr data = Native.GetClipboardData(Native.CF_DIB);
            if (data == IntPtr.Zero) data = Native.GetClipboardData(Native.CF_DIBV5);
            if (data == IntPtr.Zero) return null;
            ulong size = Native.GlobalSize(data).ToUInt64();
            if (size < 40 || size > 256 * 1024 * 1024) return null;
            IntPtr locked = Native.GlobalLock(data);
            if (locked == IntPtr.Zero) return null;
            try
            {
                byte[] dib = new byte[(int)size];
                Marshal.Copy(locked, dib, 0, dib.Length);
                int headerSize = BitConverter.ToInt32(dib, 0);
                if (headerSize < 12 || headerSize > dib.Length) return null;
                short bitCount = dib.Length >= 16 ? BitConverter.ToInt16(dib, 14) : (short)0;
                int colorsUsed = headerSize >= 40 && dib.Length >= 36 ? BitConverter.ToInt32(dib, 32) : 0;
                int paletteSize = colorsUsed > 0 ? colorsUsed * 4 : (bitCount <= 8 ? (1 << bitCount) * 4 : 0);
                int offset = 14 + headerSize + paletteSize;
                if (offset < 14 + headerSize || offset > dib.Length) offset = 14 + headerSize;
                byte[] bmp = new byte[14 + dib.Length];
                bmp[0] = (byte)'B';
                bmp[1] = (byte)'M';
                BitConverter.GetBytes(bmp.Length).CopyTo(bmp, 2);
                BitConverter.GetBytes(offset).CopyTo(bmp, 10);
                Buffer.BlockCopy(dib, 0, bmp, 14, dib.Length);
                using (MemoryStream input = new MemoryStream(bmp))
                using (Image picture = Image.FromStream(input))
                using (MemoryStream output = new MemoryStream())
                {
                    picture.Save(output, ImageFormat.Png);
                    if (output.Length > 64 * 1024 * 1024) return null;
                    return Convert.ToBase64String(output.ToArray());
                }
            }
            catch { return null; }
            finally { Native.GlobalUnlock(data); }
        }

        private static string ClipboardJson(uint since, bool allowTrees, bool streamFiles)
        {
            uint sequence = Native.GetClipboardSequenceNumber();
            if (sequence == since)
                return "{\"ok\":true,\"seq\":" + sequence + ",\"unchanged\":true}";
            string kind = "none", text = null, image = null, files = null, error = null;
            string[] paths = null;
            if (OpenClipboardWithRetry(IntPtr.Zero))
            {
                try
                {
                    paths = ReadClipboardFiles();
                    if (paths == null)
                    {
                        image = ReadClipboardImagePng();
                        if (image != null) kind = "image";
                        else
                        {
                            text = ReadClipboardText();
                            if (text != null && text.Length <= 33554432) kind = "text";
                            else text = null;
                        }
                    }
                    sequence = Native.GetClipboardSequenceNumber();
                }
                catch (Exception caught) { error = caught.Message; }
                finally { Native.CloseClipboard(); }
            }
            else error = "clipboard is busy";

            // Only the path list needs the system clipboard lock, not directory enumeration or file I/O.
            if (paths != null && streamFiles) return "{\"ok\":true,\"kind\":\"fileStream\",\"seq\":" + sequence + "}";
            if (paths != null)
            {
                try
                {
                    StringBuilder entries = new StringBuilder("[");
                    int count = 0, remaining = FileByteLimit;
                    bool hasDirectory = false;
                    foreach (string path in paths)
                        AppendClipboardPath(path, -1, allowTrees, entries, ref count, ref remaining, ref hasDirectory);
                    files = entries.Append(']').ToString();
                    kind = hasDirectory ? "fileTree" : "files";
                }
                catch (Exception caught)
                {
                    string skippedKind = allowTrees ? "skipped" : "none";
                    return "{\"ok\":true,\"seq\":" + sequence + ",\"kind\":" + Quote(skippedKind) +
                        ",\"reason\":" + Quote(caught.Message) + "}";
                }
                if (Native.GetClipboardSequenceNumber() != sequence)
                    return "{\"ok\":true,\"unchanged\":true,\"seq\":" + since + "}";
            }

            StringBuilder json = new StringBuilder();
            json.Append("{\"ok\":true,\"seq\":").Append(sequence).Append(",\"kind\":").Append(Quote(kind));
            if (text != null) json.Append(",\"text\":").Append(Quote(text));
            if (image != null) json.Append(",\"image\":").Append(Quote(image));
            if (files != null) json.Append(",\"files\":").Append(files);
            if (error != null) json.Append(",\"error\":").Append(Quote(error));
            json.Append('}');
            return json.ToString();
        }

        // Publish fully rendered handles before destroying the temporary owner.
        // Opening for writing with a null HWND leaves EmptyClipboard without an owner.
        private static bool PublishClipboard(uint format, IntPtr data, uint? expected = null)
        {
            NativeWindow window = new NativeWindow();
            window.CreateHandle(new CreateParams { Parent = new IntPtr(-3) }); // HWND_MESSAGE
            try
            {
                if (!OpenClipboardWithRetry(window.Handle)) return false;
                try { return (!expected.HasValue || Native.GetClipboardSequenceNumber() == expected.Value) && Native.EmptyClipboard() && Native.SetClipboardData(format, data) != IntPtr.Zero; }
                finally { Native.CloseClipboard(); }
            }
            finally { window.DestroyHandle(); }
        }

        private static bool PublishMemory(uint format, byte[] data, uint? expected = null)
        {
            IntPtr memory = Native.GlobalAlloc(Native.GMEM_MOVEABLE, (UIntPtr)data.Length);
            if (memory == IntPtr.Zero) return false;
            try
            {
                IntPtr locked = Native.GlobalLock(memory);
                if (locked == IntPtr.Zero) return false;
                try { Marshal.Copy(data, 0, locked, data.Length); }
                finally { Native.GlobalUnlock(memory); }
                if (!PublishClipboard(format, memory, expected)) return false;
                memory = IntPtr.Zero;
                return true;
            }
            finally { if (memory != IntPtr.Zero) Native.GlobalFree(memory); }
        }

        private static bool SetClipboardText(string text)
        {
            return PublishMemory(Native.CF_UNICODETEXT, Encoding.Unicode.GetBytes(text + "\0"));
        }

        /// <summary>
        /// Writes received files to disk and publishes them as a CF_HDROP file
        /// list, which is what Explorer pastes.
        /// </summary>
        // One bulk connection per clipboard worker. Data and metadata share a 128 KiB
        // receive-credit window, independent of the keyboard/mouse connection.
        private sealed class FileWire
        {
            private readonly Stream io;
            private readonly AgentServer server;
            public bool BetweenFiles = true;
            private int credit = 131072;
            public FileWire(Stream io, AgentServer server) { this.io = io; this.server = server; }

            public void Transfer(byte[] bytes, int count, bool send)
            {
                int pos = 0;
                while (pos < count)
                {
                    int n = Math.Min(count - pos, credit);
                    if (send) io.Write(bytes, pos, n);
                    else { n = io.Read(bytes, pos, n); if (n == 0) throw new EndOfStreamException(); }
                    pos += n;
                    credit -= n;
                    if (credit == 0)
                    {
                        // Yield a little bandwidth only while user input is arriving.
                        if (unchecked((uint)(Environment.TickCount - server._lastMotionTick)) < 200) Thread.Sleep(4);
                        if (send) { if (io.ReadByte() != 6) throw new IOException("File transfer interrupted"); }
                        else io.WriteByte(6);
                        credit = 131072;
                    }
                }
            }

            public void WriteEntry(Dictionary<string,object> entry)
            {
                byte[] bytes = Encoding.UTF8.GetBytes(Serializer.Serialize(entry));
                byte[] len = BitConverter.GetBytes(IPAddress.HostToNetworkOrder(bytes.Length));
                Transfer(len, 4, true);
                Transfer(bytes, bytes.Length, true);
            }

            public Dictionary<string,object> ReadEntry()
            {
                byte[] len = new byte[4];
                Transfer(len, 4, false);
                int n = IPAddress.NetworkToHostOrder(BitConverter.ToInt32(len, 0));
                if (n <= 0 || n > 65536) throw new InvalidDataException("Invalid file header");
                byte[] bytes = new byte[n];
                Transfer(bytes, n, false);
                return Serializer.Deserialize<Dictionary<string,object>>(Encoding.UTF8.GetString(bytes));
            }
        }

        private void SendPath(FileWire wire, string path, long parent, ref long next, byte[] buffer, uint seq)
        {
            if (Native.GetClipboardSequenceNumber() != seq) throw new IOException("Clipboard changed");
            FileAttributes a = File.GetAttributes(path);
            if ((a & FileAttributes.ReparsePoint) != 0) throw new IOException("不能传输链接或重解析点");
            string name = Path.GetFileName(path);
            ValidateName(name);
            long index = next++;
            var entry = new Dictionary<string,object> {{"name",name},{"parent",parent}};
            if ((a & FileAttributes.Directory) != 0)
            {
                entry["directory"] = true;
                wire.WriteEntry(entry);
                foreach (string child in Directory.EnumerateFileSystemEntries(path))
                    SendPath(wire, child, index, ref next, buffer, seq);
                return;
            }
            using (var file = new FileStream(path,FileMode.Open,FileAccess.Read,FileShare.Read,65536,FileOptions.SequentialScan))
            {
                long left = file.Length;
                entry["size"] = left;
                wire.BetweenFiles = false;
                wire.WriteEntry(entry);
                while (left > 0)
                {
                    if (Native.GetClipboardSequenceNumber() != seq) throw new IOException("Clipboard changed");
                    int n = file.Read(buffer,0,(int)Math.Min(left,buffer.Length));
                    if (n == 0) throw new EndOfStreamException();
                    wire.Transfer(buffer,n,true);
                    left -= n;
                }
                wire.BetweenFiles = true;
            }
        }

        private int _checkedPendingFiles;
        private const string PendingFile = ".lankvm-stream-pending";
        private static void ClearAbandonedFiles(string baseDir)
        {
            foreach (string dir in Directory.EnumerateDirectories(baseDir))
            {
                Guid id;
                if (!Guid.TryParseExact(Path.GetFileName(dir),"N",out id)) continue;
                string marker = Path.Combine(dir,PendingFile);
                try
                {
                    if (!File.Exists(marker) || (File.GetAttributes(dir) & FileAttributes.ReparsePoint) != 0) continue;
                    using (File.Open(marker,FileMode.Open,FileAccess.ReadWrite,FileShare.Delete))
                        File.Delete(marker);
                    Directory.Delete(dir,true);
                }
                catch (IOException) { } // Active transfer, or already collected.
                catch (UnauthorizedAccessException) { }
            }
        }

        private uint ReceivePaths(FileWire wire, uint expected)
        {
            string baseDir = Path.Combine(Path.GetTempPath(),"dsh-lan-kvm-paste");
            string stage = Path.Combine(baseDir,Guid.NewGuid().ToString("N"));
            Directory.CreateDirectory(baseDir);
            if (Interlocked.Exchange(ref _checkedPendingFiles,1) == 0) ClearAbandonedFiles(baseDir);
            Directory.CreateDirectory(stage);
            string marker = Path.Combine(stage,PendingFile);
            var roots = new List<string>();
            var dirs = new Dictionary<long,string>();
            byte[] buffer = new byte[65536];
            bool published = false;
            try
            {
                using (var lease = File.Open(marker,FileMode.CreateNew,FileAccess.ReadWrite,FileShare.Delete))
                {
                    for (long index = 0; ; index++)
                    {
                        var entry = wire.ReadEntry();
                        if (GetBool(entry,"end")) break;
                        string name = GetValue(entry,"name") as string;
                        ValidateName(name);
                        long parent;
                        if (!Int64.TryParse(GetString(entry,"parent"),out parent)) throw new InvalidDataException("Missing parent");
                        string dir;
                        if (parent == -1) { dir = Path.Combine(stage,index.ToString()); Directory.CreateDirectory(dir); }
                        else if (!dirs.TryGetValue(parent,out dir)) throw new InvalidDataException("Invalid directory");
                        string path = Path.Combine(dir,name);
                        if (GetBool(entry,"directory"))
                        {
                            if (Directory.Exists(path) || File.Exists(path)) throw new IOException("Duplicate name");
                            Directory.CreateDirectory(path);
                            dirs.Add(index,path);
                        }
                        else
                        {
                            long left;
                            if (!Int64.TryParse(GetString(entry,"size"),out left) || left < 0) throw new InvalidDataException("Invalid size");
                            using (var file = new FileStream(path,FileMode.CreateNew,FileAccess.Write,FileShare.None,65536,FileOptions.SequentialScan))
                                while (left > 0)
                                {
                                    if (Native.GetClipboardSequenceNumber() != expected) throw new IOException("Windows 剪贴板已更改");
                                    int n = (int)Math.Min(left,buffer.Length);
                                    wire.Transfer(buffer,n,false);
                                    file.Write(buffer,0,n);
                                    left -= n;
                                }
                        }
                        if (parent == -1) roots.Add(path);
                    }
                    // Remove the marker while still holding the lease, before publishing.
                    File.Delete(marker);
                }
                if (roots.Count == 0 || !PublishFileList(roots,expected)) throw new IOException("Windows 剪贴板已更改或正忙");
                published = true;
                return Native.GetClipboardSequenceNumber();
            }
            finally { if (!published) Directory.Delete(stage, true); }
        }

        private void HandleFileStream(TcpClient client, NetworkStream stream, Uri uri)
        {
            bool sending = QueryValue(uri.Query,"direction") == "get";
            string[] paths = null;
            uint seq;
            if (sending)
            {
                if (!UInt32.TryParse(QueryValue(uri.Query,"seq"),out seq) || !OpenClipboardWithRetry(IntPtr.Zero))
                    throw new IOException("Windows 剪贴板正忙");
                try { if (Native.GetClipboardSequenceNumber() == seq) paths = ReadClipboardFiles(); }
                finally { Native.CloseClipboard(); }
                if (paths == null) { WriteResponse(stream,409,"text/plain",Encoding.UTF8.GetBytes("Windows 剪贴板已更改")); return; }
            }
            else seq = Native.GetClipboardSequenceNumber();
            client.NoDelay = true;
            client.SendBufferSize = 65536;
            client.ReceiveBufferSize = 131072;
            var upgrade = Encoding.ASCII.GetBytes("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: lankvm-files/1\r\n\r\n");
            stream.Write(upgrade,0,upgrade.Length);
            var wire = new FileWire(stream,this);
            try
            {
                if (sending)
                {
                    byte[] buffer = new byte[65536];
                    long next = 0;
                    foreach (string path in paths) SendPath(wire,path,-1,ref next,buffer,seq);
                    if (Native.GetClipboardSequenceNumber() != seq) throw new IOException("Windows 剪贴板已更改");
                    wire.WriteEntry(new Dictionary<string,object>{{"end",true}});
                }
                else
                {
                    uint published = ReceivePaths(wire,seq);
                    byte[] ack = Encoding.ASCII.GetBytes("OK "+published+"\n");
                    stream.Write(ack,0,ack.Length);
                }
                Interlocked.Increment(ref _clipboardOps);
            }
            catch (Exception ex)
            {
                // A failed frame must never be mistaken for a successful commit.
                if (sending && wire.BetweenFiles)
                {
                    try { wire.WriteEntry(new Dictionary<string,object>{{"error",ex.Message}}); } catch (IOException) {}
                }
                if (!sending)
                {
                    byte[] reason = Encoding.UTF8.GetBytes("ERR " + ex.Message.Replace('\n',' ') + "\n");
                    try {stream.Write(reason,0,reason.Length);} catch (IOException) {}
                }
            }
        }

        private static bool SetClipboardFiles(object filesValue, bool tree)
        {
            System.Collections.IList entries = filesValue as System.Collections.IList;
            if (entries == null || entries.Count == 0 || entries.Count > MaxFileEntries)
                throw new InvalidDataException("Invalid file list");
            string stage = Path.Combine(Path.GetTempPath(), "dsh-lan-kvm-paste", Guid.NewGuid().ToString("N"));
            List<string> roots = new List<string>();
            Dictionary<int, string> directories = new Dictionary<int, string>();
            int remaining = FileByteLimit;
            bool published = false;
            Directory.CreateDirectory(stage);
            try
            {
                for (int i = 0; i < entries.Count; i++)
                {
                    Dictionary<string, object> file = entries[i] as Dictionary<string, object>;
                    if (file == null) throw new InvalidDataException("Invalid clipboard entry");
                    string name = GetValue(file, "name") as string;
                    ValidateName(name);
                    string parent;
                    bool root = !file.ContainsKey("parent");
                    if (root)
                    {
                        parent = Path.Combine(stage, i.ToString());
                        Directory.CreateDirectory(parent);
                    }
                    else if (!tree || !(file["parent"] is int) || !directories.TryGetValue((int)file["parent"], out parent))
                        throw new InvalidDataException("Invalid clipboard parent directory");
                    string target = Path.Combine(parent, name);
                    if (GetBool(file, "directory"))
                    {
                        if (!tree || file.ContainsKey("data") || Directory.Exists(target) || File.Exists(target))
                            throw new InvalidDataException("Invalid or duplicate directory");
                        Directory.CreateDirectory(target);
                        directories.Add(i, target);
                    }
                    else
                    {
                        string encoded = GetValue(file, "data") as string;
                        if (encoded == null || encoded.Length > (remaining + 2) / 3 * 4)
                            throw new InvalidDataException("Invalid clipboard file size");
                        byte[] data = Convert.FromBase64String(encoded);
                        if (data.Length > remaining) throw new InvalidDataException("Clipboard size limit exceeded");
                        using (FileStream output = new FileStream(target, FileMode.CreateNew, FileAccess.Write))
                            output.Write(data, 0, data.Length);
                        remaining -= data.Length;
                    }
                    if (root) roots.Add(target);
                }
                published = PublishFileList(roots);
                return published;
            }
            finally { if (!published) Directory.Delete(stage, true); }
        }

        private static bool PublishFileList(List<string> written, uint? expected = null)
        {
            // DROPFILES header followed by a double-null-terminated path list.
            MemoryStream payload = new MemoryStream();
            byte[] header = new byte[20];
            BitConverter.GetBytes(20).CopyTo(header, 0);   // pFiles: offset of the list
            BitConverter.GetBytes(1).CopyTo(header, 16);   // fWide: Unicode paths
            payload.Write(header, 0, header.Length);
            foreach (string path in written)
            {
                byte[] chars = Encoding.Unicode.GetBytes(path);
                payload.Write(chars, 0, chars.Length);
                payload.Write(new byte[] { 0, 0 }, 0, 2);
            }
            payload.Write(new byte[] { 0, 0 }, 0, 2);
            return PublishMemory(Native.CF_HDROP, payload.ToArray(), expected);
        }

        private static bool SetClipboardImage(string base64)
        {
            using (MemoryStream input = new MemoryStream(Convert.FromBase64String(base64)))
            using (Image source = Image.FromStream(input))
            using (Bitmap picture = new Bitmap(source))
            {
                IntPtr bitmap = picture.GetHbitmap();
                if (bitmap == IntPtr.Zero) return false;
                try
                {
                    if (!PublishClipboard(Native.CF_BITMAP, bitmap)) return false;
                    bitmap = IntPtr.Zero;
                    return true;
                }
                finally { if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap); }
            }
        }

        private static void SetClipboardFromJson(string body)
        {
            Dictionary<string, object> payload = Serializer.Deserialize<Dictionary<string, object>>(body);
            if (payload == null) throw new InvalidOperationException("missing JSON body");
            string kind = GetString(payload, "kind").ToLowerInvariant();
            string text = GetString(payload, "text");
            string image = GetString(payload, "image");
            bool ok;
            if (kind == "text") ok = SetClipboardText(text);
            else if (kind == "image") ok = SetClipboardImage(image);
            else if (kind == "files" || kind == "filetree") ok = SetClipboardFiles(GetValue(payload, "files"), kind == "filetree");
            else throw new InvalidOperationException("unsupported clipboard kind: " + kind);
            if (!ok) throw new InvalidOperationException("clipboard is busy");
        }

        private static string CursorJson()
        {
            Native.POINT point;
            Native.GetCursorPos(out point);
            return "{\"ok\":true,\"x\":" + point.X + ",\"y\":" + point.Y + "}";
        }

        private void ReleaseHeldInput()
        {
            foreach (int vk in _heldKeys)
            {
                try { KeyEvent(vk, false); } catch (InvalidOperationException) { }
            }
            foreach (string button in _heldButtons) MouseButton(button, false);
            _heldKeys.Clear();
            _heldButtons.Clear();
            _gameWindow = IntPtr.Zero;
            _ownerStream = null;
            _owner = null;
            _leasedInput = false;
        }

        private void ExpireInput(object ignored)
        {
            lock (_inputLock)
            {
                if (_leasedInput && unchecked((uint)(Environment.TickCount - _lastInputTick)) >= 5000)
                    ReleaseHeldInput();
            }
        }

        // Ignore delayed HTTP or TCP batches from a session that has already handed control back.
        private void EndSession(string id)
        {
            if (id == null || _endedSessions.Contains(id)) return;
            if (_endedSessions.Count == 32) _endedSessions.Dequeue();
            _endedSessions.Enqueue(id);
        }

        private bool ApplyInput(string body, TcpClient peer, TcpClient stream)
        {
            Dictionary<string, object> payload = Serializer.Deserialize<Dictionary<string, object>>(body);
            if (payload == null) throw new InvalidOperationException("missing JSON body");
            string session = GetString(payload, "session");
            bool leased = !String.IsNullOrEmpty(session);
            if (!leased) session = "legacy-" + ((IPEndPoint)peer.Client.RemoteEndPoint).Address;
            string op = GetString(payload, "op");
            lock (_inputLock)
            {
                if (!_running) throw new InvalidOperationException("receiver stopped");
                if (op == "release")
                {
                    if (leased) EndSession(session);
                    if (_owner == session) ReleaseHeldInput();
                    return false;
                }
                if (leased && _endedSessions.Contains(session)) return false;
                if (op == "keepalive" && _owner != session) return false;
                if (_owner != session)
                {
                    if (_leasedInput) EndSession(_owner);
                    ReleaseHeldInput();
                }
                _owner = session;
                _ownerStream = stream;
                _lastInputTick = Environment.TickCount;
                _leasedInput = leased;
                if (op == "keepalive") return false;
                _lastMotionTick = Environment.TickCount;
                ApplyCommand(payload);
                return true;
            }
        }

        private void ApplyCommand(Dictionary<string, object> payload)
        {
            string op = GetString(payload, "op").ToLowerInvariant();

            if (op == "batch")
            {
                object rawEvents;
                if (!payload.TryGetValue("events", out rawEvents) || rawEvents == null)
                {
                    throw new InvalidOperationException("batch has no events");
                }
                System.Collections.IEnumerable events = rawEvents as System.Collections.IEnumerable;
                if (events == null || rawEvents is string) throw new InvalidOperationException("batch events must be an array");
                foreach (object rawItem in events)
                {
                    Dictionary<string, object> item = rawItem as Dictionary<string, object>;
                    if (item == null) throw new InvalidOperationException("batch item is not an object");
                    ApplyCommand(item);
                }
                return;
            }

            if (op == "move")
            {
                string side = GetString(payload, "entrySide");
                if (side == "right" || side == "left")
                {
                    Native.EnterDesktop(side, Convert.ToDouble(GetValue(payload,"ratio")));
                    return;
                }
                Native.SetCursorPos(GetInt(payload, "x"), GetInt(payload, "y"));
                // Zero-delta mouse input clears the typing-hidden pointer
                // without moving it off the requested pixel.
                Native.mouse_event(Native.MOUSEEVENTF_MOVE, 0, 0, 0, UIntPtr.Zero);
                return;
            }
            if (op == "moverel")
            {
                int dx = GetInt(payload, "dx");
                int dy = GetInt(payload, "dy");
                if (dx != 0 || dy != 0)
                {
                    // A captured application may recenter the pointer between GetCursorPos
                    // and SetCursorPos. Stay relative for the entire right-button drag,
                    // including the click that first gives the application focus.
                    bool leftCamera = _heldButtons.Contains("left") && (GetBool(payload, "gameDrag") ||
                        (_gameWindow != IntPtr.Zero && Native.GetForegroundWindow() == _gameWindow));
                    if (_heldButtons.Contains("right") || leftCamera)
                    {
                        Native.MoveRelative(dx, dy);
                        return;
                    }
                    Native.POINT point;
                    if (Native.GetCursorPos(out point))
                    {
                        Native.SetCursorPos(point.X + dx, point.Y + dy);
                    }
                    // A zero-delta mouse event is what clears the "hide pointer
                    // while typing" state; it cannot move the pointer.
                    Native.mouse_event(Native.MOUSEEVENTF_MOVE, 0, 0, 0, UIntPtr.Zero);
                }
                return;
            }
            if (op == "click")
            {
                int x = GetInt(payload, "x");
                int y = GetInt(payload, "y");
                string button = GetString(payload, "button");
                int clicks = GetInt(payload, "clicks");
                if (clicks < 1) clicks = 1;
                if (clicks > 3) clicks = 3;
                Native.SetCursorPos(x, y);
                Thread.Sleep(12);
                for (int index = 0; index < clicks; index++)
                {
                    MouseButton(button, true);
                    MouseButton(button, false);
                    if (index + 1 < clicks) Thread.Sleep(55);
                }
                return;
            }
            if (op == "down" || op == "up")
            {
                string button = GetString(payload, "button").ToLowerInvariant();
                if (button != "right" && button != "middle") button = "left";
                bool down = op == "down";
                if (down && _heldButtons.Count == 0)
                {
                    IntPtr window = Native.GetForegroundWindow();
                    _gameWindow = Native.IsWarcraftWindow(window) ? window : IntPtr.Zero;
                }
                MouseButton(button, down);
                if (down) _heldButtons.Add(button);
                else _heldButtons.Remove(button);
                if (_heldButtons.Count == 0) _gameWindow = IntPtr.Zero;
                return;
            }
            if (op == "wheel")
            {
                int delta = GetInt(payload, "delta");
                bool horizontal = GetBool(payload, "horizontal");
                Native.mouse_event(horizontal ? Native.MOUSEEVENTF_HWHEEL : Native.MOUSEEVENTF_WHEEL, 0, 0, delta, UIntPtr.Zero);
                return;
            }
            if (op == "key")
            {
                int vk = GetInt(payload, "vk");
                bool down = GetBool(payload, "down");
                KeyEvent(vk, down);
                if (down) _heldKeys.Add(vk);
                else _heldKeys.Remove(vk);
                return;
            }
            if (op == "text")
            {
                TypeText(GetString(payload, "text"));
                return;
            }
            throw new InvalidOperationException("unknown op: " + op);
        }

        private static void MouseButton(string button, bool down)
        {
            string name = String.IsNullOrEmpty(button) ? "left" : button.ToLowerInvariant();
            uint flag;
            if (name == "right") flag = down ? Native.MOUSEEVENTF_RIGHTDOWN : Native.MOUSEEVENTF_RIGHTUP;
            else if (name == "middle") flag = down ? Native.MOUSEEVENTF_MIDDLEDOWN : Native.MOUSEEVENTF_MIDDLEUP;
            else flag = down ? Native.MOUSEEVENTF_LEFTDOWN : Native.MOUSEEVENTF_LEFTUP;
            Native.mouse_event(flag, 0, 0, 0, UIntPtr.Zero);
        }

        private static void KeyEvent(int vk, bool down)
        {
            if (vk <= 0 || vk > 255) throw new InvalidOperationException("invalid virtual key: " + vk);
            uint scan = Native.MapVirtualKey((uint)vk, 4); // MAPVK_VK_TO_VSC_EX
            Native.INPUT[] inputs = new Native.INPUT[1];
            inputs[0].type = Native.INPUT_KEYBOARD;
            inputs[0].U.ki.wVk = (ushort)vk;
            inputs[0].U.ki.wScan = (ushort)(scan & 0xff);
            uint flags = down ? 0u : Native.KEYEVENTF_KEYUP;
            if ((scan & 0xff00) == 0xe000) flags |= Native.KEYEVENTF_EXTENDEDKEY;
            inputs[0].U.ki.dwFlags = flags;
            if (Native.SendInput(1, inputs, Marshal.SizeOf(typeof(Native.INPUT))) != 1)
                throw new InvalidOperationException("Windows could not apply keyboard input");
        }

        private static void TypeText(string text)
        {
            if (text == null) return;
            for (int index = 0; index < text.Length; index++)
            {
                char value = text[index];
                if (value == '\r')
                {
                    if (index + 1 < text.Length && text[index + 1] == '\n') continue;
                    KeyEvent(0x0D, true);
                    KeyEvent(0x0D, false);
                }
                else if (value == '\n')
                {
                    KeyEvent(0x0D, true);
                    KeyEvent(0x0D, false);
                }
                else if (value == '\t')
                {
                    KeyEvent(0x09, true);
                    KeyEvent(0x09, false);
                }
                else if (value == '\b')
                {
                    KeyEvent(0x08, true);
                    KeyEvent(0x08, false);
                }
                else
                {
                    Native.SendUnicodeChar(value);
                }
                Thread.Sleep(2);
            }
        }

        private static string GetString(Dictionary<string, object> payload, string key)
        {
            object value;
            if (!payload.TryGetValue(key, out value) || value == null) return "";
            return Convert.ToString(value);
        }

        private static int GetInt(Dictionary<string, object> payload, string key)
        {
            object value;
            if (!payload.TryGetValue(key, out value) || value == null) return 0;
            return Convert.ToInt32(value);
        }

        private static object GetValue(Dictionary<string, object> payload, string key)
        {
            object value;
            if (!payload.TryGetValue(key, out value)) return null;
            return value;
        }

        private static bool GetBool(Dictionary<string, object> payload, string key)
        {
            object value;
            if (!payload.TryGetValue(key, out value) || value == null) return false;
            if (value is bool) return (bool)value;
            bool parsed;
            return Boolean.TryParse(Convert.ToString(value), out parsed) && parsed;
        }
    }

    /// <summary>
    /// Small always-on-top control window. The DSH panel is only a client: this
    /// window is the authority on the Windows side, so when something goes wrong
    /// the user can stop the agent from the machine being controlled instead of
    /// hunting for a hidden background process.
    /// </summary>
    public sealed class ControlWindow : Form
    {
        private readonly AgentServer _server;
        private readonly System.Windows.Forms.Timer _timer;
        private readonly Label _status;
        private readonly Label _counters;
        private readonly Label _token;

        public ControlWindow(AgentServer server)
        {
            _server = server;
            Text = "LanKvm — Windows 接收端";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 330);
            TopMost = true;
            BackColor = Color.FromArgb(24, 26, 32);
            ForeColor = Color.Gainsboro;
            Font = new Font("Microsoft YaHei UI", 9F);

            Label heading = new Label();
            heading.Text = "LanKvm — Windows 接收端";
            heading.Font = new Font("Microsoft YaHei UI", 12F, FontStyle.Bold);
            heading.ForeColor = Color.FromArgb(120, 190, 255);
            heading.SetBounds(18, 14, 520, 26);
            Controls.Add(heading);

            Label hint = new Label();
            hint.Text = "LanKvm 运行期间，Mac 可以控制这台电脑。\n"
                + "点「停止接管」或直接关闭本窗口，即可夺回控制权。";
            hint.SetBounds(18, 44, 520, 36);
            hint.ForeColor = Color.Silver;
            Controls.Add(hint);

            _status = NewValue("状态：正在启动", 18, 88, 520, 22);
            _counters = NewValue("", 18, 112, 520, 22);
            _token = NewValue("", 18, 136, 520, 22);

            Label addressLabel = new Label();
            addressLabel.Text = "在 Mac 端填入下面的地址和令牌：";
            addressLabel.SetBounds(18, 170, 520, 20);
            addressLabel.ForeColor = Color.Silver;
            Controls.Add(addressLabel);

            TextBox address = new TextBox();
            address.ReadOnly = true;
            address.SetBounds(18, 192, 520, 24);
            address.BackColor = Color.FromArgb(32, 34, 40);
            address.ForeColor = Color.White;
            address.BorderStyle = BorderStyle.FixedSingle;
            address.Text = BuildAddressHint(server);
            Controls.Add(address);

            Button toggle = new Button();
            toggle.Text = "关闭打字隐藏指针";
            toggle.SetBounds(18, 228, 170, 30);
            toggle.Click += delegate
            {
                bool ok = _server.DisablePointerVanish();
                toggle.Text = ok ? "已关闭打字隐藏指针" : "无法修改该设置";
                toggle.Enabled = false;
            };
            Controls.Add(toggle);

            Button startup = new Button();
            startup.Text = "开机自动启动";
            startup.SetBounds(318, 228, 100, 30);
            startup.Click += delegate
            {
                bool ok = Autostart.Enable(Application.ExecutablePath);
                startup.Text = ok ? "已设为开机启动" : "无法设置开机启动";
                startup.Enabled = false;
            };
            Controls.Add(startup);

            Button copy = new Button();
            copy.Text = "复制令牌";
            copy.SetBounds(198, 228, 110, 30);
            copy.Click += delegate
            {
                try { Clipboard.SetText(_server.Token); copy.Text = "已复制"; }
                catch { copy.Text = "复制失败"; }
            };
            Controls.Add(copy);

            Button stop = new Button();
            stop.Text = "停止接管";
            stop.SetBounds(428, 228, 110, 30);
            stop.BackColor = Color.FromArgb(180, 70, 70);
            stop.ForeColor = Color.White;
            stop.FlatStyle = FlatStyle.Flat;
            stop.Click += delegate
            {
                _server.Stop();
                Close();
            };
            Controls.Add(stop);

            Label firewall = new Label();
            firewall.Text = "如果 Mac 连不上，请放行入站 TCP "
                + server.Port + " 和 " + server.InputPort + "（专用网络）。";
            firewall.SetBounds(18, 268, 520, 44);
            firewall.ForeColor = Color.FromArgb(170, 170, 110);
            Controls.Add(firewall);

            _timer = new System.Windows.Forms.Timer();
            _timer.Interval = 1000;
            _timer.Tick += delegate { RefreshStatus(); };
            _timer.Start();
            FormClosing += delegate { _server.Stop(); };
            RefreshStatus();
        }

        private Label NewValue(string text, int x, int y, int width, int height)
        {
            Label label = new Label();
            label.Text = text;
            label.SetBounds(x, y, width, height);
            Controls.Add(label);
            return label;
        }

        private static string BuildAddressHint(AgentServer server)
        {
            StringBuilder builder = new StringBuilder();
            try
            {
                IPAddress[] addresses = Dns.GetHostAddresses(Dns.GetHostName());
                for (int index = 0; index < addresses.Length; index++)
                {
                    if (addresses[index].AddressFamily != AddressFamily.InterNetwork) continue;
                    if (IPAddress.IsLoopback(addresses[index])) continue;
                    if (builder.Length > 0) builder.Append("   |   ");
                    builder.Append(addresses[index]).Append(':').Append(server.Port);
                }
            }
            catch { }
            if (builder.Length == 0) builder.Append("请用 ipconfig 查看本机 IPv4 地址");
            return builder.ToString();
        }

        private void RefreshStatus()
        {
            bool running = _server.IsRunning;
            _status.Text = running ? "状态：正在监听" : "状态：已停止";
            _status.ForeColor = running ? Color.FromArgb(120, 220, 140) : Color.FromArgb(230, 120, 120);
            _counters.Text = "键鼠事件：" + _server.InputEvents
                + "     剪贴板传输：" + _server.ClipboardOps
                + "     输入端口：" + _server.InputPort
                + "     剪贴板轮询：" + _server.ClipboardPolls;
            _token.Text = "令牌：" + _server.Token;
        }
    }

    /// <summary>
    /// Registers LanKvm in HKCU\Run so it starts with the user's session.
    /// HKCU needs no administrator rights, unlike a scheduled task.
    /// </summary>
    internal static class Autostart
    {
        private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
        private const string ValueName = "LanKvm";

        public static bool Enable(string executablePath)
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key =
                    Microsoft.Win32.Registry.CurrentUser.CreateSubKey(RunKey))
                {
                    if (key == null) return false;
                    key.SetValue(ValueName, "\"" + executablePath + "\"");
                }
                return true;
            }
            catch { return false; }
        }

        public static bool IsEnabled()
        {
            try
            {
                using (Microsoft.Win32.RegistryKey key =
                    Microsoft.Win32.Registry.CurrentUser.OpenSubKey(RunKey))
                {
                    return key != null && key.GetValue(ValueName) != null;
                }
            }
            catch { return false; }
        }
    }

    /// <summary>
    /// Program entry point. Standalone Windows receiver: no PowerShell, no DSH,
    /// no Node. The window owns the main thread so it stays closable, which is
    /// the user's guaranteed way to take control back.
    /// </summary>
    internal static class Program
    {
        [STAThread]
        private static void Main(string[] args)
        {
            int port = 7681;
            string token = null;
            bool headless = false;

            for (int index = 0; index < args.Length; index++)
            {
                string argument = args[index];
                if ((argument == "-Port" || argument == "--port") && index + 1 < args.Length)
                {
                    int parsed;
                    if (Int32.TryParse(args[++index], out parsed) && parsed >= 1024 && parsed <= 65535)
                    {
                        port = parsed;
                    }
                }
                else if ((argument == "-Token" || argument == "--token") && index + 1 < args.Length)
                {
                    token = args[++index];
                }
                else if (argument == "-Headless" || argument == "--headless")
                {
                    headless = true;
                }
                else if (argument == "-Help" || argument == "--help" || argument == "/?")
                {
                    Console.WriteLine("LanKvm — 供 Mac 使用的 Windows 接收端");
                    Console.WriteLine("  LanKvm.exe [-Port 7681] [-Token ABC123] [-Headless]");
                    return;
                }
            }

            token = RememberedToken.Load(token);
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);

            AgentServer server;
            try
            {
                server = new AgentServer(port, token);
                server.StartInBackground();
            }
            catch (Exception error)
            {
                MessageBox.Show(
                    "LanKvm 无法在端口 " + port + " 上启动：\r\n\r\n" + error.Message,
                    "LanKvm",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error);
                return;
            }

            if (headless)
            {
                Console.WriteLine("LanKvm listening on TCP " + server.Port + " (input " + server.InputPort + ")");
                Console.WriteLine("Token: " + server.Token);
                Console.WriteLine("Press Ctrl+C to stop.");
                Application.Run(new ApplicationContext());
            }
            else
            {
                Application.Run(new ControlWindow(server));
            }
            server.Stop();
        }
    }

    /// <summary>
    /// Keeps the token stable across restarts. Without this the Mac would have
    /// to be reconfigured every time the receiver is restarted.
    /// </summary>
    internal static class RememberedToken
    {
        private static string TokenPath
        {
            get
            {
                string directory = System.IO.Path.Combine(
                    Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
                    "LanKvm");
                Directory.CreateDirectory(directory);
                return System.IO.Path.Combine(directory, "token.txt");
            }
        }

        public static string Load(string supplied)
        {
            if (!String.IsNullOrWhiteSpace(supplied)) return supplied;
            try
            {
                if (File.Exists(TokenPath))
                {
                    string existing = File.ReadAllText(TokenPath).Trim();
                    if (existing.Length >= 6) return existing;
                }
            }
            catch { }

            string created = Create();
            try { File.WriteAllText(TokenPath, created); }
            catch { }
            return created;
        }

        private static string Create()
        {
            byte[] bytes = new byte[5];
            using (System.Security.Cryptography.RandomNumberGenerator rng =
                System.Security.Cryptography.RandomNumberGenerator.Create())
            {
                rng.GetBytes(bytes);
            }
            StringBuilder builder = new StringBuilder();
            for (int index = 0; index < bytes.Length; index++) builder.Append(bytes[index].ToString("X2"));
            return builder.ToString();
        }
    }
}
