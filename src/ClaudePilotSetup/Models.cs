using System.Text.Json.Serialization;

namespace ClaudePilotSetup;

public sealed class CheckItem
{
    [JsonPropertyName("name")]
    public string Name { get; set; } = string.Empty;

    [JsonPropertyName("status")]
    public string Status { get; set; } = "INFO";

    [JsonPropertyName("detail")]
    public string Detail { get; set; } = string.Empty;

    [JsonPropertyName("blocking")]
    public bool Blocking { get; set; }

    [JsonIgnore]
    public string DisplayStatus => Status.ToUpperInvariant() switch
    {
        "PASS" => "正常",
        "WARN" => "提示",
        "FAIL" => "需处理",
        "INFO" => "信息",
        "MANUAL" => "请确认",
        "READY" => "就绪",
        _ => Status
    };
}

public sealed class ProgressEvent
{
    [JsonPropertyName("timestamp")]
    public string Timestamp { get; set; } = string.Empty;

    [JsonPropertyName("percent")]
    public int Percent { get; set; }

    [JsonPropertyName("level")]
    public string Level { get; set; } = "INFO";

    [JsonPropertyName("message")]
    public string Message { get; set; } = string.Empty;
}

public sealed class EngineResult
{
    [JsonPropertyName("action")]
    public string Action { get; set; } = string.Empty;

    [JsonPropertyName("success")]
    public bool Success { get; set; }

    [JsonPropertyName("exitCode")]
    public int ExitCode { get; set; }

    [JsonPropertyName("summary")]
    public string Summary { get; set; } = string.Empty;

    [JsonPropertyName("dataRoot")]
    public string DataRoot { get; set; } = string.Empty;

    [JsonPropertyName("error")]
    public string Error { get; set; } = string.Empty;

    [JsonPropertyName("reportPath")]
    public string ReportPath { get; set; } = string.Empty;

    [JsonPropertyName("restartRequired")]
    public bool RestartRequired { get; set; }

    [JsonPropertyName("checks")]
    public List<CheckItem> Checks { get; set; } = [];

    [JsonPropertyName("preview")]
    public List<string> Preview { get; set; } = [];
}

public sealed class EngineRunOptions
{
    public required string Action { get; init; }
    public required string DataRoot { get; init; }
    public string ApiKey { get; init; } = string.Empty;
    public bool Elevated { get; init; }
    public string UninstallMode { get; init; } = "PreserveWork";
    public bool RemoveGit { get; init; }
    public bool DisableVmp { get; init; }
    public bool ForceReinstall { get; init; }
    public string UpdatePolicy { get; init; } = "Block";
}

public sealed class LaunchOptions
{
    public bool AutoResume { get; private set; }
    public string EnginePath { get; private set; } = string.Empty;
    public string DataRoot { get; private set; } = string.Empty;

    public static LaunchOptions Parse(string[] args)
    {
        var result = new LaunchOptions();
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i].ToLowerInvariant())
            {
                case "--resume":
                    result.AutoResume = true;
                    break;
                case "--engine" when i + 1 < args.Length:
                    result.EnginePath = args[++i];
                    break;
                case "--data-root" when i + 1 < args.Length:
                    result.DataRoot = args[++i];
                    break;
            }
        }
        return result;
    }
}
