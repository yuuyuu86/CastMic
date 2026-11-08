using Microsoft.Win32;

namespace CastMic;

/// HKCU\Software\CastMic に保存する設定
static class Settings
{
    const string Key = @"Software\CastMic";

    public static bool AllowReverse
    {
        get => Registry.CurrentUser.OpenSubKey(Key)?.GetValue("AllowReverse") is int v && v == 1;
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(Key);
            k.SetValue("AllowReverse", value ? 1 : 0, RegistryValueKind.DWord);
        }
    }
}
