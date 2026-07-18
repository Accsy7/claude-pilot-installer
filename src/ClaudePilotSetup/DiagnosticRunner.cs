using System.Diagnostics;
using System.IO;
using System.Security.Principal;
using System.Text;

namespace ClaudePilotSetup;

public sealed class DiagnosticRunner
{
    private readonly string _scriptPath;

    public event Action<int, string>? ProgressChanged;
    public event Action<string>? OutputReceived;

    public DiagnosticRunner(string scriptPath)
    {
        _scriptPath = Path.GetFullPath(scriptPath);
    }

    public async Task ExportAsync(
        string dataRoot,
        string packageRoot,
        string outputPath,
        string currentSessionLog,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(_scriptPath))
            throw new FileNotFoundException("找不到脱敏诊断模块。", _scriptPath);

        var transientRoot = Path.Combine(Path.GetTempPath(), "ClaudePilotR3");
        Directory.CreateDirectory(transientRoot);
        var sessionLogPath = Path.Combine(transientRoot, $"diagnostic-session-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(
            sessionLogPath,
            currentSessionLog ?? string.Empty,
            new UTF8Encoding(false),
            cancellationToken);

        try
        {
            var powerShell = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.Windows),
                "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
            var startInfo = new ProcessStartInfo
            {
                FileName = powerShell,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                StandardOutputEncoding = new UTF8Encoding(false),
                StandardErrorEncoding = new UTF8Encoding(false)
            };
            foreach (var argument in new[]
            {
                "-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
                "-WindowStyle", "Hidden", "-File", _scriptPath,
                "-DataRoot", Path.GetFullPath(dataRoot),
                "-PackageRoot", Path.GetFullPath(packageRoot),
                "-OutputPath", Path.GetFullPath(outputPath),
                "-SessionLogPath", sessionLogPath,
                "-ExpectedUserSid", WindowsIdentity.GetCurrent().User?.Value ?? string.Empty
            })
            {
                startInfo.ArgumentList.Add(argument);
            }

            using var process = new Process { StartInfo = startInfo };
            process.OutputDataReceived += (_, e) =>
            {
                if (string.IsNullOrWhiteSpace(e.Data)) return;
                if (TryParseProgress(e.Data, out var percent, out var message))
                    ProgressChanged?.Invoke(percent, message);
                else
                    OutputReceived?.Invoke(e.Data);
            };
            var errors = new StringBuilder();
            process.ErrorDataReceived += (_, e) =>
            {
                if (!string.IsNullOrWhiteSpace(e.Data)) errors.AppendLine(e.Data);
            };

            if (!process.Start()) throw new InvalidOperationException("无法启动脱敏诊断模块。");
            process.BeginOutputReadLine();
            process.BeginErrorReadLine();
            await process.WaitForExitAsync(cancellationToken);
            if (process.ExitCode != 0)
            {
                var detail = errors.ToString().Trim();
                throw new InvalidOperationException(string.IsNullOrWhiteSpace(detail)
                    ? $"诊断模块退出代码：{process.ExitCode}"
                    : detail);
            }
            if (!File.Exists(outputPath))
                throw new InvalidDataException("诊断模块已退出，但没有生成目标 ZIP。");
        }
        finally
        {
            try { File.Delete(sessionLogPath); } catch { }
        }
    }

    private static bool TryParseProgress(string line, out int percent, out string message)
    {
        percent = 0;
        message = string.Empty;
        var parts = line.Split('|', 3);
        if (parts.Length != 3 || !string.Equals(parts[0], "PROGRESS", StringComparison.Ordinal) ||
            !int.TryParse(parts[1], out percent))
            return false;
        percent = Math.Clamp(percent, 0, 100);
        message = parts[2];
        return true;
    }
}
