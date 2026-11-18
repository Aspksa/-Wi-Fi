using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

[assembly: DefaultDllImportSearchPaths(DllImportSearchPath.System32)]

namespace WiFi
{
    public sealed class RadioWidth
    {
        public int Width { get; private set; }
        public int Center { get; private set; }
        public int? SecondaryCenter { get; private set; }

        internal RadioWidth(int width, int center, int? secondaryCenter)
        {
            Width = width;
            Center = center;
            SecondaryCenter = secondaryCenter;
        }
    }

    public sealed class RadioCapabilities
    {
        public bool Ht { get; internal set; }
        public bool Vht { get; internal set; }
        public bool He { get; internal set; }
        public bool Eht { get; internal set; }
        public bool Rsn { get; internal set; }
        public bool WifiDirect { get; internal set; }
        public bool Truncated { get; internal set; }
        public int ParsedElements { get; internal set; }
        public string Generation { get { return Eht ? "Wi-Fi 7 capable" :
            He ? "Wi-Fi 6 capable" : Vht ? "Wi-Fi 5 capable" :
            Ht ? "Wi-Fi 4 capable" : "unverified"; } }
    }

    public sealed class RadioPoint
    {
        public string Name { get; internal set; }
        public string Address { get; internal set; }
        public string Band { get; internal set; }
        public int Channel { get; internal set; }
        public int Frequency { get; internal set; }
        public int Signal { get; internal set; }
        public int Rssi { get; internal set; }
        public long? SeenAt { get; internal set; }
        public RadioWidth Width { get; internal set; }
        public RadioCapabilities Capabilities { get; internal set; }
        public bool HiddenSsid { get; internal set; }
    }

    public sealed class RadioScan
    {
        public List<RadioPoint> Points { get; internal set; }
        public string Connected { get; internal set; }
        public bool Completed { get; internal set; }
        public long FinishedAt { get; internal set; }
    }

    public static class NativeScanner
    {
        private const string Library = "wlanapi.dll";
        private const uint AcmSource = 8;
        private const uint ScanComplete = 7;
        private const uint ScanFail = 8;
        private const uint CurrentConnection = 7;
        private const int ConnectedState = 1;
        private const int DisconnectedState = 4;
        private const int HeaderSize = 8;
        private const int InterfaceSize = 532;
        // Windows WLAN_BSS_ENTRY uses 8-byte alignment for timestamps and a 126-element WLAN_RATE_SET.
        private const int BssSize = 360;
        // WLAN_CONNECTION_ATTRIBUTES has two enums and a WCHAR[256] profile
        // before WLAN_ASSOCIATION_ATTRIBUTES, whose BSSID follows SSID and BSS type.
        private const int ConnectionBssidOffset = 2 * 4 + 256 * 2 + 36 + 4;

        [StructLayout(LayoutKind.Sequential)]
        private struct Notification
        {
            internal uint Source;
            internal uint Code;
            internal Guid Interface;
            internal uint Size;
            internal IntPtr Data;
        }

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate void ScanCallback(ref Notification notification, IntPtr context);

        [DllImport(Library)]
        private static extern uint WlanOpenHandle(uint clientVersion, IntPtr reserved, out uint version, out IntPtr client);
        [DllImport(Library)]
        private static extern uint WlanCloseHandle(IntPtr client, IntPtr reserved);
        [DllImport(Library)]
        private static extern uint WlanEnumInterfaces(IntPtr client, IntPtr reserved, out IntPtr list);
        [DllImport(Library)]
        private static extern uint WlanRegisterNotification(IntPtr client, uint source,
            [MarshalAs(UnmanagedType.Bool)] bool ignoreDuplicate, ScanCallback callback, IntPtr context, IntPtr reserved, out uint previousSource);
        [DllImport(Library)]
        private static extern uint WlanScan(IntPtr client, ref Guid adapter, IntPtr ssid, IntPtr ie, IntPtr reserved);
        [DllImport(Library)]
        private static extern uint WlanGetNetworkBssList(IntPtr client, ref Guid adapter, IntPtr ssid, int bssType,
            [MarshalAs(UnmanagedType.Bool)] bool security, IntPtr reserved, out IntPtr list);
        [DllImport(Library)]
        private static extern uint WlanQueryInterface(IntPtr client, ref Guid adapter, uint opcode,
            IntPtr reserved, out uint size, out IntPtr data, IntPtr valueType);
        [DllImport(Library)]
        private static extern void WlanFreeMemory(IntPtr data);

