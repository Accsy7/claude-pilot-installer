using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Threading;

namespace ClaudePilotSetup;

internal static class WindowAppearance
{
    private const int WmSizing = 0x0214;
    private const int WmDpiChanged = 0x02E0;
    private const int DwmwaUseImmersiveDarkMode = 20;
    private const int DwmwaBorderColor = 34;
    private const int DwmwaCaptionColor = 35;
    private const int DwmwaTextColor = 36;

    private const int WmszLeft = 1;
    private const int WmszRight = 2;
    private const int WmszTop = 3;
    private const int WmszTopLeft = 4;
    private const int WmszTopRight = 5;
    private const int WmszBottom = 6;
    private const int WmszBottomLeft = 7;
    private const int WmszBottomRight = 8;

    private const uint MonitorDefaultToNearest = 0x00000002;
    private const uint SwpNoZOrder = 0x0004;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpNoOwnerZOrder = 0x0200;
    private const int WorkAreaSafetyPixels = 24;

    public static void Attach(Window window, double? aspectRatio = null)
    {
        window.SourceInitialized += (_, _) =>
        {
            var helper = new WindowInteropHelper(window);
            ApplyTitleBar(helper.Handle);

            if (aspectRatio is not > 0) return;
            var source = HwndSource.FromHwnd(helper.Handle);
            if (source is null) return;

            HwndSourceHook hook = (IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) =>
                WindowProc(window, aspectRatio.Value, message, wParam, lParam, ref handled);
            source.AddHook(hook);
            window.Closed += (_, _) =>
            {
                try { source.RemoveHook(hook); } catch (InvalidOperationException) { }
            };
        };
    }

    public static void AttachFixedPhysicalSize(Window window, int physicalWidth, int physicalHeight)
    {
        if (physicalWidth <= 0) throw new ArgumentOutOfRangeException(nameof(physicalWidth));
        if (physicalHeight <= 0) throw new ArgumentOutOfRangeException(nameof(physicalHeight));

        window.SourceInitialized += (_, _) =>
        {
            var helper = new WindowInteropHelper(window);
            var hwnd = helper.Handle;
            ApplyTitleBar(hwnd);
            ApplyFixedPhysicalBounds(hwnd, physicalWidth, physicalHeight);

            var source = HwndSource.FromHwnd(hwnd);
            if (source is null) return;

            HwndSourceHook hook = (IntPtr hookHwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled) =>
            {
                if (message == WmDpiChanged)
                {
                    _ = window.Dispatcher.BeginInvoke(
                        DispatcherPriority.Loaded,
                        new Action(() => ApplyFixedPhysicalBounds(hwnd, physicalWidth, physicalHeight)));
                }
                return IntPtr.Zero;
            };

            source.AddHook(hook);
            window.Loaded += (_, _) => ApplyFixedPhysicalBounds(hwnd, physicalWidth, physicalHeight);
            window.Closed += (_, _) =>
            {
                try { source.RemoveHook(hook); } catch (InvalidOperationException) { }
            };
        };
    }

    private static void ApplyFixedPhysicalBounds(IntPtr hwnd, int physicalWidth, int physicalHeight)
    {
        if (hwnd == IntPtr.Zero) return;

        var targetWidth = physicalWidth;
        var targetHeight = physicalHeight;
        var x = 0;
        var y = 0;
        var flags = SwpNoZOrder | SwpNoActivate | SwpNoOwnerZOrder;

        var monitor = MonitorFromWindow(hwnd, MonitorDefaultToNearest);
        var monitorInfo = new NativeMonitorInfo { Size = Marshal.SizeOf<NativeMonitorInfo>() };
        if (monitor != IntPtr.Zero && GetMonitorInfo(monitor, ref monitorInfo))
        {
            var workWidth = Math.Max(1, monitorInfo.Work.Right - monitorInfo.Work.Left);
            var workHeight = Math.Max(1, monitorInfo.Work.Bottom - monitorInfo.Work.Top);
            var fitScale = Math.Min(
                1.0,
                Math.Min(
                    Math.Max(1, workWidth - WorkAreaSafetyPixels) / (double)physicalWidth,
                    Math.Max(1, workHeight - WorkAreaSafetyPixels) / (double)physicalHeight));

            targetWidth = Math.Max(1, (int)Math.Floor(physicalWidth * fitScale));
            targetHeight = Math.Max(1, (int)Math.Floor(physicalHeight * fitScale));

            if (GetWindowRect(hwnd, out var current))
            {
                var centerX = current.Left + ((current.Right - current.Left) / 2);
                var centerY = current.Top + ((current.Bottom - current.Top) / 2);
                x = centerX - (targetWidth / 2);
                y = centerY - (targetHeight / 2);
            }
            else
            {
                x = monitorInfo.Work.Left + ((workWidth - targetWidth) / 2);
                y = monitorInfo.Work.Top + ((workHeight - targetHeight) / 2);
            }

            x = Math.Clamp(x, monitorInfo.Work.Left, monitorInfo.Work.Right - targetWidth);
            y = Math.Clamp(y, monitorInfo.Work.Top, monitorInfo.Work.Bottom - targetHeight);
        }
        else
        {
            flags |= 0x0002; // SWP_NOMOVE
        }

        _ = SetWindowPos(hwnd, IntPtr.Zero, x, y, targetWidth, targetHeight, flags);
    }

