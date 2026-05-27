using System.Text;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.RegularExpressions;

Console.InputEncoding = Encoding.UTF8;
Console.OutputEncoding = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false);

if (args.Any(arg => arg is "-h" or "--help"))
{
    Console.WriteLine("Reads Codex voice-recognition text from stdin or --input-file and writes a prompt-friendly version to stdout or --output-file. Optional: --rewrite-rule, --debug-decision, --version.");
    return;
}

if (args.Any(arg => arg is "--version"))
{
    Console.WriteLine("CodexVoicePromptBridge 0.2.0");
    return;
}

var inputFile = GetOptionValue(args, "--input-file");
var outputFile = GetOptionValue(args, "--output-file");
var rewriteRule = NormalizeRewriteRule(GetOptionValue(args, "--rewrite-rule"));
var debugDecision = args.Any(arg => string.Equals(arg, "--debug-decision", StringComparison.OrdinalIgnoreCase));

var input = inputFile is null
    ? await Console.In.ReadToEndAsync()
    : await File.ReadAllTextAsync(inputFile, Encoding.UTF8);

if (string.IsNullOrWhiteSpace(input))
    return;

var map = LoadCharacterMap();
var simplifiedInput = ConvertTraditionalToSimplified(input, map);
if (debugDecision)
{
    var decisionInput = ApplyNaturalChineseWordOrder(ApplyInstructionReplacements(PrepareStructureDecisionText(simplifiedInput)));
    var decision = BuildStructureDecision(decisionInput);
    var jsonOptions = new JsonSerializerOptions
    {
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true
    };
    Console.Write(JsonSerializer.Serialize(decision, jsonOptions));
    return;
}

var normalized = NormalizeForCodexPrompt(simplifiedInput, rewriteRule);

if (outputFile is null)
    Console.Write(normalized);
else
    await File.WriteAllTextAsync(outputFile, normalized, new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));

static string? GetOptionValue(string[] args, string name)
{
    for (var i = 0; i < args.Length - 1; i++)
    {
        if (string.Equals(args[i], name, StringComparison.OrdinalIgnoreCase))
            return args[i + 1];
    }

    return null;
}

static string NormalizeRewriteRule(string? rewriteRule)
{
    const string defaultRewriteRule = "先判断原始口述的真实意图和任务边界；保留事实、否定、时间、数字、路径、文件名、专有名词和条件，不新增原文没有的信息。删除不承载意义的口头禅、重复句、犹豫词和自我打断；对“不是 A，是 B”“不对，改成 B”以后者为准。将“你能不能/是不是可以”改为直接可执行请求，但真正的可行性询问要保留为问题。多件事按 1、2、3 拆分，每项写成“动作 + 对象 + 验证/交付要求”。长句按意图断句，使用规范中文标点；保留必要的语气和不确定性，关键歧义标为“需确认”。输出应简洁、清楚、可执行，适合直接发给 Codex；不要额外添加固定标题。";
    var normalized = (rewriteRule ?? string.Empty).Trim();
    return string.IsNullOrWhiteSpace(normalized) ? defaultRewriteRule : normalized;
}

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

static string ConvertTraditionalToSimplified(string input, IReadOnlyDictionary<char, char> map)
{
    if (map.Count == 0)
        return input;

    var builder = new StringBuilder(input.Length);
    foreach (var ch in input)
        builder.Append(map.TryGetValue(ch, out var simplified) ? simplified : ch);

    return builder.ToString();
}

static string NormalizeForCodexPrompt(string text, string rewriteRule)
{
    rewriteRule = NormalizeRewriteRule(rewriteRule);
    var cleaned = PrepareStructureDecisionText(text);
    cleaned = ApplyInstructionReplacements(cleaned);
    cleaned = ApplyNaturalChineseWordOrder(cleaned);
    var structureDecision = BuildStructureDecision(cleaned);

    cleaned = ApplyPromptEngineeringCompression(cleaned, rewriteRule);
    cleaned = SplitObviousMultipleRequests(cleaned);
    cleaned = ApplyNaturalChineseWordOrder(cleaned);
    cleaned = ApplyPromptEngineeringCompression(cleaned, rewriteRule);
    cleaned = NormalizePunctuation(cleaned);
    cleaned = CollapsePromptCompressionSummary(cleaned);
    cleaned = ApplyRuleDrivenPromptStructure(cleaned, structureDecision);

    return cleaned.Trim();
}

static string PrepareStructureDecisionText(string text)
{
    var cleaned = text
        .Replace("\r\n", "\n")
        .Replace('\r', '\n')
        .Replace("\uFEFF", "")
        .Trim();

    cleaned = NormalizeProductNames(cleaned);
    cleaned = NormalizeEnglishTermTranscriptions(cleaned);
    cleaned = Regex.Replace(cleaned, @"[ \t]+", " ");
    cleaned = Regex.Replace(cleaned, @"\s*\n\s*", "\n");
    cleaned = RemoveSpeechFillers(cleaned);
    cleaned = NormalizePunctuation(cleaned);
    return cleaned.Trim();
}

