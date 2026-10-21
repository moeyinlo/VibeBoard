using System.IO;
using System.Text;

namespace VibeBoardPlus.Core;

/// <summary>Runtime log written to %LOCALAPPDATA%\VibeBoardPlus\vibeboardplus.log.</summary>
public static class Log
{
    private static readonly object Gate = new();
    private const long MaxBytes = 2 * 1024 * 1024;

    public static string Directory { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "VibeBoardPlus");

    public static string FilePath { get; } = Path.Combine(Directory, "vibeboardplus.log");

    public static event Action<string>? Written;

    public static void Info(string message) => Write("info", message);
    public static void Warn(string message) => Write("warn", message);
    public static void Error(string message) => Write("error", message);

    private static void Write(string level, string message)
    {
        var line = $"[{DateTime.Now:HH:mm:ss.fff}] [{level}] {message}";
        lock (Gate)
        {
            try
            {
                System.IO.Directory.CreateDirectory(Directory);
                RotateIfNeeded();
                File.AppendAllText(FilePath, line + Environment.NewLine, Encoding.UTF8);
            }
            catch
            {
                // Logging must never take the app down.
            }
        }
        Written?.Invoke(line);
    }

    private static void RotateIfNeeded()
    {
        var info = new FileInfo(FilePath);
        if (!info.Exists || info.Length < MaxBytes) return;
        var backup = FilePath + ".1";
        if (File.Exists(backup)) File.Delete(backup);
        File.Move(FilePath, backup);
    }

    public static string ReadTail(int maxLines = 400)
    {
        try
        {
            if (!File.Exists(FilePath)) return "";
            var lines = File.ReadAllLines(FilePath);
            return string.Join(Environment.NewLine, lines.TakeLast(maxLines));
        }
        catch (Exception ex)
        {
            return $"读取日志失败：{ex.Message}";
        }
    }
}
