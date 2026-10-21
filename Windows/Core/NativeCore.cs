using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;

namespace VibeBoardPlus.Core;

/// <summary>
/// P/Invoke surface of the shared Rust core (core/crates/vibeboard-core).
///
/// Threading: callbacks arrive on core worker threads. <see cref="NativeCore"/> marshals them
/// to the UI dispatcher before raising events, and copies strings while the pointer is valid.
/// </summary>
internal static class Native
{
    internal const string Library = "vibeboard_core";

    [StructLayout(LayoutKind.Sequential)]
    internal struct Callbacks
    {
        public IntPtr userdata;
        public IntPtr on_status;
        public IntPtr on_partial_text;
        public IntPtr on_final_text;
        public IntPtr on_error;
        public IntPtr on_action;
        public IntPtr on_local_stats;
        public IntPtr on_session_started;
        public IntPtr on_cancelled;
        public IntPtr on_pcm;
        public IntPtr on_pcm_end;
        public IntPtr load_secret;
        public IntPtr save_secret;
    }

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void TextCallback(IntPtr userdata, IntPtr text);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void VoidCallback(IntPtr userdata);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void PcmCallback(IntPtr userdata, IntPtr data, UIntPtr length);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate IntPtr LoadSecretCallback(IntPtr userdata, IntPtr deviceId);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void SaveSecretCallback(IntPtr userdata, IntPtr deviceId, IntPtr secret);

