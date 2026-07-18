using System.IO;
using System.Runtime.InteropServices;
using System.Text;

namespace ClaudePilotSetup;

public static class FolderIconManager
{
    private const uint ShcneUpdateItem = 0x00002000;
    private const uint ShcneAssocChanged = 0x08000000;
    private const uint ShcnfPathW = 0x0005;

    public static string? FindDeliveryRoot()
    {
        try
        {
            var executableDirectory = new DirectoryInfo(
                Path.GetFullPath(AppContext.BaseDirectory).TrimEnd(Path.DirectorySeparatorChar));
            var candidate = string.Equals(executableDirectory.Name, "安装程序", StringComparison.OrdinalIgnoreCase)
                ? executableDirectory.Parent
                : executableDirectory;
            if (candidate is null) return null;
            return Directory.Exists(Path.Combine(candidate.FullName, "资源目录"))
                ? candidate.FullName
                : null;
        }
        catch
        {
            return null;
        }
    }

    public static void TryRepairDeliveryFolderIcon()
    {
        try
        {
            var root = FindDeliveryRoot();
            if (string.IsNullOrWhiteSpace(root)) return;

            var targetIcon = Path.Combine(root, ".ClaudePilotFolder.ico");
            var sourceIcon = Path.Combine(
                root,
                "资源目录",
                "配置",
                "Assets",
                "ClaudePilotBrand",
                "claude-symbol.ico");
            if (!File.Exists(targetIcon))
            {
                if (!File.Exists(sourceIcon)) return;
                File.Copy(sourceIcon, targetIcon, true);
            }

            var desktopIni = Path.Combine(root, "desktop.ini");
            var content =
                "[.ShellClassInfo]\r\n" +
                "IconResource=.ClaudePilotFolder.ico,0\r\n" +
                "IconFile=.ClaudePilotFolder.ico\r\n" +
                "IconIndex=0\r\n" +
                "InfoTip=Claude Pilot R3.5 Managed Offline Deployment\r\n" +
                "[ViewState]\r\n" +
                "Mode=\r\n" +
                "Vid=\r\n" +
                "FolderType=Generic\r\n";
            File.WriteAllText(desktopIni, content, Encoding.Unicode);

            File.SetAttributes(targetIcon, File.GetAttributes(targetIcon) |
                                           FileAttributes.Hidden |
                                           FileAttributes.System);
            File.SetAttributes(desktopIni, File.GetAttributes(desktopIni) |
                                           FileAttributes.Hidden |
                                           FileAttributes.System);
            var directory = new DirectoryInfo(root);
            directory.Attributes |= FileAttributes.ReadOnly;

            ShChangeNotify(ShcneUpdateItem, ShcnfPathW, root, IntPtr.Zero);
            ShChangeNotify(ShcneAssocChanged, 0, null, IntPtr.Zero);
        }
        catch
        {
            // Folder branding is best-effort and must never block deployment.
        }
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern void ShChangeNotify(
        uint eventId,
        uint flags,
        string? item1,
        IntPtr item2);
}