        private static void Check(uint error)
        {
            if (error != 0) { throw new Win32Exception((int)error); }
        }

        private static Guid FindInterface(IntPtr client)
        {
            IntPtr list;
            Check(WlanEnumInterfaces(client, IntPtr.Zero, out list));
            try
            {
                if (list == IntPtr.Zero) { throw new IOException("No WLAN interface list."); }
                int count = Marshal.ReadInt32(list);
                if (count < 0 || count > 128) { throw new IOException("Invalid WLAN interface list."); }
                Guid candidate = Guid.Empty;
                for (int i = 0; i < count; i++)
                {
                    IntPtr entry = IntPtr.Add(list, HeaderSize + i * InterfaceSize);
                    int state = Marshal.ReadInt32(entry, 528);
                    if (state != ConnectedState && state != DisconnectedState) { continue; }
                    Guid id = (Guid)Marshal.PtrToStructure(entry, typeof(Guid));
                    if (state == ConnectedState) { return id; }
                    if (candidate == Guid.Empty) { candidate = id; }
                }
                if (candidate == Guid.Empty) { throw new IOException("No active WLAN adapter."); }
                return candidate;
            }
            finally
            {
                if (list != IntPtr.Zero) { WlanFreeMemory(list); }
            }
        }

        private static string MacAddress(IntPtr entry, int offset)
        {
            var data = new byte[6];
            Marshal.Copy(IntPtr.Add(entry, offset), data, 0, data.Length);
            return BitConverter.ToString(data).Replace('-', ':').ToLowerInvariant();
        }

        private static string FindConnection(IntPtr client, ref Guid adapter)
        {
            IntPtr value;
            uint size;
            uint result = WlanQueryInterface(client, ref adapter, CurrentConnection, IntPtr.Zero, out size, out value, IntPtr.Zero);
            try
            {
                if (result != 0 || value == IntPtr.Zero || size < ConnectionBssidOffset + 6 ||
                    Marshal.ReadInt32(value) != ConnectedState) { return null; }
                return MacAddress(value, ConnectionBssidOffset);
            }
            finally
            {
                if (value != IntPtr.Zero) { WlanFreeMemory(value); }
            }
        }

        public static RadioScan Scan(int timeoutMilliseconds)
        {
            if (timeoutMilliseconds < 0 || timeoutMilliseconds > 4000) { throw new ArgumentOutOfRangeException("timeoutMilliseconds"); }
            IntPtr client;
            uint version;
            Check(WlanOpenHandle(2, IntPtr.Zero, out version, out client));
            var signal = new ManualResetEvent(false);
            ScanCallback callback = null;
            try
            {
                Guid selected = FindInterface(client);
                Guid adapter = selected;
                bool completed = false;
                if (timeoutMilliseconds > 0)
                {
                    int scanStatus = 0;
                    callback = delegate(ref Notification notice, IntPtr context)
                    {
                        if (notice.Source != AcmSource || notice.Interface != selected ||
                            (notice.Code != ScanComplete && notice.Code != ScanFail)) { return; }
                        Interlocked.Exchange(ref scanStatus, notice.Code == ScanComplete ? 1 : -1);
                        signal.Set();
                    };
                    uint previous;
                    Check(WlanRegisterNotification(client, AcmSource, false, callback, IntPtr.Zero, IntPtr.Zero, out previous));
                    Check(WlanScan(client, ref adapter, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero));
                    completed = signal.WaitOne(timeoutMilliseconds) && Interlocked.CompareExchange(ref scanStatus, 0, 0) == 1;
                }
                IntPtr list;
                Check(WlanGetNetworkBssList(client, ref adapter, IntPtr.Zero, 3, false, IntPtr.Zero, out list));
                long finished = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
                try
                {
                    if (list == IntPtr.Zero) { throw new IOException("No WLAN scan results."); }
                    return new RadioScan
                    {
                        Points = ReadBssList(list, Marshal.ReadInt32(list), finished),
                        Connected = FindConnection(client, ref adapter),
                        Completed = completed,
                        FinishedAt = finished
                    };
                }
                finally
                {
                    if (list != IntPtr.Zero) { WlanFreeMemory(list); }
                }
            }
            finally
            {
                // Closing the client also unregisters the callback and waits for dispatch to finish.
                WlanCloseHandle(client, IntPtr.Zero);
                GC.KeepAlive(callback);
                signal.Dispose();
            }
        }