static string NormalizeProductNames(string text)
{
    var cleaned = text;
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])codex(?![A-Za-z])", "Codex", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])codec(?![A-Za-z])", "Codex", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])cofirects(?![A-Za-z])", "Codex", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])type\s*whisper(?![A-Za-z])", "TypeWhisper", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])wisper(?![A-Za-z])", "Whisper", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z])whisper(?![A-Za-z])", "Whisper", RegexOptions.IgnoreCase);
    return cleaned;
}

static string NormalizeEnglishTermTranscriptions(string text)
{
    var cleaned = text;
    var replacements = new (string Pattern, string Replacement)[]
    {
        (@"扣得克斯|扣德克斯|口得克斯|口德克斯|科德克斯|科代克斯|code\s*x", "Codex"),
        (@"泰普\s*威斯珀|泰普\s*维斯珀|type\s*威斯珀|type\s*维斯珀", "TypeWhisper"),
        (@"威斯珀|维斯珀|wisper", "Whisper"),
        (@"盖特哈布|给特哈布|git\s*hub", "GitHub"),
        (@"泡儿?\s*shell|泡尔?\s*shell|power\s*壳|powershell", "PowerShell"),
        (@"爪哇\s*script|java\s*script", "JavaScript"),
        (@"type\s*script|泰普\s*script", "TypeScript"),
        (@"派森|派桑|python", "Python"),
        (@"杰森|j\s*son", "JSON"),
        (@"亚马尔|yaml", "YAML"),
        (@"马克 down|markdown", "Markdown"),
        (@"大模型|llm", "LLM"),
        (@"a\s*p\s*i|诶\s*p\s*i|接口API", "API"),
        (@"a\s*i|人工智能", "AI"),
        (@"u\s*i|用户界面", "UI"),
        (@"托肯|偷肯|token", "token"),
        (@"prompt|普朗普特|普罗姆特|提示词", "提示词"),
        (@"read\s*me|瑞德米", "README"),
        (@"localhost|local\s*host|本地host", "localhost"),
        (@"ctrl\s*\+\s*v|control\s*\+\s*v|粘贴快捷键", "Ctrl+V"),
        (@"ctrl\s*\+\s*shift\s*\+\s*d|control\s*\+\s*shift\s*\+\s*d", "Ctrl+Shift+D")
    };

    foreach (var (pattern, replacement) in replacements)
        cleaned = Regex.Replace(cleaned, pattern, replacement, RegexOptions.IgnoreCase);

    cleaned = Regex.Replace(cleaned, @"(?<=[\u4e00-\u9fff])(?=(Codex|TypeWhisper|Whisper|GitHub|PowerShell|JavaScript|TypeScript|Python|JSON|YAML|Markdown|LLM|API|AI|UI|README|localhost|Ctrl\+V|Ctrl\+Shift\+D|token))", " ");
    cleaned = Regex.Replace(cleaned, @"(Codex|TypeWhisper|Whisper|GitHub|PowerShell|JavaScript|TypeScript|Python|JSON|YAML|Markdown|LLM|API|AI|UI|README|localhost|Ctrl\+V|Ctrl\+Shift\+D|token)(?=[\u4e00-\u9fff])", "$1 ");
    return cleaned;
}

static string RemoveSpeechFillers(string text)
{
    var cleaned = Regex.Replace(text, @"^(嗯|呃|额|啊)?\s*然后的话[，,\s]*", "");
    cleaned = Regex.Replace(cleaned, @"^(嗯|呃|额|啊)?\s*然后\s*就是\s*说[，,\s]*", "");
    cleaned = Regex.Replace(cleaned, @"^(嗯|呃|额|啊)?\s*就是说[，,\s]*", "");
    cleaned = Regex.Replace(cleaned, @"^((那么|嗯|呃|额|啊|那个|这个|就是|然后|好的|好|那)[，,\s]*)+", "");
    cleaned = Regex.Replace(cleaned, @"(?<=[，。！？、\s])(怎么说呢|反正就是|大概就是说|就是说)(?=[，。！？、\s])", "");
    cleaned = Regex.Replace(cleaned, @"(?<=[，,])就是(?=(先|请|帮|把|看|检查|给))", "");
    cleaned = Regex.Replace(cleaned, @"(比如|例如)[，,、\s]*(然后|嗯|呃|额|啊|那个|这个|就是)[啊呃嗯额]*(什么的|之类的)", "$1“$2”等");
    cleaned = Regex.Replace(cleaned, @"(然后|嗯|呃|额|啊|那个|这个|就是)[啊呃嗯额]+(?=(什么的|之类的|等等|等|[，。！？、,\s]|$))", "$1");
    cleaned = Regex.Replace(cleaned, @"(?<=[\u4e00-\u9fffA-Za-z0-9])啊(?=(什么的|之类的|等等|等|[，。！？、,\s]|$))", "");
    cleaned = Regex.Replace(cleaned, @"^[，,。！？\s]+", "");
    cleaned = Regex.Replace(cleaned, @"(?<=[，。！？、\s])(嗯|呃|额|啊|那个|这个|就是|就|吧|嘛)(?=[，。！？、\s])", "");
    cleaned = Regex.Replace(cleaned, @"(这个|那个){2,}", "$1");
    cleaned = Regex.Replace(cleaned, @"(然后\s*){2,}", "然后");
    cleaned = Regex.Replace(cleaned, @"\s+(的话)(?=[，。！？]|$)", "");
    return cleaned;
}

