using System.IO;
using System.Text;
using System.Text.Json;

namespace ClaudePilotSetup;

public static class ConsentManager
{
    public const string NoticeVersion = "R3.5-managed-install-v1";

    private static string ConsentPath => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "ClaudePilotR3",
        "ui-consent.json");

    public static bool IsAccepted()
    {
        try
        {
            if (!File.Exists(ConsentPath)) return false;
            using var document = JsonDocument.Parse(File.ReadAllText(ConsentPath, Encoding.UTF8));
            var root = document.RootElement;
            return root.TryGetProperty("schemaVersion", out var schema) &&
                   schema.GetInt32() == 1 &&
                   root.TryGetProperty("noticeVersion", out var notice) &&
                   string.Equals(notice.GetString(), NoticeVersion, StringComparison.Ordinal);
        }
        catch
        {
            return false;
        }
    }

    public static bool SaveAccepted()
    {
        var path = ConsentPath;
        var parent = Path.GetDirectoryName(path)!;
        var temp = Path.Combine(parent, $".consent-{Guid.NewGuid():N}.tmp");
        try
        {
            Directory.CreateDirectory(parent);
            var payload = new
            {
                schemaVersion = 1,
                noticeVersion = NoticeVersion,
                acceptedAt = DateTimeOffset.Now.ToString("O")
            };
            File.WriteAllText(temp, JsonSerializer.Serialize(payload, new JsonSerializerOptions
            {
                WriteIndented = true
            }) + Environment.NewLine, new UTF8Encoding(false));
            File.Move(temp, path, true);
            return true;
        }
        catch
        {
            return false;
        }
        finally
        {
            try { File.Delete(temp); } catch { }
        }
    }
}
