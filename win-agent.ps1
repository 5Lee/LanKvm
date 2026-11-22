# DSH LAN KVM - Windows agent
#
# Run this on the Windows PC that should receive keyboard and mouse input:
#
#   powershell -ExecutionPolicy Bypass -File .\win-agent.ps1 -Port 7681
#
# Keep the window open. The script prints the address and token to enter in the
# DSH "LAN KVM" panel. It uses only built-in Windows PowerShell 5.1 APIs; no
# Node.js, Python, or npm package is required.
#
# This is a LAN tool. The token is required for every request. Do not expose the
# port to the public internet.

#requires -version 5.1
[CmdletBinding()]
param(
  [ValidateRange(1024, 65535)]
  [int]$Port = 7681,

  [string]$Token = '',

  [switch]$CompileOnly,

  # Run without the control window, for a scheduled task or a headless session.
  [switch]$Headless
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Token)) {
  $bytes = New-Object byte[] 5
  $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
  $rng.GetBytes($bytes)
  $Token = -join ($bytes | ForEach-Object { $_.ToString('X2') })
}
$Token = ($Token -replace '[^A-Za-z0-9_-]', '')
if ($Token.Length -lt 6) {
  throw 'Token must contain at least 6 letters, digits, "-" or "_".'
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.Web.Extensions

# The control window and the clipboard both need an STA thread.
if ([System.Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
  $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', $PSCommandPath,
                 '-Port', $Port, '-Token', $Token)
  if ($CompileOnly) { $arguments += '-CompileOnly' }
  if ($Headless)    { $arguments += '-Headless' }
  Start-Process powershell -ArgumentList $arguments
  exit 0
}

$source = @'
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

namespace DshLanKvm
{
    public static class Native
    {
        public const uint MOUSEEVENTF_MOVE = 0x0001;
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
        public static extern void keybd_event(byte virtualKey, byte scanCode, uint flags, UIntPtr extraInfo);

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
        private volatile bool _backgroundStarted;
        private static readonly object CaptureLock = new object();
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
                listener = new TcpListener(IPAddress.Any, _inputPort);
                listener.Start();
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
                        ApplyInput(line);
                        Interlocked.Increment(ref _inputEvents);
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
                try { client.Close(); } catch { }
            }
        }

        public void Stop()
        {
            _running = false;
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

                if (method == "GET" && path == "/api/clipboard")
                {
                    uint since = 0;
                    string sinceValue = QueryValue(uri.Query, "since");
                    if (sinceValue != null) UInt32.TryParse(sinceValue, out since);
                    try
                    {
                        Interlocked.Increment(ref _clipboardOps);
                        WriteResponse(stream, 200, "application/json; charset=utf-8", Encoding.UTF8.GetBytes(ClipboardJson(since)));
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
                if (method == "GET" && path == "/api/shot")
                {
                    try
                    {
                        byte[] jpeg = CaptureJpeg(58);
                        WriteResponse(stream, 200, "image/jpeg", jpeg);
                    }
                    catch (Exception error)
                    {
                        WriteResponse(stream, 503, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes("capture failed: " + error.Message));
                    }
                    return;
                }
                if (method == "POST" && path == "/api/input")
                {
                    try
                    {
                        ApplyInput(body);
                        Interlocked.Increment(ref _inputEvents);
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
            json.Append("{\"ok\":true,\"agent\":\"dsh-lan-kvm\",\"version\":2,");
            json.Append("\"machine\":").Append(Quote(Environment.MachineName)).Append('}');
            return json.ToString();
        }

        private static string PingJson()
        {
            Rectangle bounds = SystemInformation.VirtualScreen;
            StringBuilder json = new StringBuilder();
            json.Append("{\"ok\":true,\"agent\":\"dsh-lan-kvm\",\"version\":2,");
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

        private static byte[] CaptureJpeg(int quality)
        {
            lock (CaptureLock)
            {
                Rectangle bounds = SystemInformation.VirtualScreen;
                using (Bitmap bitmap = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format24bppRgb))
                {
                    using (Graphics graphics = Graphics.FromImage(bitmap))
                    {
                        graphics.CopyFromScreen(bounds.Left, bounds.Top, 0, 0, bounds.Size, CopyPixelOperation.SourceCopy);
                    }
                    ImageCodecInfo codec = null;
                    foreach (ImageCodecInfo candidate in ImageCodecInfo.GetImageEncoders())
                    {
                        if (candidate.FormatID == ImageFormat.Jpeg.Guid)
                        {
                            codec = candidate;
                            break;
                        }
                    }
                    if (codec == null) throw new InvalidOperationException("JPEG encoder is unavailable");
                    using (EncoderParameters parameters = new EncoderParameters(1))
                    {
                        parameters.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, (long)quality);
                        using (MemoryStream memory = new MemoryStream())
                        {
                            bitmap.Save(memory, codec, parameters);
                            return memory.ToArray();
                        }
                    }
                }
            }
        }

        private static bool OpenClipboardWithRetry()
        {
            for (int attempt = 0; attempt < 30; attempt++)
            {
                if (Native.OpenClipboard(IntPtr.Zero)) return true;
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

        /// <summary>Copied files as a JSON array of name plus base64 bytes.</summary>
        private static string ReadClipboardFilesJson()
        {
            string[] paths = ReadClipboardFiles();
            if (paths == null || paths.Length == 0) return null;
            StringBuilder json = new StringBuilder();
            json.Append('[');
            bool first = true;
            long total = 0;
            const long limit = 128L * 1024 * 1024;
            foreach (string path in paths)
            {
                if (String.IsNullOrEmpty(path)) continue;
                if (Directory.Exists(path)) continue;
                if (!File.Exists(path)) continue;
                FileInfo info = new FileInfo(path);
                if (info.Length > limit) return null;
                total += info.Length;
                if (total > limit) return null;
                byte[] bytes = File.ReadAllBytes(path);
                if (!first) json.Append(',');
                first = false;
                json.Append("{\"name\":").Append(Quote(Path.GetFileName(path)));
                json.Append(",\"data\":").Append(Quote(Convert.ToBase64String(bytes))).Append('}');
            }
            json.Append(']');
            return first ? null : json.ToString();
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

        private static string ClipboardJson(uint since)
        {
            uint sequence = Native.GetClipboardSequenceNumber();
            if (sequence == since)
            {
                return "{\"ok\":true,\"seq\":" + sequence + ",\"unchanged\":true}";
            }

            string kind = "none";
            string text = null;
            string image = null;
            string files = null;
            string error = null;
            if (OpenClipboardWithRetry())
            {
                try
                {
                    files = ReadClipboardFilesJson();
                    if (files != null)
                    {
                        // A file copy also carries a text path and often an icon
                        // bitmap, so it must be checked before both.
                        kind = "files";
                    }
                    else
                    {
                        image = ReadClipboardImagePng();
                        if (image != null)
                        {
                            kind = "image";
                        }
                        else
                        {
                            text = ReadClipboardText();
                            if (text != null && text.Length <= 33554432)
                            {
                                kind = "text";
                            }
                            else
                            {
                                text = null;
                            }
                        }
                    }
                }
                catch (Exception caught)
                {
                    error = caught.Message;
                }
                finally
                {
                    Native.CloseClipboard();
                }
            }
            else
            {
                error = "clipboard is busy";
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

        private static bool SetClipboardText(string text)
        {
            if (!OpenClipboardWithRetry()) return false;
            IntPtr memory = IntPtr.Zero;
            try
            {
                Native.EmptyClipboard();
                int bytes = (text.Length + 1) * 2;
                memory = Native.GlobalAlloc(Native.GMEM_MOVEABLE, (UIntPtr)bytes);
                if (memory == IntPtr.Zero) return false;
                IntPtr locked = Native.GlobalLock(memory);
                if (locked == IntPtr.Zero) return false;
                try
                {
                    char[] chars = text.ToCharArray();
                    Marshal.Copy(chars, 0, locked, chars.Length);
                    Marshal.WriteInt16(locked, chars.Length * 2, 0);
                }
                finally { Native.GlobalUnlock(memory); }
                if (Native.SetClipboardData(Native.CF_UNICODETEXT, memory) == IntPtr.Zero) return false;
                memory = IntPtr.Zero;
                return true;
            }
            finally
            {
                if (memory != IntPtr.Zero) Native.GlobalFree(memory);
                Native.CloseClipboard();
            }
        }

        /// <summary>
        /// Writes received files to disk and publishes them as a CF_HDROP file
        /// list, which is what Explorer pastes.
        /// </summary>
        private static bool SetClipboardFiles(object filesValue)
        {
            System.Collections.IEnumerable list = filesValue as System.Collections.IEnumerable;
            if (list == null) return false;
            string directory = Path.Combine(Path.GetTempPath(), "dsh-lan-kvm-paste");
            Directory.CreateDirectory(directory);
            List<string> written = new List<string>();
            foreach (object entry in list)
            {
                Dictionary<string, object> file = entry as Dictionary<string, object>;
                if (file == null) continue;
                string name = GetString(file, "name");
                string data = GetString(file, "data");
                if (String.IsNullOrEmpty(name) || String.IsNullOrEmpty(data)) continue;
                // A crafted name must not escape the paste directory.
                string safeName = Path.GetFileName(name);
                if (String.IsNullOrEmpty(safeName) || safeName == "." || safeName == "..") continue;
                string target = Path.Combine(directory, safeName);
                File.WriteAllBytes(target, Convert.FromBase64String(data));
                written.Add(target);
            }
            if (written.Count == 0) return false;

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
            byte[] blob = payload.ToArray();

            if (!OpenClipboardWithRetry()) return false;
            IntPtr memory = IntPtr.Zero;
            try
            {
                Native.EmptyClipboard();
                memory = Native.GlobalAlloc(Native.GMEM_MOVEABLE, (UIntPtr)blob.Length);
                if (memory == IntPtr.Zero) return false;
                IntPtr locked = Native.GlobalLock(memory);
                if (locked == IntPtr.Zero) return false;
                try { Marshal.Copy(blob, 0, locked, blob.Length); }
                finally { Native.GlobalUnlock(memory); }
                if (Native.SetClipboardData(Native.CF_HDROP, memory) == IntPtr.Zero) return false;
                memory = IntPtr.Zero;
                return true;
            }
            finally
            {
                if (memory != IntPtr.Zero) Native.GlobalFree(memory);
                Native.CloseClipboard();
            }
        }

        private static bool SetClipboardImage(string base64)
        {
            byte[] bytes = Convert.FromBase64String(base64);
            using (MemoryStream input = new MemoryStream(bytes))
            using (Image source = Image.FromStream(input))
            using (Bitmap picture = new Bitmap(source))
            {
                IntPtr bitmap = picture.GetHbitmap();
                if (bitmap == IntPtr.Zero) return false;
                if (!OpenClipboardWithRetry())
                {
                    Native.DeleteObject(bitmap);
                    return false;
                }
                try
                {
                    Native.EmptyClipboard();
                    if (Native.SetClipboardData(Native.CF_BITMAP, bitmap) == IntPtr.Zero)
                    {
                        Native.DeleteObject(bitmap);
                        return false;
                    }
                    bitmap = IntPtr.Zero;
                    return true;
                }
                finally
                {
                    if (bitmap != IntPtr.Zero) Native.DeleteObject(bitmap);
                    Native.CloseClipboard();
                }
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
            else if (kind == "files") ok = SetClipboardFiles(GetValue(payload, "files"));
            else throw new InvalidOperationException("unsupported clipboard kind: " + kind);
            if (!ok) throw new InvalidOperationException("clipboard is busy");
        }

        private static string CursorJson()
        {
            Native.POINT point;
            Native.GetCursorPos(out point);
            return "{\"ok\":true,\"x\":" + point.X + ",\"y\":" + point.Y + "}";
        }

        private static void ApplyInput(string body)
        {
            Dictionary<string, object> payload = Serializer.Deserialize<Dictionary<string, object>>(body);
            if (payload == null) throw new InvalidOperationException("missing JSON body");
            ApplyCommand(payload);
        }

        private static void ApplyCommand(Dictionary<string, object> payload)
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
                    // Accumulate on top of the real position and set it
                    // absolutely. Relative mouse_event input would be scaled by
                    // Windows pointer acceleration, so one Mac pixel would move
                    // the remote pointer by up to ~2.5, and the two cursors
                    // would drift apart.
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
                MouseButton(GetString(payload, "button"), op == "down");
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
            uint flags = down ? 0u : Native.KEYEVENTF_KEYUP;
            if (IsExtendedKey(vk)) flags |= Native.KEYEVENTF_EXTENDEDKEY;
            Native.keybd_event((byte)vk, 0, flags, UIntPtr.Zero);
        }

        private static bool IsExtendedKey(int vk)
        {
            // The navigation cluster, the right-hand modifiers and the numpad
            // divide are extended. VK_LWIN (0x5B) is deliberately NOT: only the
            // right Windows key (0x5C) carries the extended prefix.
            return (vk >= 0x21 && vk <= 0x2E) || vk == 0x5C || vk == 0x6F || vk == 0x90 || vk == 0x91;
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
            Text = "DSH LAN KVM - Windows agent";
            FormBorderStyle = FormBorderStyle.FixedDialog;
            MaximizeBox = false;
            MinimizeBox = true;
            StartPosition = FormStartPosition.CenterScreen;
            ClientSize = new Size(560, 330);
            TopMost = true;
            BackColor = Color.FromArgb(24, 26, 32);
            ForeColor = Color.Gainsboro;
            Font = new Font("Segoe UI", 9F);

            Label heading = new Label();
            heading.Text = "DSH LAN KVM - Windows agent";
            heading.Font = new Font("Segoe UI", 12F, FontStyle.Bold);
            heading.ForeColor = Color.FromArgb(120, 190, 255);
            heading.SetBounds(18, 14, 520, 26);
            Controls.Add(heading);

            Label hint = new Label();
            hint.Text = "The Mac controls this PC while the agent is running.\n"
                + "Click Stop agent (or close this window) to take control back here.";
            hint.SetBounds(18, 44, 520, 36);
            hint.ForeColor = Color.Silver;
            Controls.Add(hint);

            _status = NewValue("Status: starting", 18, 88, 520, 22);
            _counters = NewValue("", 18, 112, 520, 22);
            _token = NewValue("", 18, 136, 520, 22);

            Label addressLabel = new Label();
            addressLabel.Text = "Connect from DSH with this address and token:";
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
            toggle.Text = "Disable pointer hiding";
            toggle.SetBounds(18, 228, 170, 30);
            toggle.Click += delegate
            {
                bool ok = _server.DisablePointerVanish();
                toggle.Text = ok ? "Pointer hiding disabled" : "Could not change setting";
                toggle.Enabled = false;
            };
            Controls.Add(toggle);

            Button copy = new Button();
            copy.Text = "Copy token";
            copy.SetBounds(198, 228, 110, 30);
            copy.Click += delegate
            {
                try { Clipboard.SetText(_server.Token); copy.Text = "Copied"; }
                catch { copy.Text = "Copy failed"; }
            };
            Controls.Add(copy);

            Button stop = new Button();
            stop.Text = "Stop agent";
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
            firewall.Text = "If the Mac cannot connect, allow inbound TCP "
                + server.Port + " and " + server.InputPort + " for Private networks.";
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
            if (builder.Length == 0) builder.Append("run ipconfig to find this PC's IPv4 address");
            return builder.ToString();
        }

        private void RefreshStatus()
        {
            bool running = _server.IsRunning;
            _status.Text = running ? "Status: listening" : "Status: stopped";
            _status.ForeColor = running ? Color.FromArgb(120, 220, 140) : Color.FromArgb(230, 120, 120);
            _counters.Text = "Input events: " + _server.InputEvents
                + "     Clipboard operations: " + _server.ClipboardOps
                + "     Stream port: " + _server.InputPort;
            _token.Text = "Token: " + _server.Token;
        }
    }
}
'@

$referenceAssemblies = @(
  [System.Windows.Forms.Form].Assembly.Location,
  [System.Drawing.Bitmap].Assembly.Location,
  [System.Web.HttpUtility].Assembly.Location,
  [System.Web.Script.Serialization.JavaScriptSerializer].Assembly.Location
)

Add-Type -TypeDefinition $source -ReferencedAssemblies $referenceAssemblies

if ($CompileOnly) {
  Write-Host 'Windows agent compile OK.'
  exit 0
}

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$agent = New-Object DshLanKvm.AgentServer($Port, $Token)

Write-Host ''
Write-Host '  DSH LAN KVM - Windows agent' -ForegroundColor Cyan
Write-Host '  ----------------------------' -ForegroundColor DarkCyan
Write-Host ("  HTTP port:   {0}" -f $Port)
Write-Host ("  Input stream: {0}" -f ($Port + 1)) -ForegroundColor DarkCyan
Write-Host ("  Token:       {0}" -f $Token) -ForegroundColor Yellow
Write-Host ''

$addresses = @()
try {
  $addresses = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
    Where-Object { $_.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork -and -not $_.IsLoopback } |
    ForEach-Object { $_.IPAddressToString }
} catch { }

if ($addresses.Count -eq 0) {
  Write-Host '  Address: check this PC''s IPv4 address with ipconfig' -ForegroundColor Yellow
} else {
  foreach ($address in $addresses) {
    Write-Host ("  Address: {0}:{1}" -f $address, $Port) -ForegroundColor Green
  }
}

Write-Host ''
Write-Host '  Enter the address (just the IP) and token in the DSH LAN KVM panel.' -ForegroundColor Gray
Write-Host '  Copy only the characters after "Token:" - not the label itself.' -ForegroundColor Gray
Write-Host '  Keep this window open while using the remote control.' -ForegroundColor Gray
Write-Host ''
Write-Host '  If macOS cannot connect, allow TCP ports ' -NoNewline -ForegroundColor DarkYellow
Write-Host ("{0} and {1}" -f $Port, ($Port + 1)) -NoNewline -ForegroundColor Yellow
Write-Host ' in Windows Firewall (Private network).' -ForegroundColor DarkYellow
Write-Host '  Example, in an Administrator PowerShell:' -ForegroundColor DarkGray
Write-Host ("    New-NetFirewallRule -DisplayName 'DSH LAN KVM' -Direction Inbound -Protocol TCP -LocalPort {0},{1} -Action Allow -Profile Private" -f $Port, ($Port + 1)) -ForegroundColor DarkGray
Write-Host ''

if ($Headless) {
  Write-Host '  Running headless. Press Ctrl+C to stop.' -ForegroundColor DarkGray
  Write-Host ''
  try {
    $agent.Run()
  } finally {
    $agent.Stop()
    Write-Host 'Agent stopped.' -ForegroundColor DarkGray
  }
} else {
  Write-Host '  The control window is opening. Use its "Stop agent" button to stop.' -ForegroundColor Gray
  Write-Host ''
  # The window owns the main thread so it stays responsive and closable.
  $agent.StartInBackground()
  $window = New-Object DshLanKvm.ControlWindow($agent)
  [void]$window.ShowDialog()
  $agent.Stop()
  Write-Host 'Agent stopped.' -ForegroundColor DarkGray
}