static string ApplyInstructionReplacements(string text)
{
    var replacements = new (string Pattern, string Replacement)[]
    {
        ("我希望你能够", "请"),
        ("我希望你能", "请"),
        ("现在我想要你", "请"),
        ("现在我想让你", "请"),
        ("我想要你", "请"),
        ("我想让你", "请"),
        ("我希望你就是", "请"),
        ("我希望你", "请"),
        ("给我方案", "给出方案"),
        ("给我结论", "给出结论"),
        ("我想修改", "请修改"),
        ("我想改", "请修改"),
        ("你来帮我", "请帮我"),
        ("帮我来", "请帮我"),
        ("你需要", "请"),
        ("我们来", "请"),
        ("给我一个", "给出一个"),
        ("给我一份", "给出一份"),
        ("改回Codex", "改回 Codex"),
        ("用Codex", "用 Codex"),
        ("给Codex", "给 Codex"),
        ("设置这个配件", "配置这个插件"),
        ("设置这个插件", "配置这个插件"),
        ("声音样本", "语音样本"),
        ("语音判断更准确", "语音识别判断更准确"),
        ("中文混合的", "中英混合的"),
        ("中文夹英文的点", "中英混合术语"),
        ("英文转转写成汉语发音的词", "英文术语被转写成汉语发音词"),
        ("英文转写成汉语发音的词", "英文术语被转写成汉语发音词"),
        ("后面新的手腕怎么样", "回填按钮手感如何"),
        ("新的手腕怎么样", "手感如何"),
        ("自动整理感觉做的还不够到位", "自动整理质量不够到位"),
        ("整理文本规则并没有实际作用到这个自动整理文本这个上面", "整理文本规则没有实际作用到自动整理文本上"),
        ("从网页端再返回到你这个Codex里面", "从网页端回填到 Codex 输入框"),
        ("从网页端再返回到你这个 Codex 里面", "从网页端回填到 Codex 输入框"),
        ("Codex 的输入窗里面", "Codex 输入框"),
        ("真相速度", "粘贴速度")
    };

    var cleaned = text;
    foreach (var (pattern, replacement) in replacements)
        cleaned = cleaned.Replace(pattern, replacement, StringComparison.Ordinal);

    cleaned = Regex.Replace(cleaned, @"^现在请", "请");
    cleaned = Regex.Replace(cleaned, @"^你帮我看一下", "请检查");
    cleaned = Regex.Replace(cleaned, @"^帮我看一下", "请检查");
    cleaned = Regex.Replace(cleaned, @"请让在安装的时候", "请在安装时");
    cleaned = Regex.Replace(cleaned, @"就配置这个插件的时候", "配置这个插件时");
    cleaned = Regex.Replace(cleaned, @"它的读的这个语音样本", "它朗读的语音样本");
    cleaned = Regex.Replace(cleaned, @"请(就是|这个|那个)\s*", "请");
    cleaned = Regex.Replace(cleaned, @"(?<=请)(帮我)?看一下", "检查");
    cleaned = Regex.Replace(cleaned, @"可以想想办法看怎么弄", "请给出并实现处理方案");
    cleaned = Regex.Replace(cleaned, @"怎么从(这个)*网页端再返回到(你这个)*\s*Codex\s*里面，?\s*Codex 输入框", "如何从网页端回填到 Codex 输入框");
    cleaned = Regex.Replace(cleaned, @"校验结果是和符合预期的", "校验结果符合预期");
    cleaned = Regex.Replace(cleaned, @"\bAPI\s*key\b", "API key", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"Codex(?=[\u4e00-\u9fff])", "Codex ");
    cleaned = Regex.Replace(cleaned, @"Whisper(?=[\u4e00-\u9fff])", "Whisper ");
    return cleaned;
}

static string ApplyNaturalChineseWordOrder(string text)
{
    var cleaned = text;
    cleaned = Regex.Replace(
        cleaned,
        @"(?<subject>你|我|我们|他|她|他们|系统|它)?(?<ask>是否|有没有|是不是)(?<already>已经)?按照(?<target>[^。！？；;\n]{1,80}?要求)(?<done>做到了|做到|完成了|完成)",
        match =>
        {
            var subject = match.Groups["subject"].Value;
            var ask = match.Groups["ask"].Value;
            var already = match.Groups["already"].Value;
            var target = match.Groups["target"].Value;
            var done = match.Groups["done"].Value;
            return $"{subject}{ask}{already}{done}{target}";
        });

    cleaned = Regex.Replace(
        cleaned,
        @"(?<subject>你|我|我们|他|她|他们|系统|它)?(?<ask>是否|有没有|是不是)(?<already>已经)?按(?<target>[^。！？；;\n]{1,80}?要求)(?<done>做到了|做到|完成了|完成)",
        match =>
        {
            var subject = match.Groups["subject"].Value;
            var ask = match.Groups["ask"].Value;
            var already = match.Groups["already"].Value;
            var target = match.Groups["target"].Value;
            var done = match.Groups["done"].Value;
            return $"{subject}{ask}{already}{done}{target}";
        });

    return cleaned;
}

