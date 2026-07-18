using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace ClaudePilotSetup;

public sealed class EngineRunner
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNameCaseInsensitive = true
    };

    private readonly string _enginePath;

    public event Action<ProgressEvent>? ProgressChanged;
    public event Action<string>? OutputReceived;

    public EngineRunner(string enginePath)
    {
        _enginePath = Path.GetFullPath(enginePath);
    }

    public async Task<EngineResult> RunAsync(EngineRunOptions options, CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_enginePath))
        {
            throw new FileNotFoundException("找不到 R3 PowerShell 部署内核。", _enginePath);
        }

        var transientRoot = Path.Combine(Path.GetTempPath(), "ClaudePilotR3");
        Directory.CreateDirectory(transientRoot);
        var runId = Guid.NewGuid().ToString("N");
        var progressPath = Path.Combine(transientRoot, $"progress-{runId}.jsonl");
        var resultPath = Path.Combine(transientRoot, $"result-{runId}.json");
        var ticketPath = string.Empty;
        byte[]? plainBytes = null;
        byte[]? encryptedBytes = null;

        try
        {
            if (!string.IsNullOrWhiteSpace(options.ApiKey))
            {
                ticketPath = Path.Combine(transientRoot, $"key-{runId}.dpapi");
                plainBytes = Encoding.UTF8.GetBytes(options.ApiKey.Trim());
                encryptedBytes = ProtectedData.Protect(plainBytes, null, DataProtectionScope.CurrentUser);
                await File.WriteAllBytesAsync(ticketPath, encryptedBytes, cancellationToken);
            }

            var powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                UseShellExecute = options.Elevated,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = !options.Elevated,
                RedirectStandardError = !options.Elevated,
                StandardOutputEncoding = !options.Elevated ? new UTF8Encoding(false) : null,
                StandardErrorEncoding = !options.Elevated ? new UTF8Encoding(false) : null
            };
            if (options.Elevated)
            {
                startInfo.Verb = "runas";
            }

            Add(startInfo, "-NoLogo");
            Add(startInfo, "-NoProfile");
            Add(startInfo, "-NonInteractive");
            Add(startInfo, "-ExecutionPolicy");
            Add(startInfo, "Bypass");
            Add(startInfo, "-WindowStyle");
            Add(startInfo, "Hidden");
            Add(startInfo, "-File");
            Add(startInfo, _enginePath);
            Add(startInfo, "-Action");
            Add(startInfo, options.Action);
            Add(startInfo, "-DataRoot");
            Add(startInfo, Path.GetFullPath(options.DataRoot));
            Add(startInfo, "-ProgressPath");
            Add(startInfo, progressPath);
            Add(startInfo, "-ResultPath");
            Add(startInfo, resultPath);
            Add(startInfo, "-ExpectedUserSid");
            Add(startInfo, WindowsIdentity.GetCurrent().User?.Value ?? string.Empty);
            Add(startInfo, "-SetupExePath");
            Add(startInfo, Environment.ProcessPath ?? string.Empty);
            Add(startInfo, "-UpdatePolicy");
            Add(startInfo, options.UpdatePolicy);
            if (!string.IsNullOrWhiteSpace(ticketPath))
            {
                Add(startInfo, "-ApiKeyBlobPath");
                Add(startInfo, ticketPath);
            }
            if (options.ForceReinstall) Add(startInfo, "-ForceReinstall");
            if (string.Equals(options.Action, "Uninstall", StringComparison.OrdinalIgnoreCase))
            {
                Add(startInfo, "-UninstallMode");
                Add(startInfo, options.UninstallMode);
                if (options.RemoveGit) Add(startInfo, "-RemoveGit");
                if (options.DisableVmp) Add(startInfo, "-DisableVmp");
            }

            using var process = new Process { StartInfo = startInfo, EnableRaisingEvents = true };
            if (!options.Elevated)
            {
                process.OutputDataReceived += (_, e) =>
                {
                    if (!string.IsNullOrWhiteSpace(e.Data)) OutputReceived?.Invoke(e.Data);
                };
                process.ErrorDataReceived += (_, e) =>
                {
                    if (!string.IsNullOrWhiteSpace(e.Data)) OutputReceived?.Invoke(e.Data);
                };
            }

            try
            {
                if (!process.Start()) throw new InvalidOperationException("无法启动 PowerShell 部署内核。");
            }
            catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
            {
                throw new OperationCanceledException("已取消 Windows 管理员授权；没有执行该操作。", ex);
            }

            if (!options.Elevated)
            {
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
            }

            var processedLines = 0;
            while (!process.HasExited)
            {
                processedLines = ReadProgress(progressPath, processedLines);
                await Task.Delay(250, cancellationToken);
            }
            await process.WaitForExitAsync(cancellationToken);
            processedLines = ReadProgress(progressPath, processedLines);

            for (var attempt = 0; attempt < 20 && !File.Exists(resultPath); attempt++)
            {
                await Task.Delay(100, cancellationToken);
            }
            if (!File.Exists(resultPath))
            {
                return new EngineResult
                {
                    Action = options.Action,
                    Success = false,
                    ExitCode = process.ExitCode,
                    Error = $"部署内核退出代码 {process.ExitCode}，但没有生成结构化结果。"
                };
            }

            var json = await File.ReadAllTextAsync(resultPath, Encoding.UTF8, cancellationToken);
            var result = JsonSerializer.Deserialize<EngineResult>(json, JsonOptions)
                         ?? throw new InvalidDataException("结构化结果为空。");
            return result;
        }
        finally
        {
            if (plainBytes is not null) CryptographicOperations.ZeroMemory(plainBytes);
            if (encryptedBytes is not null) CryptographicOperations.ZeroMemory(encryptedBytes);
            TryDelete(ticketPath);
            TryDelete(progressPath);
            TryDelete(resultPath);
        }
    }

    private int ReadProgress(string progressPath, int processedLines)
    {
        if (!File.Exists(progressPath)) return processedLines;
        string[] lines;
        try
        {
            using var stream = new FileStream(
                progressPath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream, Encoding.UTF8, detectEncodingFromByteOrderMarks: true);
            var collected = new List<string>();
            string? line;
            while ((line = reader.ReadLine()) is not null) collected.Add(line);
            lines = collected.ToArray();
        }
        catch (IOException)
        {
            return processedLines;
        }
        catch (UnauthorizedAccessException)
        {
            return processedLines;
        }

        while (processedLines < lines.Length)
        {
            var line = lines[processedLines];
            try
            {
                var item = JsonSerializer.Deserialize<ProgressEvent>(line, JsonOptions);
                if (item is not null) ProgressChanged?.Invoke(item);
                processedLines++;
            }
            catch (JsonException)
            {
                if (processedLines == lines.Length - 1) break;
                processedLines++;
            }
        }
        return processedLines;
    }

    private static void Add(ProcessStartInfo startInfo, string argument) => startInfo.ArgumentList.Add(argument);

    private static void TryDelete(string path)
    {
        if (string.IsNullOrWhiteSpace(path)) return;
        try { File.Delete(path); } catch { }
    }
}
