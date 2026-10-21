using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace VibeBoardPlus.Core;

public enum OutputMode
{
    /// <summary>Only show the floating transcript window.</summary>
    Overlay,
    /// <summary>Type the transcript into the focused control as it is refined.</summary>
    LiveInput,
    /// <summary>Paste the final transcript into the focused control (Ctrl+V).</summary>
    PasteOnCompletion,
}

public static class OutputModeExtensions
{
    public static string ToKey(this OutputMode mode) => mode switch
    {
        OutputMode.Overlay => "overlay",
        OutputMode.LiveInput => "liveInput",
        _ => "pasteOnCompletion",
    };

    public static OutputMode Parse(string? value) => value switch
    {
        "overlay" => OutputMode.Overlay,
        "liveInput" => OutputMode.LiveInput,
        _ => OutputMode.PasteOnCompletion,
    };

    public static string Label(this OutputMode mode) => mode switch
    {
        OutputMode.Overlay => "仅悬浮窗",
        OutputMode.LiveInput => "实时输入到输入框",
        _ => "完成后粘贴到输入框",
    };
}

/// <summary>
/// Settings persisted as JSON in %APPDATA%\VibeBoardPlus\settings.json.
/// API keys are encrypted with DPAPI (current user) before being written to disk.
/// </summary>
public sealed class AppSettings
{
    public static string Directory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "VibeBoardPlus");

    public static string FilePath { get; } = Path.Combine(Directory, "settings.json");

    // ---- persisted ----

    // 默认走本地 Whisper：无需云端额度，离线可用。
    public string AsrProvider { get; set; } = "whisper";           // stepfun | whisper | external
    public string AsrModel { get; set; } = "stepaudio-2.5-asr-stream";
    public string WhisperModel { get; set; } = "small";
    public string OutputModeKey { get; set; } = "pasteOnCompletion";
    public bool AutoCopy { get; set; } = true;
    public bool RewriteEnabled { get; set; }
    /// <summary>Device secrets (`device_id` -> DPAPI-protected secret) from the core's provisioning.</summary>
    public Dictionary<string, string> DeviceSecrets { get; set; } = new();
    public string RewriteModel { get; set; } = "step-3.5-flash";
    public Dictionary<string, string> ButtonActions { get; set; } = new();
    public string RelaxedHotkey { get; set; } = "";

    /// <summary>DPAPI-protected StepFun key used for speech recognition.</summary>
    public string? RecognitionKeyProtected { get; set; }

    /// <summary>DPAPI-protected StepFun key used for semantic cleanup (separate slot).</summary>
    public string? RewriteKeyProtected { get; set; }

    // ---- runtime helpers ----

    [JsonIgnore]
    public OutputMode OutputMode
    {
        get => OutputModeExtensions.Parse(OutputModeKey);
        set => OutputModeKey = value.ToKey();
    }

    [JsonIgnore]
    public string RecognitionKey
    {
        get => Unprotect(RecognitionKeyProtected);
        set => RecognitionKeyProtected = Protect(value);
    }

    [JsonIgnore]
    public string RewriteKey
    {
        get => Unprotect(RewriteKeyProtected);
        set => RewriteKeyProtected = Protect(value);
    }

    public string? LoadDeviceSecret(string deviceId)
    {
        if (!DeviceSecrets.TryGetValue(deviceId, out var protectedValue)) return null;
        return Unprotect(protectedValue);
    }

    public void SaveDeviceSecret(string deviceId, string secret)
    {
        DeviceSecrets[deviceId] = Protect(secret);
        Save();
    }

    public ButtonAction ActionFor(string button)
    {
        var key = button.ToLowerInvariant();
        return ButtonActions.TryGetValue(key, out var raw) && Enum.TryParse<ButtonAction>(raw, true, out var action)
            ? action
            : ButtonAction.Voice;
    }

    public static AppSettings Load()
    {
        try
        {
            if (File.Exists(FilePath))
            {
                var json = File.ReadAllText(FilePath);
                var loaded = JsonSerializer.Deserialize<AppSettings>(json);
                if (loaded != null) return loaded;
            }
        }
        catch (Exception ex)
        {
            Log.Warn($"settings load failed: {ex.Message}");
        }
        return new AppSettings();
    }

    public void Save()
    {
        try
        {
            System.IO.Directory.CreateDirectory(Directory);
            var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
            File.WriteAllText(FilePath, json);
        }
        catch (Exception ex)
        {
            Log.Error($"settings save failed: {ex.Message}");
        }
    }

    private static string Protect(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        try
        {
            var bytes = ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser);
            return Convert.ToBase64String(bytes);
        }
        catch (Exception ex)
        {
            Log.Warn($"DPAPI protect failed: {ex.Message}");
            return "";
        }
    }

    private static string Unprotect(string? value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        try
        {
            var bytes = ProtectedData.Unprotect(Convert.FromBase64String(value), null, DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch (Exception ex)
        {
            Log.Warn($"DPAPI unprotect failed: {ex.Message}");
            return "";
        }
    }
}