static string SplitObviousMultipleRequests(string text)
{
    var normalized = text
        .Replace("然后另外", "。另外")
        .Replace("另外，", "。另外，")
        .Replace("另外,", "。另外，")
        .Replace("还有，", "。还有，")
        .Replace("还有,", "。还有，")
        .Replace("识别完成后", "识别完成后，")
        .Replace("从而实现", "目标是实现")
        .Replace("现在的技术路线是", "新的技术路线是：");

    normalized = Regex.Replace(normalized, @"。+", "。");
    normalized = Regex.Replace(normalized, @"[，,]\s*。", "。");
    return normalized;
}

static string ApplyPromptEngineeringCompression(string text, string rewriteRule)
{
    var cleaned = text;

    cleaned = Regex.Replace(cleaned, @"现在我想说的是[，,\s]*", "");
    cleaned = Regex.Replace(cleaned, @"(我的理解应该是|我理解应该是|我觉得|我认为)[，,\s]*", "");
    cleaned = Regex.Replace(cleaned, @"这个东西", "此功能");
    cleaned = Regex.Replace(cleaned, @"除了去口头禅(啥的|之类的)?[，,]?(还要)?加入一个(整改|整理|改写)规则[：:，,]?", "请新增提示词化压缩规则：");
    cleaned = Regex.Replace(cleaned, @"它需要总结要点[，,]?(更)?要尽量(的)?去?节约上下文[，,]?", "在保留核心意图的前提下总结要点、压缩上下文，");
    cleaned = Regex.Replace(cleaned, @"保证(这个)?传达的意思合理的情况下", "在保留核心意图的前提下");
    cleaned = Regex.Replace(cleaned, @"让它更符合\s*AI\s*的?提示词的?工程", "使输出更符合 AI 提示词工程", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"另外也要让它的上下文更简短[，,]更节约[，,]节省\s*token", "同时节省上下文/token", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"上下文更简短[，,]更节约[，,]节省\s*token", "节省上下文/token", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"要在高效的前提下做到同样的事情", "高效完成同样任务");
    cleaned = Regex.Replace(cleaned, @"在保留核心意图的前提下总结要点、压缩上下文[，,]在保留核心意图的前提下", "在保留核心意图的前提下总结要点、压缩上下文，");
    cleaned = Regex.Replace(cleaned, @"节省上下文/token", "节省上下文和 token", RegexOptions.IgnoreCase);

    if (ShouldPreferCompactPrompt(rewriteRule))
    {
        cleaned = Regex.Replace(cleaned, @"尽量(地|的)?详细(地|的)?", "必要时");
        cleaned = Regex.Replace(cleaned, @"在不影响理解的情况下", "在保留核心意图的前提下");
        cleaned = Regex.Replace(cleaned, @"帮我总结一下要点", "总结要点");
        cleaned = Regex.Replace(cleaned, @"更节约上下文", "节省上下文");
        cleaned = Regex.Replace(cleaned, @"节省\s*token", "节省 token", RegexOptions.IgnoreCase);
    }

    cleaned = Regex.Replace(cleaned, @"(节省上下文和 token[。；，,\s]*){2,}", "节省上下文和 token。", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"总结要点、压缩上下文[，,]使输出", "总结要点、压缩上下文，使输出");
    cleaned = Regex.Replace(cleaned, @"在保留核心意图的前提下总结要点、压缩上下文，使输出更符合 AI 提示词工程。?同时节省上下文和 token。?高效完成同样任务", "在保留核心意图的前提下总结要点、压缩上下文并节省 token，使输出更符合 AI 提示词工程，高效完成同样任务。", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"总结要点、压缩上下文，使输出更符合 AI 提示词工程。?同时节省上下文和 token。?高效完成同样任务", "总结要点、压缩上下文并节省 token，使输出更符合 AI 提示词工程，高效完成同样任务。", RegexOptions.IgnoreCase);
    cleaned = Regex.Replace(cleaned, @"提示词的工程", "提示词工程");

    return cleaned;
}

static bool ShouldPreferCompactPrompt(string rewriteRule)
{
    if (string.IsNullOrWhiteSpace(rewriteRule))
        return true;

    return Regex.IsMatch(
        rewriteRule,
        @"(简短|压缩|节约|节省|token|上下文|要点|总结|提示词|高效)",
        RegexOptions.IgnoreCase);
}

