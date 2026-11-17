using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;

namespace WiFi
{
    public sealed class WebCommand
    {
        public readonly string Name;
        public readonly string Value;

        internal WebCommand(string name, string value)
        {
            Name = name;
            Value = value;
        }
    }

    // Small HTTP/1.1 endpoint for the fixed, local dashboard routes.
    public sealed class WebServer : IDisposable
    {
        private readonly TcpListener listener;
        private readonly Thread thread;
        private readonly Dictionary<string, Asset> assets;
        private readonly ConcurrentQueue<WebCommand> commands = new ConcurrentQueue<WebCommand>();
        private readonly string host;
        private volatile byte[] state = Encoding.UTF8.GetBytes("{}");
        private volatile bool stopped;

        private sealed class Asset
        {
            internal readonly string Type;
            internal readonly byte[] Bytes;
            internal Asset(string type, string file)
            {
                Type = type;
                Bytes = File.ReadAllBytes(file);
            }
        }

        public string Address { get; private set; }

        public WebServer(string root)
        {
            assets = new Dictionary<string, Asset>(StringComparer.Ordinal)
            {
                { "/", new Asset("text/html; charset=utf-8", Path.Combine(root, "index.html")) },
                { "/app.css", new Asset("text/css; charset=utf-8", Path.Combine(root, "app.css")) },
                { "/app.js", new Asset("text/javascript; charset=utf-8", Path.Combine(root, "app.js")) }
            };
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start(16);
            host = "127.0.0.1:" + ((IPEndPoint)listener.LocalEndpoint).Port;
            Address = "http://" + host;
            thread = new Thread(Serve) { IsBackground = true, Name = "Wi Fi HTTP" };
            thread.Start();
        }

        public void SetState(string json) { state = Encoding.UTF8.GetBytes(json); }

        public WebCommand TakeCommand()
        {
            WebCommand command;
            return commands.TryDequeue(out command) ? command : null;
        }

        private void Serve()
        {
            while (!stopped)
            {
                try
                {
                    using (TcpClient client = listener.AcceptTcpClient())
                    {
                        client.ReceiveTimeout = 900;
                        client.SendTimeout = 900;
                        using (NetworkStream stream = client.GetStream()) { Respond(stream); }
                    }
                }
                catch (IOException) { }
                catch (SocketException) { if (stopped) { return; } }
                catch (ObjectDisposedException) { return; }
            }
        }

        private void Respond(NetworkStream stream)
        {
            var buffer = new byte[8192];
            var total = 0;
            var headerEnd = -1;
            var deadline = DateTime.UtcNow.AddSeconds(2);
            while (total < buffer.Length && headerEnd < 0 && DateTime.UtcNow < deadline)
            {
                var oldTotal = total;
                int read = stream.Read(buffer, total, buffer.Length - total);
                if (read == 0) { return; }
                total += read;
                for (int i = Math.Max(0, oldTotal - 3); i + 3 < total; i++)
                {
                    if (buffer[i] == 13 && buffer[i + 1] == 10 && buffer[i + 2] == 13 && buffer[i + 3] == 10)
                    {
                        headerEnd = i;
                        break;
                    }
                }
            }
            if (headerEnd < 0) { return; }
            string[] lines = Encoding.ASCII.GetString(buffer, 0, headerEnd).Split(new[] { "\r\n" }, StringSplitOptions.None);
            string[] request = lines[0].Split(' ');
            if (request.Length != 3 || request[2] != "HTTP/1.1" || !request[1].StartsWith("/", StringComparison.Ordinal))
            {
                Send(stream, "400 Bad Request", "text/plain", new byte[0]);
                return;
            }

            var headers = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (int i = 1; i < lines.Length; i++)
            {
                int separator = lines[i].IndexOf(':');
                if (separator < 1) { Send(stream, "400 Bad Request", "text/plain", new byte[0]); return; }
                string key = lines[i].Substring(0, separator);
                if (headers.ContainsKey(key)) { Send(stream, "400 Bad Request", "text/plain", new byte[0]); return; }
                headers.Add(key, lines[i].Substring(separator + 1).Trim());
            }

            string requestHost, origin, length, fetchSite, dashboardHeader;
            headers.TryGetValue("Origin", out origin);
            headers.TryGetValue("Sec-Fetch-Site", out fetchSite);
            if (!headers.TryGetValue("Host", out requestHost) || requestHost != host ||
                (origin != null && origin != Address) || fetchSite == "cross-site" ||
                headers.ContainsKey("Transfer-Encoding") || (headers.TryGetValue("Content-Length", out length) && length != "0"))
            {
                Send(stream, "403 Forbidden", "text/plain", new byte[0]);
                return;
            }

            string target = request[1];
            if (request[0] == "GET")
            {
                Asset asset;
                if (target == "/api/state")
                {
                    Send(stream, "200 OK", "application/json; charset=utf-8", state);
                    return;
                }
                if (assets.TryGetValue(target, out asset))
                {
                    Send(stream, "200 OK", asset.Type, asset.Bytes);
                    return;
                }
            }
            else if (request[0] == "POST" &&
                (origin == Address || (origin == null && fetchSite == "same-origin")) &&
                headers.TryGetValue("X-WiFi-Dashboard", out dashboardHeader) && dashboardHeader == "1")
            {
                int query = target.IndexOf('?');
                string path = query < 0 ? target : target.Substring(0, query);
                if ((path == "/api/refresh" || path == "/api/home" || path == "/api/track") && commands.Count < 32)
                {
                    string value = query < 0 ? String.Empty : Uri.UnescapeDataString(target.Substring(query + 1));
                    if (value.Length <= 64)
                    {
                        commands.Enqueue(new WebCommand(path.Substring(5), value));
                        Send(stream, "204 No Content", "text/plain", new byte[0]);
                        return;
                    }
                }
            }
            Send(stream, "404 Not Found", "text/plain", new byte[0]);
        }

        private static void Send(NetworkStream stream, string status, string type, byte[] content)
        {
            byte[] header = Encoding.ASCII.GetBytes(
                "HTTP/1.1 " + status + "\r\nConnection: close\r\nCache-Control: no-store\r\nContent-Type: " + type +
                "\r\nContent-Length: " + content.Length + "\r\nX-Content-Type-Options: nosniff\r\n" +
                "Content-Security-Policy: default-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'\r\n\r\n");
            stream.Write(header, 0, header.Length);
            if (content.Length > 0) { stream.Write(content, 0, content.Length); }
        }

        public void Dispose()
        {
            stopped = true;
            listener.Stop();
            thread.Join(2500);
        }
    }
}
