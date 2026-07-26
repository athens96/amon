using System.Drawing;
using Forms = System.Windows.Forms;

namespace AMon.WindowsPlatform;

public sealed class NotifyIconTrayService : IDisposable
{
    private readonly Icon _icon;
    private readonly Forms.NotifyIcon _notifyIcon;
    private readonly Forms.ContextMenuStrip _contextMenu;
    private readonly Forms.ToolStripMenuItem _petVisibilityItem;
    private bool _disposed;

    public NotifyIconTrayService(Icon icon)
    {
        ArgumentNullException.ThrowIfNull(icon);

        _icon = (Icon)icon.Clone();
        _contextMenu = new Forms.ContextMenuStrip();
        var dashboardItem = new Forms.ToolStripMenuItem("대시보드 열기");
        dashboardItem.Click += (_, _) => DashboardRequested?.Invoke(this, EventArgs.Empty);

        _petVisibilityItem = new Forms.ToolStripMenuItem("펫 숨기기");
        _petVisibilityItem.Click += (_, _) => PetVisibilityToggleRequested?.Invoke(this, EventArgs.Empty);

        var exitItem = new Forms.ToolStripMenuItem("A-mon 종료");
        exitItem.Click += (_, _) => ExitRequested?.Invoke(this, EventArgs.Empty);

        _contextMenu.Items.AddRange([
            dashboardItem,
            _petVisibilityItem,
            new Forms.ToolStripSeparator(),
            exitItem,
        ]);

        _notifyIcon = new Forms.NotifyIcon
        {
            Icon = _icon,
            Text = "A-mon",
            Visible = true,
            ContextMenuStrip = _contextMenu,
        };
        _notifyIcon.MouseClick += OnMouseClick;
    }

    public event EventHandler? DashboardRequested;

    public event EventHandler? PetVisibilityToggleRequested;

    public event EventHandler? ExitRequested;

    public void SetPetVisible(bool isVisible)
    {
        _petVisibilityItem.Text = isVisible ? "펫 숨기기" : "펫 보이기";
    }

    public void SetToolTip(string value)
    {
        var text = string.IsNullOrWhiteSpace(value) ? "A-mon" : value.Trim();
        _notifyIcon.Text = text.Length <= 63 ? text : text[..63];
    }

    public void ShowQuotaAlert(string provider, string meter, double remainingPercent)
    {
        _notifyIcon.BalloonTipTitle = $"{provider} 할당량 알림";
        _notifyIcon.BalloonTipText =
            $"{meter} 잔여량이 {remainingPercent:0.#}% 남았습니다.";
        _notifyIcon.BalloonTipIcon = Forms.ToolTipIcon.Warning;
        _notifyIcon.ShowBalloonTip(8000);
    }

    public void ShowContextMenu()
    {
        _contextMenu.Show(Forms.Cursor.Position);
    }

    private void OnMouseClick(object? sender, Forms.MouseEventArgs args)
    {
        if (args.Button == Forms.MouseButtons.Left)
        {
            DashboardRequested?.Invoke(this, EventArgs.Empty);
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _notifyIcon.MouseClick -= OnMouseClick;
        _notifyIcon.Visible = false;
        _notifyIcon.Dispose();
        _contextMenu.Dispose();
        _icon.Dispose();
    }
}
