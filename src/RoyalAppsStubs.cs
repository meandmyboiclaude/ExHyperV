namespace RoyalApps.Community.Rdp.WinForms.Controls
{
    public enum ConnectionState { Disconnected = 0, Connected = 1 }

    public class DisconnectedEventArgs : EventArgs
    {
        public string Description { get; set; }
        public DisconnectedEventArgs(string description) { Description = description; }
    }

    // Minimal stub of the control used by the app to allow compilation when the real package
    // types are not present. These stubs are intentionally lightweight and only provide
    // the members referenced by MsRdpExHost.cs so the project can build.
    public class RdpControl : System.Windows.Forms.Control
    {
        public event EventHandler OnConnected;
        public event EventHandler<DisconnectedEventArgs> OnDisconnected;

        [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
        public RdpClient RdpClient { get; set; }

        [System.ComponentModel.DesignerSerializationVisibility(System.ComponentModel.DesignerSerializationVisibility.Hidden)]
        public RoyalApps.Community.Rdp.WinForms.Configuration.RdpConfiguration RdpConfiguration { get; set; }
        public new IntPtr Handle => base.Handle;

        public RdpControl()
        {
            RdpClient = new RdpClient();
            RdpConfiguration = new RoyalApps.Community.Rdp.WinForms.Configuration.RdpConfiguration();
        }

        public void Connect() { OnConnected?.Invoke(this, EventArgs.Empty); }
        public void Disconnect() { OnDisconnected?.Invoke(this, new DisconnectedEventArgs("Disconnected")); }
    }

    public class RdpClient
    {
        public int DesktopWidth { get; set; }
        public int DesktopHeight { get; set; }
        public ConnectionState ConnectionState { get; set; }
        // The real API exposes some hook-mode fields as integers; mirror that here so
        // callers that check/assign 0/1 work.
        public int KeyboardHookMode { get; set; }

        public void UpdateSessionDisplaySettings(uint a, uint b, uint c, uint d, int e, int f, int g) { }

        // In real implementation this returns an ActiveX OCX; keep as object for the "is" checks in code.
        public object GetOcx() => null;
    }
}

namespace RoyalApps.Community.Rdp.WinForms.Configuration
{
    public enum ColorDepth { ColorDepth24Bpp = 24, ColorDepth32Bpp = 32 }
    public enum ResizeBehavior { Scrollbars = 0, Fit = 1 }

    public class RdpConfiguration
    {
        public InputSettings Input { get; set; } = new InputSettings();
        public HyperVSettings HyperV { get; set; } = new HyperVSettings();
        public DisplaySettings Display { get; set; } = new DisplaySettings();
        public RedirectionSettings Redirection { get; set; } = new RedirectionSettings();
        public PerformanceSettings Performance { get; set; } = new PerformanceSettings();
        public string Server { get; set; } = "";
    }

    public class InputSettings
    {
        public bool KeyboardHookMode { get; set; }
        public bool KeyboardHookToggleShortcutEnabled { get; set; }
        public bool AllowBackgroundInput { get; set; }
        public bool EnableWindowsKey { get; set; }
        public bool GrabFocusOnConnect { get; set; }
    }

    public class HyperVSettings
    {
        public string Instance { get; set; } = "";
        public bool EnhancedSessionMode { get; set; }
    }

    public class DisplaySettings
    {
        public ResizeBehavior ResizeBehavior { get; set; }
        public ColorDepth ColorDepth { get; set; }
        // The real configuration exposes desktop size properties used by the host.
        public int DesktopWidth { get; set; }
        public int DesktopHeight { get; set; }
    }

    public class RedirectionSettings
    {
        public bool RedirectClipboard { get; set; }
    }

    public class PerformanceSettings
    {
        public bool EnableFontSmoothing { get; set; }
        public bool EnableDesktopComposition { get; set; }
    }
}
