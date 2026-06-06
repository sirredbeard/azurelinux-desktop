using Microsoft.UI.Composition;
using Microsoft.UI.Reactor;
using Microsoft.UI.Reactor.Core;
using Microsoft.UI.Reactor.Hosting;
using Microsoft.UI.Xaml.Hosting;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Numerics;
using static Microsoft.UI.Reactor.Factories;
// WinForms (pulled in for the RDP AxHost) also defines HorizontalAlignment.
// Alias the WinUI ones.
using HorizontalAlignment = Microsoft.UI.Xaml.HorizontalAlignment;
using VerticalAlignment = Microsoft.UI.Xaml.VerticalAlignment;

namespace AzureLinuxDesktop_App;

/// <summary>
/// Windows-style boot screen shown while the wslc container boots and the
/// RDP session connects: black page, the Azure Linux logo (from
/// microsoft/azurelinux) centered, and the Windows boot "waiting circle"
/// underneath. Six dots orbit with a nonuniform sweep so they bunch and
/// spread like the OS boot spinner. The orbit runs as a compositor keyframe
/// animation (starts on mount, loops forever, no managed code per frame).
/// No XAML.
///
/// IMPORTANT: call <see cref="StopSpinner"/> before unmounting this page.
/// Tearing down the hand-built visuals while their forever-animations are
/// live crashes Microsoft.UI.Xaml with a stowed exception (0xc000027b).
/// </summary>
public static class BootPage
{
    private static readonly string LogoPath =
        Path.Combine(AppContext.BaseDirectory, "Assets", "AzureLinuxLogo.png");

    private static Microsoft.UI.Xaml.Controls.Grid? s_spinnerHost;
    private static ContainerVisual? s_container;

    public static Element Build()
    {
        return Border(
            Grid(new[] { GridSize.Star() }, new[] { GridSize.Star() },
                VStack(64,
                    // ImageElement's string source fails silently for local
                    // absolute paths; host a WinUI Image with an explicit
                    // BitmapImage instead (code, not XAML).
                    new XamlHostElement(() => new Microsoft.UI.Xaml.Controls.Image
                    {
                        Source = new BitmapImage(new Uri(LogoPath)),
                        Width = 140,
                        Height = 140,
                    })
                    { TypeKey = "boot-logo" }
                        .HAlign(HorizontalAlignment.Center),
                    new XamlHostElement(CreateBootSpinner) { TypeKey = "boot-spinner" }
                        .HAlign(HorizontalAlignment.Center)
                )
                .HAlign(HorizontalAlignment.Center)
                .VAlign(VerticalAlignment.Center)
            )
        )
        .Background("#000000");
    }

    /// <summary>
    /// Detaches and disposes the spinner's composition visuals so the boot
    /// page can be unmounted safely. Idempotent.
    /// </summary>
    public static void StopSpinner()
    {
        try
        {
            if (s_spinnerHost is not null)
            {
                ElementCompositionPreview.SetElementChildVisual(s_spinnerHost, null!);
            }
            s_container?.Dispose();
        }
        catch
        {
            // Teardown only.
        }
        finally
        {
            s_container = null;
            s_spinnerHost = null;
        }
    }

    /// <summary>
    /// The Windows boot waiting circle as raw composition visuals: each dot
    /// is a ShapeVisual whose Offset runs a looping Vector3 keyframe
    /// animation sampled from an eased sweep. Each dot runs the same sweep
    /// lagged in time, so they bunch where the sweep is slow and fan out
    /// where it is fast, like the OS boot spinner.
    /// </summary>
    private static Microsoft.UI.Xaml.FrameworkElement CreateBootSpinner()
    {
        const float side = 56f;       // host square
        const float dotSize = 7f;
        const float orbitRadius = 20f;
        const int dotCount = 6;
        const int samples = 48;       // orbit sampled into linear segments
        const double speedDip = 0.85; // 0 = constant speed; toward 1 = strong slowdown at the top
        const double dotLag = 0.075;  // time lag between successive dots (creates the trail)

        var host = new Microsoft.UI.Xaml.Controls.Grid { Width = side, Height = side };
        host.Loaded += (_, _) =>
        {
            if (s_container is not null && ReferenceEquals(s_spinnerHost, host))
                return;

            var compositor = ElementCompositionPreview.GetElementVisual(host).Compositor;
            var container = compositor.CreateContainerVisual();
            ElementCompositionPreview.SetElementChildVisual(host, container);
            s_spinnerHost = host;
            s_container = container;

            var linear = compositor.CreateLinearEasingFunction();
            var white = compositor.CreateColorBrush(Microsoft.UI.Colors.White);

            for (var i = 0; i < dotCount; i++)
            {
                var circle = compositor.CreateEllipseGeometry();
                circle.Radius = new Vector2(dotSize / 2f);
                circle.Center = new Vector2(dotSize / 2f);
                var shape = compositor.CreateSpriteShape(circle);
                shape.FillBrush = white;

                var dot = compositor.CreateShapeVisual();
                dot.Size = new Vector2(dotSize);
                dot.Shapes.Add(shape);

                var lag = i * dotLag;
                var orbit = compositor.CreateVector3KeyFrameAnimation();
                orbit.Duration = TimeSpan.FromMilliseconds(1900);
                orbit.IterationBehavior = AnimationIterationBehavior.Forever;
                for (var k = 0; k <= samples; k++)
                {
                    var p = (double)k / samples;
                    var u = (p + lag) % 1.0;
                    var sweep = u - speedDip * Math.Sin(2 * Math.PI * u) / (2 * Math.PI);
                    var angle = 2 * Math.PI * sweep;
                    orbit.InsertKeyFrame((float)p, new Vector3(
                        (float)(side / 2f - dotSize / 2f + orbitRadius * Math.Sin(angle)),
                        (float)(side / 2f - dotSize / 2f - orbitRadius * Math.Cos(angle)),
                        0f), linear);
                }
                dot.StartAnimation("Offset", orbit);
                container.Children.InsertAtTop(dot);
            }
        };
        return host;
    }
}
