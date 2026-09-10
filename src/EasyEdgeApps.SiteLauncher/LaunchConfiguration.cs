using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Windows.Forms;
using System.Xml;

namespace EasyEdgeApps.SiteLauncher
{
    public sealed class LaunchConfiguration
    {
        public string Id { get; private set; }
        public string Name { get; private set; }
        public string Url { get; private set; }
        public string EdgePath { get; private set; }
        public string EdgeProfile { get; private set; }
        public bool FreshSession { get; private set; }
        public bool DedicatedProfile { get; private set; }
        public bool Taskbar { get; private set; }
        public bool StartMenu { get; private set; }
        public int LaunchMode { get; private set; }
        public bool AlwaysOnTop { get; private set; }
        public string LauncherHash { get; private set; }
        public string Version { get; private set; }

        private static readonly string[] Fields = { "Id", "Name", "Url", "EdgePath", "EdgeProfile", "FreshSession", "DedicatedProfile", "Taskbar", "StartMenu", "LaunchMode", "AlwaysOnTop", "LauncherHash", "Version" };

        public static LaunchConfiguration Read(string directory, bool verifyBinary)
        {
            directory = Path.GetFullPath(directory);
            CheckPath(directory);
            string path = Path.Combine(directory, "eea-launch.xml");
            CheckPath(path);
            Dictionary<string, string> values = new Dictionary<string, string>(StringComparer.Ordinal);
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            {
                if (stream.Length < 2 || stream.Length > 16384) throw new InvalidDataException("Invalid launcher configuration size.");
                XmlReaderSettings settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = 16384, IgnoreWhitespace = true, IgnoreComments = false };
                using (XmlReader reader = XmlReader.Create(stream, settings))
                {
                    reader.MoveToContent();
                    if (reader.Name != "EasyEdgeApps.Launcher" || reader.GetAttribute("SchemaVersion") != "1" || reader.AttributeCount != 1 || reader.IsEmptyElement)
                        throw new InvalidDataException("Unsupported launcher protocol.");
                    reader.ReadStartElement();
                    while (reader.NodeType == XmlNodeType.Element)
                    {
                        string name = reader.Name;
                        if (Array.IndexOf(Fields, name) < 0 || values.ContainsKey(name) || reader.HasAttributes) throw new InvalidDataException("Invalid launcher configuration field.");
                        values.Add(name, reader.ReadElementContentAsString());
                    }
                    reader.ReadEndElement();
                    if (!reader.EOF || values.Count != Fields.Length) throw new InvalidDataException("Incomplete launcher configuration.");
                }
            }
            LaunchConfiguration result = new LaunchConfiguration
            {
                Id = values["Id"], Name = values["Name"], Url = values["Url"], EdgePath = values["EdgePath"], EdgeProfile = values["EdgeProfile"],
                FreshSession = Boolean(values["FreshSession"]), DedicatedProfile = Boolean(values["DedicatedProfile"]), Taskbar = Boolean(values["Taskbar"]),
                StartMenu = Boolean(values["StartMenu"]), AlwaysOnTop = Boolean(values["AlwaysOnTop"]), LauncherHash = values["LauncherHash"], Version = values["Version"]
            };
            if (!Int32.TryParse(values["LaunchMode"], NumberStyles.None, CultureInfo.InvariantCulture, out int mode) || mode < 0 || mode > 2 || values["LaunchMode"] != mode.ToString(CultureInfo.InvariantCulture))
                throw new InvalidDataException("Invalid window mode.");
            result.LaunchMode = mode;
            if (!Regex.IsMatch(result.Id, "\\A[a-f0-9]{64}\\z") || Path.GetFileName(directory) != result.Id ||
                !Regex.IsMatch(result.LauncherHash, "\\A[a-f0-9]{64}\\z") || !Regex.IsMatch(result.Version, "\\A[0-9A-Za-z.+-]{1,64}\\z"))
                throw new InvalidDataException("Launcher identity does not match its permanent directory.");
            if (result.Name.Length < 1 || result.Name.Length > 60 || result.Name != result.Name.Trim().Normalize(NormalizationForm.FormC) ||
                Regex.IsMatch(result.Name, "[<>:\"/\\\\|?*\\p{Cc}\\p{Cf}]") || result.Name.EndsWith(".", StringComparison.Ordinal)) throw new InvalidDataException("Invalid website display name.");
            Uri uri;
            if (result.Url.Length > 2048 || !Regex.IsMatch(result.Url, "\\Ahttps?://", RegexOptions.IgnoreCase) || Regex.IsMatch(result.Url, "[\\s\\p{Cc}\\p{Cf}\"\\\\]") ||
                !Uri.TryCreate(result.Url, UriKind.Absolute, out uri) || uri.UserInfo.Length != 0 || uri.Host.Length == 0 || !uri.IsWellFormedOriginalString()) throw new InvalidDataException("Invalid website address.");
            if (!Regex.IsMatch(result.EdgePath, "\\A[A-Za-z]:\\\\") || Regex.IsMatch(result.EdgePath, "[\"\\p{Cc}\\p{Cf}]") ||
                !String.Equals(Path.GetFileName(result.EdgePath), "msedge.exe", StringComparison.OrdinalIgnoreCase) ||
                !String.Equals(Path.GetFullPath(result.EdgePath), result.EdgePath, StringComparison.OrdinalIgnoreCase))
                throw new InvalidDataException("Invalid Edge executable.");
            CheckPath(result.EdgePath);
            if (!Regex.IsMatch(result.EdgeProfile, "\\A(?:Default|Profile [0-9]{1,6})?\\z")) throw new InvalidDataException("Invalid local profile token.");
            if ((result.Taskbar && (!result.StartMenu || !result.DedicatedProfile)) || (result.AlwaysOnTop && mode == 2) || (!result.FreshSession && !result.DedicatedProfile && (mode == 2 || result.AlwaysOnTop)))
                throw new InvalidDataException("Incompatible owned window settings.");
            if (verifyBinary)
            {
                string binary = Path.Combine(directory, "fresh-session.exe");
                CheckPath(binary);
                using (FileStream stream = new FileStream(binary, FileMode.Open, FileAccess.Read, FileShare.Read))
                using (SHA256 hash = SHA256.Create())
                {
                    if (stream.Length > 256L * 1024 * 1024 || BitConverter.ToString(hash.ComputeHash(stream)).Replace("-", "").ToLowerInvariant() != result.LauncherHash)
                        throw new InvalidDataException("The prebuilt launcher identity changed.");
                }
            }
            return result;
        }

