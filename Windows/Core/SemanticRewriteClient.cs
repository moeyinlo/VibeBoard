using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;

namespace VibeBoardPlus.Core;

/// <summary>
/// 云端整理的最小连通性测试（与内核同一端点/提示词）。返回 null 表示成功，否则是错误文案。
/// 正式整理由 Rust 内核完成，这里只用于设置页的「测试」按钮。
/// </summary>
public static class SemanticRewriteClient
{
    private const string Url = "https://api.stepfun.com/v1/chat/completions";
    private const string Prompt =
        "你是语音转写校对工具。输入是语音识别的原始结果，可能包含同音错字、漏字、错误断句和口头语。\n" +
        "请做轻度整理，只输出整理后的文本：修正明显的同音错字、补全标点、删除无意义的口头重复；" +
        "保留原意与专有名词；不扩写、不总结、不回答问题。拿不准的词保持原样。";

    public static string? Test(string key, string model)
    {
        if (string.IsNullOrWhiteSpace(key))
            return "未配置 StepFun API Key";
        if (string.IsNullOrWhiteSpace(model))
            model = "step-3.5-flash";

        try
        {
            using var client = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
            client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", key.Trim());
            var body = JsonSerializer.Serialize(new
            {
                model,
                stream = false,
                temperature = 0,
                max_tokens = 256,
                messages = new[]
                {
                    new { role = "system", content = Prompt },
                    new { role = "user", content = "你好你好今天下午三点开会" },
                },
            });

            using var content = new StringContent(body, Encoding.UTF8, "application/json");
            using var response = client.PostAsync(Url, content).GetAwaiter().GetResult();
            var text = response.Content.ReadAsStringAsync().GetAwaiter().GetResult();
            if (response.IsSuccessStatusCode) return null;

            var status = (int)response.StatusCode;
            return status switch
            {
                401 or 403 => "密钥无效或没有权限（HTTP 401/403）",
                402 => "账户余额不足，请充值后再用云端整理（HTTP 402）",
                429 => "请求过于频繁或额度已用尽（HTTP 429）",
                >= 500 => $"StepFun 服务暂时不可用（HTTP {status}）",
                _ => $"请求失败（HTTP {status}）：{Truncate(text)}",
            };
        }
        catch (Exception ex)
        {
            return $"连接失败：{ex.Message}";
        }
    }

    private static string Truncate(string value) => value.Length <= 180 ? value : value[..180];
}
