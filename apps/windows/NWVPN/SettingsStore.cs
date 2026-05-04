using System.IO;
using System.Text.Json;

namespace NWVPN;

internal static class SettingsStore
{
    private static string PathFile =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "NWVPN", "settings.json");

    public sealed class Model
    {
        public string Host { get; set; } = "new-world-kr-01.2fish.com.cn";
        public string Port { get; set; } = "8443";
        public string Username { get; set; } = "";
        public string Password { get; set; } = "";
        public bool InsecureTls { get; set; } = true;
        public string? CaCertPath { get; set; }
    }

    public static Model Load()
    {
        try
        {
            var p = PathFile;
            if (!File.Exists(p)) return new Model();
            var json = File.ReadAllText(p);
            return JsonSerializer.Deserialize<Model>(
                       json,
                       new JsonSerializerOptions { PropertyNameCaseInsensitive = true })
                   ?? new Model();
        }
        catch
        {
            return new Model();
        }
    }

    public static void Save(Model m)
    {
        var dir = Path.GetDirectoryName(PathFile);
        if (!string.IsNullOrEmpty(dir)) Directory.CreateDirectory(dir);
        var json = JsonSerializer.Serialize(m, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(PathFile, json);
    }
}