    [UnmanagedFunctionPointer(CallingConvention.Cdecl)]
    internal delegate void ProgressCallback(IntPtr userdata, ulong received, ulong total, int hasTotal);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_core_new(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson, Callbacks callbacks, out IntPtr error);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_core_free(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int vb_core_start(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_core_stop(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_core_cancel(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int vb_core_update_config(
        IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string configJson, out IntPtr error);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_core_external_text(
        IntPtr handle, [MarshalAs(UnmanagedType.LPUTF8Str)] string text, int isFinal);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_core_last_text(IntPtr handle);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_local_backend_info();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_model_catalog();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int vb_download_model(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, ProgressCallback callback, IntPtr userdata, out IntPtr error);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int vb_model_available([MarshalAs(UnmanagedType.LPUTF8Str)] string name);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern int vb_model_remove(
        [MarshalAs(UnmanagedType.LPUTF8Str)] string name, out IntPtr error);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_version();

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern IntPtr vb_string_alloc([MarshalAs(UnmanagedType.LPUTF8Str)] string utf8);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_string_free(IntPtr value);

    [DllImport(Library, CallingConvention = CallingConvention.Cdecl)]
    internal static extern void vb_set_log_callback(TextCallback callback, IntPtr userdata);
}

public sealed record LocalEngineStats(
    string Backend,
    string Model,
    double AudioSeconds,
    double DurationSeconds,
    double RealtimeFactor,
    int Threads,
    double? PeakRssMb,
    string SystemInfo)
{
    public string Summary =>
        $"{Backend} · {Model} · 音频 {AudioSeconds:F1}s / 耗时 {DurationSeconds:F2}s（RTF {RealtimeFactor:F2}）"
        + $" · 线程 {Threads} · 峰值内存 {(PeakRssMb.HasValue ? $"{PeakRssMb.Value:F0} MB" : "未知")}";
}

public sealed record LocalBackendInfo(string Active, string[] Compiled, string SystemInfo);

public sealed record ModelInfo(string Name, string FileName, int SizeMb, string Quality, bool Installed, string Path);

/// <summary>Owns the core handle and exposes typed events to the WPF layer.</summary>
public sealed class NativeCore : IDisposable
{
    private IntPtr _handle;
    private readonly System.Windows.Threading.Dispatcher _dispatcher;
    private readonly AppSettings _settings;

    // Delegates must stay alive for as long as the core can call them.
    private readonly Native.TextCallback _status;
    private readonly Native.TextCallback _partial;
    private readonly Native.TextCallback _final;
    private readonly Native.TextCallback _error;
    private readonly Native.TextCallback _action;
    private readonly Native.TextCallback _stats;
    private readonly Native.TextCallback _log;
    private readonly Native.VoidCallback _started;
    private readonly Native.VoidCallback _cancelled;
    private readonly Native.PcmCallback _pcm;
    private readonly Native.VoidCallback _pcmEnd;
    private readonly Native.LoadSecretCallback _loadSecret;
    private readonly Native.SaveSecretCallback _saveSecret;

    public event Action<string>? StatusChanged;
    public event Action<string>? PartialText;
    public event Action<string>? FinalText;
    public event Action<string>? Error;
    public event Action<string>? ButtonAction;
    public event Action<LocalEngineStats>? LocalStats;
    /// <summary>Decoded 16 kHz mono PCM for the shell's own recogniser.</summary>
    public event Action<byte[]>? Pcm;
    public event Action? PcmEnd;
    public event Action? SessionStarted;
    public event Action? Cancelled;

    public NativeCore(AppSettings settings)
    {
        _settings = settings;
        _dispatcher = System.Windows.Threading.Dispatcher.CurrentDispatcher;

        _status = (_, text) => Raise(StatusChanged, Read(text));
        _partial = (_, text) => Raise(PartialText, Read(text));
        _final = (_, text) => Raise(FinalText, Read(text));
        _error = (_, text) => Raise(Error, Read(text));
        _action = (_, text) => Raise(ButtonAction, Read(text));
        _stats = (_, text) => HandleStats(Read(text));
        _log = (_, text) => Log.Info($"[rust] {Read(text)}");
        _started = _ => Raise(SessionStarted);
        _cancelled = _ => Raise(Cancelled);
        _pcm = (_, data, length) =>
        {
            var bytes = new byte[(int)length];
            if (bytes.Length > 0) Marshal.Copy(data, bytes, 0, bytes.Length);
            Pcm?.Invoke(bytes);
        };
        _pcmEnd = _ => PcmEnd?.Invoke();
        _loadSecret = (_, deviceId) =>
        {
            var secret = _settings.LoadDeviceSecret(Read(deviceId));
            return secret is null ? IntPtr.Zero : Native.vb_string_alloc(secret);
        };
        _saveSecret = (_, deviceId, secret) => _settings.SaveDeviceSecret(Read(deviceId), Read(secret));
    }

    private static string Read(IntPtr pointer) =>
        pointer == IntPtr.Zero ? string.Empty : Marshal.PtrToStringUTF8(pointer) ?? string.Empty;

    private void Raise<T>(Action<T>? handler, T value)
    {
        if (handler is null) return;
        _dispatcher.BeginInvoke(() => handler(value));
    }

    private void Raise(Action? handler)
    {
        if (handler is null) return;
        _dispatcher.BeginInvoke(handler);
    }

    private void HandleStats(string json)
    {
        try
        {
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var stats = new LocalEngineStats(
                root.GetProperty("backend").GetString() ?? "?",
                root.GetProperty("model").GetString() ?? "?",
                root.GetProperty("audioSeconds").GetDouble(),
                root.GetProperty("durationSeconds").GetDouble(),
                root.GetProperty("realtimeFactor").GetDouble(),
                root.GetProperty("threads").GetInt32(),
                root.TryGetProperty("peakRssMb", out var memory) && memory.ValueKind == JsonValueKind.Number
                    ? memory.GetDouble()
                    : null,
                root.TryGetProperty("systemInfo", out var info) ? info.GetString() ?? "" : "");
            _dispatcher.BeginInvoke(() => LocalStats?.Invoke(stats));
        }
        catch (Exception ex)
        {
            Log.Warn($"解析本地统计失败：{ex.Message}");
        }
    }

    public void Start()
    {
        Native.vb_set_log_callback(_log, IntPtr.Zero);

        var callbacks = new Native.Callbacks
        {
            userdata = IntPtr.Zero,
            on_status = Marshal.GetFunctionPointerForDelegate(_status),
            on_partial_text = Marshal.GetFunctionPointerForDelegate(_partial),
            on_final_text = Marshal.GetFunctionPointerForDelegate(_final),
            on_error = Marshal.GetFunctionPointerForDelegate(_error),
            on_action = Marshal.GetFunctionPointerForDelegate(_action),
            on_local_stats = Marshal.GetFunctionPointerForDelegate(_stats),
            on_session_started = Marshal.GetFunctionPointerForDelegate(_started),
            on_cancelled = Marshal.GetFunctionPointerForDelegate(_cancelled),
            on_pcm = Marshal.GetFunctionPointerForDelegate(_pcm),
            on_pcm_end = Marshal.GetFunctionPointerForDelegate(_pcmEnd),
            load_secret = Marshal.GetFunctionPointerForDelegate(_loadSecret),
            save_secret = Marshal.GetFunctionPointerForDelegate(_saveSecret),
        };

        var config = BuildConfigJson();
        _handle = Native.vb_core_new(config, callbacks, out var error);
        if (_handle == IntPtr.Zero)
        {
            var message = ReadError(error);
            Log.Error($"内核初始化失败：{message}");
            throw new InvalidOperationException($"内核初始化失败：{message}");
        }

        Backend = ReadBackendInfo();
        var result = Native.vb_core_start(_handle);
        Log.Info($"core v{Version()} started -> {result}, backend={Backend?.Active ?? "?"}");
        if (result != 0) throw new InvalidOperationException("内核启动失败");
    }

    public void UpdateConfiguration()
    {
        if (_handle == IntPtr.Zero) return;
        var result = Native.vb_core_update_config(_handle, BuildConfigJson(), out var error);
        if (result != 0) Log.Warn($"配置更新失败：{ReadError(error)}");
        else Log.Info("配置已更新");
    }

    public void Cancel()
    {
        if (_handle != IntPtr.Zero) Native.vb_core_cancel(_handle);
    }

    public void SendExternalText(string text, bool isFinal)
    {
        if (_handle != IntPtr.Zero) Native.vb_core_external_text(_handle, text, isFinal ? 1 : 0);
    }

    public string LastText()
    {
        if (_handle == IntPtr.Zero) return "";
        var pointer = Native.vb_core_last_text(_handle);
        if (pointer == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringUTF8(pointer) ?? ""; }
        finally { Native.vb_string_free(pointer); }
    }

    public LocalBackendInfo? Backend { get; private set; }

    private string BuildConfigJson()
    {
        var config = new Dictionary<string, object?>
        {
            ["provider"] = _settings.AsrProvider,
            ["model"] = _settings.AsrModel,
            ["whisper_model"] = _settings.WhisperModel,
            ["recognition_key"] = _settings.RecognitionKey,
            ["rewrite_enabled"] = _settings.RewriteEnabled,
            ["rewrite_model"] = _settings.RewriteModel,
            ["rewrite_key"] = string.IsNullOrEmpty(_settings.RewriteKey)
                ? _settings.RecognitionKey
                : _settings.RewriteKey,
            ["base_url"] = "https://torchfun.com",
            ["button_actions"] = _settings.ButtonActions,
        };
        return JsonSerializer.Serialize(config);
    }

    private static string ReadError(IntPtr error)
    {
        if (error == IntPtr.Zero) return "未知错误";
        try { return Marshal.PtrToStringUTF8(error) ?? "未知错误"; }
        finally { Native.vb_string_free(error); }
    }

    public static string Version()
    {
        var pointer = Native.vb_version();
        if (pointer == IntPtr.Zero) return "?";
        try { return Marshal.PtrToStringUTF8(pointer) ?? "?"; }
        finally { Native.vb_string_free(pointer); }
    }

    public static LocalBackendInfo? ReadBackendInfo()
    {
        var pointer = Native.vb_local_backend_info();
        if (pointer == IntPtr.Zero) return null;
        try
        {
            var json = Marshal.PtrToStringUTF8(pointer);
            if (string.IsNullOrEmpty(json)) return null;
            using var document = JsonDocument.Parse(json);
            var root = document.RootElement;
            var compiled = root.TryGetProperty("compiled", out var list)
                ? list.EnumerateArray().Select(item => item.GetString() ?? "").ToArray()
                : Array.Empty<string>();
            return new LocalBackendInfo(
                root.GetProperty("active").GetString() ?? "?",
                compiled,
                root.TryGetProperty("systemInfo", out var info) ? info.GetString() ?? "" : "");
        }
        catch
        {
            return null;
        }
        finally
        {
            Native.vb_string_free(pointer);
        }
    }

    public static IReadOnlyList<ModelInfo> ModelCatalog()
    {
        var pointer = Native.vb_model_catalog();
        if (pointer == IntPtr.Zero) return Array.Empty<ModelInfo>();
        try
        {
            var json = Marshal.PtrToStringUTF8(pointer);
            if (string.IsNullOrEmpty(json)) return Array.Empty<ModelInfo>();
            using var document = JsonDocument.Parse(json);
            return document.RootElement.EnumerateArray().Select(item => new ModelInfo(
                item.GetProperty("name").GetString() ?? "",
                item.GetProperty("fileName").GetString() ?? "",
                item.GetProperty("sizeMb").GetInt32(),
                item.TryGetProperty("quality", out var quality) ? quality.GetString() ?? "" : "",
                item.TryGetProperty("installed", out var installed) && installed.GetBoolean(),
                item.TryGetProperty("path", out var path) ? path.GetString() ?? "" : ""
            )).ToList();
        }
        catch
        {
            return Array.Empty<ModelInfo>();
        }
        finally
        {
            Native.vb_string_free(pointer);
        }
    }

    public static bool ModelInstalled(string name) => Native.vb_model_available(name) != 0;

    public static string? RemoveModel(string name)
    {
        var result = Native.vb_model_remove(name, out var error);
        return result == 0 ? null : ReadError(error);
    }

    /// <summary>Downloads a model; progress is reported on the calling thread.</summary>
    public static string? DownloadModel(string name, Action<double?, ulong>? progress = null)
    {
        Native.ProgressCallback? callback = null;
        if (progress is not null)
        {
            callback = (_, received, total, hasTotal) =>
            {
                var fraction = hasTotal != 0 && total > 0 ? (double)received / total : (double?)null;
                progress(fraction, received);
            };
        }
        var result = Native.vb_download_model(name, callback ?? ((_, _, _, _) => { }), IntPtr.Zero, out var error);
        GC.KeepAlive(callback);
        return result == 0 ? null : ReadError(error);
    }

    public void Dispose()
    {
        if (_handle == IntPtr.Zero) return;
        Native.vb_core_stop(_handle);
        Native.vb_core_free(_handle);
        _handle = IntPtr.Zero;
    }
}