    private static void ApplyTitleBar(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;

        var lightMode = 0;
        var canvas = ToColorRef(0xF0, 0xEE, 0xE6);
        var ink = ToColorRef(0x2D, 0x29, 0x26);
        var border = ToColorRef(0xE2, 0xDA, 0xD4);

        _ = DwmSetWindowAttribute(hwnd, DwmwaUseImmersiveDarkMode, ref lightMode, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, DwmwaCaptionColor, ref canvas, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, DwmwaTextColor, ref ink, sizeof(int));
        _ = DwmSetWindowAttribute(hwnd, DwmwaBorderColor, ref border, sizeof(int));
    }

    private static IntPtr WindowProc(
        Window window,
        double aspectRatio,
        int message,
        IntPtr wParam,
        IntPtr lParam,
        ref bool handled)
    {
        if (message != WmSizing || lParam == IntPtr.Zero) return IntPtr.Zero;

        var edge = wParam.ToInt32();
        if (edge is < WmszLeft or > WmszBottomRight) return IntPtr.Zero;

        var rect = Marshal.PtrToStructure<NativeRect>(lParam);
        var width = Math.Max(1, rect.Right - rect.Left);
        var height = Math.Max(1, rect.Bottom - rect.Top);
        var dpi = VisualTreeHelper.GetDpi(window);
        var minimumWidth = (int)Math.Ceiling(window.MinWidth * dpi.DpiScaleX);
        var minimumHeight = (int)Math.Ceiling(window.MinHeight * dpi.DpiScaleY);
        var heightDriven = edge is WmszTop or WmszBottom;

        if (heightDriven)
        {
            height = Math.Max(height, minimumHeight);
            width = (int)Math.Round(height * aspectRatio);
            if (width < minimumWidth)
            {
                width = minimumWidth;
                height = (int)Math.Round(width / aspectRatio);
            }
        }
        else
        {
            width = Math.Max(width, minimumWidth);
            height = (int)Math.Round(width / aspectRatio);
            if (height < minimumHeight)
            {
                height = minimumHeight;
                width = (int)Math.Round(height * aspectRatio);
            }
        }

        if (edge is WmszLeft or WmszTopLeft or WmszBottomLeft)
            rect.Left = rect.Right - width;
        else
            rect.Right = rect.Left + width;

        if (edge is WmszTop or WmszTopLeft or WmszTopRight)
            rect.Top = rect.Bottom - height;
        else
            rect.Bottom = rect.Top + height;

        Marshal.StructureToPtr(rect, lParam, false);
        handled = true;
        return new IntPtr(1);
    }

    private static int ToColorRef(byte red, byte green, byte blue) =>
        red | (green << 8) | (blue << 16);

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(
        IntPtr hwnd,
        int attribute,
        ref int attributeValue,
        int attributeSize);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowPos(
        IntPtr hwnd,
        IntPtr hwndInsertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);

    [DllImport("user32.dll")]
    private static extern IntPtr MonitorFromWindow(IntPtr hwnd, uint flags);

    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetMonitorInfo(IntPtr monitor, ref NativeMonitorInfo monitorInfo);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetWindowRect(IntPtr hwnd, out NativeRect rect);

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    private struct NativeMonitorInfo
    {
        public int Size;
        public NativeRect Monitor;
        public NativeRect Work;
        public uint Flags;
    }
}
