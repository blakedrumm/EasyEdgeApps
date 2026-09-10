using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using global::Windows.Foundation;

namespace EasyEdgeApps.Manager;

public sealed class FlowPanel : Panel
{
    public double Spacing { get; set; } = 8;

    protected override Size MeasureOverride(Size availableSize)
    {
        double horizontal = 0, vertical = 0, rowHeight = 0, width = 0;
        foreach (var child in Children.Where(child => child.Visibility == Visibility.Visible))
        {
            child.Measure(new(availableSize.Width, double.PositiveInfinity));
            var desired = child.DesiredSize;
            if (horizontal > 0 && horizontal + desired.Width > availableSize.Width)
            { vertical += rowHeight + Spacing; horizontal = 0; rowHeight = 0; }
            width = Math.Max(width, horizontal + desired.Width);
            horizontal += desired.Width + Spacing;
            rowHeight = Math.Max(rowHeight, desired.Height);
        }
        return new(width, vertical + rowHeight);
    }

    protected override Size ArrangeOverride(Size finalSize)
    {
        double horizontal = 0, vertical = 0, rowHeight = 0;
        foreach (var child in Children.Where(child => child.Visibility == Visibility.Visible))
        {
            var desired = child.DesiredSize;
            var width = Math.Min(finalSize.Width, desired.Width);
            if (horizontal > 0 && horizontal + width > finalSize.Width)
            { vertical += rowHeight + Spacing; horizontal = 0; rowHeight = 0; }
            child.Arrange(new(horizontal, vertical, width, desired.Height));
            horizontal += width + Spacing;
            rowHeight = Math.Max(rowHeight, desired.Height);
        }
        return finalSize;
    }
}