        private static string ReadName(IntPtr row)
        {
            int length = Marshal.ReadInt32(row);
            if (length < 1 || length > 32) { return String.Empty; }
            var bytes = new byte[length];
            Marshal.Copy(IntPtr.Add(row, 4), bytes, 0, length);
            try { return new UTF8Encoding(false, true).GetString(bytes); }
            catch (DecoderFallbackException) { return Encoding.Default.GetString(bytes); }
        }

        private static int ChannelOf(int frequency, out string band)
        {
            band = null;
            if (frequency == 2484) { band = "2.4"; return 14; }
            if (frequency >= 2412 && frequency <= 2472 && (frequency - 2407) % 5 == 0)
            {
                band = "2.4";
                return (frequency - 2407) / 5;
            }
            if (frequency >= 5160 && frequency <= 5885 && frequency % 5 == 0)
            {
                band = "5";
                return (frequency - 5000) / 5;
            }
            return 0;
        }

        private static long? ReadSeenAt(IntPtr row, long finished)
        {
            long fileTime = Marshal.ReadInt64(row, 80);
            // FILETIME ticks are 100 ns since 1601. Some drivers return zero.
            const long UnixEpoch = 116444736000000000L;
            if (fileTime <= UnixEpoch) { return null; }
            long milliseconds = (fileTime - UnixEpoch) / 10000L;
            return milliseconds <= finished + 1500 ? (long?)milliseconds : null;
        }

        internal static List<RadioPoint> ReadBssList(IntPtr list, int size, long finished)
        {
            if (size < HeaderSize || size > 32 * 1024 * 1024) { throw new IOException("Invalid WLAN result size."); }
            int count = Marshal.ReadInt32(list, 4);
            if (count < 0 || count > (size - HeaderSize) / BssSize) { throw new IOException("Invalid WLAN result count."); }
            int tableEnd = HeaderSize + count * BssSize;
            var points = new List<RadioPoint>();
            for (int i = 0; i < count; i++)
            {
                int rowOffset = HeaderSize + i * BssSize;
                IntPtr row = IntPtr.Add(list, rowOffset);
                if (Marshal.ReadInt32(row, 48) != 1) { continue; } // Infrastructure BSS.
                int frequency = Marshal.ReadInt32(row, 92) / 1000;
                string band;
                int channel = ChannelOf(frequency, out band);
                if (channel == 0) { continue; }
                long? seenAt = ReadSeenAt(row, finished);
                if (seenAt.HasValue && finished - seenAt.Value > 90000) { continue; }

                RadioWidth width = null;
                RadioCapabilities caps = new RadioCapabilities();
                int offset = Marshal.ReadInt32(row, 352);
                int length = Marshal.ReadInt32(row, 356);
                if (length > 0 && length <= 4096 && offset >= tableEnd - rowOffset && offset <= size - rowOffset - length)
                {
                    var bytes = new byte[length];
                    Marshal.Copy(IntPtr.Add(row, offset), bytes, 0, length);
                    width = DecodeWidth(bytes, band, channel, frequency);
                    caps = DecodeCapabilities(bytes);
                }
                points.Add(new RadioPoint
                {
                    Name = ReadName(row), Address = MacAddress(row, 40), Band = band, Channel = channel,
                    Frequency = frequency, Signal = Math.Max(0, Math.Min(100, Marshal.ReadInt32(row, 60))),
                    Rssi = Marshal.ReadInt32(row, 56), SeenAt = seenAt, Width = width,
                    HiddenSsid = Marshal.ReadInt32(row) == 0,
                    Capabilities = caps
                });
            }
            return points;
        }

