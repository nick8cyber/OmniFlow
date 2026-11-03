using System.Drawing.Drawing2D;

namespace FreeFlow.UI;

/// <summary>Vector glyphs drawn on demand (no image assets). All painters take the drawing color.</summary>
public static class Icons
{
    /// <summary>API-key glyph (AI Provider page).</summary>
    public static void Key(Graphics g, Rectangle r, Color color)
    {
        using var pen = IconPen(g, r, color, 12f);
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;
        g.DrawEllipse(pen, x + w * 0.06f, y + h * 0.30f, w * 0.40f, h * 0.40f);
        g.DrawLine(pen, x + w * 0.46f, y + h * 0.50f, x + w * 0.94f, y + h * 0.50f);
        g.DrawLine(pen, x + w * 0.72f, y + h * 0.50f, x + w * 0.72f, y + h * 0.70f);
        g.DrawLine(pen, x + w * 0.90f, y + h * 0.50f, x + w * 0.90f, y + h * 0.74f);
    }


    /// <summary>Four-point sparkles (Processing page).</summary>
    public static void Sparkles(Graphics g, Rectangle r, Color color)
    {
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;
        PointF[] star =
        {
            new(x + w * 0.50f, y + h * 0.04f),
            new(x + w * 0.62f, y + h * 0.38f),
            new(x + w * 0.96f, y + h * 0.50f),
            new(x + w * 0.62f, y + h * 0.62f),
            new(x + w * 0.50f, y + h * 0.96f),
            new(x + w * 0.38f, y + h * 0.62f),
            new(x + w * 0.04f, y + h * 0.50f),
            new(x + w * 0.38f, y + h * 0.38f),
        };
        using var brush = new SolidBrush(color);
        g.FillPolygon(brush, star);
        PointF[] small =
        {
            new(x + w * 0.82f, y + h * 0.78f),
            new(x + w * 0.88f, y + h * 0.92f),
            new(x + w * 0.74f, y + h * 0.92f),
        };
        g.FillPolygon(brush, small);
    }


    /// <summary>"Aa" word glyph (Vocabulary page).</summary>
    public static void Letters(Graphics g, Rectangle r, Color color) =>
        TextRenderer.DrawText(g, "Aa", Theme.FontBodySemibold, r, color,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);

    /// <summary>Clock face (History page).</summary>
    public static void Clock(Graphics g, Rectangle r, Color color)
    {
        using var pen = IconPen(g, r, color, 11f);
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;
        g.DrawEllipse(pen, x + w * 0.10f, y + h * 0.10f, w * 0.80f, h * 0.80f);
        g.DrawLine(pen, x + w * 0.50f, y + h * 0.28f, x + w * 0.50f, y + h * 0.52f);
        g.DrawLine(pen, x + w * 0.50f, y + h * 0.52f, x + w * 0.68f, y + h * 0.60f);
    }

    /// <summary>Studio microphone (setup hero and tray icon).</summary>
    public static void Microphone(Graphics g, Rectangle r, Color color)
    {
        float x = r.X, y = r.Y, w = r.Width, h = r.Height;

        var capsule = Rectangle.Round(new RectangleF(x + w * 0.36f, y + h * 0.08f, w * 0.28f, h * 0.42f));
        Theme.FillRounded(g, color, capsule, Math.Max(2, (int)(capsule.Width / 2)));

        using var pen = new Pen(color, Math.Max(1.6f, w / 14f))
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
        g.DrawArc(pen, x + w * 0.22f, y + h * 0.28f, w * 0.56f, h * 0.52f, 15f, 150f);
        g.DrawLine(pen, x + w * 0.50f, y + h * 0.80f, x + w * 0.50f, y + h * 0.90f);
        g.DrawLine(pen, x + w * 0.32f, y + h * 0.90f, x + w * 0.68f, y + h * 0.90f);
    }

    private static Pen IconPen(Graphics g, Rectangle r, Color color, float divisor)
    {
        return new Pen(color, Math.Max(1.4f, Math.Min(r.Width, r.Height) / divisor))
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
        };
    }
}
