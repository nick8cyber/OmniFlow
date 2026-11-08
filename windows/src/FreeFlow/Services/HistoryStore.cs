using System.IO;
using System.Text.Json;
using FreeFlow.Core;

namespace FreeFlow.Services;

public sealed record HistoryEntry(
    DateTime Timestamp,
    string AppName,
    string RawTranscript,
    string FinalText,
    string Status,
    string ProviderUsed);

/// <summary>Local pipeline history (last 20 entries, text only — audio is never stored).</summary>
public sealed class HistoryStore
{
    private const int MaxEntries = 20;

    // R7: Append does read-modify-write; two concurrent appends (e.g. a session
    // finishing while the user retries from the tray) raced the tmp-file move and
    // lost entries. All file operations serialize on this lock.
    private static readonly object FileLock = new();

    private static string FilePath => Path.Combine(SettingsStore.DirectoryPath, "history.json");

    public List<HistoryEntry> Load()
    {
        lock (FileLock)
        {
            try
            {
                if (!File.Exists(FilePath)) return [];
                var json = File.ReadAllText(FilePath);
                return JsonSerializer.Deserialize<List<HistoryEntry>>(json, JsonOpts.Serializer) ?? [];
            }
            catch (Exception)
            {
                return [];
            }
        }
    }

    public void Append(HistoryEntry entry)
    {
        lock (FileLock)
        {
            try
            {
                var entries = LoadUnlocked();
                entries.Insert(0, entry);
                if (entries.Count > MaxEntries) entries = entries.Take(MaxEntries).ToList();
                Directory.CreateDirectory(SettingsStore.DirectoryPath);
                var tempPath = FilePath + ".tmp";
                File.WriteAllText(tempPath, JsonSerializer.Serialize(entries, JsonOpts.Serializer));
                File.Move(tempPath, FilePath, overwrite: true);
            }
            catch (Exception)
            {
                // History is best-effort and must never break dictation.
            }
        }
    }

    public void Clear()
    {
        lock (FileLock)
        {
            try
            {
                if (File.Exists(FilePath)) File.Delete(FilePath);
            }
            catch (Exception)
            {
            }
        }
    }

    private List<HistoryEntry> LoadUnlocked()
    {
        try
        {
            if (!File.Exists(FilePath)) return [];
            var json = File.ReadAllText(FilePath);
            return JsonSerializer.Deserialize<List<HistoryEntry>>(json, JsonOpts.Serializer) ?? [];
        }
        catch (Exception)
        {
            return [];
        }
    }
}
