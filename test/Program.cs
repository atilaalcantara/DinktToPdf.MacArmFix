using System.Reflection;
using System.Runtime.InteropServices;
using System.Runtime.Loader;
using DinkToPdf;
using DinkToPdf.Contracts;

NativeDependencyResolver.Register();

string outputPath = Path.Combine(AppContext.BaseDirectory, "complex-dinktopdf-arm-test.pdf");
byte[] pdf = PdfGenerator.ConvertHtmlToPdf(HtmlSamples.ComplexInvoiceDashboard(), outputPath);

Console.WriteLine($"PDF gerado com sucesso: {outputPath}");
Console.WriteLine($"Tamanho: {pdf.Length:N0} bytes");

public static class PdfGenerator
{
    private static readonly PdfTools Tools = CreateTools();
    private static readonly IConverter Converter = new BasicConverter(Tools);

    private static PdfTools CreateTools()
    {
        var tools = new PdfTools();
        tools.Load();
        return tools;
    }

    public static byte[] ConvertHtmlToPdf(string html, string? outputPath = null)
    {
        var document = new HtmlToPdfDocument
        {
            GlobalSettings =
            {
                ColorMode = ColorMode.Color,
                Orientation = Orientation.Portrait,
                PaperSize = PaperKind.A4,
                Margins = new MarginSettings
                {
                    Top = 12,
                    Right = 10,
                    Bottom = 14,
                    Left = 10,
                    Unit = Unit.Millimeters
                },
                DocumentTitle = "DinkToPdf ARM64 Shim Test",
                Out = null
            },
            Objects =
            {
                new ObjectSettings
                {
                    HtmlContent = html,
                    WebSettings =
                    {
                        DefaultEncoding = "utf-8",
                        Background = true,
                        LoadImages = true,
                        EnableJavascript = true,
                        PrintMediaType = true
                    },
                    HeaderSettings =
                    {
                        FontName = "Helvetica",
                        FontSize = 8,
                        Left = "DinkToPdf ARM64 shim",
                        Right = "Pagina [page] de [toPage]",
                        Line = true
                    },
                    FooterSettings =
                    {
                        FontName = "Helvetica",
                        FontSize = 7,
                        Center = "Gerado via libwkhtmltox.dylib ARM64 proxy",
                        Line = true
                    }
                }
            }
        };

        byte[] pdf = Converter.Convert(document);

        if (!string.IsNullOrWhiteSpace(outputPath))
        {
            File.WriteAllBytes(outputPath, pdf);
        }

        return pdf;
    }
}

public static class NativeDependencyResolver
{
    public static void Register()
    {
        Assembly dinkAssembly = typeof(PdfTools).Assembly;
        NativeLibrary.SetDllImportResolver(dinkAssembly, ResolveDinkToPdfNativeLibrary);
    }

    private static IntPtr ResolveDinkToPdfNativeLibrary(string libraryName, Assembly assembly, DllImportSearchPath? searchPath)
    {
        if (!libraryName.Contains("libwkhtmltox", StringComparison.OrdinalIgnoreCase) &&
            !libraryName.Contains("wkhtmltox", StringComparison.OrdinalIgnoreCase))
        {
            return IntPtr.Zero;
        }

        string nativePath = Path.Combine(AppContext.BaseDirectory, "runtimes", "osx-arm64", "native", "libwkhtmltox.dylib");
        if (!File.Exists(nativePath))
        {
            nativePath = Path.Combine(AppContext.BaseDirectory, "libwkhtmltox.dylib");
        }

        if (!File.Exists(nativePath))
        {
            throw new FileNotFoundException("libwkhtmltox.dylib ARM64 nao encontrada.", nativePath);
        }

        return NativeLibrary.Load(nativePath, assembly, searchPath);
    }
}

public static class HtmlSamples
{
    public static string ComplexInvoiceDashboard()
    {
        string htmlPath = Path.Combine(AppContext.BaseDirectory, "assets", "complex-invoice-dashboard.html");
        if (!File.Exists(htmlPath))
        {
            throw new FileNotFoundException("Arquivo HTML de exemplo nao encontrado.", htmlPath);
        }

        return File.ReadAllText(htmlPath);
    }
}
