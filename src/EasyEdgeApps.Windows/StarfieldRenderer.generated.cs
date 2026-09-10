#nullable disable
using System;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Windows.Forms;

namespace EasyEdgeApps.Windows
{
    public sealed class StarfieldRenderer : IDisposable
    {
        private struct Star
        {
            public float Horizontal, Vertical, Depth, Phase, Flux;
            public int Tone, Kernel;
        }

        private readonly Star[] stars = new Star[2200];
        private readonly Color[] tones = { Color.FromArgb(226, 239, 255), Color.FromArgb(107, 183, 239), Color.FromArgb(255, 196, 143) };
        private readonly int[] kernelSizes = { 3, 7, 13, 25, 41 };
        private readonly float[][] kernels = new float[5][];
        private Bitmap image;
        private int[] background, pixels;
        private int width, height;
        private bool disposed;

        public StarfieldRenderer()
        {
            Random random = new Random(67129);
            for (int kernel = 0; kernel < kernels.Length; kernel++) kernels[kernel] = CreateKernel(kernelSizes[kernel], kernel);
            for (int index = 0; index < stars.Length; index++)
            {
                double brightness = random.NextDouble();
                Star star = new Star {
                    Horizontal = (float)random.NextDouble(), Vertical = (float)random.NextDouble(),
                    Depth = (float)random.NextDouble(), Phase = (float)(random.NextDouble() * Math.PI * 2),
                    Tone = random.Next(10) < 6 ? 0 : random.Next(1, 3),
                    Kernel = brightness > 0.994 ? 4 : brightness > 0.97 ? 3 : brightness > 0.86 ? 2 : brightness > 0.52 ? 1 : 0,
                    Flux = (float)(40 + brightness * 180)
                };
                stars[index] = star;
            }
        }

        private static float[] CreateKernel(int size, int level)
        {
            float[] kernel = new float[size * size];
            double center = (size - 1) / 2.0;
            for (int vertical = 0; vertical < size; vertical++)
            {
                for (int horizontal = 0; horizontal < size; horizontal++)
                {
                    double horizontalDistance = horizontal - center;
                    double verticalDistance = vertical - center;
                    double distance = horizontalDistance * horizontalDistance + verticalDistance * verticalDistance;
                    double core = Math.Exp(-distance / (0.42 + level * 0.24));
                    double halo = level == 0 ? 0 : Math.Exp(-distance / (size * size * 0.075)) * (0.055 + level * 0.016);
                    double rays = level < 3 ? 0 : (Math.Exp(-horizontalDistance * horizontalDistance * 3.5) + Math.Exp(-verticalDistance * verticalDistance * 3.5)) * Math.Exp(-Math.Sqrt(distance) / (size * 0.16)) * 0.07;
                    kernel[vertical * size + horizontal] = (float)(core + halo + rays);
                }
            }
            return kernel;
        }

        private void EnsureViewport(Size viewport)
        {
            if (image != null && image.Size == viewport) return;
            Bitmap replacement = new Bitmap(viewport.Width, viewport.Height, PixelFormat.Format32bppPArgb);
            if (image != null) image.Dispose();
            image = replacement;
            width = viewport.Width;
            height = viewport.Height;
            pixels = new int[checked(width * height)];
            background = new int[pixels.Length];
            for (int index = 0; index < background.Length; index++) background[index] = unchecked((int)0xff050709);
        }

        private void AddLight(int horizontal, int vertical, float intensity, Color color)
        {
            if ((uint)horizontal >= (uint)width || (uint)vertical >= (uint)height || intensity < 0.6f) return;
            int offset = vertical * width + horizontal;
            int previous = pixels[offset];
            int red = Math.Min(255, ((previous >> 16) & 255) + (int)(color.R * intensity / 255));
            int green = Math.Min(255, ((previous >> 8) & 255) + (int)(color.G * intensity / 255));
            int blue = Math.Min(255, (previous & 255) + (int)(color.B * intensity / 255));
            pixels[offset] = unchecked((int)0xff000000) | (red << 16) | (green << 8) | blue;
        }

