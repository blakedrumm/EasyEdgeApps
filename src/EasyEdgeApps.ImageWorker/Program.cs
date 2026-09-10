using EasyEdgeApps.Windows;

try
{
    if (args.Length != 1) return 3;
    using var input = Console.OpenStandardInput();
    using var buffer = new MemoryStream();
    var chunk = new byte[32768];
    int count;
    while ((count = input.Read(chunk)) != 0)
    {
        if (buffer.Length + count > IconService.MaximumInputBytes) return 3;
        buffer.Write(chunk, 0, count);
    }
    var icon = IconService.Convert(buffer.ToArray(), args[0]);
    using var output = Console.OpenStandardOutput();
    output.Write(icon);
    output.Flush();
    return 0;
}
catch { return 3; }