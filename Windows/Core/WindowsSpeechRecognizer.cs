using System.IO;
using System.Speech.AudioFormat;
using System.Speech.Recognition;

namespace VibeBoardPlus.Core;

/// <summary>
/// Windows' built-in recogniser, used when the core is configured with the `external`
/// provider. Audio arrives as 16 kHz mono PCM16 from the core; recognition runs on a worker
/// thread once the session ends.
///
/// Requires a matching Windows speech language pack; when absent the engine throws and the
/// session falls back to showing the transcript window (nothing to show) plus a clear error.
/// </summary>
public sealed class WindowsSpeechRecognizer : IDisposable
{
    private readonly MemoryStream _pcm = new();
    private bool _recording;
    private SpeechRecognitionEngine? _engine;

    public string Language { get; set; } = "zh-CN";

    public event Action<string, bool>? Text;
    public event Action<string>? Error;

    public bool Start()
    {
        _pcm.SetLength(0);
        _recording = true;
        return true;
    }

    public void Append(byte[] pcm)
    {
        if (!_recording) return;
        _pcm.Write(pcm, 0, pcm.Length);
    }

    public void Finish()
    {
        if (!_recording) return;
        _recording = false;
        var audio = _pcm.ToArray();
        if (audio.Length < 16_000)
        {
            Error?.Invoke("录音太短，未识别到文字");
            return;
        }

        Task.Run(() =>
        {
            try
            {
                var culture = System.Globalization.CultureInfo.GetCultureInfo(Language);
                using var engine = new SpeechRecognitionEngine(culture);
                engine.LoadGrammar(new DictationGrammar());
                engine.SetInputToAudioStream(new MemoryStream(audio),
                    new SpeechAudioFormatInfo(16_000, AudioBitsPerSample.Sixteen, AudioChannel.Mono));

                var collected = new List<string>();
                engine.SpeechRecognized += (_, args) =>
                {
                    if (!string.IsNullOrWhiteSpace(args.Result?.Text)) collected.Add(args.Result.Text);
                };
                engine.Recognize();
                var text = string.Join("", collected).Trim();
                Text?.Invoke(text, true);
            }
            catch (Exception ex)
            {
                Log.Warn($"Windows 语音识别失败：{ex.Message}");
                Error?.Invoke($"Windows 语音识别不可用（需要中文语音语言包）：{ex.Message}");
            }
        });
    }

    public void Cancel()
    {
        _recording = false;
        _pcm.SetLength(0);
        _engine?.Dispose();
        _engine = null;
    }

    public void Dispose() => Cancel();
}
