using System.IO;
using System.Net.Http;
using System.Text.Json;

namespace OmniFlow.Services;

/// <summary>
/// GitHub-releases updater (macOS UpdateManager parity): checks
/// nick8cyber/omniflow-windows releases/latest for a OmniFlow.exe asset newer than the
/// running build, downloads it and swaps the running exe (current renamed to
/// .old — a running exe cannot be deleted but can be renamed; the .old file is
/// removed on the next start). With no published releases the check reports
/// "up to date" instead of failing.
/// </summary>
public static class Updater
{
    private const string LatestApi =
        "https://api.github.com/repos/nick8cyber/omniflow-windows/releases/latest";

    public sealed record UpdateInfo(string Tag, string AssetUrl);

    public static Version CurrentVersion =>
        System.Reflection.Assembly.GetEntryAssembly()?.GetName().Version ?? new Version(0, 0, 0);

    /// <summary>Update info when the latest release is newer than this build;
    /// null when there are no releases, the asset is missing, or the release is
    /// not newer. Network/auth failures surface as null (caller reports "up to
    /// date" rather than an error — the same fail-soft contract as the mac side).</summary>
    public static async Task<UpdateInfo?> CheckForUpdateAsync(CancellationToken ct)
    {
        try
        {
            using var http = new HttpClient();
            http.DefaultRequestHeaders.UserAgent.ParseAdd("OmniFlow-Updater");
            using var response = await http.GetAsync(LatestApi, ct);
            if (!response.IsSuccessStatusCode) return null; // 404 = no releases yet
            using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
            var root = doc.RootElement;
            var tag = root.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
            if (string.IsNullOrEmpty(tag)) return null;
            if (!TryParseVersion(tag, out var remote) || remote <= CurrentVersion) return null;
            if (!root.TryGetProperty("assets", out var assets) ||
                assets.ValueKind != JsonValueKind.Array) return null;
            foreach (var asset in assets.EnumerateArray())
            {
                var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
                if (!string.Equals(name, "OmniFlow.exe", StringComparison.OrdinalIgnoreCase)) continue;
                var url = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
                if (!string.IsNullOrEmpty(url)) return new UpdateInfo(tag, url);
            }
            return null;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public static async Task DownloadAndReplaceAsync(string assetUrl, CancellationToken ct)
    {
        var exePath = Environment.ProcessPath
            ?? throw new InvalidOperationException("No process path");
        var tempPath = exePath + ".new";
        using (var http = new HttpClient())
        {
            http.DefaultRequestHeaders.UserAgent.ParseAdd("OmniFlow-Updater");
            using var response = await http.GetAsync(assetUrl, HttpCompletionOption.ResponseHeadersRead, ct);
            response.EnsureSuccessStatusCode();
            await using var source = await response.Content.ReadAsStreamAsync(ct);
            await using var target = File.Create(tempPath);
            await source.CopyToAsync(target, ct);
        }
        var oldPath = exePath + ".old";
        File.Delete(oldPath);
        File.Move(exePath, oldPath);
        File.Move(tempPath, exePath);
    }

    /// <summary>Startup cleanup: removes the previous update's swapped-out binary.</summary>
    public static void CleanupOldBinary()
    {
        try
        {
            var exePath = Environment.ProcessPath;
            if (exePath == null) return;
            var oldPath = exePath + ".old";
            if (File.Exists(oldPath)) File.Delete(oldPath);
        }
        catch (Exception)
        {
            // A locked .old file (e.g. antivirus scan) must not block startup.
        }
    }

    private static bool TryParseVersion(string tag, out Version version)
    {
        var trimmed = tag.TrimStart('v', 'V');
        return Version.TryParse(trimmed, out version!);
    }
}
