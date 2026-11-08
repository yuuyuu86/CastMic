using System.Drawing.Drawing2D;

namespace CastMic;

/// トレイアイコン: 灰 = 未接続 / 緑 = 接続中 / 赤 = ミュート
static class TrayIcons
{
    public static readonly Icon Idle = Make(Color.Gray);
    public static readonly Icon Live = Make(Color.FromArgb(0x2E, 0xA0, 0x43));
    public static readonly Icon Muted = Make(Color.FromArgb(0xD0, 0x30, 0x30));

    static Icon Make(Color color)
    {
        using var bmp = new Bitmap(32, 32);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            using var b = new SolidBrush(color);
            using var white = new SolidBrush(Color.White);
            g.FillEllipse(b, 1, 1, 30, 30);
            // マイクの形
            g.FillRectangle(white, 12, 6, 8, 13);
            g.FillEllipse(white, 12, 2, 8, 8);
            g.FillEllipse(white, 12, 15, 8, 8);
            using var pen = new Pen(Color.White, 2);
            g.DrawArc(pen, 8, 10, 16, 14, 0, 180);
            g.DrawLine(pen, 16, 24, 16, 28);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }
}
