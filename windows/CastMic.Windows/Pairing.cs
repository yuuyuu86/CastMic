using System.Security.Cryptography;
using System.Text;

namespace CastMic;

/// 6 桁のペアリングコード。%APPDATA%\CastMic\pairing.txt に保存 (現在のユーザーのみ読み書き可能な場所)
public static class Pairing
{
    static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "CastMic");
    static readonly string FilePath = Path.Combine(Dir, "pairing.txt");

    public static string Load()
    {
        try
        {
            var s = File.ReadAllText(FilePath).Trim();
            if (s.Length == 6 && s.All(char.IsAsciiDigit)) return s;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return Regenerate();
    }

    public static string Regenerate()
    {
        var code = RandomNumberGenerator.GetInt32(0, 1_000_000).ToString("D6");
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, code);
        return code;
    }

    public static bool Matches(string expected, string? given) =>
        given != null && CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(expected), Encoding.ASCII.GetBytes(given));
}