        private void DrawStar(float horizontal, float vertical, Star star, float brightness)
        {
            int size = kernelSizes[star.Kernel];
            float[] kernel = kernels[star.Kernel];
            float left = horizontal - (size - 1) / 2f;
            float top = vertical - (size - 1) / 2f;
            int originHorizontal = (int)Math.Floor(left);
            int originVertical = (int)Math.Floor(top);
            float fractionHorizontal = left - originHorizontal;
            float fractionVertical = top - originVertical;
            float topLeft = (1 - fractionHorizontal) * (1 - fractionVertical);
            float topRight = fractionHorizontal * (1 - fractionVertical);
            float bottomLeft = (1 - fractionHorizontal) * fractionVertical;
            float bottomRight = fractionHorizontal * fractionVertical;
            Color tone = tones[star.Tone];
            for (int row = 0; row < size; row++)
            {
                for (int column = 0; column < size; column++)
                {
                    float intensity = kernel[row * size + column] * brightness;
                    if (intensity < 0.6f) continue;
                    int pixelHorizontal = originHorizontal + column;
                    int pixelVertical = originVertical + row;
                    AddLight(pixelHorizontal, pixelVertical, intensity * topLeft, tone);
                    AddLight(pixelHorizontal + 1, pixelVertical, intensity * topRight, tone);
                    AddLight(pixelHorizontal, pixelVertical + 1, intensity * bottomLeft, tone);
                    AddLight(pixelHorizontal + 1, pixelVertical + 1, intensity * bottomRight, tone);
                }
            }
        }

        public void Render(Graphics graphics, Size viewport, double seconds, PointF pointer, float pointerInfluence)
        {
            if (disposed) throw new ObjectDisposedException("StarfieldRenderer");
            if (viewport.Width < 1 || viewport.Height < 1) return;
            EnsureViewport(viewport);
            Array.Copy(background, pixels, pixels.Length);
            float influence = Math.Max(0, Math.Min(1, pointerInfluence));
            float horizontalShift = (Math.Max(0, Math.Min(1, pointer.X)) - 0.5f) * influence;
            float verticalShift = (Math.Max(0, Math.Min(1, pointer.Y)) - 0.5f) * influence;
            double horizontalSpan = width + 64;
            double verticalSpan = height + 64;
            for (int index = 0; index < stars.Length; index++)
            {
                Star star = stars[index];
                double horizontalDrift = star.Horizontal * horizontalSpan - seconds * (1.6 + star.Depth * 3.2);
                double verticalDrift = star.Vertical * verticalSpan + seconds * (0.48 + star.Depth * 0.96);
                float horizontal = (float)((horizontalDrift % horizontalSpan + horizontalSpan) % horizontalSpan) - 32;
                float vertical = (float)((verticalDrift % verticalSpan + verticalSpan) % verticalSpan) - 32;
                horizontal += horizontalShift * (4 + star.Depth * 14);
                vertical += verticalShift * (4 + star.Depth * 14);
                float shimmer = (float)(0.97 + Math.Sin(seconds * 0.18 + star.Phase) * 0.03);
                DrawStar(horizontal, vertical, star, star.Flux * shimmer);
            }
            BitmapData data = image.LockBits(new Rectangle(Point.Empty, image.Size), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
            try { Marshal.Copy(pixels, 0, data.Scan0, pixels.Length); }
            finally { image.UnlockBits(data); }
            GraphicsState original = graphics.Save();
            try
            {
                graphics.CompositingMode = CompositingMode.SourceCopy;
                graphics.DrawImageUnscaled(image, 0, 0);
            }
            finally { graphics.Restore(original); }
        }

        public void Dispose()
        {
            if (disposed) return;
            disposed = true;
            if (image != null) { image.Dispose(); image = null; }
            background = null;
            pixels = null;
        }
    }

}
