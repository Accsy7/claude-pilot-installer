using System.IO;
using System.Security.Principal;
using System.Text.Json;

namespace ClaudePilotSetup;

public sealed class ComponentOwnershipInfo
{
    public bool Trusted { get; init; }
    public bool GitRemovable { get; init; }
    public bool VmpDisableAllowed { get; init; }
    public string Detail { get; init; } = string.Empty;
}

public static class DeploymentOwnershipReader
{
    public static ComponentOwnershipInfo Read(string requestedDataRoot)
    {
        try
        {
            var dataRoot = Normalize(requestedDataRoot);
            var pointerPath = Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                "ClaudePilotR3",
                "deployment-pointer.json");
            var markerPath = Path.Combine(dataRoot, ".claude-pilot-r3-managed.json");
            var statePath = Path.Combine(dataRoot, "State", "deployment-state.json");

            if (!Directory.Exists(dataRoot) || !File.Exists(pointerPath) ||
                !File.Exists(markerPath) || !File.Exists(statePath))
            {
                return Locked("缺少完整的指针、归属标记或状态文件。");
            }

            if (HasReparsePoint(dataRoot) || HasReparsePoint(markerPath) || HasReparsePoint(statePath))
                return Locked("数据目录或状态文件包含重解析点，不能在界面开放归属组件清理。");

            using var pointerDocument = JsonDocument.Parse(File.ReadAllText(pointerPath));
            using var markerDocument = JsonDocument.Parse(File.ReadAllText(markerPath));
            using var stateDocument = JsonDocument.Parse(File.ReadAllText(statePath));
            var pointer = pointerDocument.RootElement;
            var marker = markerDocument.RootElement;
            var state = stateDocument.RootElement;

            var expectedSid = WindowsIdentity.GetCurrent().User?.Value ?? string.Empty;
            var pointerId = StringValue(pointer, "DeploymentId");
            var markerId = StringValue(marker, "DeploymentId");
            var stateId = StringValue(state, "DeploymentId");
            var stateStorage = Property(state, "Storage");
            var stateDataRoot = stateStorage is { } storage ? StringValue(storage, "DataRoot") : string.Empty;

            var trusted =
                string.Equals(StringValue(pointer, "ManagedBy"), "ClaudePilotR3", StringComparison.Ordinal) &&
                string.Equals(StringValue(marker, "ManagedBy"), "ClaudePilotR3", StringComparison.Ordinal) &&
                !string.IsNullOrWhiteSpace(pointerId) &&
                string.Equals(pointerId, markerId, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(pointerId, stateId, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(StringValue(pointer, "WindowsUserSid"), expectedSid, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(StringValue(marker, "WindowsUserSid"), expectedSid, StringComparison.OrdinalIgnoreCase) &&
                string.Equals(StringValue(state, "WindowsUserSid"), expectedSid, StringComparison.OrdinalIgnoreCase) &&
                SamePath(StringValue(pointer, "DataRoot"), dataRoot) &&
                SamePath(StringValue(marker, "DataRoot"), dataRoot) &&
                SamePath(stateDataRoot, dataRoot);

            if (!trusted) return Locked("归属 ID、当前用户 SID 或数据目录路径不一致。");

            var git = Property(state, "Git");
            var vmp = Property(state, "VirtualMachinePlatform");
            var gitInstalledByPilot = git is { } gitValue && BoolValue(gitValue, "InstalledByPilot");
            var gitPresentBefore = git is { } gitBefore && BoolValue(gitBefore, "PresentBefore");
            var vmpEnabledByPilot = vmp is { } vmpValue && BoolValue(vmpValue, "EnabledByPilot");

            return new ComponentOwnershipInfo
            {
                Trusted = true,
                GitRemovable = gitInstalledByPilot && !gitPresentBefore,
                VmpDisableAllowed = vmpEnabledByPilot,
                Detail = "已验证指针、标记、状态、当前用户和规范化路径一致。"
            };
        }
        catch (Exception ex)
        {
            return Locked($"归属状态读取失败：{ex.Message}");
        }
    }

    private static ComponentOwnershipInfo Locked(string detail) => new()
    {
        Trusted = false,
        GitRemovable = false,
        VmpDisableAllowed = false,
        Detail = detail
    };

    private static bool HasReparsePoint(string path) =>
        (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;

    private static string Normalize(string path) =>
        Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

    private static bool SamePath(string left, string right)
    {
        if (string.IsNullOrWhiteSpace(left) || string.IsNullOrWhiteSpace(right)) return false;
        return string.Equals(Normalize(left), Normalize(right), StringComparison.OrdinalIgnoreCase);
    }

    private static JsonElement? Property(JsonElement element, string name)
    {
        if (element.ValueKind != JsonValueKind.Object) return null;
        foreach (var property in element.EnumerateObject())
            if (string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
                return property.Value;
        return null;
    }

    private static string StringValue(JsonElement element, string name)
    {
        var value = Property(element, name);
        return value is { ValueKind: JsonValueKind.String } ? value.Value.GetString() ?? string.Empty : string.Empty;
    }

    private static bool BoolValue(JsonElement element, string name)
    {
        var value = Property(element, name);
        return value is { ValueKind: JsonValueKind.True } ||
               value is { ValueKind: JsonValueKind.String } &&
               bool.TryParse(value.Value.GetString(), out var parsed) && parsed;
    }
}