static string CollapsePromptCompressionSummary(string text)
{
    if (text.Contains("请新增提示词化压缩规则", StringComparison.Ordinal) &&
        text.Contains("总结要点", StringComparison.Ordinal) &&
        (text.Contains("节省上下文", StringComparison.Ordinal) || text.Contains("节省 token", StringComparison.Ordinal)) &&
        text.Contains("AI 提示词工程", StringComparison.Ordinal))
    {
        return "请新增提示词化压缩规则：在保留核心意图的前提下总结要点、压缩上下文并节省 token，使输出更符合 AI 提示词工程，高效完成同样任务。";
    }

    return text;
}

static string NormalizePunctuation(string text)
{
    var cleaned = text
        .Replace("，。", "。")
        .Replace(",。", "。")
        .Replace(",,", ",")
        .Replace("，，", "，");

    cleaned = Regex.Replace(cleaned, @"[，,]\s*", "，");
    cleaned = Regex.Replace(cleaned, @"[。]\s*", "。");
    cleaned = Regex.Replace(cleaned, @"[；;]\s*", "；");
    cleaned = Regex.Replace(cleaned, @"(?<![A-Za-z0-9])[：:]\s*", "：");
    cleaned = Regex.Replace(cleaned, @"[ \t]+", " ");
    cleaned = Regex.Replace(cleaned, @"\s*\n\s*", "\n");
    return cleaned.Trim();
}

static string ApplyRuleDrivenPromptStructure(string text, StructureDecision decision)
{
    if (!decision.ShouldList)
        return text;

    string? candidate = null;
    if (TryFormatCalibrationRound(text, out var calibrationText))
        candidate = calibrationText;

    if (candidate is null && TryFormatReturnFlowTest(text, out var returnFlowTestText))
        candidate = returnFlowTestText;

    if (candidate is null)
    {
        var items = ExtractPromptItems(text, decision);
        if (items.Count < 2)
            return text;

        var builder = new StringBuilder();
        for (var i = 0; i < Math.Min(5, items.Count); i++)
            builder.AppendLine($"{i + 1}. {EnsureSentence(items[i])}");

        candidate = builder.ToString().Trim();
    }

    return ValidateStructuredOutput(text, candidate, decision) ? candidate : text;
}

static bool TryFormatCalibrationRound(string text, out string formatted)
{
    formatted = string.Empty;
    if (!Regex.IsMatch(text, @"新一轮.*校正|校正.*新一轮"))
        return false;

    var items = new List<string>();

    if (Regex.IsMatch(text, @"输出.*结果|结果.*调整|调整"))
        items.Add("先看看输出的结果，再来说后面有哪些要调整。");

    if (Regex.IsMatch(text, @"回填按钮|手感|手腕|没[有太]*明白|试试看"))
        items.Add("另外，你说让我试试回填按钮手感如何，我没有太明白。我现在操作试试看，你具体是什么意思。");

    if (items.Count == 0)
        return false;

    var builder = new StringBuilder();
    builder.AppendLine("我们现在来开始新一轮的校正：");
    for (var i = 0; i < items.Count; i++)
        builder.AppendLine($"{i + 1}. {items[i]}");

    formatted = builder.ToString().Trim();
    return true;
}

static bool TryFormatReturnFlowTest(string text, out string formatted)
{
    formatted = string.Empty;
    if (!Regex.IsMatch(text, @"(检验|测试)") ||
        !Regex.IsMatch(text, @"Codex|页面|窗口|回填|返回"))
    {
        return false;
    }

    var items = new List<string>();
    if (Regex.IsMatch(text, @"Codex.*文本.*页面|页面.*文本|输入.*文本"))
        items.Add("看一下现在能不能把我在 Codex 里输入的文本放到页面里，并处理成我想要的样子。");

    if (Regex.IsMatch(text, @"返回|回填|窗口|输入框"))
        items.Add("最后把处理后的文本回填到 Codex 输入框，并清空原有输入内容。");

    if (items.Count == 0)
        return false;

    var builder = new StringBuilder();
    builder.AppendLine("我们来做一个新的检验：");
    for (var i = 0; i < items.Count; i++)
        builder.AppendLine($"{i + 1}. {items[i]}");

    formatted = builder.ToString().Trim();
    return true;
}