        private static bool Boolean(string value)
        {
            if (value != "true" && value != "false") throw new InvalidDataException("Invalid Boolean configuration value.");
            return value == "true";
        }

        private static void CheckPath(string path)
        {
            if (path.StartsWith("\\\\", StringComparison.Ordinal) || path.IndexOf(':', 2) >= 0) throw new InvalidDataException("Unsupported launcher storage path.");
            for (string current = path; current != null; current = Path.GetDirectoryName(current))
            {
                try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Reparse-point launcher storage is not supported."); }
                catch (FileNotFoundException) { }
                catch (DirectoryNotFoundException) { }
            }
        }
    }

    internal static class Program
    {
        [STAThread]
        private static int Main(string[] arguments)
        {
            try
            {
                LaunchConfiguration configuration = LaunchConfiguration.Read(AppContext.BaseDirectory.TrimEnd(Path.DirectorySeparatorChar), true);
                if (arguments.Length == 1 && arguments[0] == "--health") return 0;
                if (arguments.Length == 1 && (arguments[0] == "--pin" || arguments[0] == "--pin-state") && !configuration.Taskbar) return 4;
                EeaFreshSession.Configure(configuration);
                return EeaFreshSession.RunConfigured(arguments);
            }
            catch
            {
                if (arguments.Length != 0) return 4;
                MessageBox.Show("This website configuration or launcher could not be verified. Open Easy Edge Apps to check it. No browser was started.", "Easy Edge Apps", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return 1;
            }
        }
    }
}

public static partial class EeaFreshSession
{
    private static EasyEdgeApps.SiteLauncher.LaunchConfiguration Configuration;
    private static string LauncherFile { get { return Path.Combine(AppContext.BaseDirectory, "fresh-session.exe"); } }

    public static void Configure(EasyEdgeApps.SiteLauncher.LaunchConfiguration configuration)
    {
        if (Configuration != null) throw new InvalidOperationException("A website launcher cannot change identity while running.");
        Configuration = configuration;
        FreshMode = configuration.FreshSession;
        WindowMode = configuration.LaunchMode;
        AlwaysOnTop = configuration.AlwaysOnTop;
    }

    private static void RunShared(string edge, string website)
    {
        string arguments = "--app=\"" + website + "\"";
        if (Configuration.EdgeProfile.Length != 0) arguments += " --profile-directory=\"" + Configuration.EdgeProfile + "\"";
        if (Configuration.LaunchMode == 1) arguments += " --start-maximized";
        using (Process process = Process.Start(new ProcessStartInfo(edge, arguments) { UseShellExecute = false })) { }
    }
}