namespace CastMic;

static class Program
{
    [STAThread]
    static int Main(string[] args)
    {
        // インストーラーから (管理者で) 呼ばれる
        if (args.Length >= 1 && args[0] is "--install-driver" or "--remove-driver")
        {
            try
            {
                if (args[0] == "--install-driver") return DriverInstaller.Install(args.Length > 1 ? args[1] : "CastMicAudio.inf");
                DriverInstaller.Remove();
                return 0;
            }
            catch (System.ComponentModel.Win32Exception ex)
            {
                File.AppendAllText(Path.Combine(Path.GetTempPath(), "castmic-install.log"), $"{DateTime.Now:s} {args[0]}: {ex.NativeErrorCode:X} {ex.Message}\r\n");
                return 1;
            }
        }

        // 二重起動防止 (ポートとホットキーが衝突するため)
        using var mutex = new Mutex(true, @"Local\CastMic.Windows", out var first);
        if (!first) return 0;

        ApplicationConfiguration.Initialize();
        Application.Run(new MainForm());
        return 0;
    }
}