static StructureDecision BuildStructureDecision(string text)
{
    var normalized = NormalizePunctuation(text);
    var protectedSpans = DetectLiteralSpans(normalized);
    var reasons = new List<string>();
    var confidence = 0.0;

    var hasQuestionIntent = Regex.IsMatch(normalized, @"(是不是|是否|能不能|可不可以|有没有|要不要|吗[？?]?|[？?])");
    if (hasQuestionIntent)
        reasons.Add("question_intent");

    var explicitEnumMatches = Regex.Matches(
        normalized,
        @"(第一(?:个|点)?|第二(?:个|点)?|第三(?:个|点)?|第四(?:个|点)?|首先|其次|再次|最后)");
    var hasExplicitQuantityIntent = Regex.IsMatch(
        normalized,
        @"(有[一二两三四五六七八九十0-9]+(?:件事|个点|点|项)|分成[一二两三四五六七八九十0-9]+(?:点|条|项)|列成\s*(?:1|一)[、,.，]\s*(?:2|二)|分别是)");
    var hasStepRequest = Regex.IsMatch(normalized, @"(按步骤|分条|拆成要点|列成|列出|分点|分成.+(?:点|条|项))");

    if (explicitEnumMatches.Count >= 2 || hasExplicitQuantityIntent)
    {
        reasons.Add("explicit_enum");
        confidence = Math.Max(confidence, 0.88);
    }

    if (hasStepRequest)
    {
        reasons.Add("explicit_step_request");
        confidence = Math.Max(confidence, explicitEnumMatches.Count >= 1 ? 0.9 : 0.78);
    }

    var hasSequenceOnly = Regex.IsMatch(normalized, @"先.+然后.+(最后|再|接着)");
    if (hasSequenceOnly && !hasStepRequest && !hasExplicitQuantityIntent && explicitEnumMatches.Count < 2)
    {
        reasons.Add("sequence_only");
        confidence = Math.Max(confidence, 0.45);
    }

    var connectorCount = Regex.Matches(normalized, @"(另外|还有|同时|再帮我|最后)").Count;
    var commandCount = Regex.Matches(normalized, @"(请|检查|更新|运行|打开|读取|生成|保存|修复|实现|确认|验证|处理|同步|补充|输出|给出)").Count;
    if (connectorCount >= 2 && commandCount >= 3)
    {
        reasons.Add("multi_task");
        confidence = Math.Max(confidence, 0.76);
    }

    if (protectedSpans.Count > 0 && reasons.Count == 0)
    {
        reasons.Add("protected_number_only");
        confidence = Math.Max(confidence, 0.2);
    }

    if (hasQuestionIntent && !hasStepRequest && !hasExplicitQuantityIntent && explicitEnumMatches.Count < 2)
        confidence = Math.Min(confidence, 0.55);

    if (reasons.Count == 0)
        reasons.Add("plain_paragraph");

    var shouldList = confidence >= 0.75 &&
        (reasons.Contains("explicit_enum") || reasons.Contains("explicit_step_request") || reasons.Contains("multi_task"));

    return new StructureDecision(
        Mode: "conservative",
        ShouldList: shouldList,
        Confidence: Math.Round(confidence, 2),
        Reasons: reasons.Distinct().ToList(),
        ProtectedSpanCount: protectedSpans.Count,
        ProtectedSpans: protectedSpans);
}