        // Parse only bounded information elements from a BSS entry.
        // An IE describes advertised capabilities, not the generation of the client link.
        public static RadioCapabilities DecodeCapabilities(byte[] bytes)
        {
            var data = new RadioCapabilities();
            if (bytes == null) { return data; }
            if (bytes.Length > 4096) { data.Truncated = true; return data; }
            for (int i = 0; i + 2 <= bytes.Length;)
            {
                int id = bytes[i++];
                int length = bytes[i++];
                if (length > bytes.Length - i) { data.Truncated = true; break; }
                data.ParsedElements++;
                if (id == 45 || id == 61) { data.Ht = true; }
                if (id == 191 || id == 192) { data.Vht = true; }
                if (id == 48) { data.Rsn = true; }
                if (id == 255 && length >= 2)
                {
                    // 802.11 extended IE identifiers: HE Capabilities/Operation 35/36,
                    // EHT Operation 106, EHT Capabilities 108.
                    int ext = bytes[i];
                    if (ext == 35 || ext == 36) { data.He = true; }
                    if (ext == 106 || ext == 108) { data.Eht = true; }
                }
                if (id == 221 && length >= 4 &&
                    bytes[i] == 0x50 && bytes[i + 1] == 0x6f &&
                    bytes[i + 2] == 0x9a && bytes[i + 3] == 0x09)
                {
                    data.WifiDirect = true; // P2P vendor IE, not confirmed device discovery.
                }
                i += length;
            }
            if (bytes.Length > 0 && data.ParsedElements == 0) { data.Truncated = true; }
            return data;
        }

        private static int SegmentFrequency(string band, int channel)
        {
            if (channel == 0) { return 0; }
            return band == "2.4" ? (channel == 14 ? 2484 : 2407 + 5 * channel) : 5000 + 5 * channel;
        }

        private static RadioWidth Footprint(string band, int primary, int width, int center, int second)
        {
            int lower = band == "2.4" ? 2400 : 5150;
            int upper = band == "2.4" ? 2500 : 5900;
            if (center - width / 2 < lower || center + width / 2 > upper ||
                Math.Abs(primary - center) >= width / 2 || (primary - center + width / 2) % 20 != 10) { return null; }
            if (band == "2.4" && width == 40 &&
                (2 * center - primary < 2412 || 2 * center - primary > 2472)) { return null; }
            if (second != 0 && (second - width / 2 < lower || second + width / 2 > upper ||
                Math.Abs(second - center) <= width)) { return null; }
            return new RadioWidth(width, center, second == 0 ? (int?)null : second);
        }

        public static RadioWidth DecodeWidth(byte[] elements, string band, int channel, int frequency)
        {
            if (elements == null || (band != "2.4" && band != "5")) { return null; }
            RadioWidth ht = null, vht = null, eht = null;
            for (int i = 0; i + 1 < elements.Length;)
            {
                int id = elements[i++];
                int length = elements[i++];
                if (length > elements.Length - i) { return null; }
                if (id == 61 && length >= 22 && elements[i] == channel) // HT Operation
                {
                    int offset = elements[i + 1] & 3;
                    bool forty = (elements[i + 1] & 4) != 0 && (offset == 1 || offset == 3);
                    ht = Footprint(band, frequency, forty ? 40 : 20, frequency + (forty ? (offset == 1 ? 10 : -10) : 0), 0);
                }
                if (id == 192 && length >= 5 && band == "5") // VHT Operation
                {
                    int code = elements[i];
                    int first = SegmentFrequency(band, elements[i + 1]);
                    int second = SegmentFrequency(band, elements[i + 2]);
                    if (code == 1)
                    {
                        if (second == 0) { vht = Footprint(band, frequency, 80, first, 0); }
                        else if (Math.Abs(first - second) == 40) { vht = Footprint(band, frequency, 160, second, 0); }
                        else { vht = Footprint(band, frequency, 80, first, second); }
                    }
                    else if (code == 2) { vht = Footprint(band, frequency, 160, first, 0); }
                    else if (code == 3 && second != 0) { vht = Footprint(band, frequency, 80, first, second); }
                }
                if (id == 255 && length >= 9 && elements[i] == 106 && (elements[i + 1] & 1) != 0) // EHT Operation
                {
                    int code = elements[i + 6] & 7;
                    int first = SegmentFrequency(band, elements[i + 7]);
                    int second = SegmentFrequency(band, elements[i + 8]);
                    if (code < 3 && (band != "2.4" || code < 2))
                    {
                        eht = Footprint(band, frequency, 20 << code, first, 0);
                    }
                    else if (code == 3 && band == "5" && second != 0)
                    {
                        eht = Math.Abs(first - second) == 40
                            ? Footprint(band, frequency, 160, second, 0)
                            : Footprint(band, frequency, 80, first, second);
                    }
                }
                i += length;
            }
            return eht ?? vht ?? ht;
        }
    }
}
