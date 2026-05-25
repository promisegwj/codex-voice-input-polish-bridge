using System.Text;
using System.Text.RegularExpressions;

Console.InputEncoding = Encoding.UTF8;
Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

var input = await Console.In.ReadToEndAsync();
if (string.IsNullOrEmpty(input))
    return;

var map = LoadCharacterMap();
if (map.Count == 0)
{
    Console.Write(input);
    return;
}

var builder = new StringBuilder(input.Length);
foreach (var ch in input)
    builder.Append(map.TryGetValue(ch, out var simplified) ? simplified : ch);

var output = builder.ToString();

if (IsCodexProfile())
    output = LightlyPolishCodexPrompt(output);

Console.Write(output);

static Dictionary<char, char> LoadCharacterMap()
{
    var map = new Dictionary<char, char>();
    var path = Path.Combine(AppContext.BaseDirectory, "TSCharacters.txt");

    if (File.Exists(path))
    {
        foreach (var rawLine in File.ReadLines(path, Encoding.UTF8))
        {
            var line = rawLine.Trim();
            if (line.Length == 0 || line.StartsWith('#'))
                continue;

            var parts = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (parts.Length < 2 || parts[0].Length == 0 || parts[1].Length == 0)
                continue;

            map[parts[0][0]] = parts[1][0];
        }
    }

    if (map.Count > 0)
        return map;

    foreach (var (traditional, simplified) in GetFallbackPairs())
        map[traditional] = simplified;

    return map;
}

static bool IsCodexProfile()
{
    var profile = Environment.GetEnvironmentVariable("TYPEWHISPER_PROFILE") ?? "";
    return profile.Contains("Codex", StringComparison.OrdinalIgnoreCase);
}

static string LightlyPolishCodexPrompt(string text)
{
    var cleaned = text
        .Replace("\r\n", "\n")
        .Replace('\r', '\n')
        .Replace("\uFEFF", "")
        .Trim();

    cleaned = Regex.Replace(cleaned, @"[ \t]+", " ");
    cleaned = Regex.Replace(cleaned, @"\s*\n\s*", "\n");

    cleaned = Regex.Replace(cleaned, @"^(嗯|呃|额|啊|那个|这个|就是|然后|好的|好[，,\s]+)+", "");
    cleaned = Regex.Replace(cleaned, @"^[，,。！？\s]+", "");
    cleaned = Regex.Replace(cleaned, @"(?<=[，。！？、\s])(嗯|呃|额|啊|那个|这个|就是)(?=[，。！？、\s])", "");
    cleaned = Regex.Replace(cleaned, @"(然后\s*){2,}", "然后");
    cleaned = Regex.Replace(cleaned, @"\s+(的话)(?=[，。！？]|$)", "");

    var replacements = new (string Pattern, string Replacement)[]
    {
        ("我希望你就是", "请"),
        ("我想让你就是", "请"),
        ("我想让你", "请"),
        ("我希望你", "请"),
        ("你来帮我", "请帮我"),
        ("帮我来", "请帮我"),
        ("你需要", "请"),
        ("我们来", "请"),
        ("给我一个", "给出一个"),
        ("给我一份", "给出一份")
    };

    foreach (var (pattern, replacement) in replacements)
        cleaned = cleaned.Replace(pattern, replacement, StringComparison.Ordinal);

    cleaned = Regex.Replace(cleaned, @"请(就是|这个|那个)\s*", "请");
    cleaned = Regex.Replace(cleaned, @"(?<=请)(帮我)?看一下", "检查");
    cleaned = cleaned.Replace("，。", "。").Replace(",。", "。");

    cleaned = Regex.Replace(cleaned, @"[，,]\s*", "，");
    cleaned = Regex.Replace(cleaned, @"[。]\s*", "。");
    cleaned = Regex.Replace(cleaned, @"\s+", " ").Trim();

    if (!StartsLikeInstruction(cleaned))
        cleaned = "请根据以下口述内容理解我的需求，并直接执行：" + cleaned;

    cleaned = SplitObviousMultipleRequests(cleaned);
    return cleaned.Trim();
}

static bool StartsLikeInstruction(string text)
{
    var starters = new[] { "请", "帮我", "检查", "修改", "实现", "分析", "总结", "解释", "不要", "先", "把", "用", "给出", "设计" };
    return starters.Any(starter => text.StartsWith(starter, StringComparison.Ordinal));
}

static string SplitObviousMultipleRequests(string text)
{
    var normalized = text
        .Replace("然后另外", "。另外")
        .Replace("另外，", "。另外，")
        .Replace("另外,", "。另外，")
        .Replace("还有，", "。还有，")
        .Replace("还有,", "。还有，");

    normalized = Regex.Replace(normalized, @"。+", "。");
    normalized = Regex.Replace(normalized, @"[，,]\s*。", "。");
    return normalized;
}

static (char Traditional, char Simplified)[] GetFallbackPairs() =>
[
    ('繁', '繁'), ('體', '体'), ('臺', '台'), ('灣', '湾'), ('語', '语'),
    ('說', '说'), ('識', '识'), ('這', '这'), ('個', '个'), ('實', '实'),
    ('準', '准'), ('確', '确'), ('轉', '转'), ('輸', '输'), ('優', '优'),
    ('化', '化'), ('錯', '错'), ('誤', '误'), ('對', '对'), ('會', '会'),
    ('話', '话'), ('還', '还'), ('讓', '让'), ('處', '处'), ('理', '理'),
    ('後', '后'), ('與', '与'), ('為', '为'), ('時', '时'), ('長', '长'),
    ('應', '应'), ('現', '现'), ('態', '态'), ('內', '内'), ('容', '容')
];