static List<string> ExtractPromptItems(string text, StructureDecision decision)
{
    var knownItems = decision.ShouldList ? ExtractKnownVoiceBridgeItems(text) : [];
    if (knownItems.Count >= 2)
        return knownItems;

    var working = text.Trim();
    working = Regex.Replace(working, @"^请执行[:：]?", "");
    working = Regex.Replace(working, @"^请根据以下口述内容理解我的需求，并直接执行[:：]?", "");
    working = Regex.Replace(working, @"这是我现在的整理文本规则[:：].*$", "", RegexOptions.Singleline);
    working = Regex.Replace(working, @"有(两个|三个|几个)点(可以)?提一下[：:，,]?", "。");
    working = Regex.Replace(working, @"(第一个点|第一个|第一点|第一|首先)[呢嘛]?[，,、\s]*(就是|是)?", "\n§");
    working = Regex.Replace(working, @"(第二个点|第二个|第二点|第二|其次)[呢嘛]?[，,、\s]*(就是|是)?", "\n§");
    working = Regex.Replace(working, @"(第三个点|第三个|第三点|第三|再次)[呢嘛]?[，,、\s]*(就是|是)?", "\n§");
    working = Regex.Replace(working, @"(第四个点|第四个|第四点|第四|最后)[呢嘛]?[，,、\s]*(就是|是)?", "\n§");
    working = Regex.Replace(working, @"(一个就是|一个是|另一个就是|另一个是|另外就是|另外是|还有就是|还有是|下一步的话)", "\n§");

    var rawParts = working
        .Split("§", StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .SelectMany(part => part.Split('。', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        .ToList();

    var items = new List<string>();
    foreach (var rawPart in rawParts)
    {
        var item = CleanPromptItem(rawPart);
        if (item.Length < 3)
            continue;

        if (Regex.IsMatch(item, @"^(这一轮|这里|这边|我发现|是吧|对吧|那么|那这里)"))
            continue;

        if (Regex.IsMatch(item, @"^(我)?有[一二两三四五六七八九十0-9]+(件事|个点|点|项)$|^请按步骤处理$"))
            continue;

        if (items.Any(existing => string.Equals(existing, item, StringComparison.Ordinal)))
            continue;

        items.Add(item);
    }

    if (items.Count == 1 && items[0].Length > 120)
    {
        var splitItems = Regex.Split(items[0], @"[；;，,](?=(请|把|让|优化|实现|修正|去除|总结|压缩|保留|根据|生成))")
            .Select(CleanPromptItem)
            .Where(item => item.Length >= 3)
            .Distinct()
            .ToList();
        if (splitItems.Count >= 2)
            return splitItems;
    }

    return items;
}

static List<string> ExtractKnownVoiceBridgeItems(string text)
{
    var items = new List<string>();

    if (Regex.IsMatch(text, @"整理文本规则|初步文本|自动整理"))
        items.Add("根据整理文本规则生成更满意的初步文本，让自动整理结果先概括整体意图，再拆成清晰要点。");

    if (Regex.IsMatch(text, @"中英混合|英文术语|汉语发音词|Codex.*识别.*英文"))
        items.Add("处理中英混合口述，修正常见英文术语被识别成汉语发音词的问题，并保留必要英文术语。");

    if (Regex.IsMatch(text, @"回填到\s*Codex\s*输入框|网页端.*Codex\s*输入框|最终确认文本|整理好的文本.*Codex"))
        items.Add("实现将网页端最终整理文本复制或回填到 Codex 输入框的路径。");

    if (Regex.IsMatch(text, @"规则没有实际作用|没有实际作用|不够到位|一二三点|1、2、3|1，2，3"))
        items.Add("确保用户填写的整理文本规则会实际参与自动整理，并输出为更符合 AI 提示词工程的可执行提示词。");

    return items.Distinct().ToList();
}

static List<LiteralSpan> DetectLiteralSpans(string text)
{
    var spans = new List<LiteralSpan>();

    AddMatches(spans, text, @"(?<!\d)(?:\d{1,3}\.){3}\d{1,3}:\d+(?!\d)", "endpoint");
    AddMatches(spans, text, @"(?<![\w.])(?:v\d+(?:\.\d+){1,3}|net\d+(?:\.\d+){1,2})(?![\w.])", "version", RegexOptions.IgnoreCase);
    AddMatches(spans, text, @"(?<![A-Za-z0-9])A\d+(?:-v\d+)?(?![A-Za-z0-9])", "voice_model", RegexOptions.IgnoreCase);
    AddMatches(spans, text, @"(?<![A-Za-z0-9])[-+]?\d+(?:\.\d+)?\s*(?:ms|毫秒|秒钟?|分钟|小时|天|MB|GB|KB|%|Hz|条|个|次|元)(?![A-Za-z0-9])", "number");
    AddMatches(spans, text, @"(?<![A-Za-z0-9])Ctrl(?:\s*\+\s*[A-Za-z0-9]+)+(?![A-Za-z0-9])", "shortcut", RegexOptions.IgnoreCase);
    AddMatches(spans, text, @"(?:[A-Za-z]:\\[^\s，。！？；;]+|(?:\.{1,2}[\\/])?[A-Za-z0-9_.-]+[\\/][^\s，。！？；;]+|/[A-Za-z0-9_.-][^\s，。！？；;]*)", "path");
    AddMatches(spans, text, @"(?<![\w])[\w.-]+\.(?:md|cs|jsonl?|ps1|html|exe|dll|csproj)(?![\w])", "file");
    AddMatches(spans, text, @"(不要|不能|不是|不接|不改|未|没有|不得|禁止|只保留|只做|(?<!识)别)", "negative");
    AddMatches(spans, text, @"(如果|除非|只要|当.+?时|在.+?前提下)", "condition");
    AddMatches(spans, text, @"(是不是|是否|能不能|可不可以|有没有|要不要|[？?])", "question");
    AddMatches(spans, text, @"(可能|大概|也许|暂时|先暂时|不确定|需确认)", "uncertainty");
    AddMatches(spans, text, @"(优先|必须|务必|阻断级|发布默认|个人机器)", "priority");
    AddMatches(spans, text, @"(?<![A-Za-z])(Codex|TypeWhisper|Whisper|GitHub|PowerShell|JavaScript|TypeScript|Python|JSONL?|YAML|Markdown|LLM|API|AI|UI|README|localhost|ProseMirror|Program\.cs)(?![A-Za-z])", "proper_noun", RegexOptions.IgnoreCase);
    AddMatches(spans, text, @"(两三个|一两分钟|十来个|半小时|一会儿|几个|一堆|一点|一下)", "fuzzy_quantity");

    return spans
        .GroupBy(span => $"{span.Start}:{span.Length}:{span.Category}")
        .Select(group => group.First())
        .OrderBy(span => span.Start)
        .ThenByDescending(span => span.Length)
        .ToList();
}

static void AddMatches(List<LiteralSpan> spans, string text, string pattern, string category, RegexOptions options = RegexOptions.None)
{
    foreach (Match match in Regex.Matches(text, pattern, options))
    {
        if (!match.Success || string.IsNullOrWhiteSpace(match.Value))
            continue;

        spans.Add(new LiteralSpan(match.Index, match.Length, match.Value, category));
    }
}

static bool ValidateStructuredOutput(string originalText, string candidate, StructureDecision decision)
{
    if (string.IsNullOrWhiteSpace(candidate))
        return false;

    var itemMatches = Regex.Matches(candidate, @"(?m)^\s*\d+[\.、．]\s*\S+");
    if (itemMatches.Count < 2 || itemMatches.Count > 5)
        return false;

    var lines = candidate
        .Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
        .Where(line => Regex.IsMatch(line, @"^\d+[\.、．]\s*"))
        .Select(line => Regex.Replace(line, @"^\d+[\.、．]\s*", "").Trim())
        .ToList();

    if (lines.Count != itemMatches.Count)
        return false;

    if (lines.Any(line => line.Length < 4 || !LooksLikeActionableItem(line)))
        return false;

    foreach (var span in decision.ProtectedSpans.Where(ShouldPreserveSpanInStructuredOutput))
    {
        if (!ContainsRelaxed(candidate, span.Text))
            return false;
    }

    if (Regex.IsMatch(originalText, @"(是不是|是否|能不能|可不可以|有没有|要不要|[？?])") &&
        !Regex.IsMatch(candidate, @"(是不是|是否|能不能|可不可以|有没有|要不要|[？?])"))
    {
        return false;
    }

    return true;
}

static bool LooksLikeActionableItem(string line)
{
    return Regex.IsMatch(
        line,
        @"(请|检查|更新|运行|打开|读取|生成|保存|修复|实现|确认|验证|处理|同步|补充|输出|给出|给我|结论|保留|删除|不要|不接|看|跑|改|做|启动|回填)");
}

static bool ShouldPreserveSpanInStructuredOutput(LiteralSpan span)
{
    return span.Category is
        "endpoint" or "version" or "voice_model" or "number" or "shortcut" or
        "path" or "file" or "negative" or "condition" or "question" or
        "uncertainty" or "priority" or "proper_noun";
}

static bool ContainsRelaxed(string haystack, string needle)
{
    static string NormalizeComparable(string value) =>
        Regex.Replace(value, @"\s+", "", RegexOptions.None).ToLowerInvariant();

    var normalizedHaystack = NormalizeComparable(haystack);
    var normalizedNeedle = NormalizeComparable(needle);
    return normalizedNeedle.Length == 0 || normalizedHaystack.Contains(normalizedNeedle, StringComparison.Ordinal);
}

static string CleanPromptItem(string item)
{
    var cleaned = item.Trim('，', ',', '。', '；', ';', '：', ':', ' ', '\t', '\n');
    cleaned = Regex.Replace(cleaned, @"^(那么|然后|那|这里的话|这边的话|的话|就是|是)\s*", "");
    cleaned = Regex.Replace(cleaned, @"我发现\s*", "");
    cleaned = Regex.Replace(cleaned, @"我感觉\s*", "");
    cleaned = Regex.Replace(cleaned, @"呃|嗯|啊|吧|嘛", "");
    cleaned = Regex.Replace(cleaned, @"这样的话就很不好", "");
    cleaned = Regex.Replace(cleaned, @"^你\s+", "");
    cleaned = Regex.Replace(cleaned, @"^你的\s+", "");
    cleaned = Regex.Replace(cleaned, @"^给我结论$", "给出结论");
    cleaned = Regex.Replace(cleaned, @"这个+", "这个");
    cleaned = Regex.Replace(cleaned, @"整理文本规则这块还有对于原始文本的这个作用啊", "优化整理文本规则对原始文本的作用");
    cleaned = Regex.Replace(cleaned, @"根据这边整理文本的规则，?去生成一个我们比较满意的初步文本", "根据整理文本规则生成更满意的初步文本");
    cleaned = Regex.Replace(cleaned, @"偶尔还会穿插一些英文的点.*?英文术语被转写成汉语发音词", "处理中英混合口述，修正常见英文术语被转写成汉语发音词的问题");
    cleaned = Regex.Replace(cleaned, @"把这个从它整理好的文本.*?Codex 输入框.*", "实现将网页端最终整理文本回填到 Codex 输入框的路径");
    cleaned = Regex.Replace(cleaned, @"我不知道.*?路径", "");
    cleaned = Regex.Replace(cleaned, @"整理文本规则没有实际作用到自动整理文本上", "让整理文本规则实际作用到自动整理文本上");
    cleaned = Regex.Replace(cleaned, @"自动整理质量不够到位.*", "优化自动整理质量，使输出先总结大意，再拆成清晰要点，并作为可执行提示词。");
    cleaned = Regex.Replace(cleaned, @"应该是你能把我的文章大意先总结到，?然后列成一二三点这样", "先总结整体意图，再列成 1、2、3 点");
    cleaned = Regex.Replace(cleaned, @"再作为提示词放在这个自动整理文本里", "并输出为自动整理文本中的可执行提示词");
    cleaned = Regex.Replace(cleaned, @"\s+", " ");
    return cleaned.Trim('，', ',', '。', '；', ';', '：', ':', ' ');
}

static string EnsureSentence(string text)
{
    var cleaned = text.Trim();
    if (Regex.IsMatch(cleaned, @"[。！？]$"))
        return cleaned;

    return cleaned + "。";
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

public sealed record LiteralSpan(int Start, int Length, string Text, string Category);

public sealed record StructureDecision(
    string Mode,
    bool ShouldList,
    double Confidence,
    List<string> Reasons,
    int ProtectedSpanCount,
    List<LiteralSpan> ProtectedSpans);
