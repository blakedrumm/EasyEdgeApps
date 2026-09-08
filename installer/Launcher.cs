using System;
using System.Diagnostics;
using System.IO;
using System.Windows.Forms;

namespace EasyEdgeApps
{
    public static class Launcher
    {
        public static ProcessStartInfo CreateStartInfo(string installDirectory, string windowsDirectory)
        {
            string scriptPath = Path.Combine(Path.GetFullPath(installDirectory), "EasyEdgeApps.ps1");
            string interpreterPath = Path.Combine(Path.GetFullPath(windowsDirectory), @"System32\WindowsPowerShell\v1.0\powershell.exe");
            if (!File.Exists(scriptPath) || !File.Exists(interpreterPath))
                throw new FileNotFoundException("The application or Windows PowerShell could not be found.");
            if (scriptPath.IndexOf('"') >= 0)
                throw new ArgumentException("The application location is invalid.");
            return new ProcessStartInfo
            {
                FileName = interpreterPath,
                Arguments = "-NoLogo -NoProfile -STA -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + scriptPath + "\"",
                WorkingDirectory = Path.GetDirectoryName(scriptPath),
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };
        }

        [STAThread]
        private static int Main()
        {
            Application.EnableVisualStyles();
            try
            {
                ProcessStartInfo startInfo = CreateStartInfo(AppDomain.CurrentDomain.BaseDirectory, Environment.GetFolderPath(Environment.SpecialFolder.Windows));
                using (Process child = Process.Start(startInfo))
                {
                    if (child == null) throw new InvalidOperationException("Windows PowerShell did not start.");
                    child.WaitForExit();
                    if (child.ExitCode == 0) return 0;
                }
            }
            catch (Exception)
            {
            }
            MessageBox.Show("Easy Edge Apps could not start. Ask your helper to repair the installation or run EasyEdgeApps.ps1 in Windows PowerShell to see the error. Your organization's application policies still apply.",
                "Easy Edge Apps", MessageBoxButtons.OK, MessageBoxIcon.Warning);
            return 1;
        }
    }
}